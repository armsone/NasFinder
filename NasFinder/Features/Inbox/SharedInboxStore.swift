import Combine
import Foundation
import UniformTypeIdentifiers

@MainActor
final class SharedInboxStore: ObservableObject {
    @Published private(set) var records: [SharedInboxRecord] = []
    @Published var errorMessage: String?
    @Published var shouldPresentInbox = false
    @Published private(set) var pendingPreviewRecordID: UUID?

    init() {
        reload()
    }

    func reload() {
        do {
            records = try SharedInbox.records().sorted {
                if $0.importedAt == $1.importedAt {
                    return $0.originalFilename.localizedStandardCompare($1.originalFilename)
                        == .orderedAscending
                }
                return $0.importedAt > $1.importedAt
            }
            errorMessage = nil
        } catch {
            errorMessage = "받은 파일 목록을 읽지 못했습니다: \(error.localizedDescription)"
        }
    }

    func delete(_ record: SharedInboxRecord) {
        do {
            try SharedInbox.delete(record)
            records.removeAll { $0.id == record.id }
            errorMessage = nil
        } catch {
            let deletionErrorMessage = "\(record.originalFilename)을(를) 삭제하지 못했습니다: \(error.localizedDescription)"
            reload()
            errorMessage = deletionErrorMessage
        }
    }

    func sceneDidBecomeActive() {
        reload()
    }

    func handleOpenURL(_ url: URL) async {
        if Self.isInboxURL(url) {
            reload()
            pendingPreviewRecordID = Self.recordID(from: url)
            shouldPresentInbox = true
            return
        }

        guard url.isFileURL else { return }
        do {
            let record = try await Task.detached(priority: .userInitiated) {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }
                let values = try url.resourceValues(forKeys: [.contentTypeKey])
                let record = try SharedInbox.importTemporaryFile(
                    at: url,
                    originalFilename: url.lastPathComponent,
                    contentTypeIdentifier: values.contentType?.identifier
                )
                try SharedInbox.append(records: [record])
                return record
            }.value
            reload()
            pendingPreviewRecordID = record.id
            shouldPresentInbox = true
        } catch {
            errorMessage = "파일을 NasFinder로 열지 못했습니다: \(error.localizedDescription)"
        }
    }

    @discardableResult
    func importDownloadedFile(
        at url: URL,
        originalFilename: String,
        contentTypeIdentifier: String?
    ) async throws -> SharedInboxRecord {
        let record = try await Task.detached(priority: .userInitiated) {
            let record = try SharedInbox.importTemporaryFile(
                at: url,
                originalFilename: originalFilename,
                contentTypeIdentifier: contentTypeIdentifier
            )
            do {
                try SharedInbox.append(records: [record])
                return record
            } catch {
                try? SharedInbox.delete(record)
                throw error
            }
        }.value
        reload()
        return record
    }

    func consumePendingPreviewRecordID() -> UUID? {
        defer { pendingPreviewRecordID = nil }
        return pendingPreviewRecordID
    }

    private static func isInboxURL(_ url: URL) -> Bool {
        guard url.scheme?.caseInsensitiveCompare("nasfinder") == .orderedSame else {
            return false
        }

        if url.host?.caseInsensitiveCompare("inbox") == .orderedSame {
            return true
        }

        return url.pathComponents.contains {
            $0.caseInsensitiveCompare("inbox") == .orderedSame
        }
    }

    private static func recordID(from url: URL) -> UUID? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawID = components.queryItems?.first(where: { $0.name == "id" })?.value else {
            return nil
        }
        return UUID(uuidString: rawID)
    }
}
