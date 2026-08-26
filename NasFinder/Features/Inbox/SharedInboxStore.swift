import Combine
import Foundation
import UniformTypeIdentifiers

private struct FilesImportResult: Sendable {
    let records: [SharedInboxRecord]
    let failedFilenames: [String]
    let saveError: String?
}

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
            errorMessage = "폰하드 파일 목록을 읽지 못했습니다: \(error.localizedDescription)"
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

    func delete(_ recordsToDelete: [SharedInboxRecord]) {
        guard !recordsToDelete.isEmpty else { return }

        var failedFilenames: [String] = []
        for record in recordsToDelete {
            do {
                try SharedInbox.delete(record)
                records.removeAll { $0.id == record.id }
            } catch {
                failedFilenames.append(record.originalFilename)
            }
        }

        if failedFilenames.isEmpty {
            errorMessage = nil
        } else {
            reload()
            errorMessage = "일부 파일을 삭제하지 못했습니다: \(failedFilenames.joined(separator: ", "))"
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
    func importFromFiles(_ urls: [URL]) async -> Int {
        guard !urls.isEmpty else { return 0 }

        let result = await Task.detached(priority: .userInitiated) {
            var importedRecords: [SharedInboxRecord] = []
            var failedFilenames: [String] = []

            for url in urls {
                let accessed = url.startAccessingSecurityScopedResource()
                defer {
                    if accessed { url.stopAccessingSecurityScopedResource() }
                }

                do {
                    let values = try url.resourceValues(forKeys: [.contentTypeKey])
                    let record = try SharedInbox.importTemporaryFile(
                        at: url,
                        originalFilename: url.lastPathComponent,
                        contentTypeIdentifier: values.contentType?.identifier
                    )
                    importedRecords.append(record)
                } catch {
                    failedFilenames.append(url.lastPathComponent)
                }
            }

            guard !importedRecords.isEmpty else {
                return FilesImportResult(
                    records: importedRecords,
                    failedFilenames: failedFilenames,
                    saveError: nil
                )
            }

            do {
                try SharedInbox.append(records: importedRecords)
                return FilesImportResult(
                    records: importedRecords,
                    failedFilenames: failedFilenames,
                    saveError: nil
                )
            } catch {
                for record in importedRecords {
                    try? SharedInbox.delete(record)
                }
                return FilesImportResult(
                    records: [],
                    failedFilenames: failedFilenames,
                    saveError: error.localizedDescription
                )
            }
        }.value

        reload()

        if let saveError = result.saveError {
            errorMessage = "선택한 파일을 보관하지 못했습니다: \(saveError)"
        } else if !result.failedFilenames.isEmpty {
            let failedCount = result.failedFilenames.count
            errorMessage = "\(failedCount)개 파일을 가져오지 못했습니다."
        } else {
            errorMessage = nil
        }

        return result.records.count
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

    /// Clears only navigation requested for the current presentation. Stored
    /// PhoneHard files and errors remain untouched.
    func resetTransientPresentation() {
        shouldPresentInbox = false
        pendingPreviewRecordID = nil
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
