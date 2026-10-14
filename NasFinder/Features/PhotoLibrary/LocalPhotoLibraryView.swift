import AVFoundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Browses photos/videos picked from the system Photos picker, entirely without a NAS
/// connection and without requesting photo-library access: only the items the user
/// explicitly selects are copied into the app's sandbox for preview and trailer creation.
struct LocalPhotoLibraryView: View {
    private struct Entry: Identifiable {
        let id: String
        let item: RemoteFileItem
        let url: URL
        let isVideo: Bool
        var thumbnail: UIImage?
    }

    @EnvironmentObject private var inboxStore: SharedInboxStore

    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var hasAutoPresentedPicker = false
    @State private var entries: [Entry] = []
    @State private var isPickerPresented = false
    @State private var isLoadingSelection = false
    @State private var errorMessage: String?
    @State private var pendingSelection: [PhotosPickerItem]?
    @State private var isProcessingSelection = false
    @State private var trailerSelection: VideoTrailerSelection?
    @State private var previewItem: RemoteFileItem?

    /// `PhotosPickerItem.itemIdentifier` is nil for assets without a stable PHAsset
    /// identifier (e.g. items from a limited library grant). There is no `.id` member
    /// on `PhotosPickerItem`, so for those items this remembers a UUID keyed by the
    /// `PhotosPickerItem` value itself (which is `Hashable`), giving every item a
    /// stable identity for the lifetime it stays in `pickerSelection`.
    @State private var rememberedIdentities: [PhotosPickerItem: String] = [:]

    @State private var loadTotal = 0
    @State private var loadCompleted = 0
    @State private var currentLoadingLabel: String?
    @State private var importSummaryText: String?

    @State private var isCopyingToPhoneHard = false
    @State private var copyProgressTotal = 0
    @State private var copyProgressCompleted = 0

    private let columns = [GridItem(.adaptive(minimum: ui(92), maximum: ui(120)), spacing: ui(8))]

    private var service: LocalPhotoLibraryFileService {
        LocalPhotoLibraryFileService(entries: entries.map { ($0.item, $0.url) })
    }

    var body: some View {
        content
            .navigationTitle("내 사진·영상")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Group {
                        Button {
                            isPickerPresented = true
                        } label: {
                            Label("선택", systemImage: "photo.badge.plus")
                        }
                    }
                    .uiBarFont()
                }
            }
            .photosPicker(
                isPresented: $isPickerPresented,
                selection: $pickerSelection,
                matching: .any(of: [.images, .videos]),
                photoLibrary: .shared()
            )
            .onChange(of: pickerSelection) { _, newValue in
                syncEntries(with: newValue)
            }
            .onAppear {
                // Present the native picker automatically only on this view's very first
                // appearance, so the user doesn't need an extra tap to open it after
                // navigating in, but returning here (from the trailer, preview, or a
                // pushed screen) never re-triggers or re-clears an in-progress selection.
                guard !hasAutoPresentedPicker else { return }
                hasAutoPresentedPicker = true
                isPickerPresented = true
            }
            .fullScreenCover(item: $trailerSelection) { selection in
                VideoTrailerView(items: selection.items, service: service, mode: selection.mode)
            }
            .fullScreenCover(item: $previewItem) { item in
                RemotePreviewView(
                    item: item,
                    sequentialItems: entries.map(\.item),
                    service: service,
                    onClose: { previewItem = nil }
                )
            }
            .alert("알림", isPresented: errorBinding) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onDisappear(perform: cleanupTemporaryFiles)
    }

    @ViewBuilder
    private var content: some View {
        if entries.isEmpty, isLoadingSelection {
            loadingProgressView
        } else if entries.isEmpty {
            ContentUnavailableView {
                Label("사진과 영상을 선택하세요", systemImage: "photo.on.rectangle.angled")
            } description: {
                Text("iPhone 사진 보관함에서 선택한 항목만 미리 보고 예고편을 만듭니다. NAS 연결 없이도 사용할 수 있고, 선택만으로는 아무것도 업로드되지 않습니다.")
            } actions: {
                Button("사진·영상 선택", systemImage: "photo.badge.plus") {
                    isPickerPresented = true
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: ui(8)) {
                    ForEach(entries) { entry in
                        gridCell(entry)
                    }
                }
                .padding(ui(12))
            }
            .safeAreaInset(edge: .top) {
                if isLoadingSelection {
                    progressBanner
                } else if let importSummaryText {
                    Text(importSummaryText)
                        .font(.ui(.footnote))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, ui(12))
                        .padding(.vertical, ui(6))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomActionBar
            }
        }
    }

    private var loadingProgressView: some View {
        VStack(spacing: ui(16)) {
            if loadTotal > 0 {
                ProgressView(value: Double(loadCompleted), total: Double(loadTotal))
                    .frame(maxWidth: ui(220))
            } else {
                ProgressView()
            }
            Text(progressStatusText)
                .font(.ui(.subheadline))
                .foregroundStyle(.secondary)
            if let currentLoadingLabel {
                Text(currentLoadingLabel)
                    .font(.ui(.caption))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var progressBanner: some View {
        VStack(alignment: .leading, spacing: ui(4)) {
            Text(progressStatusText)
                .font(.ui(.footnote))
            if loadTotal > 0 {
                ProgressView(value: Double(loadCompleted), total: Double(loadTotal))
            } else {
                ProgressView()
                    .scaleEffect(0.7, anchor: .leading)
            }
            if let currentLoadingLabel {
                Text(currentLoadingLabel)
                    .font(.ui(.caption2))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, ui(12))
        .padding(.vertical, ui(8))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    private var progressStatusText: String {
        guard loadTotal > 0 else { return "사진·영상 가져오는 중…" }
        return "사진·영상 가져오는 중 · \(loadCompleted)/\(loadTotal)개"
    }

    @ViewBuilder
    private var bottomActionBar: some View {
        VStack(spacing: ui(8)) {
            if isCopyingToPhoneHard {
                VStack(alignment: .leading, spacing: ui(4)) {
                    Text(copyProgressTotal > 0
                        ? "폰하드로 복사하는 중 · \(copyProgressCompleted)/\(copyProgressTotal)개"
                        : "폰하드로 복사하는 중…")
                        .font(.ui(.footnote))
                    if copyProgressTotal > 0 {
                        ProgressView(value: Double(copyProgressCompleted), total: Double(copyProgressTotal))
                    }
                }
            }
            HStack(spacing: ui(8)) {
                Button {
                    Task { await copySelectedToPhoneHard() }
                } label: {
                    Label("폰하드에 복사", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingSelection || isCopyingToPhoneHard || entries.isEmpty)

                if entries.contains(where: { $0.item.isTrailerEligible }) {
                    Button {
                        let clips = entries.map(\.item).filter(\.isTrailerEligible)
                        guard !clips.isEmpty else { return }
                        trailerSelection = VideoTrailerSelection(items: clips)
                    } label: {
                        Label("예고편 만들기", systemImage: "film")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isLoadingSelection || isCopyingToPhoneHard)
                }
            }
            if entries.contains(where: { $0.item.isTrailerEligible }) {
                Button {
                    let clips = entries.map(\.item).filter(\.isTrailerEligible)
                    guard !clips.isEmpty else { return }
                    trailerSelection = VideoTrailerSelection(items: clips, mode: .mediaMusic)
                } label: {
                    Label("음악 입히기", systemImage: "music.note")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(isLoadingSelection || isCopyingToPhoneHard)
            }
        }
        .padding(ui(12))
        .background(.bar)
    }

    private func gridCell(_ entry: Entry) -> some View {
        Button {
            previewItem = entry.item
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = entry.thumbnail {
                        Image(uiImage: thumbnail)
                            .resizable()
                            .scaledToFill()
                    } else {
                        Rectangle()
                            .fill(.secondary.opacity(0.15))
                        ProgressView()
                    }
                }
                .frame(width: ui(100), height: ui(100))
                .clipShape(RoundedRectangle(cornerRadius: ui(10), style: .continuous))

                if entry.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.ui(.caption))
                        .foregroundStyle(.white)
                        .padding(ui(4))
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("선택 해제", systemImage: "xmark.circle") {
                remove(entry)
            }
            if entry.item.isTrailerEligible {
                Button("예고편 보기", systemImage: "film") {
                    trailerSelection = VideoTrailerSelection(items: [entry.item])
                }
            }
            if entry.item.isVideo {
                Button("음악 입히기", systemImage: "music.note") {
                    trailerSelection = VideoTrailerSelection(items: [entry.item], mode: .mediaMusic)
                }
            }
        }
        .accessibilityLabel(entry.isVideo ? "영상" : "사진")
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }

    private func photoKey(for item: PhotosPickerItem) -> String {
        if let itemIdentifier = item.itemIdentifier {
            return itemIdentifier
        }
        if let remembered = rememberedIdentities[item] {
            return remembered
        }
        let generated = UUID().uuidString
        rememberedIdentities[item] = generated
        return generated
    }

    private func remove(_ entry: Entry) {
        pickerSelection.removeAll { photoKey(for: $0) == entry.id }
        entries.removeAll { $0.id == entry.id }
        rememberedIdentities = rememberedIdentities.filter { $0.value != entry.id }
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// Selection changes are queued and drained by a single serialized loop so that
    /// overlapping PhotosPicker updates (fired while a previous import batch is still
    /// loading) can never race on `entries`, append duplicates, or resurrect an item
    /// the user already deselected before its load finished.
    private func syncEntries(with newSelection: [PhotosPickerItem]) {
        pendingSelection = newSelection
        guard !isProcessingSelection else { return }
        isProcessingSelection = true
        Task {
            while let selection = pendingSelection {
                pendingSelection = nil
                await applySelection(selection)
            }
            isProcessingSelection = false
        }
    }

    private func applySelection(_ newSelection: [PhotosPickerItem]) async {
        let newKeys = Set(newSelection.map(photoKey))
        let removed = entries.filter { !newKeys.contains($0.id) }
        for entry in removed {
            try? FileManager.default.removeItem(at: entry.url)
        }
        entries.removeAll { !newKeys.contains($0.id) }
        rememberedIdentities = rememberedIdentities.filter { newKeys.contains($0.value) }

        let existingKeys = Set(entries.map(\.id))
        let additions = newSelection.filter { !existingKeys.contains(photoKey(for: $0)) }
        guard !additions.isEmpty else { return }

        isLoadingSelection = true
        loadTotal = additions.count
        loadCompleted = 0
        var addedCount = 0
        var failedCount = 0

        for pickerItem in additions {
            let key = photoKey(for: pickerItem)
            let types = pickerItem.supportedContentTypes
            let looksLikeVideo = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
            currentLoadingLabel = looksLikeVideo ? "영상 불러오는 중" : "사진 불러오는 중"

            do {
                let media = try await LocalPhotoLibrarySelectionLoader.load(item: pickerItem)

                // The user may have deselected this item (or it may already have been
                // added by a newer queued batch) while the load was in flight.
                let stillWanted = pickerSelection.contains { photoKey(for: $0) == key }
                let alreadyAdded = entries.contains { $0.id == key }
                guard stillWanted, !alreadyAdded else {
                    try? FileManager.default.removeItem(at: media.url)
                    loadCompleted += 1
                    continue
                }

                let byteCount = (try? FileManager.default.attributesOfItem(atPath: media.url.path)[.size] as? Int64) ?? nil
                let name = "\(media.isVideo ? "동영상" : "사진")-\(entries.count + 1).\(media.url.pathExtension)"
                let item = RemoteFileItem(
                    connectionID: LocalPhotoLibraryFileService.connectionID,
                    path: key,
                    name: name,
                    kind: .file,
                    size: byteCount,
                    modifiedAt: nil,
                    contentTypeIdentifier: media.contentType?.identifier
                )
                entries.append(
                    Entry(id: key, item: item, url: media.url, isVideo: media.isVideo, thumbnail: nil)
                )
                await loadThumbnail(for: key)
                addedCount += 1
            } catch {
                failedCount += 1
                errorMessage = "일부 항목을 불러오지 못했습니다: \(error.localizedDescription)"
            }
            loadCompleted += 1
        }

        isLoadingSelection = false
        loadTotal = 0
        loadCompleted = 0
        currentLoadingLabel = nil

        if addedCount > 0 {
            importSummaryText = failedCount > 0
                ? "사진·영상 \(addedCount)개를 가져왔습니다. \(failedCount)개는 실패했습니다."
                : "사진·영상 \(addedCount)개를 가져왔습니다."
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if importSummaryText != nil {
                    importSummaryText = nil
                }
            }
        }
    }

    /// Copies the currently selected gallery entries into the durable PhoneHard inbox
    /// via `SharedInboxStore`'s normal import API, so originals stay untouched and
    /// available for preview/trailer while a separate copy lands in PhoneHard.
    private func copySelectedToPhoneHard() async {
        guard !isLoadingSelection, !isCopyingToPhoneHard else { return }
        let snapshot = entries
        guard !snapshot.isEmpty else { return }

        isCopyingToPhoneHard = true
        copyProgressTotal = snapshot.count
        copyProgressCompleted = 0
        var succeeded = 0
        var failed = 0

        for entry in snapshot {
            guard FileManager.default.fileExists(atPath: entry.url.path) else {
                failed += 1
                copyProgressCompleted += 1
                continue
            }
            do {
                _ = try await inboxStore.importDownloadedFile(
                    at: entry.url,
                    originalFilename: entry.item.name,
                    contentTypeIdentifier: entry.item.contentTypeIdentifier
                )
                succeeded += 1
            } catch {
                failed += 1
            }
            copyProgressCompleted += 1
        }

        isCopyingToPhoneHard = false
        copyProgressTotal = 0
        copyProgressCompleted = 0

        if failed > 0 {
            errorMessage = "폰하드로 \(succeeded)개를 복사했습니다. \(failed)개는 복사하지 못했습니다."
        } else {
            importSummaryText = "폰하드로 \(succeeded)개를 복사했습니다."
            Task {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if importSummaryText != nil {
                    importSummaryText = nil
                }
            }
        }
    }

    private func loadThumbnail(for id: String) async {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        let url = entry.url
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
        // SwiftUI can fire `onDisappear` on the presenting view while a `fullScreenCover`
        // (preview/trailer) is still up, or while an import batch is still writing files.
        // Only delete our owned temp copies once nothing is still consuming them.
        guard trailerSelection == nil, previewItem == nil, !isProcessingSelection else { return }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry.url)
        }
    }
}
