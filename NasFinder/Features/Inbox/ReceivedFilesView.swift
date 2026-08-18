import SwiftUI
import UniformTypeIdentifiers

struct ReceivedFilesView: View {
    private struct UploadabilityTaskID: Hashable {
        let records: [SharedInboxRecord]
        let refreshGeneration: Int
    }

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @State private var previewItem: RemoteFileItem?
    @State private var isSelecting = false
    @State private var selectedRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadableRecordIDs: Set<SharedInboxRecord.ID> = []
    @State private var uploadabilityRefreshGeneration = 0
    @State private var pendingUploadSources: [LocalUploadSource] = []
    @State private var isChoosingUploadDestination = false
    @State private var isImportingFromFiles = false

    var body: some View {
        Group {
            if inboxStore.records.isEmpty {
                ContentUnavailableView {
                    Label("받은 파일이 없습니다", systemImage: "tray")
                } description: {
                    Text("다른 앱의 공유 메뉴에서 NasFinder를 선택하면 이곳에 파일이 보관됩니다.")
                }
            } else {
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
                            .contextMenu {
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
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .refreshable {
                    reloadInbox()
                }
            }
        }
        .background(SkyBreezeBackground())
        .navigationTitle("받은 파일")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !isSelecting {
                    Button("파일에서 가져오기", systemImage: "doc.badge.plus") {
                        isImportingFromFiles = true
                    }
                }

                if !inboxStore.records.isEmpty {
                    Button(isSelecting ? "완료" : "선택") {
                        if isSelecting {
                            endSelection()
                        } else {
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
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            uploadabilityRefreshGeneration &+= 1
        }
        .alert("받은 파일 오류", isPresented: errorBinding) {
            Button("확인", role: .cancel) {
                inboxStore.errorMessage = nil
            }
        } message: {
            Text(inboxStore.errorMessage ?? "")
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
            .disabled(isSelecting && !isUploadableFile(record))
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
            HStack {
                Label("\(selectedRecords.count)개 선택", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()

                Spacer()

                Button(allRecordsAreSelected ? "전체 해제" : "전체 선택") {
                    if allRecordsAreSelected {
                        selectedRecordIDs.removeAll()
                    } else {
                        selectedRecordIDs = uploadableRecordIDs
                    }
                }
                .font(.subheadline.weight(.semibold))
            }

            Button("NAS로 보내기", systemImage: "arrow.up.doc") {
                beginUpload(of: selectedRecords)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .disabled(selectedRecords.isEmpty)
            .accessibilityLabel("선택한 파일 \(selectedRecords.count)개를 NAS로 보내기")
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private var selectedRecords: [SharedInboxRecord] {
        inboxStore.records.filter {
            selectedRecordIDs.contains($0.id) && isUploadableFile($0)
        }
    }

    private var uploadabilityTaskID: UploadabilityTaskID {
        UploadabilityTaskID(
            records: inboxStore.records,
            refreshGeneration: uploadabilityRefreshGeneration
        )
    }

    private var allRecordsAreSelected: Bool {
        !uploadableRecordIDs.isEmpty && selectedRecordIDs == uploadableRecordIDs
    }

    private func toggleSelection(of record: SharedInboxRecord) {
        guard isUploadableFile(record) else { return }
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

        Group {
            if item.isImage || item.isVideo || item.contentType.conforms(to: .pdf) {
                RemoteThumbnailView(
                    item: item,
                    service: LocalInboxFileService(records: [record]),
                    size: size
                )
            } else {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .foregroundStyle(iconColor(for: item))
            }
        }
        .frame(width: size.width, height: size.height)
        .background(.quaternary.opacity(0.55), in: shape)
        .clipShape(shape)
        .accessibilityHidden(true)
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
        name: "받은 파일",
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
        "받은 파일을 찾을 수 없습니다. 목록을 새로 고친 뒤 다시 시도하세요."
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
