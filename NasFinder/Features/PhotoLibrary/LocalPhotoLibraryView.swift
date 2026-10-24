import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 맥락(일반/영상 만들기/뮤직비디오/현재 프로젝트)에 맞는 선택 세션을 골라 본문에 넘긴다.
/// 선택은 화면이 아니라 세션이 들고 있어 pop·모듈 전환·재생성에도 사라지지 않는다.
struct LocalPhotoLibraryView: View {
    @Environment(\.trailerProjectSink) private var projectSink
    private let initialMode: VideoTrailerMode?
    /// Mac 파인더의 '내 사진·영상'에서만 true. 사이드바가 다른 소스를 이미 열어 주므로 거기서만 중복 탭을 숨긴다.
    /// 영상 만들기 재료 고르기 등 나머지는 모든 소스 탭을 보여 준다(주변 사이드바 환경값에 기대지 않는다).
    private let hidesDuplicateSources: Bool
    init(initialMode: VideoTrailerMode? = nil, hidesDuplicateSources: Bool = false) {
        self.initialMode = initialMode
        self.hidesDuplicateSources = hidesDuplicateSources
    }

    private var scope: LocalPhotoLibrarySelectionStore.Scope {
        if projectSink != nil { return .project }
        switch initialMode {
        case .mediaMusic: return .mediaMusic
        case .trailer: return .trailer
        case nil: return .library
        }
    }
    var body: some View {
        LocalPhotoLibraryPicker(initialMode: initialMode, hidesDuplicateSources: hidesDuplicateSources,
                                session: LocalPhotoLibrarySelectionStore.store(for: scope))
    }
}

/// 사진과 달력은 같은 PHAsset 바스켓을 사용하며 실제 작업을 시작할 때만 원본을 복사한다.
private struct LocalPhotoLibraryPicker: View {
    @Environment(\.trailerProjectSink) private var projectSink
    private typealias EntryOrigin = LocalPhotoSelectionOrigin
    private typealias Entry = LocalPhotoSelectionEntry
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @Environment(\.scenePhase) private var scenePhase
    private let initialMode: VideoTrailerMode?
    @ObservedObject private var session: LocalPhotoLibrarySelectionStore
    private let hidesDuplicateSources: Bool
    init(initialMode: VideoTrailerMode?, hidesDuplicateSources: Bool, session: LocalPhotoLibrarySelectionStore) {
        self.initialMode = initialMode
        self.hidesDuplicateSources = hidesDuplicateSources
        self.session = session
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    private var sourcePages: [MediaSourcePage] {
        return hidesDuplicateSources && usesShellSidebar ? MediaSourcePage.shellPages : MediaSourcePage.allCases
    }
    private var sourcePage: MediaSourcePage {
        get { session.sourcePage }
        nonmutating set { session.sourcePage = newValue }
    }
    private var sourcePageBinding: Binding<MediaSourcePage> { $session.sourcePage }
    private var pickerSelectionBinding: Binding<[PhotosPickerItem]> { $session.pickerSelection }
    private var pickerSelection: [PhotosPickerItem] {
        get { session.pickerSelection }
        nonmutating set { session.pickerSelection = newValue }
    }
    private var entries: [Entry] {
        get { session.entries }
        nonmutating set { session.entries = newValue }
    }
    private var rememberedIdentities: [PhotosPickerItem: String] {
        get { session.rememberedIdentities }
        nonmutating set { session.rememberedIdentities = newValue }
    }
    private var queuedGoogleRecords: [SharedInboxRecord] {
        get { session.queuedGoogleRecords }
        nonmutating set { session.queuedGoogleRecords = newValue }
    }
    private var googleLifecycle: EmbeddedGooglePhotosLifecycle { session.googleLifecycle }
    @State private var libraryAssets: PHFetchResult<PHAsset>?
    @State private var authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
    @State private var isLoadingLibrary = false
    @State private var libraryQueryGeneration = 0
    @State private var isPickerPresented = false
    @State private var isFileImporterPresented = false
    @State private var pendingFileImportResult: Result<[URL], Error>?
    @State private var isLoadingSelection = false
    @State private var errorMessage: String?
    @State private var trailerSelection: VideoTrailerSelection?
    @State private var editingService: LocalPhotoLibraryFileService?
    @State private var editingTemporaryURLs: [URL] = []
    @State private var previewItem: RemoteFileItem?
    @State private var nativePreviewAsset: PHAsset?
    @State private var previewItems: [RemoteFileItem] = []
    @State private var previewService: LocalPhotoLibraryFileService?
    @State private var previewTemporaryURLs: [URL] = []
    @State private var loadTotal = 0
    @State private var loadCompleted = 0
    @State private var currentLoadingLabel: String?
    @State private var importSummaryText: String?
    @State private var workbenchRequest: WorkbenchAddRequest?
    private struct PhoneHardCopyRequest {
        let selection: [Entry]
        let folderPath: String?
    }
    @State private var isChoosingPhoneHardDestination = false
    @State private var pendingPhoneHardCopy: PhoneHardCopyRequest?
    @State private var isCopyingToPhoneHard = false
    @State private var copyProgressTotal = 0
    @State private var copyProgressCompleted = 0
    @State private var isFileImporting = false
    @State private var isCleanupPendingOnDeparture = false
    @State private var preparationTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: ui(92), maximum: ui(120)), spacing: ui(8))]
    private var service: LocalPhotoLibraryFileService {
        LocalPhotoLibraryFileService(entries: entries.compactMap { entry in entry.url.map { (entry.item, $0) } })
    }
    private var isBusy: Bool { isLoadingSelection || isCopyingToPhoneHard }
    private var selectedIdentifiers: Set<String> { Set(entries.map(\.id)) }
    private var navigationTitleText: String {
        switch initialMode {
        case .mediaMusic: "뮤직비디오"
        case .trailer: "영상 만들기"
        case nil: "내 미디어"
        }
    }
    private var themeRefresh = ThemeRefresh()
    var body: some View {
        let _ = themeRefresh.theme
        mediaContent.modifier(PreserveMediaNavigation())
    }
    private var mediaContent: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                // 파일 브라우저의 뒤로와 같은 모양(32pt 강조 원 + 44pt 터치). 길게 누르기 동작은 파일 브라우저에만 있다.
                Button { dismiss() } label: {
                    InterfaceIcon(systemName: "chevron.left", size: ui(20))
                        .font(.system(size: ui(17), weight: .semibold))
                        .foregroundStyle(PorcelainMetrics.accent)
                        .frame(width: ui(32), height: ui(32))
                        .background(PorcelainMetrics.accent.opacity(0.12), in: Circle())
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }.accessibilityLabel("뒤로")
                Text(navigationTitleText).porcelainFont(.section, weight: .semibold)
                    .foregroundStyle(PorcelainMetrics.graphite)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
            .padding(.horizontal, ui(4))
            .background(PorcelainMetrics.paper)
            MediaSourceTabBar(page: sourcePageBinding, pages: sourcePages)
            MediaSourcePager(page: sourcePageBinding, pages: sourcePages) { page in
                pageContent(page).disabled(isBusy)
            }
        }
        .onAppear {
            // 이전에 다른 출처 탭에 있었어도 사이드바가 맡는 출처 탭이 없는 창에서는 사진으로 돌아온다.
            if !sourcePages.contains(sourcePage) { sourcePage = .photos }
        }
        .background(PorcelainMetrics.paper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .bottom) {
            if !entries.isEmpty || isCopyingToPhoneHard { bottomActionBar }
        }
        .safeAreaInset(edge: .top) {
            if isLoadingSelection { progressBanner }
            else if let importSummaryText {
                Text(importSummaryText).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                    .padding(ui(8)).frame(maxWidth: .infinity, alignment: .leading)
                    .background(PorcelainMetrics.sidebar)
            }
        }
        .photosPicker(isPresented: $isPickerPresented, selection: pickerSelectionBinding,
                      matching: .any(of: [.images, .videos]), photoLibrary: .shared())
        #if targetEnvironment(macCatalyst)
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true,
                      onCompletion: handleFileImportResult)
        #else
        .fullScreenCover(isPresented: $isFileImporterPresented, onDismiss: {
            guard let result = pendingFileImportResult else { return }
            pendingFileImportResult = nil
            handleFileImportResult(result)
        }) {
            MediaDocumentPicker { result in
                pendingFileImportResult = result
                isFileImporterPresented = false
            }
            .ignoresSafeArea()
        }
        #endif
        .onChange(of: pickerSelection) { _, selected in addPickerItems(selected) }
        .task {
            isCleanupPendingOnDeparture = false
            if LocalPhotoLibraryCalendarService.authorizationStatus == .notDetermined {
                _ = await LocalPhotoLibraryCalendarService.requestAccess()
            }
            await refreshLibrary()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshLibrary() } }
        }
        .onAppear { isCleanupPendingOnDeparture = false }
        .sheet(isPresented: $isChoosingPhoneHardDestination, onDismiss: {
            guard let request = pendingPhoneHardCopy else {
                runDeferredCleanupIfPending()
                return
            }
            pendingPhoneHardCopy = nil
            startPreparation { await copySelectedToPhoneHard(request.selection, toFolder: request.folderPath) }
        }) {
            InboxDestinationPickerView(inboxStore: inboxStore, operation: nil, excludedPaths: [],
                title: "폰하드 복사 위치", onPickDestination: { folderPath in
                    pendingPhoneHardCopy = PhoneHardCopyRequest(selection: entries, folderPath: folderPath)
                    isChoosingPhoneHardDestination = false
                })
        }
        .overlay {
            if let asset = nativePreviewAsset {
                GeometryReader { geometry in
                    NasFinderAssetPreview(asset: asset,
                        onRemoveSelection: selectedIdentifiers.contains(asset.localIdentifier) ? {
                            toggleAsset(asset)
                            nativePreviewAsset = nil
                        } : nil,
                        onDismiss: { nativePreviewAsset = nil })
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .ignoresSafeArea()
            }
        }
        .workbenchAddSheet($workbenchRequest)
        .routesTrailerSelection($trailerSelection, service: { editingService ?? service }, sink: projectSink)
        .trailerEditorCover(item: trailerCoverBinding($trailerSelection, sink: projectSink)) { selection in
            VideoTrailerView(items: selection.items, service: editingService ?? service, mode: selection.mode,
                             keepsSelectionOrder: selection.keepsSelectionOrder)
        }
        .fullScreenCover(item: $previewItem) { item in
            RemotePreviewView(item: item, sequentialItems: previewItems, service: previewService ?? service,
                              onClose: { previewItem = nil })
        }
        .alert("미디어 알림", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
        .onChange(of: trailerSelection?.id) { _, id in if id == nil { runDeferredCleanupIfPending() } }
        .onChange(of: previewItem?.id) { _, id in
            if id == nil {
                previewService = nil
                previewItems = []
                for url in previewTemporaryURLs { try? FileManager.default.removeItem(at: url) }
                previewTemporaryURLs = []
                runDeferredCleanupIfPending()
            }
        }
        .onChange(of: isPickerPresented) { _, showing in if !showing { runDeferredCleanupIfPending() } }
        .onChange(of: isFileImporterPresented) { _, showing in if !showing { runDeferredCleanupIfPending() } }
        .onDisappear(perform: cleanupTemporaryFiles)
    }
    @ViewBuilder private func pageContent(_ page: MediaSourcePage) -> some View {
        switch page {
        case .photos: photoModeContent
        case .calendar:
            LocalPhotoLibraryCalendarView(selectedIdentifiers: selectedIdentifiers,
                onToggle: toggleAsset, onAdd: addAssets, onRemove: removeAssets,
                onRemoveDates: { dates in
                    removeAssets(entries.compactMap { entry in
                        guard let asset = entry.asset, let date = asset.creationDate,
                              dates.contains(Calendar.current.startOfDay(for: date)) else { return nil }
                        return asset
                    })
                },
                onPreview: { asset in nativePreviewAsset = asset },
                onRequestPhotoMode: { isPickerPresented = true })
        case .phoneHard:
            NavigationStack {
                MediaSelectionBrowser(connection: LocalInboxFileService.phoneHardConnection, rootPath: LocalInboxFileService.rootPath,
                                      rootTitle: LocalInboxFileService.phoneHardConnection.name, service: LocalInboxFileService(),
                                      onPickMedia: pickedFromBrowser)
            }
        case .favorites:
            NavigationStack { MediaFavoritePickerView(onPickMedia: pickedFromBrowser) }
        case .network:
            MediaNetworkSourcePage(onPickMedia: pickedFromBrowser)
        case .files:
            MediaFilesSourcePage(selectedIDs: selectedIdentifiers, isActive: sourcePage == .files,
                imported: entries.filter { $0.origin == .file }.map {
                    MediaImportedFile(id: $0.id, name: $0.item.name, isVideo: $0.isVideo, thumbnail: $0.thumbnail)
                },
                onToggle: { url in
                    let key = "file:" + url.standardizedFileURL.path
                    if let entry = entries.first(where: { $0.id == key }) { remove(entry) }
                    else { Task { await importFileURLs([url]) } }
                },
                onRemoveImported: { id in
                    if let entry = entries.first(where: { $0.id == id }) { remove(entry) }
                },
                onOpenSystemImporter: { isFileImporterPresented = true })
        case .google:
            GooglePhotosImportFlowView(inboxStore: inboxStore, lifecycle: googleLifecycle, onImportedMedia: { records in
                queuedGoogleRecords.append(contentsOf: records)
                drainGoogleQueue()
            }, onExit: { sourcePage = .photos })
        }
    }
    private var photoModeContent: some View {
        VStack(spacing: ui(6)) {
            if authorizationStatus == .limited {
                HStack {
                    Text("허용한 미디어만 표시됩니다").font(.ui(.footnote)).foregroundStyle(.secondary)
                    Spacer()
                    Button("선택 변경") { presentLimitedLibraryPicker() }.font(.ui(.footnote))
                }.padding(.horizontal, ui(12))
            }
            if authorizationStatus == .authorized || authorizationStatus == .limited {
                if let libraryAssets, libraryAssets.count > 0 {
                    NasFinderPhotoGrid(assets: libraryAssets,
                        selection: entries.filter { $0.asset != nil }.map(\.id),
                        onSelectionChange: applyPhotoGridSelection)
                } else if isLoadingLibrary { ProgressView("사진 보관함 불러오는 중") }
                else {
                    ContentUnavailableView("미디어가 없습니다", systemImage: "photo.on.rectangle",
                        description: Text(authorizationStatus == .limited ? "선택 변경으로 허용할 미디어를 추가할 수 있습니다." : "사진 보관함의 미디어가 여기에 표시됩니다."))
                }
            } else { photoAccessContent }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var photoAccessContent: some View {
        ContentUnavailableView {
            Label("사진 보관함 접근이 꺼져 있습니다", interfaceSystemImage: "lock")
        } description: {
            Text("설정에서 사진 접근을 허용하거나 시스템 선택기로 필요한 항목만 선택할 수 있습니다. 기존 선택 항목은 유지됩니다.")
        } actions: {
            Button("설정에서 사진 접근 확인") { openPhotoSettings() }
            Button("시스템 사진 선택기") { isPickerPresented = true }.buttonStyle(PorcelainProminentButtonStyle())
        }
    }
    private var bottomActionBar: some View {
        VStack(spacing: ui(8)) {
            if isCopyingToPhoneHard {
                Text("폰하드로 복사하는 중 · \(copyProgressCompleted)/\(copyProgressTotal)개").font(.ui(.footnote))
                ProgressView(value: Double(copyProgressCompleted), total: Double(max(copyProgressTotal, 1)))
            }
            if !entries.isEmpty {
                MediaBasketTray(
                    items: entries.map { MediaBasketTrayItem(id: $0.id, name: $0.item.name, isVideo: $0.isVideo,
                                                             thumbnail: $0.thumbnail, asset: $0.asset) },
                    isBusy: isBusy,
                    onPreview: { id in startPreparation { await previewSelected(ids: [id]) } },
                    onRemove: { id in if let entry = entries.first(where: { $0.id == id }) { remove(entry) } })
            }
            // 폭이 넓으면 한 줄, 좁으면 상태/미리보기 + 액션 두 줄, 큰 글자에서는 전폭 세로 배치.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: ui(8)) {
                    footerStatusRow
                    Spacer(minLength: ui(4))
                    footerActionButtons(fillsWidth: false)
                }
                VStack(spacing: ui(6)) {
                    HStack(spacing: ui(8)) { footerStatusRow; Spacer(minLength: 0) }
                    HStack(spacing: ui(8)) { footerActionButtons(fillsWidth: true) }
                }
                VStack(spacing: ui(6)) {
                    HStack(spacing: ui(8)) { footerStatusRow; Spacer(minLength: 0) }
                    VStack(spacing: ui(6)) { footerActionButtons(fillsWidth: true) }
                }
            }
        }.padding(.horizontal, ui(12)).padding(.vertical, ui(8))
        .background(PorcelainMetrics.card.opacity(0.95))
        .overlay(alignment: .top) { PorcelainMetrics.line.frame(height: 0.5) }
    }
    @ViewBuilder private var footerStatusRow: some View {
        Text("선택됨 \(entries.count)개").font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
        if !entries.isEmpty {
            Button("미리보기", interfaceSystemImage: "eye") {
                startPreparation { await previewSelected() }
            }.font(.ui(.footnote)).frame(minHeight: 36).disabled(isBusy)
            Button("모두 비우기", interfaceSystemImage: "xmark.circle") { clearSelection() }
                .font(.ui(.footnote)).frame(minHeight: 36).disabled(isBusy)
        }
    }
    @ViewBuilder private func footerActionButtons(fillsWidth: Bool) -> some View {
        Group {
            Button {
                pendingPhoneHardCopy = nil
                inboxStore.reload()
                isChoosingPhoneHardDestination = true
            } label: { footerActionLabel("폰하드 복사", fillsWidth: fillsWidth) }
            Button {
                presentWorkbenchAdd()
            } label: { footerActionLabel("작업대에 담기", fillsWidth: fillsWidth) }
            Button {
                startPreparation { await beginTrailer(mode: initialMode ?? .trailer) }
            } label: { footerActionLabel(projectSink == nil ? "바로 영상 제작" : "현재 프로젝트에 추가", fillsWidth: fillsWidth) }
        }
        .font(PorcelainTypeface.font(size: 14, weight: .medium))
        .buttonStyle(PorcelainProminentButtonStyle())
        .disabled(isBusy || entries.isEmpty)
    }
    private func footerActionLabel(_ title: String, fillsWidth: Bool) -> some View {
        Text(title).padding(.horizontal, ui(8)).frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: ui(30))
    }
    private var progressStatusText: String {
        loadTotal > 0 ? "미디어 준비 중 · \(loadCompleted)/\(loadTotal)개" : "미디어 준비 중…"
    }
    private var progressBanner: some View {
        VStack(alignment: .leading, spacing: ui(4)) {
            HStack {
                Text(progressStatusText).font(.ui(.footnote))
                Spacer()
                if preparationTask != nil {
                    Button("취소") { preparationTask?.cancel() }.font(.ui(.footnote))
                }
            }
            ProgressView(value: Double(loadCompleted), total: Double(max(loadTotal, 1)))
            if let currentLoadingLabel { Text(currentLoadingLabel).font(.ui(.caption2)).foregroundStyle(.secondary) }
        }.padding(ui(10))
        .background(PorcelainMetrics.sidebar)
        .overlay(alignment: .bottom) { PorcelainMetrics.line.frame(height: 0.5) }
    }
    private func photoKey(for item: PhotosPickerItem) -> String {
        if let identifier = item.itemIdentifier { return identifier }
        if let remembered = rememberedIdentities[item] { return remembered }
        let id = UUID().uuidString
        rememberedIdentities[item] = id
        return id
    }
    private func remove(_ entry: Entry) {
        guard !isBusy else { return }
        pickerSelection.removeAll { photoKey(for: $0) == entry.id }
        entries.removeAll { $0.id == entry.id }
        rememberedIdentities = rememberedIdentities.filter { $0.value != entry.id }
        discardOwnedFile(of: entry)
    }
    private func discardOwnedFile(of entry: Entry) {
        session.discardOwnedFile(of: entry)
    }
    private func applyPhotoGridSelection(_ identifiers: [String]) {
        guard !isBusy else { return }
        let wanted = Set(identifiers)
        let existingAssets = entries.compactMap(\.asset)
        let existing = Set(existingAssets.map(\.localIdentifier))
        guard wanted != existing else { return }
        removeAssets(existingAssets.filter { !wanted.contains($0.localIdentifier) })
        let additions = identifiers.filter { !existing.contains($0) }
        guard !additions.isEmpty else { return }
        let fetched = LocalPhotoLibraryCalendarService.assets(withIdentifiers: additions)
        let byID = Dictionary(uniqueKeysWithValues: fetched.map { ($0.localIdentifier, $0) })
        addAssets(additions.compactMap { byID[$0] })
    }
    private func addPickerItems(_ selection: [PhotosPickerItem]) {
        for pickerItem in selection {
            let key = photoKey(for: pickerItem)
            guard !entries.contains(where: { $0.id == key }) else { continue }
            if authorizationStatus == .authorized || authorizationStatus == .limited,
               let asset = PHAsset.fetchAssets(withLocalIdentifiers: [key], options: nil).firstObject {
                addAssets([asset]); continue
            }
            let type = pickerItem.supportedContentTypes.first { $0.conforms(to: .movie) || $0.conforms(to: .video) }
                ?? pickerItem.supportedContentTypes.first { $0.conforms(to: .image) }
            let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
            let name = "\(isVideo ? "동영상" : "사진")-\(entries.count + 1).\(type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg"))"
            let item = RemoteFileItem(connectionID: LocalPhotoLibraryFileService.connectionID, path: key, name: name, kind: .file,
                                      size: nil, modifiedAt: nil, contentTypeIdentifier: type?.identifier)
            var pickerEntry = Entry(id: key, item: item, url: nil, isVideo: isVideo, thumbnail: nil, origin: .photoPicker, pickerItem: pickerItem)
            if let identifier = pickerItem.itemIdentifier {
                pickerEntry.reference = WorkbenchEntryFactory.entry(assetIdentifier: identifier, name: name, isVideo: isVideo)
            }
            entries.append(pickerEntry)
        }
    }
    private func assetEntry(_ asset: PHAsset) -> Entry {
        let isVideo = asset.mediaType == .video
        let name = LocalPhotoLibraryCalendarService.originalFilename(for: asset) ?? "\(isVideo ? "동영상.mov" : "사진.jpg")"
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? (isVideo ? .movie : .image)
        let item = RemoteFileItem(connectionID: LocalPhotoLibraryFileService.connectionID, path: asset.localIdentifier,
                                  name: name, kind: .file, size: nil, modifiedAt: asset.creationDate, contentTypeIdentifier: type.identifier)
        var entry = Entry(id: asset.localIdentifier, item: item, url: nil, isVideo: isVideo, thumbnail: nil, origin: .calendar,
                          duration: LocalPhotoLibraryCalendarService.duration(for: asset), asset: asset)
        entry.reference = WorkbenchEntryFactory.entry(asset: asset, name: name)
        return entry
    }
    private func addAssets(_ assets: [PHAsset]) {
        guard !isBusy else { return }
        var selected = selectedIdentifiers
        for asset in assets where !selected.contains(asset.localIdentifier) {
            entries.append(assetEntry(asset))
            selected.insert(asset.localIdentifier)
        }
    }
    private func removeAssets(_ assets: [PHAsset]) {
        guard !isBusy else { return }
        let ids = Set(assets.map(\.localIdentifier))
        let removed = entries.filter { ids.contains($0.id) }
        entries.removeAll { ids.contains($0.id) }
        pickerSelection.removeAll { ids.contains(photoKey(for: $0)) }
        rememberedIdentities = rememberedIdentities.filter { !ids.contains($0.value) }
        for entry in removed { discardOwnedFile(of: entry) }
    }
    private func toggleAsset(_ asset: PHAsset) {
        if let entry = entries.first(where: { $0.id == asset.localIdentifier }) { remove(entry) }
        else { addAssets([asset]) }
    }
    private func refreshLibrary() async {
        authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { libraryAssets = nil; return }
        libraryQueryGeneration += 1
        let generation = libraryQueryGeneration
        isLoadingLibrary = true
        let result = await Task.detached(priority: .userInitiated) { LocalPhotoLibraryCalendarService.recentAssets() }.value
        guard generation == libraryQueryGeneration else { return }
        libraryAssets = result
        isLoadingLibrary = false
    }
    private func openPhotoSettings() {
        #if targetEnvironment(macCatalyst)
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos")!
        #else
        let url = URL(string: UIApplication.openSettingsURLString)!
        #endif
        UIApplication.shared.open(url)
    }
    private func presentLimitedLibraryPicker() {
        guard let root = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: root) { _ in
            Task { @MainActor in await refreshLibrary() }
        }
    }
    private func startPreparation(_ operation: @escaping @MainActor () async -> Void) {
        guard !isBusy, preparationTask == nil else { return }
        preparationTask = Task {
            await operation()
            preparationTask = nil
            runDeferredCleanupIfPending()
            drainGoogleQueue()
        }
    }
    private func drainGoogleQueue() {
        guard !queuedGoogleRecords.isEmpty, !isBusy, preparationTask == nil else { return }
        let records = queuedGoogleRecords
        queuedGoogleRecords = []
        let items = records.map { LocalInboxFileService.remoteItem(for: $0) }.filter(\.isTrailerEligible)
        guard !items.isEmpty else { return }
        let service = LocalInboxFileService(records: records)
        // 폰하드로 가져온 파일은 저장 경로로 다시 가리킬 수 있다(Google 원본이 아니라 폰하드 안의 파일).
        let references = Dictionary(records.map {
            ($0.id.uuidString, WorkbenchEntryFactory.entry(
                remote: LocalInboxFileService.browserItem(for: $0), sourceLabel: WorkbenchSourceLabel.phoneHard))
        }, uniquingKeysWith: { first, _ in first })
        startPreparation { await importRemoteMedia(items, service: service, origin: .googlePhotos, references: references) }
    }
    private func prepare(_ selection: [Entry]) async -> [(Entry, URL)] {
        guard !isLoadingSelection else { return [] }
        isLoadingSelection = true
        loadTotal = selection.count
        loadCompleted = 0
        defer { isLoadingSelection = false; loadTotal = 0; loadCompleted = 0; currentLoadingLabel = nil }
        var result: [(Entry, URL)] = []
        var failedNames: [String] = []
        for entry in selection {
            if Task.isCancelled { break }
            currentLoadingLabel = entry.item.name
            defer { loadCompleted += 1 }
            do {
                let url: URL
                if let existing = entry.url, FileManager.default.fileExists(atPath: existing.path) { url = existing }
                else if let asset = entry.asset { url = try await LocalPhotoLibraryCalendarService.exportOriginal(for: asset).url }
                else if let picker = entry.pickerItem { url = try await LocalPhotoLibrarySelectionLoader.load(item: picker).url }
                else if let deferred = entry.deferred {
                    // 선택만 해 둔 원본은 영상 제작·미리보기·폰하드 복사처럼 실제로 필요한 이 순간에 가져온다.
                    url = try await LocalPhotoLibrarySelectionLoader.materialize(deferred, name: entry.item.name)
                }
                else { throw LocalPhotoLibraryError.fileUnavailable }
                if Task.isCancelled {
                    if entry.url != url { try? FileManager.default.removeItem(at: url) }
                    break
                }
                if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index].url = url }
                result.append((entry, url))
            } catch is CancellationError { break }
            catch { failedNames.append(entry.item.name) }
        }
        if !failedNames.isEmpty {
            let names = failedNames.prefix(3).joined(separator: ", ")
            errorMessage = "\(failedNames.count)개 항목을 준비하지 못했습니다: \(names). 선택은 유지됩니다. iCloud 다운로드와 사진 접근 권한을 확인하고 다시 시도해 주세요."
        }
        return Task.isCancelled ? [] : result
    }
    /// 고른 항목의 원본 위치(참조)만 작업대 포켓에 담는다. 이 화면이 이미 준비해 둔 임시 사본이나 내려받은 파일은 쓰지 않고,
    /// 참조를 만들 수 없는 항목(원본 위치를 다시 가리킬 수 없는 것)은 몰래 복사하지 않고 담지 못했다고 알린다.
    private func presentWorkbenchAdd() {
        var references: [WorkbenchEntry] = []
        var missing: [String] = []
        for entry in entries {
            if let reference = entry.reference { references.append(reference) } else { missing.append(entry.item.name) }
        }
        var notices: [String] = []
        if !missing.isEmpty {
            let sample = missing.prefix(3).joined(separator: ", ")
            notices.append("\(missing.count)개는 나중에 다시 가리킬 원본 위치를 알 수 없어 담지 않았습니다 (\(sample)\(missing.count > 3 ? " 외" : "")). 사진 접근을 허용하거나 원본 위치에서 직접 담아 주세요. 몰래 복사하지 않습니다.")
        }
        guard !references.isEmpty else {
            errorMessage = notices.first ?? "담을 항목이 없습니다."
            return
        }
        workbenchRequest = WorkbenchAddRequest(title: "선택한 미디어 \(references.count)개", entries: references, notices: notices)
    }
    private func beginTrailer(mode: VideoTrailerMode) async {
        let originals = await prepare(entries)
        guard !Task.isCancelled else { return }
        let previousTemporaryURLs = Set(editingTemporaryURLs)
        let prepared = await prepareEditingRepresentations(originals)
        guard !Task.isCancelled else {
            discardEditingTemporaryFiles(editingTemporaryURLs.filter { !previousTemporaryURLs.contains($0) })
            return
        }
        let clips = prepared.map { $0.0.item }.filter(\.isTrailerEligible)
        guard !clips.isEmpty else { return }
        editingService = LocalPhotoLibraryFileService(entries: prepared.map { ($0.0.item, $0.1) })
        trailerSelection = VideoTrailerSelection(items: clips, mode: mode, keepsSelectionOrder: true)
    }

    /// 편집 준비에서만 표현을 바꾸며 바스켓의 원래 Entry/URL과 원본 복사는 유지한다.
    private func prepareEditingRepresentations(_ originals: [(Entry, URL)]) async -> [(Entry, URL)] {
        isLoadingSelection = true
        loadTotal = originals.count
        loadCompleted = 0
        defer { isLoadingSelection = false; loadTotal = 0; loadCompleted = 0; currentLoadingLabel = nil }
        var result: [(Entry, URL)] = []
        var createdURLs: [URL] = []
        defer {
            if Task.isCancelled { discardEditingTemporaryFiles(createdURLs) }
        }
        for (entry, url) in originals {
            if Task.isCancelled { break }
            currentLoadingLabel = entry.item.name
            defer { loadCompleted += 1 }
            guard let asset = entry.asset, asset.mediaSubtypes.contains(.photoLive) else {
                result.append((entry, url)); continue
            }
            let worker = Task.detached(priority: .userInitiated) {
                try await LivePhotoEditingSelection.choose(asset: asset, originalPhotoURL: url)
            }
            do {
                let decision = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if Task.isCancelled {
                    for owned in decision.ownedURLs { try? FileManager.default.removeItem(at: owned) }
                    break
                }
                createdURLs.append(contentsOf: decision.ownedURLs)
                editingTemporaryURLs.append(contentsOf: decision.ownedURLs)
                guard decision.kind != .originalPhoto else { result.append((entry, url)); continue }
                let isVideo = decision.kind == .video
                let fileExtension = decision.url.pathExtension.lowercased()
                let type = UTType(filenameExtension: fileExtension) ?? (isVideo ? UTType.movie : UTType.jpeg)
                let base = URL(fileURLWithPath: entry.item.name).deletingPathExtension().lastPathComponent
                let name = base + "." + (fileExtension.isEmpty ? (isVideo ? "mov" : "jpg") : fileExtension)
                let size = (try? decision.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init)
                let item = RemoteFileItem(connectionID: entry.item.connectionID, path: entry.id, name: name,
                    kind: .file, size: size, modifiedAt: entry.item.modifiedAt, contentTypeIdentifier: type.identifier)
                let edited = Entry(id: entry.id, item: item, url: decision.url, isVideo: isVideo,
                    thumbnail: entry.thumbnail, origin: entry.origin, duration: decision.duration,
                    asset: entry.asset, pickerItem: entry.pickerItem)
                result.append((edited, decision.url))
            } catch is CancellationError { break }
            catch { result.append((entry, url)) }
        }
        return Task.isCancelled ? [] : result
    }
    /// 취소된 이번 준비가 만든 파일만 지우며 이전 편집/다른 소비자의 파일은 유지한다.
    private func discardEditingTemporaryFiles(_ urls: [URL]) {
        let owned = Set(urls)
        for url in owned { try? FileManager.default.removeItem(at: url) }
        editingTemporaryURLs.removeAll { owned.contains($0) }
    }
    private func previewSelected(ids: [String]? = nil) async {
        let subset = ids.map { ids in entries.filter { ids.contains($0.id) } } ?? entries
        if let asset = subset.first?.asset { nativePreviewAsset = asset; return }
        await showPreview(await prepare(subset))
    }
    private func showPreview(_ prepared: [(Entry, URL)]) async {
        guard !Task.isCancelled, let first = prepared.first else { return }
        previewItems = prepared.map { $0.0.item }
        previewService = LocalPhotoLibraryFileService(entries: prepared.map { ($0.0.item, $0.1) })
        previewItem = first.0.item
    }
    private func handleFileImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case let .failure(error):
            let cocoa = error as NSError
            guard !(cocoa.domain == NSCocoaErrorDomain && cocoa.code == CocoaError.Code.userCancelled.rawValue) else { return }
            errorMessage = "파일을 가져오지 못했습니다: \(error.localizedDescription)"
        case let .success(urls):
            Task { await importFileURLs(urls) }
        }
    }

    /// Copies each Files-app URL into a sandboxed temp file inside a paired security-scope
    /// begin/stop, preserving the original filename. The source document is never mutated.
    private func importFileURLs(_ urls: [URL]) async {
        guard !urls.isEmpty, !isFileImporting else { return }
        isFileImporting = true
        defer {
            isFileImporting = false
            runDeferredCleanupIfPending()
        }
        isLoadingSelection = true
        loadTotal = urls.count
        loadCompleted = 0
        var addedCount = 0
        var failedCount = 0

        for url in urls {
            currentLoadingLabel = "파일 불러오는 중"
            // Keyed by the source document's own URL (not a fresh UUID per import) so
            // re-picking the same Files-app document doesn't add it to the basket twice;
            // two different documents that merely share a filename still get distinct
            // keys because the full path differs.
            let key = "file:" + url.standardizedFileURL.path
            guard !entries.contains(where: { $0.id == key }) else {
                loadCompleted += 1
                continue
            }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            do {
                defer { if didStartAccess { url.stopAccessingSecurityScopedResource() } }

                let contentType = UTType(filenameExtension: url.pathExtension.lowercased())
                let isVideo = contentType?.conforms(to: .movie) == true || contentType?.conforms(to: .video) == true

                // 북마크를 만들 수 있으면 복사하지 않고 선택만 기록한다. 영상 제작 등을 시작할 때에만 가져온다.
                if case .success(let reference) = WorkbenchEntryFactory.entry(fileURL: url), let bookmark = reference.bookmarkData {
                    let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let lazyItem = RemoteFileItem(
                        connectionID: LocalPhotoLibraryFileService.connectionID, path: key, name: url.lastPathComponent,
                        kind: .file, size: values?.fileSize.map(Int64.init), modifiedAt: values?.contentModificationDate,
                        contentTypeIdentifier: contentType?.identifier)
                    var lazyEntry = Entry(id: key, item: lazyItem, url: nil, isVideo: isVideo, thumbnail: nil, origin: .file)
                    lazyEntry.deferred = .bookmark(bookmark)
                    lazyEntry.reference = reference
                    entries.append(lazyEntry)
                    addedCount += 1
                    loadCompleted += 1
                    continue
                }

                // 북마크를 만들 수 없는 파일은 이전처럼 이 선택에서 쓸 임시 사본만 만든다(작업대 참조는 만들지 않는다).
                let destination = LocalPhotoLibrarySelectionLoader.temporaryURL(fileExtension: url.pathExtension)
                try FileManager.default.copyItem(at: url, to: destination)

                // A different in-flight import (e.g. a concurrent file-importer result)
                // may have added this same source document while the copy above ran;
                // never append a second entry for it, and drop the redundant copy.
                guard !entries.contains(where: { $0.id == key }) else {
                    try? FileManager.default.removeItem(at: destination)
                    loadCompleted += 1
                    continue
                }

                let resourceValues = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                var duration: TimeInterval?
                if isVideo {
                    let seconds = try? await AVURLAsset(url: destination).load(.duration).seconds
                    if let seconds, seconds.isFinite, seconds > 0 {
                        duration = seconds
                    }
                }

                let item = RemoteFileItem(
                    connectionID: LocalPhotoLibraryFileService.connectionID,
                    path: key,
                    name: url.lastPathComponent,
                    kind: .file,
                    size: resourceValues?.fileSize.map(Int64.init),
                    modifiedAt: resourceValues?.contentModificationDate,
                    contentTypeIdentifier: contentType?.identifier
                )
                entries.append(
                    Entry(id: key, item: item, url: destination, isVideo: isVideo, thumbnail: nil, origin: .file, duration: duration)
                )
                await loadThumbnail(for: key)
                addedCount += 1
            } catch {
                failedCount += 1
                errorMessage = "일부 파일을 가져오지 못했습니다: \(error.localizedDescription)"
            }
            loadCompleted += 1
        }

        isLoadingSelection = false
        loadTotal = 0
        loadCompleted = 0
        currentLoadingLabel = nil

        if addedCount > 0 {
            showTemporaryImportSummary(
                failedCount > 0
                    ? "파일 \(addedCount)개를 선택에 추가했습니다. \(failedCount)개는 실패했습니다."
                    : "파일 \(addedCount)개를 선택에 추가했습니다."
            )
        }
    }

    /// 브라우저에서 고른 항목만 앱 소유 사본으로 가져와 같은 바스켓 끝에 추가한다.
    private func pickedFromBrowser(_ items: [RemoteFileItem], _ service: any RemoteFileService) {
        let isPhoneHard = service is LocalInboxFileService
        startPreparation { await importRemoteMedia(items, service: service, origin: isPhoneHard ? .phoneHard : .network) }
    }

    /// 선택한 항목만 내려받는다. 네트워크 항목은 앱 소유 임시 사본으로 두고, 폰하드에 이미 있는 파일은
    /// 복사하지 않고 읽기만 한다. 취소·실패해도 이전 선택과 이미 추가한 항목은 유지한다.
    private func importRemoteMedia(_ items: [RemoteFileItem], service: any RemoteFileService, origin: EntryOrigin,
                                   references: [String: WorkbenchEntry] = [:]) async {
        guard !isLoadingSelection else { return }
        let ownsCopies = origin == .network
        isLoadingSelection = true
        loadTotal = items.count
        loadCompleted = 0
        defer { isLoadingSelection = false; loadTotal = 0; loadCompleted = 0; currentLoadingLabel = nil }
        var added = 0
        var skipped = 0
        var failedNames: [String] = []
        for item in items {
            if Task.isCancelled { break }
            currentLoadingLabel = item.name
            defer { loadCompleted += 1 }
            var key = "remote:\(service.connection.id.uuidString):\(item.path)"
            if ownsCopies, entries.contains(where: { $0.id == key }) { skipped += 1; continue }
            if ownsCopies {
                // 네트워크 원본은 선택만 기록한다(내려받기·복사·썸네일 생성 없음). 영상 제작·미리보기·폰하드 복사처럼
                // 원본이 실제로 필요한 동작을 시작할 때에만 `prepare`가 가져온다. '작업대에 담기'는 이 참조만 쓴다.
                let lazyItem = RemoteFileItem(
                    connectionID: LocalPhotoLibraryFileService.connectionID, path: key, name: item.name, kind: .file,
                    size: item.size, modifiedAt: item.modifiedAt, contentTypeIdentifier: item.contentTypeIdentifier)
                var lazyEntry = Entry(id: key, item: lazyItem, url: nil, isVideo: item.isVideo, thumbnail: nil, origin: origin)
                lazyEntry.deferred = .remote(item: item, service: service)
                lazyEntry.reference = references[item.path] ?? WorkbenchEntryFactory.entry(
                    remote: item,
                    sourceLabel: service is DeviceFolderFileService ? WorkbenchSourceLabel.deviceFiles : WorkbenchSourceLabel.nas)
                entries.append(lazyEntry)
                added += 1
                continue
            }
            do {
                let downloaded = try await service.download(item)
                var url = downloaded
                if !ownsCopies {
                    key = "local:" + downloaded.standardizedFileURL.path
                    if entries.contains(where: { $0.id == key }) { skipped += 1; continue }
                } else {
                    let destination = LocalPhotoLibrarySelectionLoader.temporaryURL(
                        fileExtension: URL(fileURLWithPath: item.name).pathExtension)
                    try FileManager.default.copyItem(at: downloaded, to: destination)
                    url = destination
                }
                if Task.isCancelled || entries.contains(where: { $0.id == key }) {
                    if ownsCopies { try? FileManager.default.removeItem(at: url) }
                    break
                }
                var duration: TimeInterval?
                if item.isVideo {
                    let seconds = try? await AVURLAsset(url: url).load(.duration).seconds
                    if let seconds, seconds.isFinite, seconds > 0 { duration = seconds }
                }
                let entryItem = RemoteFileItem(connectionID: LocalPhotoLibraryFileService.connectionID, path: key,
                    name: item.name, kind: .file, size: item.size, modifiedAt: item.modifiedAt,
                    contentTypeIdentifier: item.contentTypeIdentifier)
                var entry = Entry(id: key, item: entryItem, url: url, isVideo: item.isVideo, thumbnail: nil,
                                  origin: origin, duration: duration)
                entry.ownsURL = ownsCopies
                entry.reference = references[item.path] ?? WorkbenchEntryFactory.entry(
                    remote: item,
                    sourceLabel: origin == .phoneHard ? WorkbenchSourceLabel.phoneHard
                        : service is DeviceFolderFileService ? WorkbenchSourceLabel.deviceFiles : WorkbenchSourceLabel.nas)
                entries.append(entry)
                await loadThumbnail(for: key)
                added += 1
            } catch is CancellationError { break }
            catch { failedNames.append(item.name) }
        }
        if !failedNames.isEmpty {
            let names = failedNames.prefix(3).joined(separator: ", ")
            errorMessage = "\(failedNames.count)개 항목을 가져오지 못했습니다: \(names). 기존 선택과 가져온 \(added)개는 유지됩니다."
        } else if added > 0 {
            showTemporaryImportSummary("\(added)개를 선택에 추가했습니다." + (skipped > 0 ? " 이미 있는 \(skipped)개는 건너뛰었습니다." : ""))
        }
    }

    private func showTemporaryImportSummary(_ text: String) {
        importSummaryText = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if importSummaryText == text {
                importSummaryText = nil
            }
        }
    }


    private func copySelectedToPhoneHard(_ selection: [Entry], toFolder folderPath: String?) async {
        // 첫 await 전에 출처를 고정한다(준비 중 모드가 바뀌어도 이 복사의 공개 범위는 그대로).
        let jobPrivate: Bool = PrivacyMode.currentlyActive
        let prepared = await prepare(selection)
        guard !Task.isCancelled, !prepared.isEmpty else { return }
        isCopyingToPhoneHard = true
        copyProgressTotal = prepared.count
        copyProgressCompleted = 0
        defer { isCopyingToPhoneHard = false; copyProgressTotal = 0; copyProgressCompleted = 0 }
        var succeeded = 0
        var failed = 0
        for (entry, url) in prepared {
            if Task.isCancelled { break }
            do {
                _ = try await inboxStore.importDownloadedItem(at: url, originalName: entry.item.name,
                    contentTypeIdentifier: entry.item.contentTypeIdentifier, intoFolder: folderPath, isPrivate: jobPrivate)
                succeeded += 1
            } catch { failed += 1 }
            copyProgressCompleted += 1
        }
        if failed > 0 { errorMessage = "폰하드로 \(succeeded)개를 복사했습니다. \(failed)개는 실패했으며 선택은 유지됩니다." }
        else { showTemporaryImportSummary("폰하드로 \(succeeded)개를 복사했습니다.") }
    }
    private func loadThumbnail(for id: String) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        guard let url = entry.url else { return }
        let isVideo = entry.isVideo
        let image = await Task.detached(priority: .utility) {
            if isVideo {
                let asset = AVURLAsset(url: url)
                let generator = AVAssetImageGenerator(asset: asset)
                generator.appliesPreferredTrackTransform = true
                generator.maximumSize = CGSize(width: 240, height: 240)
                guard let cgImage = try? generator.copyCGImage(at: .zero, actualTime: nil) else { return nil as UIImage? }
                return UIImage(cgImage: cgImage)
            }
            guard let data = try? Data(contentsOf: url) else { return nil as UIImage? }
            return UIImage(data: data)
        }.value
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].thumbnail = image
    }


    /// 화면을 떠날 때는 선택(항목·임시 사본·Google 세션)을 세션에 그대로 남기고,
    /// 이 화면이 미리보기·편집을 위해 만든 파생 임시 파일만 정리한다. 진행 중 작업은 취소만 한다.
    private func cleanupTemporaryFiles() {
        guard trailerSelection == nil, previewItem == nil, nativePreviewAsset == nil, !isPickerPresented, !isFileImporterPresented,
              !isChoosingPhoneHardDestination, pendingPhoneHardCopy == nil else { return }
        guard !isLoadingSelection, !isFileImporting, !isCopyingToPhoneHard, preparationTask == nil else {
            isCleanupPendingOnDeparture = true
            preparationTask?.cancel()
            return
        }
        isCleanupPendingOnDeparture = false
        for url in previewTemporaryURLs { try? FileManager.default.removeItem(at: url) }
        previewTemporaryURLs = []
        editingService = nil
        for url in editingTemporaryURLs { try? FileManager.default.removeItem(at: url) }
        editingTemporaryURLs = []
    }
    /// 사용자가 명시적으로 선택을 모두 비울 때만 대기 항목과 앱 소유 임시 사본을 해제한다.
    private func clearSelection() {
        guard !isBusy, preparationTask == nil else { return }
        session.releaseAll()
    }
    private func runDeferredCleanupIfPending() {
        if isCleanupPendingOnDeparture { cleanupTemporaryFiles() }
    }
}
