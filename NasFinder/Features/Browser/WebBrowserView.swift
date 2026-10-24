import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct BrowserDownloadedFile: Identifiable, Equatable {
    let id = UUID()
    let temporaryURL: URL
    let filename: String
    let contentTypeIdentifier: String?
    /// Started by the explicit "음악 다운로드" action, so it goes to PhoneHard's Music folder.
    var isMusic = false
    var mimeType: String?

    /// 사진·영상 파일이면 영상 여부(true=영상), 그 밖의 파일이면 nil. 이름과 형식 정보만 본다.
    var materialKind: Bool? {
        let type = contentTypeIdentifier.flatMap { UTType($0) }
            ?? mimeType.flatMap { UTType(mimeType: $0) }
            ?? UTType(filenameExtension: (filename as NSString).pathExtension)
        guard let type else { return nil }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return true }
        if type.conforms(to: .image) { return false }
        return nil
    }
}

/// A music file found on the current page. Only its file name is ever shown; the
/// address itself stays inside the web view's own download.
struct BrowserMusicCandidate: Identifiable, Equatable {
    let url: URL
    /// The song title that belongs to this very file (media session, element label or
    /// link text), never one borrowed from another candidate.
    var title: String?
    var isPlaying = false
    var id: String { url.absoluteString }
    /// Same exact file across rescans: the whole address including its query (which can
    /// select the song, e.g. `/stream?id=A`), without the fragment. Never shown or logged.
    var identity: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.fragment = nil
        components.user = nil
        components.password = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        return components.string ?? url.absoluteString
    }
    var displayName: String {
        if let title = BrowserURLPolicy.musicFilenameBase(title) { return title }
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        return name.isEmpty || name == "/" ? (url.host ?? "음악") : name
    }
}

enum BrowserURLPolicy {
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    static func safeFilename(_ suggestedFilename: String, response: URLResponse) -> String {
        let fallback = response.url?.lastPathComponent ?? "download"
        let raw = suggestedFilename.isEmpty ? fallback : suggestedFilename
        let cleaned = raw
            .components(separatedBy: CharacterSet(charactersIn: "/:\\"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "download" : cleaned
    }

    /// A title that is safe to use as a file name: no control or forbidden characters,
    /// no address or signed-query look-alikes, bounded length. `nil` when nothing usable.
    static func musicFilenameBase(_ title: String?) -> String? {
        guard var text = title?.precomposedStringWithCanonicalMapping else { return nil }
        if text.contains("://") || (text.contains("=") && text.contains("&")) { return nil }
        var forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        forbidden.formUnion(.controlCharacters)
        forbidden.formUnion(.illegalCharacters)
        forbidden.formUnion(CharacterSet(charactersIn: "\u{200B}\u{200E}\u{200F}\u{202A}\u{202B}\u{202C}\u{202D}\u{202E}\u{2066}\u{2067}\u{2068}\u{2069}\u{FEFF}"))
        text = text.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
        text = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        var bounded = ""
        for character in text.prefix(100) {
            if bounded.utf8.count + String(character).utf8.count > 220 { break }
            bounded.append(character)
        }
        text = bounded.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
        if text.isEmpty { return nil }
        // Long unbroken alphanumeric runs are tokens or ids, not song names.
        if !text.contains(" "), text.count >= 32,
           text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }) { return nil }
        return text
    }

    static func isAudio(filename: String, mimeType: String?) -> Bool {
        if mimeType?.lowercased().hasPrefix("audio/") == true { return true }
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        return RemoteFileItem.isAudio(filename: filename, contentType: type)
    }

    /// What a browser sends by default: the whole page address to the same origin, only
    /// the origin to another one, and nothing from a secure page to an insecure one.
    static func referer(from page: URL?, to target: URL) -> String? {
        guard let page, let scheme = page.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = page.host,
              !(scheme == "https" && target.scheme?.lowercased() != "https") else { return nil }
        let origin = "\(scheme)://\(host)" + (page.port.map { ":\($0)" } ?? "")
        let sameOrigin = target.scheme?.lowercased() == scheme && target.host == host && target.port == page.port
        guard sameOrigin, var components = URLComponents(url: page, resolvingAgainstBaseURL: false) else {
            return origin + "/"
        }
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? origin + "/"
    }
}

@MainActor
final class NasFinderBrowserSessionStore {
    static let shared = NasFinderBrowserSessionStore()
    static let retentionInterval: TimeInterval = 30 * 60

    private var retainedWebView: WKWebView?
    private var retainedAt: Date?
    private var expirationTask: Task<Void, Never>?

    func retain(_ webView: WKWebView) {
        pausePlayback(in: webView)
        retainedWebView = webView
        retainedAt = Date()
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.retentionInterval))
            self?.clearIfExpired()
        }
    }

    func takeValidWebView() -> WKWebView? {
        guard let retainedAt,
              Date().timeIntervalSince(retainedAt) <= Self.retentionInterval,
              let retainedWebView else {
            clear()
            return nil
        }
        expirationTask?.cancel()
        self.retainedWebView = nil
        self.retainedAt = nil
        return retainedWebView
    }

    func pausePlayback(in webView: WKWebView) {
        webView.evaluateJavaScript(
            "document.querySelectorAll('video,audio').forEach((item) => { try { item.pause(); } catch (_) {} });"
        )
        webView.pauseAllMediaPlayback()
    }

    private func clearIfExpired() {
        guard let retainedAt,
              Date().timeIntervalSince(retainedAt) >= Self.retentionInterval else { return }
        clear()
    }

    private func clear() {
        retainedWebView?.stopLoading()
        retainedWebView = nil
        retainedAt = nil
        expirationTask?.cancel()
        expirationTask = nil
    }
}

struct WebBrowserView: View {
    /// Set only when the trailer editor opened this browser to fetch music: a saved
    /// music file is handed back and the browser closes itself.
    var onMusicSaved: ((SharedInboxRecord) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var favoritesStore: BrowserFavoritesStore
    @Environment(\.trailerProjectSink) private var projectSink

    @FocusState private var isAddressFocused: Bool
    @State private var currentURLText = "https://www.google.com"
    @State private var addressText = "https://www.google.com"
    @State private var requestedURL: URL?
    @State private var canGoBack = false
    @State private var isPageLoading = false
    @State private var pageLoadProgress = 0.0
    @State private var goBackTrigger = 0
    @State private var stopLoadingTrigger = 0
    @State private var reloadTrigger = 0
    @State private var cancelDownloadTrigger = 0
    @State private var isDownloading = false
    @State private var pendingDownload: BrowserDownloadedFile?
    @State private var workbenchRequest: WorkbenchAddRequest?
    @State private var isSaveDialogPresented = false
    @State private var networkUploadFile: BrowserDownloadedFile?
    @State private var lastNetworkUploadFile: BrowserDownloadedFile?
    @State private var didCompleteNetworkUpload = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showFavoritePanel = false
    @State private var showFavoriteEditor = false
    @State private var musicCandidates: [BrowserMusicCandidate] = []
    @State private var musicDownloadTarget: BrowserMusicCandidate?
    @State private var musicDownloadTrigger = 0
    @State private var isChoosingMusicCandidate = false
    @State private var dismissMusicTrigger = 0
    @State private var isMusicNoticeHidden = false
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        VStack(spacing: 0) {
            addressBar

            ZStack(alignment: .top) {
                NasFinderWebView(
                    initialURL: initialURL,
                    currentURLText: $currentURLText,
                    requestedURL: $requestedURL,
                    canGoBack: $canGoBack,
                    isPageLoading: $isPageLoading,
                    pageLoadProgress: $pageLoadProgress,
                    goBackTrigger: $goBackTrigger,
                    stopLoadingTrigger: $stopLoadingTrigger,
                    reloadTrigger: $reloadTrigger,
                    cancelDownloadTrigger: $cancelDownloadTrigger,
                    isDownloading: $isDownloading,
                    musicCandidates: $musicCandidates,
                    musicDownloadTarget: musicDownloadTarget,
                    musicDownloadTrigger: $musicDownloadTrigger,
                    dismissMusicTrigger: $dismissMusicTrigger,
                    onDownloaded: {
                        if $0.isMusic {
                            saveMusicDownload($0)
                        } else {
                            pendingDownload = $0
                            isSaveDialogPresented = true
                        }
                    },
                    onError: { errorMessage = $0 }
                )

                if isDownloading {
                    downloadOverlay
                } else if showFavoritePanel {
                    favoritePanel
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .padding(.horizontal, ui(12))
                        .padding(.vertical, ui(8))
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, ui(10))
                        .onTapGesture { self.statusMessage = nil }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PorcelainMetrics.paper)
        .overlay(alignment: .bottom) {
            if !isDownloading, !isMusicNoticeHidden, !musicCandidates.isEmpty || onMusicSaved != nil {
                musicDownloadBar
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: currentURLText) { _, newValue in
            addressText = newValue
            isMusicNoticeHidden = false
        }
        .onChange(of: musicCandidates) { _, newValue in
            // Dismissed songs are filtered out, so anything listed here is new.
            if !newValue.isEmpty { isMusicNoticeHidden = false }
        }
        .confirmationDialog(
            "어디에 저장할까요?",
            isPresented: $isSaveDialogPresented,
            titleVisibility: .visible
        ) {
            Button("폰하드에 저장") { savePendingDownloadToInbox() }
            if let file = pendingDownload, file.materialKind != nil {
                // 웹에서 받은 파일은 나중에 다시 가리킬 원본 위치가 없으므로, 먼저 폰하드에 저장한 뒤 그 폰하드 파일을 참조한다.
                Button("폰하드에 저장하고 작업대에 담기") { addPendingDownloadToWorkbench(addToProject: false) }
                if projectSink != nil {
                    Button("폰하드에 저장하고 현재 프로젝트에 추가") { addPendingDownloadToWorkbench(addToProject: true) }
                }
            }
            if let file = pendingDownload,
               BrowserURLPolicy.isAudio(filename: file.filename, mimeType: file.mimeType) {
                Button("폰하드 Music 폴더에 저장") { savePendingDownloadToMusic() }
            }
            Button("네트워크 위치 선택") { chooseNetworkDestination() }
            Button("취소", role: .cancel) { cancelPendingDownload() }
        } message: {
            Text(pendingDownload?.filename ?? "다운로드한 파일")
        }
        .sheet(item: $networkUploadFile, onDismiss: networkUploadSheetDidDismiss) { file in
            InboxUploadDestinationView(
                sources: [
                    LocalUploadSource(
                        url: file.temporaryURL,
                        preferredName: file.filename
                    )
                ],
                onUploadCompleted: completeNetworkUpload
            )
        }
        .workbenchAddSheet($workbenchRequest)
        .alert("브라우저 알림", isPresented: errorBinding) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(isPresented: $showFavoriteEditor) {
            BrowserFavoritesEditorView()
                .environmentObject(favoritesStore)
        }
    }

    private var addressBar: some View {
        HStack(spacing: ui(7)) {
            Image(interfaceSystemName: canGoBack ? "chevron.left" : "xmark", pointSize: ui(13))
                .font(.system(size: ui(13), weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.68))
                .frame(width: ui(32), height: ui(32))
                .background(Color.secondary.opacity(0.10), in: Circle())
                .contentShape(Circle())
                .gesture(backOrCloseGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(canGoBack ? "이전 페이지" : "브라우저 닫기")
                .accessibilityHint("길게 누르면 브라우저를 닫습니다.")

            HStack(spacing: ui(4)) {
                TextField("웹 주소 입력", text: $addressText)
                    .focused($isAddressFocused)
                    .font(.system(size: ui(13), weight: .medium))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(loadAddress)

                if isAddressFocused, !addressText.isEmpty {
                    Button {
                        addressText = ""
                    } label: {
                        Image(interfaceSystemName: "xmark.circle.fill", pointSize: ui(14))
                            .font(.system(size: ui(14)))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("주소 모두 지우기")
                }
            }
                .padding(.horizontal, ui(10))
                .frame(height: ui(32))
                .background(.thinMaterial, in: Capsule())

            browserIcon(isPageLoading ? "xmark" : "arrow.right", primary: true)
                .contentShape(Circle())
                .gesture(primaryAddressGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(isPageLoading ? "로딩 중지" : "주소로 이동")
                .accessibilityHint("길게 누르면 복사한 주소를 붙여넣고 이동합니다.")

            Button { reloadTrigger += 1 } label: {
                browserIcon("arrow.clockwise")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("새로고침")

            Image(interfaceSystemName: isCurrentFavorite ? "bookmark.fill" : "bookmark", pointSize: ui(13))
                .font(.system(size: ui(13), weight: .semibold))
                .foregroundStyle(isCurrentFavorite ? SkyBreezeTheme.accent : Color.primary.opacity(0.68))
                .frame(width: ui(32), height: ui(32))
                .background(
                    isCurrentFavorite
                        ? SkyBreezeTheme.accent.opacity(0.12)
                        : Color.secondary.opacity(0.10),
                    in: Circle()
                )
                .contentShape(Circle())
                .gesture(favoriteButtonGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(showFavoritePanel ? "즐겨찾기 목록 닫기" : "즐겨찾기 목록 열기")
                .accessibilityHint("길게 누르면 현재 주소를 즐겨찾기에 추가하거나 해제합니다.")
        }
        .padding(.horizontal, ui(12))
        .padding(.vertical, ui(9))
        .background(.bar)
        .overlay(alignment: .bottom) { pageLoadProgressBar.frame(height: ui(2)) }
    }

    private func browserIcon(_ systemName: String, primary: Bool = false) -> some View {
        Image(interfaceSystemName: systemName, pointSize: ui(13))
            .font(.system(size: ui(13), weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary.opacity(0.68))
            .frame(width: ui(32), height: ui(32))
            .background(primary ? SkyBreezeTheme.accent : Color.secondary.opacity(0.10), in: Circle())
    }

    private var pageLoadProgressBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Color.secondary.opacity(isPageLoading ? 0.14 : 0)
                SkyBreezeTheme.accent
                    .frame(width: proxy.size.width * CGFloat(min(max(pageLoadProgress, 0), 1)))
            }
        }
        .opacity(isPageLoading ? 1 : 0)
        .animation(.easeInOut(duration: 0.18), value: pageLoadProgress)
    }

    private var downloadOverlay: some View {
        HStack(spacing: ui(10)) {
            ProgressView()
            Text("파일을 내려받는 중…")
                .font(.ui(.subheadline))
            Button("취소", role: .cancel) { cancelDownloadTrigger += 1 }
                .font(.ui(.caption))
        }
        .padding(.horizontal, ui(14))
        .padding(.vertical, ui(10))
        .background(.regularMaterial, in: Capsule())
        .padding(.top, ui(10))
    }

    /// Recognizing music on a page only offers this action; nothing is downloaded until
    /// the user taps it.
    private var musicDownloadBar: some View {
        HStack(spacing: ui(8)) {
            Image(interfaceSystemName: "music.note")
            if musicCandidates.isEmpty {
                Text("음악 파일이 있는 페이지를 열면 받을 수 있어요")
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
            } else {
                Button("음악 다운로드") {
                    if musicCandidates.count == 1 || musicCandidates[0].isPlaying {
                        requestMusicDownload(musicCandidates[0])
                    } else {
                        isChoosingMusicCandidate = true
                    }
                }
                .font(.ui(.subheadline).weight(.semibold))
                if musicCandidates.count > 1 {
                    Text("\(musicCandidates.count)개")
                        .font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
            }
            Button(action: closeMusicNotice) {
                Image(interfaceSystemName: "xmark.circle.fill")
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("음악 알림 닫기")
        }
        .padding(.horizontal, ui(14))
        .padding(.vertical, ui(10))
        .background(.regularMaterial, in: Capsule())
        .padding(.bottom, ui(14))
        .confirmationDialog(
            "받을 음악을 선택하세요",
            isPresented: $isChoosingMusicCandidate,
            titleVisibility: .visible
        ) {
            ForEach(musicCandidates.prefix(12)) { candidate in
                Button(candidate.displayName) { requestMusicDownload(candidate) }
            }
            Button("취소", role: .cancel) {}
        }
    }

    /// Hides the notice and forgets the pending choice. A running download is untouched.
    private func closeMusicNotice() {
        isMusicNoticeHidden = true
        isChoosingMusicCandidate = false
        musicDownloadTarget = nil
        dismissMusicTrigger += 1
    }

    private func requestMusicDownload(_ candidate: BrowserMusicCandidate) {
        guard !isDownloading else { return }
        musicDownloadTarget = candidate
        musicDownloadTrigger += 1
    }

    private func savePendingDownloadToMusic() {
        guard let file = pendingDownload else { return }
        pendingDownload = nil
        isSaveDialogPresented = false
        saveMusicDownload(file)
    }

    /// The Music folder takes anything recognized as audio; whether it can really be
    /// decoded is checked when it is picked for a video.
    private func saveMusicDownload(_ file: BrowserDownloadedFile) {
        let jobPrivate = PrivacyMode.currentlyActive
        Task {
            defer { removeTemporaryDownload(file) }
            guard BrowserURLPolicy.isAudio(filename: file.filename, mimeType: file.mimeType) else {
                errorMessage = "받은 파일이 음악 파일이 아니어서 저장하지 않았습니다."
                return
            }
            do {
                let record = try await inboxStore.importMusicFile(
                    at: file.temporaryURL,
                    originalFilename: file.filename,
                    contentTypeIdentifier: file.contentTypeIdentifier,
                    isPrivate: jobPrivate
                )
                if let onMusicSaved {
                    onMusicSaved(record)
                    dismiss()
                } else {
                    statusMessage = "폰하드 Music 폴더에 저장했습니다."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var initialURL: URL {
        favoritesStore.publicFavorites.compactMap(BrowserURLPolicy.normalizedURL).first
            ?? URL(string: "https://www.google.com")!
    }

    private var isCurrentFavorite: Bool { favoritesStore.contains(currentURLText) }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func loadAddress() {
        guard let url = BrowserURLPolicy.normalizedURL(from: addressText) else {
            errorMessage = "올바른 웹 주소를 입력해 주세요."
            return
        }
        requestedURL = url
    }

    private var backOrCloseGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first: dismiss()
                case .second:
                    if canGoBack { goBackTrigger += 1 } else { dismiss() }
                }
            }
    }

    private var primaryAddressGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first: pasteCopiedAddressAndLoad()
                case .second:
                    if isPageLoading { stopLoadingTrigger += 1 } else { loadAddress() }
                }
            }
    }

    private var favoriteButtonGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.5)
            .exclusively(before: TapGesture())
            .onEnded { value in
                switch value {
                case .first: favoritesStore.toggle(currentURLText)
                case .second:
                    withAnimation(.easeInOut(duration: 0.18)) {
                        showFavoritePanel.toggle()
                    }
                }
            }
    }

    private func pasteCopiedAddressAndLoad() {
        addressText = ""
        guard let value = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              BrowserURLPolicy.normalizedURL(from: value) != nil else {
            errorMessage = "클립보드에 이동할 수 있는 웹 주소가 없습니다."
            return
        }
        addressText = value
        loadAddress()
    }

    private var favoritePanel: some View {
        VStack(spacing: 0) {
            HStack {
                Label("즐겨찾기", interfaceSystemImage: "bookmark.fill")
                    .font(.ui(.subheadline).weight(.semibold))
                Spacer()
                Button {
                    showFavoritePanel = false
                    showFavoriteEditor = true
                } label: {
                    Image(interfaceSystemName: "slider.horizontal.3")
                        .frame(width: ui(32), height: ui(32))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("즐겨찾기 편집")
            }
            .padding(.horizontal, ui(14))
            .padding(.vertical, ui(10))

            Divider()

            if favoritesStore.favorites.isEmpty {
                Text("등록된 즐겨찾기가 없습니다.")
                    .font(.ui(.caption))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .padding(ui(24))
            } else {
                ScrollView {
                    LazyVStack(spacing: ui(4)) {
                        ForEach(favoritesStore.favorites, id: \.self) { favorite in
                            favoriteRow(favorite)
                        }
                    }
                    .padding(ui(8))
                }
                .frame(maxHeight: ui(360))
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: ui(10), style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ui(10), style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .padding(.horizontal, ui(12))
        .padding(.top, ui(8))
    }

    private func favoriteRow(_ favorite: String) -> some View {
        HStack(spacing: ui(10)) {
            BrowserFavoriteFavicon(address: favorite)
                .contentShape(Rectangle())
                .onTapGesture { favoritesStore.remove(favorite) }
                .onLongPressGesture(minimumDuration: 0.55) {
                    favoritesStore.makeHomepage(favorite)
                }

            Button {
                showFavoritePanel = false
                if let url = BrowserURLPolicy.normalizedURL(from: favorite) {
                    requestedURL = url
                }
            } label: {
                HStack(spacing: ui(8)) {
                    VStack(alignment: .leading, spacing: ui(2)) {
                        Text(BrowserFavoriteFavicon.displayTitle(for: favorite))
                            .font(.ui(.caption).weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(favorite)
                            .font(.ui(.caption2))
                            .foregroundStyle(PorcelainMetrics.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: ui(4))
                    if favorite == favoritesStore.publicFavorites.first {
                        Image(interfaceSystemName: "house.fill", pointSize: 11)
                            .font(.ui(.caption2).weight(.bold))
                            .foregroundStyle(SkyBreezeTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, ui(8))
        .frame(height: ui(50))
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: ui(8)))
    }

    private func savePendingDownloadToInbox() {
        guard let file = pendingDownload else { return }
        pendingDownload = nil
        isSaveDialogPresented = false
        let jobPrivate = PrivacyMode.currentlyActive
        Task {
            defer { removeTemporaryDownload(file) }
            do {
                try await inboxStore.importDownloadedFile(
                    at: file.temporaryURL,
                    originalFilename: file.filename,
                    contentTypeIdentifier: file.contentTypeIdentifier,
                    isPrivate: jobPrivate
                )
                statusMessage = "폰하드에 저장했습니다."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// 받은 파일이 실제 사진·영상일 때만 다룬다. 웹 다운로드는 임시 파일뿐이라 나중에 다시 가리킬 원본 위치가 없다.
    /// 그래서 사용자가 고른 "폰하드에 저장"으로 먼저 보관한 뒤, 그 폰하드 파일의 위치만 작업대에 참조로 담는다
    /// (작업대가 몰래 복사하지 않는다). 웹 페이지 주소나 스트리밍 주소는 영상으로 만들지 않는다.
    private func addPendingDownloadToWorkbench(addToProject: Bool) {
        guard let file = pendingDownload, file.materialKind != nil else { return }
        pendingDownload = nil
        isSaveDialogPresented = false
        let jobPrivate = PrivacyMode.currentlyActive
        Task {
            defer { removeTemporaryDownload(file) }
            do {
                let record = try await inboxStore.importDownloadedFile(
                    at: file.temporaryURL, originalFilename: file.filename, contentTypeIdentifier: file.contentTypeIdentifier,
                    isPrivate: jobPrivate)
                if addToProject, let sink = projectSink {
                    let remote = LocalInboxFileService.remoteItem(for: record)
                    sink.add([remote], LocalInboxFileService(records: [record]))
                    statusMessage = "폰하드에 저장하고 현재 프로젝트에 추가했습니다."
                } else {
                    let entry = WorkbenchEntryFactory.entry(
                        remote: LocalInboxFileService.browserItem(for: record), sourceLabel: WorkbenchSourceLabel.phoneHard)
                    workbenchRequest = WorkbenchAddRequest(title: "폰하드에 저장한 \(file.filename)", entries: [entry])
                    statusMessage = "폰하드에 저장했습니다."
                }
            } catch {
                errorMessage = "폰하드에 저장하지 못해 작업대에 담지 않았습니다. \(error.localizedDescription)"
            }
        }
    }

    private func chooseNetworkDestination() {
        guard let file = pendingDownload else { return }
        pendingDownload = nil
        isSaveDialogPresented = false
        lastNetworkUploadFile = file
        didCompleteNetworkUpload = false
        networkUploadFile = file
    }

    private func completeNetworkUpload() {
        didCompleteNetworkUpload = true
        if let file = lastNetworkUploadFile {
            removeTemporaryDownload(file)
        }
        statusMessage = "네트워크 위치에 저장했습니다."
        networkUploadFile = nil
        lastNetworkUploadFile = nil
    }

    private func networkUploadSheetDidDismiss() {
        defer {
            lastNetworkUploadFile = nil
            didCompleteNetworkUpload = false
        }
        guard !didCompleteNetworkUpload,
              let file = lastNetworkUploadFile,
              FileManager.default.fileExists(atPath: file.temporaryURL.path) else { return }
        pendingDownload = file
        isSaveDialogPresented = true
    }

    private func cancelPendingDownload() {
        if let file = pendingDownload {
            removeTemporaryDownload(file)
        }
        pendingDownload = nil
        isSaveDialogPresented = false
    }

    private func removeTemporaryDownload(_ file: BrowserDownloadedFile) {
        try? FileManager.default.removeItem(
            at: file.temporaryURL.deletingLastPathComponent()
        )
    }
}

private struct NasFinderWebView: UIViewRepresentable {
    let initialURL: URL
    @Binding var currentURLText: String
    @Binding var requestedURL: URL?
    @Binding var canGoBack: Bool
    @Binding var isPageLoading: Bool
    @Binding var pageLoadProgress: Double
    @Binding var goBackTrigger: Int
    @Binding var stopLoadingTrigger: Int
    @Binding var reloadTrigger: Int
    @Binding var cancelDownloadTrigger: Int
    @Binding var isDownloading: Bool
    @Binding var musicCandidates: [BrowserMusicCandidate]
    let musicDownloadTarget: BrowserMusicCandidate?
    @Binding var musicDownloadTrigger: Int
    @Binding var dismissMusicTrigger: Int
    let onDownloaded: (BrowserDownloadedFile) -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.websiteDataStore = .default()
        let webView = NasFinderBrowserSessionStore.shared.takeValidWebView()
            ?? WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        context.coordinator.attach(to: webView)
        if webView.url == nil {
            webView.load(URLRequest(url: initialURL))
        } else {
            context.coordinator.updateState(from: webView)
            context.coordinator.scheduleMusicScan(in: webView)
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.handleControls(in: webView)
        if let requestedURL, webView.url != requestedURL {
            webView.load(URLRequest(url: requestedURL))
            DispatchQueue.main.async { self.requestedURL = nil }
        }
    }

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.cancelDownload()
        NasFinderBrowserSessionStore.shared.retain(webView)
        coordinator.invalidate()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
        var parent: NasFinderWebView
        private var progressObservation: NSKeyValueObservation?
        private var activeDownload: WKDownload?
        private var destinationURL: URL?
        private var downloadActivityID: UUID?
        private var handledGoBackTrigger = 0
        private var handledStopLoadingTrigger = 0
        private var handledReloadTrigger = 0
        private var handledCancelDownloadTrigger = 0
        private var handledMusicDownloadTrigger = 0
        private var popupReturnURL: URL?
        private var isMusicDownload = false
        private var downloadMIMEType: String?
        private var musicScanTask: Task<Void, Never>?
        /// Audio responses seen as navigations: the one that is about to become the
        /// page itself, and the ones loaded into frames of the current page.
        private var pendingMainFrameMusicURL: URL?
        private var responseMusicURLs: [URL] = []
        private var handledDismissMusicTrigger = 0
        private weak var webView: WKWebView?
        private var musicSignalTask: Task<Void, Never>?
        private var musicSignalProxy: MusicSignalProxy?
        /// Bumped on every committed navigation so late scan results of an old page are dropped.
        private var pageGeneration = 0
        private var scanSequence = 0
        private var scannedMusic: [BrowserMusicCandidate] = []
        private var dismissedMusicKeys = Set<String>()
        private var lastPlayingKey: String?
        private var lastMusicSignalAt: ContinuousClock.Instant?
        /// The candidate and its own title, fixed when the download starts.
        private var musicSnapshot: BrowserMusicCandidate?

        init(parent: NasFinderWebView) { self.parent = parent }

        func attach(to webView: WKWebView) {
            self.webView = webView
            // The page can only ask for a rescan through this handler; it carries no commands.
            let proxy = MusicSignalProxy(coordinator: self)
            musicSignalProxy = proxy
            let controller = webView.configuration.userContentController
            controller.removeScriptMessageHandler(forName: Self.musicSignalName)
            controller.removeAllUserScripts()
            controller.add(proxy, name: Self.musicSignalName)
            controller.addUserScript(WKUserScript(
                source: Self.musicSignalScript,
                injectionTime: .atDocumentStart,
                forMainFrameOnly: true
            ))
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
                [weak self] webView, _ in
                Task { @MainActor in self?.parent.pageLoadProgress = webView.estimatedProgress }
            }
        }

        func invalidate() {
            progressObservation?.invalidate()
            progressObservation = nil
            musicScanTask?.cancel()
            musicScanTask = nil
            musicSignalTask?.cancel()
            musicSignalTask = nil
            if let controller = webView?.configuration.userContentController {
                controller.removeScriptMessageHandler(forName: Self.musicSignalName)
                controller.removeAllUserScripts()
            }
            musicSignalProxy = nil
        }

        static let musicSignalName = "nasFinderMusicSignal"
        private static let musicSignalScript = #"""
        (() => {
          if (window.__nasFinderMusicSignal) return;
          window.__nasFinderMusicSignal = true;
          const handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nasFinderMusicSignal;
          if (!handler) return;
          let timer = 0, kind = 'scan';
          const send = (next) => {
            if (next === 'nav') kind = 'nav';
            if (timer) return;
            timer = setTimeout(() => { timer = 0; const message = kind; kind = 'scan'; try { handler.postMessage(message); } catch (_) {} }, 250);
          };
          ['play', 'playing', 'loadstart', 'emptied', 'loadedmetadata', 'durationchange'].forEach((name) => {
            document.addEventListener(name, (event) => { if (event.target && event.target.tagName === 'AUDIO') send('scan'); }, true);
          });
          ['pushState', 'replaceState'].forEach((name) => {
            const original = history[name];
            history[name] = function () { const result = original.apply(this, arguments); send('nav'); return result; };
          });
          window.addEventListener('popstate', () => send('nav'));
          window.addEventListener('hashchange', () => send('nav'));
        })();
        """#

        /// Only a plain "scan"/"nav" string from the top frame of the current web view
        /// is accepted, and it only schedules a rescan.
        fileprivate func handleMusicSignal(_ message: WKScriptMessage) {
            guard let webView, message.webView === webView, message.frameInfo.isMainFrame,
                  let kind = message.body as? String, kind == "scan" || kind == "nav" else { return }
            if kind == "nav" { responseMusicURLs.removeAll() }
            // Untrusted pages can spam this handler: coalesce bursts before creating a task.
            let now = ContinuousClock.now
            if let last = lastMusicSignalAt, now - last < .milliseconds(250) { return }
            lastMusicSignalAt = now
            musicSignalTask?.cancel()
            musicSignalTask = Task { [weak self, weak webView] in
                for delay in [0.3, 1.5] {
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, let webView else { return }
                    self.scanMusic(in: webView)
                }
            }
        }

        private func musicKey(_ candidate: BrowserMusicCandidate) -> String { candidate.identity }

        /// Hides what is listed now (and keeps it hidden) until a new song or a new page.
        private func dismissCurrentMusic() {
            if lastPlayingKey == nil, let playing = parent.musicCandidates.first(where: { $0.isPlaying }) {
                lastPlayingKey = musicKey(playing)
            }
            dismissedMusicKeys.formUnion(parent.musicCandidates.map(musicKey))
            publishMusicCandidates()
        }

        func handleControls(in webView: WKWebView) {
            if parent.goBackTrigger != handledGoBackTrigger {
                handledGoBackTrigger = parent.goBackTrigger
                if webView.canGoBack { webView.goBack() }
            }
            if parent.stopLoadingTrigger != handledStopLoadingTrigger {
                handledStopLoadingTrigger = parent.stopLoadingTrigger
                webView.stopLoading()
                parent.isPageLoading = false
            }
            if parent.reloadTrigger != handledReloadTrigger {
                handledReloadTrigger = parent.reloadTrigger
                webView.reload()
            }
            if parent.cancelDownloadTrigger != handledCancelDownloadTrigger {
                handledCancelDownloadTrigger = parent.cancelDownloadTrigger
                cancelDownload()
            }
            if parent.musicDownloadTrigger != handledMusicDownloadTrigger {
                handledMusicDownloadTrigger = parent.musicDownloadTrigger
                if let target = parent.musicDownloadTarget { startMusicDownload(target, in: webView) }
            }
            if parent.dismissMusicTrigger != handledDismissMusicTrigger {
                handledDismissMusicTrigger = parent.dismissMusicTrigger
                DispatchQueue.main.async { [weak self] in self?.dismissCurrentMusic() }
            }
        }

        /// Runs through the web view's own download, so the page's cookies, redirects
        /// and authentication apply exactly as for any other download here.
        private func startMusicDownload(_ candidate: BrowserMusicCandidate, in webView: WKWebView) {
            guard activeDownload == nil, destinationURL == nil, !isMusicDownload else { return }
            var request = URLRequest(url: candidate.url)
            // Only for this request: never serve an earlier track from the same endpoint.
            request.cachePolicy = .reloadIgnoringLocalCacheData
            if let referer = BrowserURLPolicy.referer(from: webView.url, to: candidate.url) {
                request.setValue(referer, forHTTPHeaderField: "Referer")
            }
            isMusicDownload = true
            musicSnapshot = candidate
            beginDownload()
            webView.startDownload(using: request) { [weak self] download in
                guard let self else { return }
                guard self.isMusicDownload else {
                    download.cancel { _ in }
                    return
                }
                self.configure(download)
            }
        }

        func scheduleMusicScan(in webView: WKWebView) {
            musicScanTask?.cancel()
            // Pages often attach their player after loading, so look again twice.
            musicScanTask = Task { [weak self, weak webView] in
                for delay in [0.0, 1.5, 4.0] {
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    guard !Task.isCancelled, let self, let webView else { return }
                    self.scanMusic(in: webView)
                }
            }
        }

        private func scanMusic(in webView: WKWebView) {
            let script = #"""
            (() => {
              const found = new Map();
              const clean = (value) => (typeof value === 'string' ? value.replace(/\s+/g, ' ').trim().slice(0, 160) : '');
              const session = (navigator.mediaSession && navigator.mediaSession.metadata && clean(navigator.mediaSession.metadata.title)) || '';
              const label = (item) => clean(item.getAttribute('title')) || clean(item.getAttribute('aria-label')) || clean(item.getAttribute('data-title'));
              const add = (value, title, playing) => {
                try {
                  if (!value) return;
                  const href = new URL(value, document.baseURI).href;
                  const old = found.get(href);
                  if (old) { old.p = old.p || playing; if (!old.t) old.t = title; return; }
                  found.set(href, { u: href, t: title || '', p: playing });
                } catch (_) {}
              };
              const music = /\.(mp3|m4a|m4b|aac|wav|flac|ogg|oga|opus|aiff?|caf|wma)([?#]|$)/i;
              document.querySelectorAll('audio').forEach((item) => {
                const playing = !item.paused && !item.ended;
                const title = playing ? (session || label(item) || clean(document.title)) : label(item);
                add(item.currentSrc || item.src, title, playing);
                item.querySelectorAll('source').forEach((source) => add(source.src, title, playing));
              });
              document.querySelectorAll('a[href]').forEach((item) => {
                if (music.test(item.href)) add(item.href, label(item) || clean(item.textContent), false);
              });
              return Array.from(found.values()).slice(0, 200);
            })()
            """#
            let page = webView.url
            let generation = pageGeneration
            scanSequence += 1
            let sequence = scanSequence
            webView.evaluateJavaScript(script) { [weak self, weak webView] result, _ in
                guard let self, let webView, webView.url == page,
                      generation == self.pageGeneration, sequence == self.scanSequence else { return }
                let items = result as? [[String: Any]] ?? []
                let found = items.compactMap { item -> BrowserMusicCandidate? in
                    guard let text = item["u"] as? String, let url = URL(string: text) else { return nil }
                    let title = (item["t"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    return BrowserMusicCandidate(url: url, title: title, isPlaying: item["p"] as? Bool ?? false)
                }
                self.scannedMusic = found.filter { $0.isPlaying } + found.filter { !$0.isPlaying }
                // A song that starts playing now is a new song, even if it was closed before.
                let playing = self.scannedMusic.first { $0.isPlaying }.map(self.musicKey)
                if let playing, playing != self.lastPlayingKey { self.dismissedMusicKeys.remove(playing) }
                // Pause/emptied keeps the last known track so resuming it is not "new".
                if let playing { self.lastPlayingKey = playing }
                self.publishMusicCandidates()
            }
        }

        /// Only plain web addresses are offered; `blob:` and `data:` sources (streamed or
        /// protected playback) are never turned into a download. The latest audio response
        /// is only a fallback when the page itself shows nothing.
        private func publishMusicCandidates() {
            var seen = Set<String>()
            var source = scannedMusic
            if source.isEmpty, let latest = responseMusicURLs.last {
                source = [BrowserMusicCandidate(url: latest)]
            }
            let candidates = source.filter { candidate in
                guard ["http", "https"].contains(candidate.url.scheme?.lowercased() ?? ""),
                      !dismissedMusicKeys.contains(musicKey(candidate)) else { return false }
                return seen.insert(candidate.url.absoluteString).inserted
            }.prefix(30).map { $0 }
            if parent.musicCandidates != candidates { parent.musicCandidates = candidates }
        }

        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            musicScanTask?.cancel()
            musicSignalTask?.cancel()
            pageGeneration += 1
            responseMusicURLs = pendingMainFrameMusicURL.map { [$0] } ?? []
            pendingMainFrameMusicURL = nil
            scannedMusic = []
            dismissedMusicKeys.removeAll()
            lastPlayingKey = nil
            publishMusicCandidates()
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            guard navigationAction.targetFrame == nil else { return nil }
            if popupReturnURL == nil {
                popupReturnURL = webView.url
            }
            webView.load(navigationAction.request)
            return nil
        }

        func webViewDidClose(_ webView: WKWebView) {
            if webView.canGoBack {
                webView.goBack()
            } else if let popupReturnURL {
                webView.load(URLRequest(url: popupReturnURL))
            }
            popupReturnURL = nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            if navigationAction.shouldPerformDownload {
                beginDownload()
                decisionHandler(.download)
            } else if ["http", "https", "about"].contains(url.scheme?.lowercased() ?? "") {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void
        ) {
            let response = navigationResponse.response as? HTTPURLResponse
            let disposition = response?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
            if let url = navigationResponse.response.url,
               BrowserURLPolicy.isAudio(filename: url.lastPathComponent,
                                        mimeType: navigationResponse.response.mimeType) {
                // Recognized only: this just makes the "음악 다운로드" action available.
                if navigationResponse.isForMainFrame {
                    pendingMainFrameMusicURL = url
                } else if !responseMusicURLs.contains(url) {
                    responseMusicURLs.append(url)
                    publishMusicCandidates()
                }
            }
            if !navigationResponse.canShowMIMEType || disposition?.contains("attachment") == true {
                if navigationResponse.isForMainFrame { pendingMainFrameMusicURL = nil }
                beginDownload()
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            pendingMainFrameMusicURL = nil
            parent.isPageLoading = true
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isPageLoading = false
            parent.pageLoadProgress = 1
            updateState(from: webView)
            scheduleMusicScan(in: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFail navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isPageLoading = false
            updateState(from: webView)
            if (error as NSError).code != NSURLErrorCancelled {
                parent.onError(error.localizedDescription)
            }
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            parent.isPageLoading = false
            updateState(from: webView)
            if (error as NSError).code != NSURLErrorCancelled {
                parent.onError(error.localizedDescription)
            }
        }

        func webView(
            _ webView: WKWebView,
            navigationResponse: WKNavigationResponse,
            didBecome download: WKDownload
        ) { configure(download) }

        func webView(
            _ webView: WKWebView,
            navigationAction: WKNavigationAction,
            didBecome download: WKDownload
        ) { configure(download) }

        func download(
            _ download: WKDownload,
            decideDestinationUsing response: URLResponse,
            suggestedFilename: String,
            completionHandler: @escaping @MainActor @Sendable (URL?) -> Void
        ) {
            beginDownload()
            downloadMIMEType = response.mimeType
            if isMusicDownload, let status = (response as? HTTPURLResponse)?.statusCode,
               !(200..<300).contains(status) {
                resetDownloadState()
                finishDownload()
                parent.onError("음악 파일을 받지 못했습니다. (HTTP \(status))")
                completionHandler(nil)
                return
            }
            var filename = BrowserURLPolicy.safeFilename(suggestedFilename, response: response)
            if isMusicDownload {
                let serverExtension = (filename as NSString).pathExtension
                let mimeExtension = response.mimeType.flatMap { type in
                    type.lowercased().hasPrefix("audio/") ? UTType(mimeType: type)?.preferredFilenameExtension : nil
                }
                let recognized = BrowserURLPolicy.isAudio(filename: filename, mimeType: nil)
                let fileExtension = recognized ? serverExtension : (mimeExtension ?? serverExtension)
                // The song title captured with this candidate names the file; the server's
                // file name is the fallback.
                let serverStem = serverExtension.isEmpty ? filename : String(filename.dropLast(serverExtension.count + 1))
                let base = BrowserURLPolicy.musicFilenameBase(musicSnapshot?.title)
                    ?? BrowserURLPolicy.musicFilenameBase(serverStem) ?? "음악"
                filename = fileExtension.isEmpty ? base : "\(base).\(fileExtension)"
            }
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("NasFinder-WebDownloads", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let destination = directory.appendingPathComponent(filename)
                destinationURL = destination
                completionHandler(destination)
            } catch {
                resetDownloadState()
                finishDownload()
                parent.onError(error.localizedDescription)
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            defer { finishDownload() }
            guard let destinationURL else {
                resetDownloadState()
                return
            }
            let filename = destinationURL.lastPathComponent
            let type = UTType(filenameExtension: destinationURL.pathExtension)?.identifier
            if isMusicDownload, let snapshot = musicSnapshot {
                // Consumed: do not keep offering the file that was just saved.
                dismissedMusicKeys.insert(musicKey(snapshot))
                publishMusicCandidates()
            }
            parent.onDownloaded(
                BrowserDownloadedFile(
                    temporaryURL: destinationURL,
                    filename: filename,
                    contentTypeIdentifier: type,
                    isMusic: isMusicDownload,
                    mimeType: downloadMIMEType
                )
            )
            resetDownloadState()
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let destinationURL {
                try? FileManager.default.removeItem(at: destinationURL.deletingLastPathComponent())
            }
            resetDownloadState()
            finishDownload()
            if (error as NSError).code != NSURLErrorCancelled {
                parent.onError(error.localizedDescription)
            }
        }

        func cancelDownload() {
            activeDownload?.cancel { _ in }
            if let destinationURL {
                try? FileManager.default.removeItem(at: destinationURL.deletingLastPathComponent())
            }
            resetDownloadState()
            finishDownload()
        }

        private func resetDownloadState() {
            destinationURL = nil
            activeDownload = nil
            isMusicDownload = false
            musicSnapshot = nil
            downloadMIMEType = nil
        }

        private func configure(_ download: WKDownload) {
            beginDownload()
            activeDownload = download
            download.delegate = self
        }

        private func beginDownload() {
            if downloadActivityID == nil {
                let activityID = UUID()
                downloadActivityID = activityID
                ScreenAwakeController.shared.beginActivity(activityID)
            }
            parent.isDownloading = true
        }

        private func finishDownload() {
            if let downloadActivityID {
                ScreenAwakeController.shared.finishActivity(downloadActivityID)
            }
            downloadActivityID = nil
            parent.isDownloading = false
        }

        func updateState(from webView: WKWebView) {
            if let url = webView.url { parent.currentURLText = url.absoluteString }
            parent.canGoBack = webView.canGoBack
        }
    }
}

/// Holds the coordinator weakly: the web view's content controller retains its handlers.
@MainActor
private final class MusicSignalProxy: NSObject, WKScriptMessageHandler {
    weak var coordinator: NasFinderWebView.Coordinator?
    init(coordinator: NasFinderWebView.Coordinator) { self.coordinator = coordinator }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        coordinator?.handleMusicSignal(message)
    }
}
