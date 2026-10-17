import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// 사진과 달력은 같은 PHAsset 바스켓을 사용하며 실제 작업을 시작할 때만 원본을 복사한다.
struct LocalPhotoLibraryView: View {
    private enum BrowseMode: String, CaseIterable, Identifiable {
        case photos = "사진"
        case calendar = "달력"
        var id: String { rawValue }
    }
    private enum EntryOrigin { case photoPicker, calendar, file }
    private struct Entry: Identifiable {
        let id: String
        let item: RemoteFileItem
        var url: URL?
        let isVideo: Bool
        var thumbnail: UIImage?
        let origin: EntryOrigin
        var duration: TimeInterval?
        var asset: PHAsset? = nil
        var pickerItem: PhotosPickerItem? = nil
    }
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @Environment(\.scenePhase) private var scenePhase
    private let initialMode: VideoTrailerMode?
    init(initialMode: VideoTrailerMode? = nil) { self.initialMode = initialMode }

    @State private var mode: BrowseMode = .photos
    @State private var libraryAssets: PHFetchResult<PHAsset>?
    @State private var authorizationStatus = LocalPhotoLibraryCalendarService.authorizationStatus
    @State private var isLoadingLibrary = false
    @State private var libraryQueryGeneration = 0
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var entries: [Entry] = []
    @State private var isPickerPresented = false
    @State private var isFileImporterPresented = false
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
    @State private var rememberedIdentities: [PhotosPickerItem: String] = [:]
    @State private var loadTotal = 0
    @State private var loadCompleted = 0
    @State private var currentLoadingLabel: String?
    @State private var importSummaryText: String?
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
        case .trailer: "예고편 만들기"
        case .mediaMusic: "뮤직비디오"
        case nil: "내 사진·영상"
        }
    }
    var body: some View { mediaContent.modifier(PreserveMediaNavigation()) }
    private var mediaContent: some View {
        VStack(spacing: 0) {
            Picker("보기 방식", selection: $mode) {
                ForEach(BrowseMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, ui(12)).padding(.top, ui(8))
            modeContent.disabled(isBusy)
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("파일에서 추가", systemImage: "folder.badge.plus") { isFileImporterPresented = true }
                    Button("시스템 사진 선택기", systemImage: "photo.badge.plus") { isPickerPresented = true }
                } label: { Label("추가", systemImage: "plus") }
                .disabled(isBusy).uiBarFont()
            }
        }
        .safeAreaInset(edge: .bottom) { bottomActionBar }
        .safeAreaInset(edge: .top) {
            if isLoadingSelection { progressBanner }
            else if let importSummaryText {
                Text(importSummaryText).font(.ui(.footnote)).foregroundStyle(.secondary)
                    .padding(ui(8)).frame(maxWidth: .infinity, alignment: .leading).background(.bar)
            }
        }
        .photosPicker(isPresented: $isPickerPresented, selection: $pickerSelection,
                      matching: .any(of: [.images, .videos]), photoLibrary: .shared())
        .fileImporter(isPresented: $isFileImporterPresented, allowedContentTypes: [.image, .movie], allowsMultipleSelection: true,
                      onCompletion: handleFileImportResult)
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
        .fullScreenCover(item: $trailerSelection) { selection in
            VideoTrailerView(items: selection.items, service: editingService ?? service, mode: selection.mode)
        }
        .fullScreenCover(item: $previewItem) { item in
            RemotePreviewView(item: item, sequentialItems: previewItems, service: previewService ?? service,
                              onClose: { previewItem = nil })
        }
        .alert("알림", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
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
    @ViewBuilder private var modeContent: some View {
        switch mode {
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
        }
    }
    private var photoModeContent: some View {
        VStack(spacing: ui(6)) {
            if authorizationStatus == .limited {
                HStack {
                    Text("허용한 사진·영상만 표시됩니다").font(.ui(.footnote)).foregroundStyle(.secondary)
                    Spacer()
                    Button("선택 변경") { presentLimitedLibraryPicker() }.font(.ui(.footnote))
                }.padding(.horizontal, ui(12))
            }
            let extraEntries = entries.filter { $0.asset == nil }
            if !extraEntries.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: ui(8)) {
                        ForEach(extraEntries) { selectedEntryCell($0) }
                    }.padding(.horizontal, ui(12))
                }.frame(height: ui(108))
            }
            if authorizationStatus == .authorized || authorizationStatus == .limited {
                if let libraryAssets, libraryAssets.count > 0 {
                    NasFinderPhotoGrid(assets: libraryAssets,
                        selection: entries.filter { $0.asset != nil }.map(\.id),
                        onSelectionChange: applyPhotoGridSelection)
                } else if isLoadingLibrary { ProgressView("사진 보관함 불러오는 중") }
                else {
                    ContentUnavailableView("사진·영상이 없습니다", systemImage: "photo.on.rectangle",
                        description: Text(authorizationStatus == .limited ? "선택 변경으로 허용할 사진·영상을 추가할 수 있습니다." : "사진 보관함의 사진·영상이 여기에 표시됩니다."))
                }
            } else { photoAccessContent }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
    private var photoAccessContent: some View {
        ContentUnavailableView {
            Label("사진 보관함 접근이 꺼져 있습니다", systemImage: "lock")
        } description: {
            Text("설정에서 사진 접근을 허용하거나 시스템 선택기로 필요한 항목만 선택할 수 있습니다. 기존 선택 항목은 유지됩니다.")
        } actions: {
            Button("설정에서 사진 접근 확인") { openPhotoSettings() }
            Button("시스템 사진 선택기") { isPickerPresented = true }.buttonStyle(.borderedProminent)
        }
    }
    private var bottomActionBar: some View {
        VStack(spacing: ui(8)) {
            if isCopyingToPhoneHard {
                Text("폰하드로 복사하는 중 · \(copyProgressCompleted)/\(copyProgressTotal)개").font(.ui(.footnote))
                ProgressView(value: Double(copyProgressCompleted), total: Double(max(copyProgressTotal, 1)))
            }
            HStack {
                Text("선택됨 \(entries.count)개").font(.ui(.footnote)).foregroundStyle(.secondary)
                Spacer()
                if !entries.isEmpty {
                    Button("미리보기", systemImage: "eye") {
                        startPreparation { await previewSelected() }
                    }.font(.ui(.footnote)).disabled(isBusy)
                }
            }
            HStack(spacing: ui(8)) {
                Button {
                    pendingPhoneHardCopy = nil
                    inboxStore.reload()
                    isChoosingPhoneHardDestination = true
                } label: { Text("폰하드 복사").frame(maxWidth: .infinity, minHeight: ui(32)) }
                Button {
                    startPreparation { await beginTrailer(mode: .trailer) }
                } label: { Text("예고편 제작").frame(maxWidth: .infinity, minHeight: ui(32)) }
                Button {
                    startPreparation { await beginTrailer(mode: .mediaMusic) }
                } label: { Text("뮤직비디오").frame(maxWidth: .infinity, minHeight: ui(32)) }
            }
            .font(.ui(.subheadline).weight(.semibold))
            .buttonStyle(.borderedProminent)
            .disabled(isBusy || entries.isEmpty)
        }.padding(ui(12)).background(.bar)
    }
    private var progressStatusText: String {
        loadTotal > 0 ? "사진·영상 준비 중 · \(loadCompleted)/\(loadTotal)개" : "사진·영상 준비 중…"
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
        }.padding(ui(10)).background(.bar)
    }
    private func selectedEntryCell(_ entry: Entry) -> some View {
        Button { remove(entry) } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = entry.thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Rectangle().fill(.secondary.opacity(0.15)).overlay(Image(systemName: entry.isVideo ? "film" : "photo")) }
                }.frame(width: ui(100), height: ui(100)).clipped()
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Color.accentColor).padding(ui(4))
                    .allowsHitTesting(false).accessibilityHidden(true)
            }.clipShape(RoundedRectangle(cornerRadius: ui(10)))
        }.buttonStyle(.plain)
        .highPriorityGesture(
            LongPressGesture(minimumDuration: 0.45, maximumDistance: 10)
                .exclusively(before: TapGesture())
                .onEnded { gesture in
                    switch gesture {
                    case .first: startPreparation { await previewSelected(ids: [entry.id]) }
                    case .second: remove(entry)
                    }
                }
        )
        .accessibilityAction(named: "미리보기") { startPreparation { await previewSelected(ids: [entry.id]) } }
        .accessibilityLabel(entry.item.name).accessibilityAddTraits(.isSelected)
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
        if let url = entry.url { try? FileManager.default.removeItem(at: url) }
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
            entries.append(Entry(id: key, item: item, url: nil, isVideo: isVideo, thumbnail: nil, origin: .photoPicker, pickerItem: pickerItem))
        }
    }
    private func assetEntry(_ asset: PHAsset) -> Entry {
        let isVideo = asset.mediaType == .video
        let name = LocalPhotoLibraryCalendarService.originalFilename(for: asset) ?? "\(isVideo ? "동영상.mov" : "사진.jpg")"
        let type = UTType(filenameExtension: URL(fileURLWithPath: name).pathExtension) ?? (isVideo ? .movie : .image)
        let item = RemoteFileItem(connectionID: LocalPhotoLibraryFileService.connectionID, path: asset.localIdentifier,
                                  name: name, kind: .file, size: nil, modifiedAt: asset.creationDate, contentTypeIdentifier: type.identifier)
        return Entry(id: asset.localIdentifier, item: item, url: nil, isVideo: isVideo, thumbnail: nil, origin: .calendar,
                     duration: LocalPhotoLibraryCalendarService.duration(for: asset), asset: asset)
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
        for entry in removed {
            if let url = entry.url { try? FileManager.default.removeItem(at: url) }
        }
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
        }
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
        trailerSelection = VideoTrailerSelection(items: clips, mode: mode)
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
                    ? "파일에서 \(addedCount)개를 가져왔습니다. \(failedCount)개는 실패했습니다."
                    : "파일에서 \(addedCount)개를 가져왔습니다."
            )
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
                    contentTypeIdentifier: entry.item.contentTypeIdentifier, intoFolder: folderPath)
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


    private func cleanupTemporaryFiles() {
        guard trailerSelection == nil, previewItem == nil, nativePreviewAsset == nil, !isPickerPresented, !isFileImporterPresented,
              !isChoosingPhoneHardDestination, pendingPhoneHardCopy == nil else { return }
        guard !isLoadingSelection, !isFileImporting, !isCopyingToPhoneHard, preparationTask == nil else {
            isCleanupPendingOnDeparture = true
            preparationTask?.cancel()
            return
        }
        isCleanupPendingOnDeparture = false
        for entry in entries {
            if let url = entry.url { try? FileManager.default.removeItem(at: url) }
        }
        for url in previewTemporaryURLs { try? FileManager.default.removeItem(at: url) }
        previewTemporaryURLs = []
        editingService = nil
        for url in editingTemporaryURLs { try? FileManager.default.removeItem(at: url) }
        editingTemporaryURLs = []
    }
    private func runDeferredCleanupIfPending() {
        if isCleanupPendingOnDeparture { cleanupTemporaryFiles() }
    }
}
