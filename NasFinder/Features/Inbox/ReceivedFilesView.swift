import SwiftUI
import UniformTypeIdentifiers

struct ReceivedFilesView: View {
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @State private var previewItem: RemoteFileItem?

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
                                Button("삭제", systemImage: "trash", role: .destructive) {
                                    inboxStore.delete(record)
                                }
                            }
                            .contextMenu {
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
                .listStyle(.plain)
                .refreshable {
                    inboxStore.reload()
                }
            }
        }
        .navigationTitle("받은 파일")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("새로 고침", systemImage: "arrow.clockwise") {
                    inboxStore.reload()
                }
            }
        }
        .task {
            inboxStore.reload()
            if let recordID = inboxStore.consumePendingPreviewRecordID(),
               let record = inboxStore.records.first(where: { $0.id == recordID }) {
                previewItem = LocalInboxFileService.remoteItem(for: record)
            }
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
    }

    private func receivedFileRow(_ record: SharedInboxRecord) -> some View {
        let item = LocalInboxFileService.remoteItem(for: record)

        return HStack(spacing: 12) {
            Button {
                previewItem = item
            } label: {
                HStack(spacing: 12) {
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
            .accessibilityLabel(record.originalFilename)
            .accessibilityValue(
                ByteCountFormatter.string(fromByteCount: record.byteCount, countStyle: .file)
            )

            if let fileURL = try? SharedInbox.fileURL(for: record) {
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

        let mediaItems = records
            .map { LocalInboxFileService.remoteItem(for: $0) }
            .filter { $0.isImage || $0.isVideo }
        return mediaItems.contains(item) ? mediaItems : [item]
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
