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
    /// Whether PhoneHard's physical Music folder exists, even while it is still empty.
    @Published private(set) var musicFolderExists = false

    init() {
        reload()
    }

    func reload() {
        musicFolderExists = SharedInbox.musicDirectoryExists()
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
            reload()
            errorMessage = nil
        } catch {
            let deletionErrorMessage = "\(record.originalFilename)을(를) 삭제하지 못했습니다: \(error.localizedDescription)"
            reload()
            errorMessage = deletionErrorMessage
        }
    }

    /// Deleting a folder also removes every descendant on disk and in the manifest, so
    /// the in-memory list is always reloaded from disk afterward rather than trimmed by
    /// hand; a hand-trimmed list would otherwise keep showing a deleted folder's children.
    func delete(_ recordsToDelete: [SharedInboxRecord]) {
        guard !recordsToDelete.isEmpty else { return }

        var failedFilenames: [String] = []
        for record in recordsToDelete {
            do {
                try SharedInbox.delete(record)
            } catch {
                failedFilenames.append(record.originalFilename)
            }
        }

        reload()
        errorMessage = failedFilenames.isEmpty
            ? nil
            : "일부 파일을 삭제하지 못했습니다: \(failedFilenames.joined(separator: ", "))"
    }

    /// Children directly inside `path` (`nil` is the PhoneHard root). Never includes
    /// grandchildren, so folder navigation only ever shows one level at a time.
    func children(of path: String?) -> [SharedInboxRecord] {
        records.filter { Self.parentPath(of: $0.storedFilename) == path }
    }

    static func parentPath(of storedFilename: String) -> String? {
        let parent = (storedFilename as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    /// Count of every real file and folder physically on disk under `storedFilename`
    /// (the folder itself is not included), hidden ones included, since those are exactly
    /// what a recursive delete removes. Reads disk metadata directly rather than the
    /// manifest, which is reconciled with `.skipsHiddenFiles` and would otherwise miss
    /// hidden files or anything just dropped in by another process (e.g. a WebHard
    /// upload) before the next reload. Callers should `reload()` immediately before
    /// reading it so the folder itself is known to still exist.
    func descendantCount(of storedFilename: String) -> Int {
        (try? SharedInbox.descendantCount(of: storedFilename)) ?? 0
    }

    @discardableResult
    func createFolder(named name: String, in parentPath: String?) async -> Bool {
        do {
            try await Task.detached(priority: .userInitiated) {
                try SharedInbox.createFolder(named: name, in: parentPath)
            }.value
            reload()
            errorMessage = nil
            return true
        } catch {
            reload()
            errorMessage = "폴더를 만들지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    /// Moves every selected record into `destinationPath`, keeping each `id`. Stops
    /// counting a record as failed only once its own move actually threw; every attempted
    /// record (success or failure) is reflected accurately in `errorMessage`.
    func move(_ recordsToMove: [SharedInboxRecord], toFolder destinationPath: String?) async {
        guard !recordsToMove.isEmpty else { return }
        var failedNames: [String] = []
        for record in recordsToMove {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SharedInbox.moveItem(record, toFolder: destinationPath)
                }.value
            } catch {
                failedNames.append(record.originalFilename)
            }
        }
        reload()
        errorMessage = failedNames.isEmpty
            ? nil
            : "일부 항목을 이동하지 못했습니다: \(failedNames.joined(separator: ", "))"
    }

    /// Copies every selected record into `destinationPath`. Every copy (including the
    /// whole subtree of a copied folder) gets brand-new ids; originals are never touched.
    func copy(_ recordsToCopy: [SharedInboxRecord], toFolder destinationPath: String?) async {
        guard !recordsToCopy.isEmpty else { return }
        var failedNames: [String] = []
        for record in recordsToCopy {
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try SharedInbox.copyItem(record, toFolder: destinationPath)
                }.value
            } catch {
                failedNames.append(record.originalFilename)
            }
        }
        reload()
        errorMessage = failedNames.isEmpty
            ? nil
            : "일부 항목을 복사하지 못했습니다: \(failedNames.joined(separator: ", "))"
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

    /// Stores a downloaded music file in PhoneHard's Music folder and commits it to the
    /// normal manifest. Existing audio records stay where they are.
    @discardableResult
    func importMusicFile(
        at url: URL,
        originalFilename: String,
        contentTypeIdentifier: String?
    ) async throws -> SharedInboxRecord {
        let record = try await Task.detached(priority: .userInitiated) {
            let record = try SharedInbox.importTemporaryMusicFile(
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
