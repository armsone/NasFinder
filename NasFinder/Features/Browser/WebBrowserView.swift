import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct BrowserDownloadedFile: Identifiable, Equatable {
    let id = UUID()
    let temporaryURL: URL
    let filename: String
    let contentTypeIdentifier: String?
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
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var favoritesStore: BrowserFavoritesStore

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
    @State private var isSaveDialogPresented = false
    @State private var networkUploadFile: BrowserDownloadedFile?
    @State private var lastNetworkUploadFile: BrowserDownloadedFile?
    @State private var didCompleteNetworkUpload = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showFavoritePanel = false
    @State private var showFavoriteEditor = false

    var body: some View {
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
                    onDownloaded: {
                        pendingDownload = $0
                        isSaveDialogPresented = true
                    },
                    onError: { errorMessage = $0 }
                )

                if isDownloading {
                    downloadOverlay
                } else if showFavoritePanel {
                    favoritePanel
                } else if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.top, 10)
                        .onTapGesture { self.statusMessage = nil }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: currentURLText) { _, newValue in
            addressText = newValue
        }
        .confirmationDialog(
            "어디에 저장할까요?",
            isPresented: $isSaveDialogPresented,
            titleVisibility: .visible
        ) {
            Button("받은 파일에 저장") { savePendingDownloadToInbox() }
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
        .alert("브라우저 오류", isPresented: errorBinding) {
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
        HStack(spacing: 7) {
            Image(systemName: canGoBack ? "chevron.left" : "xmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.primary.opacity(0.68))
                .frame(width: 32, height: 32)
                .background(Color.secondary.opacity(0.10), in: Circle())
                .contentShape(Circle())
                .gesture(backOrCloseGesture)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(canGoBack ? "이전 페이지" : "브라우저 닫기")
                .accessibilityHint("길게 누르면 브라우저를 닫습니다.")

            HStack(spacing: 4) {
                TextField("웹 주소 입력", text: $addressText)
                    .focused($isAddressFocused)
                    .font(.system(size: 13, weight: .medium))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit(loadAddress)

                if isAddressFocused, !addressText.isEmpty {
                    Button {
                        addressText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("주소 모두 지우기")
                }
            }
                .padding(.horizontal, 10)
                .frame(height: 32)
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

            Image(systemName: isCurrentFavorite ? "bookmark.fill" : "bookmark")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isCurrentFavorite ? SkyBreezeTheme.accent : Color.primary.opacity(0.68))
                .frame(width: 32, height: 32)
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
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
        .overlay(alignment: .bottom) { pageLoadProgressBar.frame(height: 2) }
    }

    private func browserIcon(_ systemName: String, primary: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Color.primary.opacity(0.68))
            .frame(width: 32, height: 32)
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
        HStack(spacing: 10) {
            ProgressView()
            Text("파일을 내려받는 중…")
                .font(.subheadline)
            Button("취소", role: .cancel) { cancelDownloadTrigger += 1 }
                .font(.caption)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, 10)
    }

    private var initialURL: URL {
        favoritesStore.favorites.compactMap(BrowserURLPolicy.normalizedURL).first
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
                Label("즐겨찾기", systemImage: "bookmark.fill")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    showFavoritePanel = false
                    showFavoriteEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 32, height: 32)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("즐겨찾기 편집")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            if favoritesStore.favorites.isEmpty {
                Text("등록된 즐겨찾기가 없습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(favoritesStore.favorites, id: \.self) { favorite in
                            favoriteRow(favorite)
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.20), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func favoriteRow(_ favorite: String) -> some View {
        HStack(spacing: 10) {
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
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(BrowserFavoriteFavicon.displayTitle(for: favorite))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text(favorite)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if favorite == favoritesStore.favorites.first {
                        Image(systemName: "house.fill")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(SkyBreezeTheme.accent)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    private func savePendingDownloadToInbox() {
        guard let file = pendingDownload else { return }
        pendingDownload = nil
        isSaveDialogPresented = false
        Task {
            defer { removeTemporaryDownload(file) }
            do {
                try await inboxStore.importDownloadedFile(
                    at: file.temporaryURL,
                    originalFilename: file.filename,
                    contentTypeIdentifier: file.contentTypeIdentifier
                )
                statusMessage = "받은 파일에 저장했습니다."
            } catch {
                errorMessage = error.localizedDescription
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
        private var popupReturnURL: URL?

        init(parent: NasFinderWebView) { self.parent = parent }

        func attach(to webView: WKWebView) {
            progressObservation = webView.observe(\.estimatedProgress, options: [.new]) {
                [weak self] webView, _ in
                Task { @MainActor in self?.parent.pageLoadProgress = webView.estimatedProgress }
            }
        }

        func invalidate() {
            progressObservation?.invalidate()
            progressObservation = nil
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
            if !navigationResponse.canShowMIMEType || disposition?.contains("attachment") == true {
                beginDownload()
                decisionHandler(.download)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isPageLoading = true
            updateState(from: webView)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isPageLoading = false
            parent.pageLoadProgress = 1
            updateState(from: webView)
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
            let filename = BrowserURLPolicy.safeFilename(suggestedFilename, response: response)
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
                finishDownload()
                parent.onError(error.localizedDescription)
                completionHandler(nil)
            }
        }

        func downloadDidFinish(_ download: WKDownload) {
            defer { finishDownload() }
            guard let destinationURL else { return }
            let filename = destinationURL.lastPathComponent
            let type = UTType(filenameExtension: destinationURL.pathExtension)?.identifier
            parent.onDownloaded(
                BrowserDownloadedFile(
                    temporaryURL: destinationURL,
                    filename: filename,
                    contentTypeIdentifier: type
                )
            )
            self.destinationURL = nil
            activeDownload = nil
        }

        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            if let destinationURL {
                try? FileManager.default.removeItem(at: destinationURL.deletingLastPathComponent())
            }
            self.destinationURL = nil
            activeDownload = nil
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
            destinationURL = nil
            activeDownload = nil
            finishDownload()
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
