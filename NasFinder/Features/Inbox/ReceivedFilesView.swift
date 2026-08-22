import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

private enum ReceivedFilesLayoutStyle: String, CaseIterable, Identifiable {
    case details
    case thumbnails
    case posters
    case overflow

    var id: String { rawValue }

    var title: String {
        switch self {
        case .details: "자세히"
        case .thumbnails: "썸네일"
        case .posters: "포스터"
        case .overflow: "오버플로우"
        }
    }

    var systemImage: String {
        switch self {
        case .details: "list.bullet"
        case .thumbnails: "square.grid.3x3"
        case .posters: "square.grid.2x2"
        case .overflow: "rectangle.stack.fill"
        }
    }
}

struct ReceivedFilesView: View {
    private struct UploadabilityTaskID: Hashable {
        let records: [SharedInboxRecord]
        let refreshGeneration: Int
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var webHardController: WebHardServerController
    @AppStorage("receivedFilesLayoutStyle.v1") private var storedLayoutStyle =
        ReceivedFilesLayoutStyle.details.rawValue
    @AppStorage("receivedFilesOverflowDark.v1") private var overflowUsesDarkBackground = false
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    @State private var previewItem: RemoteFileItem?
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadableRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadabilityRefreshGeneration = 0
    @State private var pendingUploadSources: [LocalUploadSource] = []
    @State private var isChoosingUploadDestination = false
    @State private var isImportingFromFiles = false
    @State private var isImportingFromGooglePhotos = false
    @State private var isConfirmingSelectionDeletion = false

    var body: some View {
        VStack(spacing: 0) {
            if !isSelecting {
                WebHardConnectionPanel()
                    .frame(maxWidth: 760)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 14)
            }

            Group {
                if inboxStore.records.isEmpty {
                    ContentUnavailableView {
                        Label("폰하드가 비어 있습니다", systemImage: "tray")
                    } description: {
                        Text("내가 저장하거나 다른 기기에서 보낸 파일이 이곳에 모입니다.")
                    } actions: {
                        Button("파일 가져오기", systemImage: "doc.badge.plus") {
                            isImportingFromFiles = true
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Google 포토에서 가져오기", systemImage: "photo.badge.arrow.down") {
                            isImportingFromGooglePhotos = true
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    receivedFilesContent
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(SkyBreezeBackground())
        .navigationTitle(
            isSelecting ? "\(selectedRecords.count)개 선택" : (isEnamel ? "" : "폰하드")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(allRecordsAreSelected ? "전체 해제" : "전체 선택") {
                        toggleAllSelection()
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("지우기", systemImage: "trash", role: .destructive) {
                        isConfirmingSelectionDeletion = true
                    }
                    .disabled(selectedRecords.isEmpty)

                    Button("완료") {
                        endSelection()
                    }
                }
            } else {
                if isEnamel {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            PhoneHardMark(size: 26)
                            Text("폰하드")
                                .font(.headline)
                                .foregroundStyle(.primary)
                        }
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    if !inboxStore.records.isEmpty {
                        Menu {
                            ForEach(ReceivedFilesLayoutStyle.allCases) { style in
                                Button {
                                    storedLayoutStyle = style.rawValue
                                } label: {
                                    Label(style.title, systemImage: style.systemImage)
                                    if layoutStyle == style {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: layoutStyle.systemImage)
                        }
                        .accessibilityLabel("보기")
                    }

                    Menu {
                        Button("파일에서 가져오기", systemImage: "doc.badge.plus") {
                            isImportingFromFiles = true
                        }
                        Button("Google 포토에서 가져오기", systemImage: "photo.badge.arrow.down") {
                            isImportingFromGooglePhotos = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("폰하드 메뉴")

                    if !inboxStore.records.isEmpty {
                        Button("선택") {
                            isSelecting = true
                        }
                    }
                }
            }
        }
        .modifier(
            ReceivedFilesImporterModifier(
                isPresented: $isImportingFromFiles,
                importFiles: { urls in
                    Task {
                        await inboxStore.importFromFiles(urls)
                    }
                },
                importFailed: { error in
                    let cocoaError = error as NSError
                    guard !(cocoaError.domain == NSCocoaErrorDomain
                            && cocoaError.code == CocoaError.Code.userCancelled.rawValue) else {
                        return
                    }
                    inboxStore.errorMessage =
                        "파일을 선택하지 못했습니다: \(error.localizedDescription)"
                }
            )
        )
        .safeAreaInset(edge: .bottom) {
            if isSelecting {
                uploadSelectionBar
            }
        }
        .task {
            reloadInbox()
            if let recordID = inboxStore.consumePendingPreviewRecordID(),
               let record = inboxStore.records.first(where: { $0.id == recordID }) {
                previewItem = LocalInboxFileService.remoteItem(for: record)
            }
        }
        .onAppear(perform: reloadInbox)
        .task(id: uploadabilityTaskID) {
            let records = inboxStore.records
            let refreshGeneration = uploadabilityRefreshGeneration
            let uploadableIDs = await Task.detached(priority: .utility) {
                Set(records.compactMap { record -> SharedInboxRecord.ID? in
                    guard let url = try? SharedInbox.fileURL(for: record),
                          let values = try? url.resourceValues(
                            forKeys: [.isRegularFileKey]
                          ),
                          values.isRegularFile == true else { return nil }
                    return record.id
                })
            }.value
            guard !Task.isCancelled,
                  inboxStore.records == records,
                  uploadabilityRefreshGeneration == refreshGeneration else { return }
            uploadableRecordIDs = uploadableIDs
            selectedRecordIDs.formIntersection(uploadableIDs)
        }
        .onChange(of: Set(inboxStore.records.map(\.id))) { _, validRecordIDs in
            selectedRecordIDs.formIntersection(validRecordIDs)
        }
        .onChange(of: webHardController.thumbnailGeneration) { _, _ in
            reloadInbox()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            uploadabilityRefreshGeneration &+= 1
        }
        .alert("폰하드 오류", isPresented: errorBinding) {
            Button("확인", role: .cancel) {
                inboxStore.errorMessage = nil
            }
        } message: {
            Text(inboxStore.errorMessage ?? "")
        }
        .alert("선택한 파일을 지울까요?", isPresented: $isConfirmingSelectionDeletion) {
            Button("취소", role: .cancel) {}
            Button("지우기", role: .destructive) {
                deleteSelectedRecords()
            }
        } message: {
            Text("선택한 \(selectedRecords.count)개 파일이 이 기기에서 삭제됩니다.")
        }
        .fullScreenCover(item: $previewItem) { item in
            let records = inboxStore.records
            let service = LocalInboxFileService(records: records)
            RemotePreviewView(
                item: item,
                sequentialItems: sequentialMediaItems(from: records, including: item),
                service: service
            )
        }
        .sheet(
            isPresented: $isChoosingUploadDestination,
            onDismiss: {
                pendingUploadSources = []
                endSelection()
            }
        ) {
            InboxUploadDestinationView(sources: pendingUploadSources)
        }
        .sheet(
            isPresented: $isImportingFromGooglePhotos,
            onDismiss: {
                reloadInbox()
            }
        ) {
            GooglePhotosImportFlowView(inboxStore: inboxStore)
        }
    }

    @ViewBuilder
    private var receivedFilesContent: some View {
        switch layoutStyle {
        case .details:
            List {
                ForEach(inboxStore.records) { record in
                    receivedFileRow(record)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if !isSelecting {
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    inboxStore.delete(record)
                                }
                            }
                        }
                        .contextMenu { recordContextMenu(record) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { reloadInbox() }
        case .thumbnails, .posters:
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: layoutStyle == .posters ? 20 : 14) {
                    ForEach(inboxStore.records) { record in
                        receivedFileTile(record, poster: layoutStyle == .posters)
                            .contextMenu { recordContextMenu(record) }
                    }
                }
                .padding(16)
            }
            .refreshable { reloadInbox() }
        case .overflow:
            FileBrowserCoverFlowView(
                items: inboxStore.records,
                usesDarkBackground: $overflowUsesDarkBackground,
                itemName: { $0.originalFilename },
                thumbnail: { record, size in
                    let item = LocalInboxFileService.remoteItem(for: record)
                    return receivedFileArtwork(for: item, record: record, requestSize: size)
                },
                onActivate: activate,
                onShowActions: nil
            )
        }
    }

    private var layoutStyle: ReceivedFilesLayoutStyle {
        ReceivedFilesLayoutStyle(rawValue: storedLayoutStyle) ?? .details
    }

    private var isEnamel: Bool {
        AppThemePreference.resolved(selectedThemeRawValue) == .skeuomorphism
    }

    private var gridColumns: [GridItem] {
        [GridItem(.adaptive(minimum: layoutStyle == .posters ? 164 : 104), spacing: 14)]
    }

    @ViewBuilder
    private func recordContextMenu(_ record: SharedInboxRecord) -> some View {
        if !isSelecting {
            if isUploadableFile(record) {
                Button("NAS로 보내기", systemImage: "arrow.up.doc") {
                    beginUpload(of: [record])
                }
            }

            if let fileURL = try? SharedInbox.fileURL(for: record) {
                ShareLink(item: fileURL) {
                    Label("공유", systemImage: "square.and.arrow.up")
                }
            }

            Button("삭제", systemImage: "trash", role: .destructive) {
                inboxStore.delete(record)
            }
        }
    }

    private func activate(_ record: SharedInboxRecord) {
        if isSelecting {
            toggleSelection(of: record)
        } else {
            previewItem = LocalInboxFileService.remoteItem(for: record)
        }
    }

    private func receivedFileTile(_ record: SharedInboxRecord, poster: Bool) -> some View {
        let item = LocalInboxFileService.remoteItem(for: record)
        let selected = selectedRecordIDs.contains(record.id)
        let requestSide: CGFloat = poster ? 360 : 220

        return Button {
            activate(record)
        } label: {
            VStack(alignment: .leading, spacing: poster ? 9 : 6) {
                receivedFileArtwork(
                    for: item,
                    record: record,
                    requestSize: CGSize(width: requestSide, height: requestSide)
                )
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(.quaternary.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: poster ? 15 : 11))
                .overlay(alignment: .topTrailing) {
                    if isSelecting {
                        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            .font(.title2)
                            .foregroundStyle(selected ? Color.accentColor : .secondary)
                            .padding(8)
                    }
                }

                Text(record.originalFilename)
                    .font(poster ? .headline : .caption)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if poster {
                    Text(record.importedAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isSelecting ? selectionAccessibilityLabel(for: record) : record.originalFilename
        )
    }

    private func receivedFileRow(_ record: SharedInboxRecord) -> some View {
        let item = LocalInboxFileService.remoteItem(for: record)

        return HStack(spacing: 12) {
            Button {
                if isSelecting {
                    toggleSelection(of: record)
                } else {
                    previewItem = item
                }
            } label: {
                HStack(spacing: 12) {
                    if isSelecting {
                        Image(
                            systemName: selectedRecordIDs.contains(record.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .font(.title3)
                        .foregroundStyle(
                            selectedRecordIDs.contains(record.id) ? Color.accentColor : .secondary
                        )
                        .accessibilityHidden(true)
                    }

                    leadingPreview(for: item, record: record)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(record.originalFilename)
                            .foregroundStyle(.primary)
                            .lineLimit(2)

                        HStack(spacing: 7) {
                            Text(ByteCountFormatter.string(
                                fromByteCount: record.byteCount,
                                countStyle: .file
                            ))
                            Text(record.importedAt, format: .dateTime
                                .year().month().day().hour().minute())
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                isSelecting
                    ? selectionAccessibilityLabel(for: record)
                    : record.originalFilename
            )
            .accessibilityValue(
                ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)
            )

            if !isSelecting, let fileURL = try? SharedInbox.fileURL(for: record) {
                ShareLink(item: fileURL) {
                    Image(systemName: "square.and.arrow.up")
                        .frame(width: 38, height: 38)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(record.originalFilename) 공유")
            }
        }
        .padding(.vertical, 3)
    }

    private var uploadSelectionBar: some View {
        VStack(spacing: 10) {
            Button("NAS로 보내기", systemImage: "arrow.up.doc") {
                beginUpload(of: selectedUploadableRecords)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(selectedUploadableRecords.isEmpty)
            .accessibilityLabel("선택한 파일 \(selectedUploadableRecords.count)개를 NAS로 보내기")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedRecords: [SharedInboxRecord] {
        inboxStore.records.filter {
            selectedRecordIDs.contains($0.id)
        }
    }

    private var selectedUploadableRecords: [SharedInboxRecord] {
        selectedRecords.filter(isUploadableFile)
    }

    private var uploadabilityTaskID: UploadabilityTaskID {
        UploadabilityTaskID(
            records: inboxStore.records,
            refreshGeneration: uploadabilityRefreshGeneration
        )
    }

    private var allRecordsAreSelected: Bool {
        let recordIDs = Set(inboxStore.records.map(\.id))
        return !recordIDs.isEmpty && selectedRecordIDs == recordIDs
    }

    private func toggleAllSelection() {
        if allRecordsAreSelected {
            selectedRecordIDs.removeAll()
        } else {
            selectedRecordIDs = Set(inboxStore.records.map(\.id))
        }
    }

    private func deleteSelectedRecords() {
        let records = selectedRecords
        guard !records.isEmpty else { return }
        inboxStore.delete(records)
        endSelection()
    }

    private func toggleSelection(of record: SharedInboxRecord) {
        if selectedRecordIDs.contains(record.id) {
            selectedRecordIDs.remove(record.id)
        } else {
            selectedRecordIDs.insert(record.id)
        }
    }

    private func endSelection() {
        isSelecting = false
        selectedRecordIDs.removeAll()
    }

    private func reloadInbox() {
        inboxStore.reload()
        uploadabilityRefreshGeneration &+= 1
    }

    private func beginUpload(of records: [SharedInboxRecord]) {
        guard !records.isEmpty else { return }

        do {
            var preparedSources: [LocalUploadSource] = []
            for record in records {
                let url = try SharedInbox.fileURL(for: record)
                let values = try url.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                preparedSources.append(
                    LocalUploadSource(url: url, preferredName: record.originalFilename)
                )
            }
            guard !preparedSources.isEmpty else {
                throw ReceivedFileUploadError.folderUnsupported(
                    records.first?.originalFilename ?? "선택한 항목"
                )
            }
            pendingUploadSources = preparedSources
            isChoosingUploadDestination = true
        } catch {
            pendingUploadSources = []
            inboxStore.errorMessage = "NAS로 보낼 파일을 준비하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func isUploadableFile(_ record: SharedInboxRecord) -> Bool {
        uploadableRecordIDs.contains(record.id)
    }

    private func selectionAccessibilityLabel(for record: SharedInboxRecord) -> String {
        guard isUploadableFile(record) else {
            return "\(record.originalFilename), 폴더는 NAS 전송 선택 불가"
        }
        return "\(record.originalFilename), \(selectedRecordIDs.contains(record.id) ? "선택됨" : "선택하지 않음")"
    }

    @ViewBuilder
    private func leadingPreview(
        for item: RemoteFileItem,
        record: SharedInboxRecord
    ) -> some View {
        let size = CGSize(width: 56, height: 56)
        let shape = RoundedRectangle(cornerRadius: 9)

        receivedFileArtwork(for: item, record: record, requestSize: size)
        .frame(width: size.width, height: size.height)
        .background(.quaternary.opacity(0.55), in: shape)
        .clipShape(shape)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func receivedFileArtwork(
        for item: RemoteFileItem,
        record: SharedInboxRecord,
        requestSize: CGSize
    ) -> some View {
        if item.isImage || item.isVideo || item.contentType.conforms(to: .pdf) {
            LocalInboxThumbnailView(record: record, item: item, size: requestSize)
        } else {
            Image(systemName: item.systemImage)
                .font(.system(size: min(requestSize.width, requestSize.height) * 0.42))
                .foregroundStyle(iconColor(for: item))
        }
    }

    private func sequentialMediaItems(
        from records: [SharedInboxRecord],
        including item: RemoteFileItem
    ) -> [RemoteFileItem] {
        guard item.isImage || item.isVideo else { return [item] }

        let relatedItems = records.map { LocalInboxFileService.remoteItem(for: $0) }
        return relatedItems.contains(item) ? relatedItems : [item]
    }

    private func iconColor(for item: RemoteFileItem) -> Color {
        if item.isImage { return .blue }
        if item.isVideo { return .pink }
        return .secondary
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { inboxStore.errorMessage != nil },
            set: { if !$0 { inboxStore.errorMessage = nil } }
        )
    }
}

private struct LocalInboxThumbnailView: View {
    let record: SharedInboxRecord
    let item: RemoteFileItem
    let size: CGSize

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }

            if item.isVideo {
                Image(systemName: "play.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .padding(5)
                    .background(.ultraThinMaterial, in: Circle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .task(id: thumbnailTaskID) {
            await loadThumbnail()
        }
    }

    private var thumbnailTaskID: String {
        "\(record.id.uuidString)-\(Int(size.width.rounded()))x\(Int(size.height.rounded()))"
    }

    @MainActor
    private func loadThumbnail() async {
        image = nil
        isLoading = true
        defer { isLoading = false }

        guard let fileURL = try? SharedInbox.fileURL(for: record) else { return }
        let maximumPixelSize = Int(
            ceil(max(size.width, size.height) * UIScreen.main.scale)
        )
        let cacheKey = RemoteThumbnailCacheKey.remoteData(
            for: item,
            size: thumbnailSize(for: maximumPixelSize)
        )
        if let cachedData = await SuperThumbnailCache.shared.data(forKey: cacheKey),
           let cachedImage = try? await RemoteThumbnailImageDecoder.downsample(
            data: cachedData,
            maximumPixelSize: maximumPixelSize
           ) {
            guard !Task.isCancelled else { return }
            image = UIImage(cgImage: cachedImage.image)
            return
        }

        if item.isImage,
           let decodedImage = await LocalInboxImageThumbnailGenerator.generate(
            fileURL: fileURL,
            maximumPixelSize: maximumPixelSize
           ) {
            guard !Task.isCancelled else { return }
            image = decodedImage
            await storeInSuperThumbnailCache(decodedImage, forKey: cacheKey)
            return
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        guard let representation = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        guard !Task.isCancelled else { return }
        image = representation.uiImage
        await storeInSuperThumbnailCache(representation.uiImage, forKey: cacheKey)
    }

    private func thumbnailSize(for maximumPixelSize: Int) -> RemoteThumbnailSize {
        if maximumPixelSize <= 360 { return .small }
        if maximumPixelSize <= 1_024 { return .medium }
        return .large
    }

    private func storeInSuperThumbnailCache(_ image: UIImage, forKey key: String) async {
        guard let data = image.jpegData(compressionQuality: 0.84) else { return }
        await SuperThumbnailCache.shared.store(data, forKey: key)
    }
}

private struct LocalInboxSendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private enum LocalInboxImageThumbnailGenerator {
    static func generate(fileURL: URL, maximumPixelSize: Int) async -> UIImage? {
        let boundedMaximumPixelSize = max(maximumPixelSize, 1)
        let decoded = await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil as LocalInboxSendableCGImage? }
            return autoreleasepool {
                let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    sourceOptions
                ), CGImageSourceGetCount(source) > 0 else { return nil }

                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: boundedMaximumPixelSize,
                ] as CFDictionary
                guard let image = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions
                ) else { return nil }
                return LocalInboxSendableCGImage(image: image)
            }
        }.value
        guard !Task.isCancelled, let decoded else { return nil }
        return UIImage(cgImage: decoded.image)
    }
}

private struct ReceivedFilesImporterModifier: ViewModifier {
    @Binding var isPresented: Bool
    let importFiles: ([URL]) -> Void
    let importFailed: (Error) -> Void

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $isPresented,
                allowedContentTypes: [.data, .content],
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case .success(let urls):
                    guard !urls.isEmpty else { return }
                    importFiles(urls)
                case .failure(let error):
                    importFailed(error)
                }
            }
            .fileDialogConfirmationLabel("가져오기")
            .fileDialogMessage("나의 iPhone 또는 iCloud Drive에서 파일을 선택하세요.")
    }
}

struct LocalInboxFileService: RemoteFileService {
    static let connectionID = UUID(uuidString: "8E89F463-1601-4A4A-9890-0E7429A5DA94")!

    let connection = RemoteConnection(
        id: connectionID,
        name: "폰하드",
        kind: .synology,
        host: "localhost",
        username: ""
    )

    private let recordsByPath: [String: SharedInboxRecord]

    init(records: [SharedInboxRecord]) {
        recordsByPath = Dictionary(
            uniqueKeysWithValues: records.map { ($0.id.uuidString, $0) }
        )
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        recordsByPath.values
            .sorted { $0.importedAt > $1.importedAt }
            .map { Self.remoteItem(for: $0) }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        guard let record = recordsByPath[item.path] else {
            throw LocalInboxFileError.recordNotFound
        }
        return try SharedInbox.fileURL(for: record)
    }

    func testConnection() async throws {}

    static func remoteItem(for record: SharedInboxRecord) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: record.id.uuidString,
            name: record.originalFilename,
            kind: .file,
            size: record.byteCount,
            modifiedAt: record.importedAt,
            contentTypeIdentifier: record.contentTypeIdentifier
        )
    }
}

private enum LocalInboxFileError: LocalizedError {
    case recordNotFound

    var errorDescription: String? {
        "폰하드 파일을 찾을 수 없습니다. 목록을 새로 고친 뒤 다시 시도하세요."
    }
}

private enum ReceivedFileUploadError: LocalizedError {
    case folderUnsupported(String)

    var errorDescription: String? {
        switch self {
        case .folderUnsupported(let name):
            "\(name)은(는) 폴더입니다. 현재는 파일만 NAS로 보낼 수 있습니다."
        }
    }
}
