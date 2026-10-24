import Foundation

public struct SharedInboxRecord: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let contentTypeIdentifier: String?
    public let byteCount: Int64
    public let importedAt: Date
    /// User-created folders only. Absent in every manifest written before this feature,
    /// so decoding defaults it to `false` and keeps those legacy file records unchanged.
    public let isDirectory: Bool
    /// App-private visibility flag. `nil` (absent in every older manifest) means public; it is only ever
    /// written as `true`, so existing records are never rewritten with a new key. A folder's flag also
    /// hides everything below it (see `PrivateScope`). Hiding is a display rule of this app, not protection.
    public let isPrivate: Bool?

    public init(
        id: UUID,
        originalFilename: String,
        storedFilename: String,
        contentTypeIdentifier: String?,
        byteCount: Int64,
        importedAt: Date,
        isDirectory: Bool = false,
        isPrivate: Bool? = nil
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.importedAt = importedAt
        self.isDirectory = isDirectory
        self.isPrivate = isPrivate == true ? true : nil
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        originalFilename = try container.decode(String.self, forKey: .originalFilename)
        storedFilename = try container.decode(String.self, forKey: .storedFilename)
        contentTypeIdentifier = try container.decodeIfPresent(String.self, forKey: .contentTypeIdentifier)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        isDirectory = try container.decodeIfPresent(Bool.self, forKey: .isDirectory) ?? false
        isPrivate = try container.decodeIfPresent(Bool.self, forKey: .isPrivate) == true ? true : nil
    }

    /// The same record (same id and place) with another visibility flag.
    public func settingPrivate(_ flag: Bool?) -> SharedInboxRecord {
        SharedInboxRecord(
            id: id,
            originalFilename: originalFilename,
            storedFilename: storedFilename,
            contentTypeIdentifier: contentTypeIdentifier,
            byteCount: byteCount,
            importedAt: importedAt,
            isDirectory: isDirectory,
            isPrivate: flag
        )
    }
}

/// Which stored paths are private: a record's own flag or any ancestor folder's flag.
/// Built from the full manifest; it never changes or deletes anything.
public struct PrivateScope: Sendable {
    public let files: Set<String>
    public let folders: [String]
    public let ids: Set<UUID>

    public init(records: [SharedInboxRecord]) {
        let flagged = records.filter { $0.isPrivate == true }
        files = Set(flagged.map(\.storedFilename))
        folders = flagged.filter(\.isDirectory).map(\.storedFilename)
        // UUID 경로로 들어오는 조회도 상위 폴더가 비공개인 하위 기록을 놓치지 않도록, 자기 플래그뿐 아니라
        // 상위 폴더 플래그를 물려받은 기록의 id까지 포함한다(경로 구성요소별 집합 조회라 O(n·깊이)).
        let folderSet = Set(folders)
        ids = Set(records.filter { record in
            if record.isPrivate == true { return true }
            guard !folderSet.isEmpty else { return false }
            var prefix = ""
            for component in record.storedFilename.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(component) : prefix + "/" + component
                if folderSet.contains(prefix) { return true }
            }
            return false
        }.map(\.id))
    }

    /// Own flag or an ancestor folder's flag (by stored path prefix).
    public func contains(storedFilename: String) -> Bool {
        if files.contains(storedFilename) { return true }
        return folders.contains { storedFilename.hasPrefix($0 + "/") }
    }

    public func contains(_ record: SharedInboxRecord) -> Bool {
        record.isPrivate == true || ids.contains(record.id) || contains(storedFilename: record.storedFilename)
    }

    /// Does anything below `storedFilename` (a folder; "" is the root) carry its own private flag?
    /// A recursive export or delete of a visible folder would otherwise take those hidden items along.
    public func hasPrivateDescendant(of storedFilename: String) -> Bool {
        if storedFilename.isEmpty { return !files.isEmpty }
        let prefix = storedFilename + "/"
        return files.contains { $0.hasPrefix(prefix) }
    }

    /// Is `storedFilename` inside a private folder (its own flag not counted)?
    public func inheritsPrivate(storedFilename: String) -> Bool {
        folders.contains { storedFilename.hasPrefix($0 + "/") }
    }
}

public enum SharedInbox {
    public static let appGroupIdentifier = "group.com.armsone.nasfinder"

    /// PhoneHard's physical music folder, directly inside the inbox. Only music saved
    /// there carries a `Music/<filename>` relative `storedFilename`; every other record
    /// keeps its existing flat name and location.
    public static let musicDirectoryName = "Music"

    private static let inboxDirectoryName = "SharedInbox"
    private static let manifestFilename = ".nasfinder-manifest.json"
    private static let legacyManifestFilename = "manifest.json"
    private static let processLock = NSLock()

    public enum InboxError: LocalizedError, Sendable {
        case appGroupUnavailable
        case unsafeFilename(String)
        case sourceUnavailable
        case duplicateRecord
        case coordinationFailed(String)
        case musicFolderUnavailable
        case destinationNotFound
        case destinationNotAFolder
        case destinationAlreadyExists(String)
        case destinationInsideSource
        case staleRecord
        case partialMoveFailure(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "NasFinder App Group 저장소를 열 수 없습니다."
            case let .unsafeFilename(filename):
                "안전하지 않은 파일 이름입니다: \(filename)"
            case .sourceUnavailable:
                "공유된 임시 파일을 읽을 수 없습니다."
            case .duplicateRecord:
                "이미 있는 폰하드 파일과 식별자가 충돌했습니다."
            case let .coordinationFailed(message):
                "공유 저장소를 조정하지 못했습니다: \(message)"
            case .musicFolderUnavailable:
                "폰하드에 Music이라는 이름의 다른 항목이 있어 Music 폴더를 쓸 수 없습니다. 그 항목의 이름을 바꾼 뒤 다시 시도하세요."
            case .destinationNotFound:
                "이동할 폴더를 찾을 수 없습니다."
            case .destinationNotAFolder:
                "선택한 위치는 폴더가 아닙니다."
            case let .destinationAlreadyExists(name):
                "\(name) 위치에 같은 이름의 항목이 이미 있습니다."
            case .destinationInsideSource:
                "폴더를 자기 자신이나 그 안의 하위 폴더로 옮기거나 복사할 수 없습니다."
            case .staleRecord:
                "이동할 항목의 저장된 정보가 오래되어 이동할 수 없습니다. 목록을 새로고침한 뒤 다시 시도하세요."
            case let .partialMoveFailure(message):
                "항목이 새 위치로 옮겨졌지만 목록 정보를 갱신하지 못했습니다: \(message). 목록을 새로고침해 실제 위치를 확인하세요."
            }
        }
    }

    public static func records() throws -> [SharedInboxRecord] {
        try withProcessLock {
            let locations = try prepareLocations()
            var result: [SharedInboxRecord] = []
            try updateRecords(at: locations.manifestURL) { records in
                records = try reconciledRecords(records, inboxURL: locations.inboxURL)
                result = records
            }
            return result
        }
    }

    /// The private paths according to the manifest on disk right now (taken under the same process
    /// lock as every import/commit). Surfaces outside the app, such as the local web server, use this instead
    /// of an in-memory snapshot so a file committed a moment ago is already classified.
    public static func privateScope() throws -> PrivateScope {
        try withProcessLock {
            let locations = try prepareLocations()
            return PrivateScope(records: try readRecords(at: locations.manifestURL))
        }
    }

    /// Explicit visibility change for one record (and, through the folder rule, everything below a folder).
    /// Only the flag changes; id, place, order and bytes stay. `nil`/`false` makes it public again.
    @discardableResult
    public static func setPrivate(_ record: SharedInboxRecord, _ isPrivate: Bool) throws -> SharedInboxRecord {
        try withProcessLock {
            let locations = try prepareLocations()
            var result = record
            try updateRecords(at: locations.manifestURL) { records in
                guard let index = records.firstIndex(where: {
                    $0.id == record.id || $0.storedFilename == record.storedFilename
                }) else { throw InboxError.staleRecord }
                records[index] = records[index].settingPrivate(isPrivate ? true : nil)
                result = records[index]
            }
            return result
        }
    }

    public static func storageURL() throws -> URL {
        try withProcessLock { try prepareLocations().inboxURL }
    }

    public static func fileURL(for record: SharedInboxRecord) throws -> URL {
        try withProcessLock {
            let locations = try prepareLocations()
            return try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )
        }
    }

    public static func isMusicStoredFilename(_ storedFilename: String) -> Bool {
        storedFilename.hasPrefix(musicDirectoryName + "/")
    }

    /// Whether the Music folder is already there as a real directory. Never creates it.
    public static func musicDirectoryExists() -> Bool {
        withProcessLock {
            guard let locations = try? prepareLocations() else { return false }
            return (try? existingMusicDirectory(inboxURL: locations.inboxURL)) != nil
        }
    }

    /// Copies a provider-owned temporary item into the durable App Group inbox and commits its record
    /// in the same locked step: the bytes are staged under a hidden name, then renamed to the final
    /// name and appended to the manifest (with the privacy flag) before the lock is released, so the
    /// item is never visible at its final name without its classification. The returned record is
    /// already committed; do not `append` it again.
    @discardableResult
    public static func importTemporaryFile(
        at sourceURL: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        isPrivate: Bool? = nil
    ) throws -> SharedInboxRecord {
        try importTemporaryFile(
            at: sourceURL,
            originalFilename: originalFilename,
            contentTypeIdentifier: contentTypeIdentifier,
            intoMusicDirectory: false,
            isPrivate: isPrivate
        )
    }

    /// Same as `importTemporaryFile`, but the single regular file lands in the physical
    /// Music folder. An existing Music directory is reused as-is; a file or link already
    /// using that name is an error and is never replaced.
    @discardableResult
    public static func importTemporaryMusicFile(
        at sourceURL: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        isPrivate: Bool? = nil
    ) throws -> SharedInboxRecord {
        try importTemporaryFile(
            at: sourceURL,
            originalFilename: originalFilename,
            contentTypeIdentifier: contentTypeIdentifier,
            intoMusicDirectory: true,
            isPrivate: isPrivate
        )
    }

    /// Copies a temporary file or folder tree straight into `folderStoredPath` (`nil` is
    /// the PhoneHard root) and commits its record in the same locked step, so the item
    /// never passes through the root first. A name collision is resolved with a unique
    /// name inside that folder; nothing existing is replaced or merged into, and the
    /// source is only read.
    @discardableResult
    public static func importTemporaryItem(
        at sourceURL: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        intoFolder folderStoredPath: String?,
        isPrivate: Bool? = nil
    ) throws -> SharedInboxRecord {
        try withProcessLock {
            let fileManager = FileManager.default
            let locations = try prepareLocations()
            let sourceValues = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard sourceValues.isRegularFile == true || sourceValues.isDirectory == true,
                  sourceValues.isSymbolicLink != true else {
                throw InboxError.sourceUnavailable
            }
            let isDirectory = sourceValues.isDirectory == true

            try validateFolderDestination(folderStoredPath, inboxURL: locations.inboxURL)
            let destinationParentURL = try validatedDirectoryURL(
                for: folderStoredPath,
                inboxURL: locations.inboxURL
            )
            let safeOriginalName = displayFilename(originalFilename, fallbackURL: sourceURL)
            let uniqueName = uniqueStoredFilename(
                preferredName: safeOriginalName,
                inboxURL: destinationParentURL
            )
            let storedFilename = Self.joined(folderStoredPath, uniqueName)
            try rejectReservedRootName(storedFilename, parentStoredPath: folderStoredPath)
            let destinationURL = try validatedFileURL(
                storedFilename: storedFilename,
                inboxURL: locations.inboxURL
            )
            guard !fileManager.fileExists(atPath: destinationURL.path) else {
                throw InboxError.destinationAlreadyExists(uniqueName)
            }

            // Same hidden, task-owned staging name as `copyItem`: a half-copied tree never
            // surfaces as a record, and a failure only ever removes what this call made.
            let stagingURL = destinationParentURL.appendingPathComponent(
                ".nasfinder-download-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try fileManager.copyItem(at: sourceURL, to: stagingURL)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }
            do {
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try? fileManager.removeItem(at: stagingURL)
                throw InboxError.destinationAlreadyExists(uniqueName)
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }

            do {
                let existingIDs = Set(try readRecords(at: locations.manifestURL).map(\.id))
                var identifier = UUID()
                while existingIDs.contains(identifier) { identifier = UUID() }
                // A folder shows under the unique name it physically received, so a second
                // download of the same folder is told apart from the first.
                let record = SharedInboxRecord(
                    id: identifier,
                    originalFilename: isDirectory ? uniqueName : safeOriginalName,
                    storedFilename: storedFilename,
                    contentTypeIdentifier: isDirectory ? nil : contentTypeIdentifier,
                    byteCount: isDirectory ? 0 : try allocatedByteCount(at: destinationURL),
                    importedAt: Date(),
                    isDirectory: isDirectory,
                    isPrivate: isPrivate
                )
                try appendLocked(records: [record], locations: locations)
                return record
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    private static func importTemporaryFile(
        at sourceURL: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        intoMusicDirectory: Bool,
        isPrivate: Bool?
    ) throws -> SharedInboxRecord {
        try withProcessLock {
            let fileManager = FileManager.default
            let locations = try prepareLocations()
            let sourceValues = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])

            guard sourceValues.isRegularFile == true
                    || (sourceValues.isDirectory == true && !intoMusicDirectory),
                  sourceValues.isSymbolicLink != true else {
                throw InboxError.sourceUnavailable
            }
            let directoryURL = try intoMusicDirectory
                ? prepareMusicDirectory(inboxURL: locations.inboxURL)
                : locations.inboxURL

            let existingIDs = Set(try readRecords(at: locations.manifestURL).map(\.id))
            let safeOriginalName = displayFilename(originalFilename, fallbackURL: sourceURL)
            var identifier: UUID
            var storedFilename: String
            var destinationURL: URL
            repeat {
                identifier = UUID()
                storedFilename = uniqueStoredFilename(
                    preferredName: safeOriginalName,
                    inboxURL: directoryURL
                )
                if intoMusicDirectory {
                    storedFilename = musicDirectoryName + "/" + storedFilename
                }
                destinationURL = try validatedFileURL(
                    storedFilename: storedFilename,
                    inboxURL: locations.inboxURL
                )
            } while existingIDs.contains(identifier) || fileManager.fileExists(atPath: destinationURL.path)

            // Hidden, task-owned staging name (dot files are skipped by reconcile and by the web server's
            // listing), so a half-copied or not-yet-classified file never shows at its final name.
            let stagingURL = directoryURL.appendingPathComponent(
                ".nasfinder-import-\(UUID().uuidString)",
                isDirectory: false
            )
            var bodyError: Error?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: .withoutChanges,
                writingItemAt: stagingURL,
                options: [],
                error: &coordinationError
            ) { coordinatedSource, coordinatedDestination in
                do {
                    try fileManager.copyItem(at: coordinatedSource, to: coordinatedDestination)
                } catch {
                    bodyError = error
                }
            }

            if let coordinationError {
                try? fileManager.removeItem(at: stagingURL)
                throw InboxError.coordinationFailed(coordinationError.localizedDescription)
            }
            if let bodyError {
                try? fileManager.removeItem(at: stagingURL)
                throw bodyError
            }

            do {
                let byteCount = try allocatedByteCount(at: stagingURL)
                try fileManager.moveItem(at: stagingURL, to: destinationURL)
                let record = SharedInboxRecord(
                    id: identifier,
                    originalFilename: safeOriginalName,
                    storedFilename: storedFilename,
                    contentTypeIdentifier: contentTypeIdentifier,
                    byteCount: byteCount,
                    importedAt: Date(),
                    isPrivate: isPrivate
                )
                do {
                    try appendLocked(records: [record], locations: locations)
                } catch {
                    // Only what this call created is removed.
                    try? fileManager.removeItem(at: destinationURL)
                    throw error
                }
                return record
            } catch {
                try? fileManager.removeItem(at: stagingURL)
                throw error
            }
        }
    }

    /// Atomically commits a batch so the host app never observes a half-finished share.
    public static func append(records newRecords: [SharedInboxRecord]) throws {
        guard !newRecords.isEmpty else { return }
        try withProcessLock {
            try appendLocked(records: newRecords, locations: try prepareLocations())
        }
    }

    public static func delete(_ record: SharedInboxRecord) throws {
        try withProcessLock {
            let locations = try prepareLocations()
            let storedURL = try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )

            if FileManager.default.fileExists(atPath: storedURL.path) {
                var bodyError: Error?
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: storedURL,
                    options: .forDeleting,
                    error: &coordinationError
                ) { coordinatedURL in
                    do {
                        try FileManager.default.removeItem(at: coordinatedURL)
                    } catch {
                        bodyError = error
                    }
                }
                if let coordinationError {
                    throw InboxError.coordinationFailed(coordinationError.localizedDescription)
                }
                if let bodyError { throw bodyError }
            }

            // The filesystem above is the source of truth: only drop manifest entries for
            // items that are actually gone. A partial failure elsewhere in the tree then
            // keeps every still-present file's original id reachable instead of orphaning it.
            try updateRecords(at: locations.manifestURL) { records in
                records.removeAll { candidate in
                    let matchesTarget = candidate.id == record.id
                        || candidate.storedFilename == record.storedFilename
                        || candidate.storedFilename.hasPrefix(record.storedFilename + "/")
                    guard matchesTarget else { return false }
                    guard let candidateURL = try? validatedFileURL(
                        storedFilename: candidate.storedFilename,
                        inboxURL: locations.inboxURL
                    ) else { return true }
                    return !FileManager.default.fileExists(atPath: candidateURL.path)
                }
            }
        }
    }

    /// Creates a real, empty, physical subfolder under `parentStoredPath` (`nil` is the
    /// PhoneHard root) and commits it as a manifest record so it keeps showing up, even
    /// while empty, across refreshes and relaunches. Never overwrites an existing item.
    @discardableResult
    public static func createFolder(
        named name: String,
        in parentStoredPath: String?,
        isPrivate: Bool? = nil
    ) throws -> SharedInboxRecord {
        try withProcessLock {
            let locations = try prepareLocations()
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName != ".",
                  trimmedName != "..",
                  !trimmedName.contains("/"),
                  !trimmedName.contains("\\") else {
                throw InboxError.unsafeFilename(name)
            }

            try validateFolderDestination(parentStoredPath, inboxURL: locations.inboxURL)
            let storedFilename = Self.joined(parentStoredPath, trimmedName)
            try rejectReservedRootName(storedFilename, parentStoredPath: parentStoredPath)
            let destinationURL = try validatedFileURL(
                storedFilename: storedFilename,
                inboxURL: locations.inboxURL
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw InboxError.destinationAlreadyExists(trimmedName)
            }

            try FileManager.default.createDirectory(
                at: destinationURL,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )

            let existingIDs = Set(try readRecords(at: locations.manifestURL).map(\.id))
            var identifier = UUID()
            while existingIDs.contains(identifier) { identifier = UUID() }

            let record = SharedInboxRecord(
                id: identifier,
                originalFilename: trimmedName,
                storedFilename: storedFilename,
                contentTypeIdentifier: nil,
                byteCount: 0,
                importedAt: Date(),
                isDirectory: true,
                isPrivate: isPrivate
            )
            do {
                try appendLocked(records: [record], locations: locations)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
            return record
        }
    }

    /// Moves a file or folder (with every descendant) to a new parent folder, keeping
    /// every affected record's `id`. A name collision at the destination is resolved with
    /// a unique name, exactly like importing a duplicate file; nothing is ever overwritten.
    @discardableResult
    public static func moveItem(
        _ record: SharedInboxRecord,
        toFolder destinationStoredPath: String?
    ) throws -> SharedInboxRecord {
        try withProcessLock {
            let locations = try prepareLocations()
            let sourceURL = try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw InboxError.sourceUnavailable
            }

            let currentParent = Self.parentPath(of: record.storedFilename)
            if Self.normalized(currentParent) == Self.normalized(destinationStoredPath) {
                return record
            }

            try validateFolderDestination(destinationStoredPath, inboxURL: locations.inboxURL)
            if record.isDirectory, let destinationStoredPath {
                guard destinationStoredPath != record.storedFilename,
                      !destinationStoredPath.hasPrefix(record.storedFilename + "/") else {
                    throw InboxError.destinationInsideSource
                }
            }

            let destinationParentURL = try validatedDirectoryURL(
                for: destinationStoredPath,
                inboxURL: locations.inboxURL
            )
            let itemName = (record.storedFilename as NSString).lastPathComponent
            let uniqueName = uniqueStoredFilename(
                preferredName: itemName,
                inboxURL: destinationParentURL
            )
            let newStoredFilename = Self.joined(destinationStoredPath, uniqueName)
            try rejectReservedRootName(newStoredFilename, parentStoredPath: destinationStoredPath)
            let destinationURL = try validatedFileURL(
                storedFilename: newStoredFilename,
                inboxURL: locations.inboxURL
            )

            var bodyError: Error?
            var coordinationError: NSError?
            NSFileCoordinator(filePresenter: nil).coordinate(
                writingItemAt: sourceURL,
                options: .forMoving,
                writingItemAt: destinationURL,
                options: [],
                error: &coordinationError
            ) { coordinatedSource, coordinatedDestination in
                do {
                    try FileManager.default.moveItem(at: coordinatedSource, to: coordinatedDestination)
                } catch {
                    bodyError = error
                }
            }
            if let coordinationError {
                throw InboxError.coordinationFailed(coordinationError.localizedDescription)
            }
            if let bodyError { throw bodyError }

            let oldPrefix = record.storedFilename + "/"
            let newPrefix = newStoredFilename + "/"
            var movedRecord = record
            do {
                try updateRecords(at: locations.manifestURL) { records in
                    // Moving out of a private place never makes the item public by itself: if it was private
                    // (own flag or a private ancestor) and the new parent is not private, it keeps the flag.
                    let scope = PrivateScope(records: records)
                    let wasPrivate = records.first {
                        $0.id == record.id || $0.storedFilename == record.storedFilename
                    }.map { scope.contains($0) } ?? false
                    let stampPrivate = wasPrivate && !scope.inheritsPrivate(storedFilename: newStoredFilename)
                    var matchedCount = 0
                    for index in records.indices {
                        if records[index].id == record.id
                            || records[index].storedFilename == record.storedFilename {
                            matchedCount += 1
                            let updated = SharedInboxRecord(
                                id: records[index].id,
                                originalFilename: records[index].originalFilename,
                                storedFilename: newStoredFilename,
                                contentTypeIdentifier: records[index].contentTypeIdentifier,
                                byteCount: records[index].byteCount,
                                importedAt: records[index].importedAt,
                                isDirectory: records[index].isDirectory,
                                isPrivate: stampPrivate ? true : records[index].isPrivate
                            )
                            records[index] = updated
                            movedRecord = updated
                        } else if records[index].storedFilename.hasPrefix(oldPrefix) {
                            let suffix = records[index].storedFilename.dropFirst(oldPrefix.count)
                            records[index] = SharedInboxRecord(
                                id: records[index].id,
                                originalFilename: records[index].originalFilename,
                                storedFilename: newPrefix + suffix,
                                contentTypeIdentifier: records[index].contentTypeIdentifier,
                                byteCount: records[index].byteCount,
                                importedAt: records[index].importedAt,
                                isDirectory: records[index].isDirectory,
                                isPrivate: records[index].isPrivate
                            )
                        }
                    }
                    // A stale `record` (unknown id, already-renamed storedFilename) must
                    // never report success after the filesystem already moved the item;
                    // the catch below undoes the move so the manifest and disk agree again.
                    guard matchedCount >= 1 else {
                        throw InboxError.staleRecord
                    }
                }
            } catch {
                // The manifest never reflects a location the filesystem does not have.
                // Moving the item back keeps both in lockstep instead of losing the record.
                // If the rollback itself fails, the file is genuinely stuck at the new
                // location with no manifest entry; report that distinctly instead of
                // silently swallowing it, so the caller never believes the move fully
                // failed when the item actually moved. The next reconcile still picks the
                // file up at its new physical location under a fresh, stable id.
                var rollbackError: NSError?
                var rollbackBodyError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: destinationURL,
                    options: .forMoving,
                    writingItemAt: sourceURL,
                    options: [],
                    error: &rollbackError
                ) { coordinatedDestination, coordinatedSource in
                    do {
                        try FileManager.default.moveItem(at: coordinatedDestination, to: coordinatedSource)
                    } catch {
                        rollbackBodyError = error
                    }
                }
                if rollbackError != nil || rollbackBodyError != nil {
                    throw InboxError.partialMoveFailure(error.localizedDescription)
                }
                throw error
            }
            return movedRecord
        }
    }

    /// Renames a file or folder in place, keeping its parent folder and every affected
    /// record's `id`. The new name becomes both the displayed and the physical name. A
    /// name already in use there is an error; nothing is ever overwritten or merged into.
    @discardableResult
    public static func renameItem(
        _ record: SharedInboxRecord,
        to newName: String
    ) throws -> SharedInboxRecord {
        try withProcessLock {
            let locations = try prepareLocations()
            let trimmedName = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            // A dot-prefixed name would drop out of every listing while staying on disk.
            guard !trimmedName.isEmpty,
                  !trimmedName.hasPrefix("."),
                  !trimmedName.contains("/"),
                  !trimmedName.contains("\\") else {
                throw InboxError.unsafeFilename(newName)
            }

            let sourceURL = try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw InboxError.sourceUnavailable
            }

            let parentStoredPath = Self.parentPath(of: record.storedFilename)
            let newStoredFilename = Self.joined(parentStoredPath, trimmedName)
            if newStoredFilename == record.storedFilename,
               record.originalFilename == trimmedName {
                return record
            }
            try rejectReservedRootName(newStoredFilename, parentStoredPath: parentStoredPath)
            let destinationURL = try validatedFileURL(
                storedFilename: newStoredFilename,
                inboxURL: locations.inboxURL
            )

            // When only the displayed name differs the file already has this physical
            // name and stays where it is. A change of letter case alone is the same file
            // on a case-insensitive volume, so it is moved rather than seen as a conflict.
            let movesOnDisk = newStoredFilename != record.storedFilename
            let isCaseOnlyChange = movesOnDisk
                && newStoredFilename.compare(record.storedFilename, options: .caseInsensitive)
                    == .orderedSame
            if movesOnDisk {
                guard isCaseOnlyChange
                        || !FileManager.default.fileExists(atPath: destinationURL.path) else {
                    throw InboxError.destinationAlreadyExists(trimmedName)
                }
                var bodyError: Error?
                var coordinationError: NSError?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: sourceURL,
                    options: .forMoving,
                    writingItemAt: destinationURL,
                    options: [],
                    error: &coordinationError
                ) { coordinatedSource, coordinatedDestination in
                    do {
                        try FileManager.default.moveItem(at: coordinatedSource, to: coordinatedDestination)
                    } catch {
                        bodyError = error
                    }
                }
                if let coordinationError {
                    throw InboxError.coordinationFailed(coordinationError.localizedDescription)
                }
                if let bodyError { throw bodyError }
            }

            let oldPrefix = record.storedFilename + "/"
            let newPrefix = newStoredFilename + "/"
            var renamedRecord = record
            do {
                try updateRecords(at: locations.manifestURL) { records in
                    var matchedCount = 0
                    for index in records.indices {
                        if records[index].id == record.id
                            || records[index].storedFilename == record.storedFilename {
                            matchedCount += 1
                            let updated = SharedInboxRecord(
                                id: records[index].id,
                                originalFilename: trimmedName,
                                storedFilename: newStoredFilename,
                                contentTypeIdentifier: records[index].contentTypeIdentifier,
                                byteCount: records[index].byteCount,
                                importedAt: records[index].importedAt,
                                isDirectory: records[index].isDirectory,
                                isPrivate: records[index].isPrivate
                            )
                            records[index] = updated
                            renamedRecord = updated
                        } else if records[index].storedFilename.hasPrefix(oldPrefix) {
                            let suffix = records[index].storedFilename.dropFirst(oldPrefix.count)
                            records[index] = SharedInboxRecord(
                                id: records[index].id,
                                originalFilename: records[index].originalFilename,
                                storedFilename: newPrefix + suffix,
                                contentTypeIdentifier: records[index].contentTypeIdentifier,
                                byteCount: records[index].byteCount,
                                importedAt: records[index].importedAt,
                                isDirectory: records[index].isDirectory,
                                isPrivate: records[index].isPrivate
                            )
                        }
                    }
                    guard matchedCount >= 1 else {
                        throw InboxError.staleRecord
                    }
                }
            } catch {
                // Same rule as `moveItem`: the manifest never names a location the
                // filesystem does not have, so the item goes back under its old name.
                guard movesOnDisk else { throw error }
                var rollbackError: NSError?
                var rollbackBodyError: Error?
                NSFileCoordinator(filePresenter: nil).coordinate(
                    writingItemAt: destinationURL,
                    options: .forMoving,
                    writingItemAt: sourceURL,
                    options: [],
                    error: &rollbackError
                ) { coordinatedDestination, coordinatedSource in
                    do {
                        try FileManager.default.moveItem(at: coordinatedDestination, to: coordinatedSource)
                    } catch {
                        rollbackBodyError = error
                    }
                }
                if rollbackError != nil || rollbackBodyError != nil {
                    throw InboxError.partialMoveFailure(error.localizedDescription)
                }
                throw error
            }
            return renamedRecord
        }
    }

    /// Copies a file or folder (with every descendant) into a new parent folder. Every
    /// copied record, including the top-level item, gets a brand-new `id`; the original
    /// is left completely untouched. A name collision at the destination is resolved with
    /// a unique name rather than overwriting anything.
    @discardableResult
    public static func copyItem(
        _ record: SharedInboxRecord,
        toFolder destinationStoredPath: String?
    ) throws -> [SharedInboxRecord] {
        try withProcessLock {
            let locations = try prepareLocations()
            let sourceURL = try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                throw InboxError.sourceUnavailable
            }

            try validateFolderDestination(destinationStoredPath, inboxURL: locations.inboxURL)
            // Same self/descendant guard as moveItem: without it the API (not just the
            // picker UI, which merely hides the source row) would let `A` be copied into
            // its own descendant `A/B`.
            if record.isDirectory, let destinationStoredPath {
                guard destinationStoredPath != record.storedFilename,
                      !destinationStoredPath.hasPrefix(record.storedFilename + "/") else {
                    throw InboxError.destinationInsideSource
                }
            }

            let destinationParentURL = try validatedDirectoryURL(
                for: destinationStoredPath,
                inboxURL: locations.inboxURL
            )
            let itemName = (record.storedFilename as NSString).lastPathComponent
            let uniqueName = uniqueStoredFilename(
                preferredName: itemName,
                inboxURL: destinationParentURL
            )
            let newStoredFilename = Self.joined(destinationStoredPath, uniqueName)
            try rejectReservedRootName(newStoredFilename, parentStoredPath: destinationStoredPath)
            let destinationURL = try validatedFileURL(
                storedFilename: newStoredFilename,
                inboxURL: locations.inboxURL
            )
            guard !FileManager.default.fileExists(atPath: destinationURL.path) else {
                throw InboxError.destinationAlreadyExists(uniqueName)
            }

            // Existing manifest records for the subtree are mirrored into the copy so
            // nested, user-created folders (and their records) keep showing up; loose
            // files are rediscovered automatically on the next `records()` reconcile.
            let manifestRecords = try readRecords(at: locations.manifestURL)
            let trackedDescendants = manifestRecords.filter {
                $0.id != record.id && $0.storedFilename.hasPrefix(record.storedFilename + "/")
            }
            // The copy of a private item (own flag or private ancestor) is private too; the original is untouched.
            let copyIsPrivate = PrivateScope(records: manifestRecords).contains(record)
                || record.isPrivate == true

            // Copy into a hidden, task-owned staging name first and rename into place only
            // once the whole tree has fully landed. A failure at either step can only ever
            // remove the staging item we just created: reconcile ignores dotfiles, so a
            // half-written staging tree never surfaces as a record, and a race where
            // another writer claims `destinationURL` first surfaces as a plain rename
            // failure that leaves that preexisting item completely untouched.
            let stagingURL = destinationParentURL.appendingPathComponent(
                ".nasfinder-copy-\(UUID().uuidString)",
                isDirectory: false
            )
            do {
                try FileManager.default.copyItem(at: sourceURL, to: stagingURL)
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                throw error
            }
            do {
                try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                try? FileManager.default.removeItem(at: stagingURL)
                throw InboxError.destinationAlreadyExists(uniqueName)
            } catch {
                try? FileManager.default.removeItem(at: stagingURL)
                throw error
            }

            let oldPrefix = record.storedFilename + "/"
            var newRecords: [SharedInboxRecord] = [
                SharedInboxRecord(
                    id: UUID(),
                    originalFilename: record.originalFilename,
                    storedFilename: newStoredFilename,
                    contentTypeIdentifier: record.contentTypeIdentifier,
                    byteCount: record.isDirectory ? 0 : record.byteCount,
                    importedAt: Date(),
                    isDirectory: record.isDirectory,
                    isPrivate: copyIsPrivate ? true : nil
                ),
            ]
            for descendant in trackedDescendants {
                let suffix = descendant.storedFilename.dropFirst(oldPrefix.count)
                newRecords.append(
                    SharedInboxRecord(
                        id: UUID(),
                        originalFilename: descendant.originalFilename,
                        storedFilename: newStoredFilename + "/" + suffix,
                        contentTypeIdentifier: descendant.contentTypeIdentifier,
                        byteCount: descendant.isDirectory ? 0 : descendant.byteCount,
                        importedAt: Date(),
                        isDirectory: descendant.isDirectory,
                        isPrivate: descendant.isPrivate
                    )
                )
            }

            do {
                try appendLocked(records: newRecords, locations: locations)
            } catch {
                try? FileManager.default.removeItem(at: destinationURL)
                throw error
            }
            return newRecords
        }
    }

    /// Counts every real file and folder physically on disk under `storedFilename`,
    /// including hidden ones, since a recursive delete removes them too and the manifest
    /// (reconciled with `.skipsHiddenFiles`) would otherwise undercount what a deletion
    /// confirmation promises. Symlinks are counted as the single entry they are but never
    /// followed, so nothing outside the inbox root is ever walked. The hidden manifest
    /// file itself only ever lives at the inbox root, never inside a subfolder, so no
    /// reserved name needs filtering here.
    public static func descendantCount(of storedFilename: String) throws -> Int {
        try withProcessLock {
            let locations = try prepareLocations()
            let folderURL = try validatedFileURL(
                storedFilename: storedFilename,
                inboxURL: locations.inboxURL
            )
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return 0
            }
            guard let enumerator = FileManager.default.enumerator(
                at: folderURL,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ) else { return 0 }

            var count = 0
            for case let url as URL in enumerator {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                }
                count += 1
            }
            return count
        }
    }

    /// `nil` means the PhoneHard root, which always exists. Anything else must already be
    /// a real, manifest-reserved-name-free, non-symlink directory under the root.
    private static func validateFolderDestination(
        _ storedPath: String?,
        inboxURL: URL
    ) throws {
        guard let storedPath else { return }
        guard storedPath != legacyManifestFilename, storedPath != manifestFilename else {
            throw InboxError.destinationNotAFolder
        }
        let url = try validatedFileURL(storedFilename: storedPath, inboxURL: inboxURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw InboxError.destinationNotFound
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw InboxError.destinationNotAFolder
        }
    }

    /// `manifest.json` and the hidden manifest file are only reserved at the PhoneHard
    /// root: `reconciledRecords` silently drops any record with that exact stored
    /// filename there, so landing a create/move/copy result on one would make the item
    /// vanish on the very next reload while the file stays on disk forever. The same name
    /// one level deeper (e.g. `Music/manifest.json`) is an ordinary, trackable file.
    private static func rejectReservedRootName(
        _ storedFilename: String,
        parentStoredPath: String?
    ) throws {
        guard parentStoredPath == nil,
              storedFilename == legacyManifestFilename || storedFilename == manifestFilename else {
            return
        }
        throw InboxError.unsafeFilename(storedFilename)
    }

    private static func validatedDirectoryURL(
        for storedPath: String?,
        inboxURL: URL
    ) throws -> URL {
        guard let storedPath else { return inboxURL }
        return try validatedFileURL(storedFilename: storedPath, inboxURL: inboxURL)
    }

    private static func joined(_ parentStoredPath: String?, _ name: String) -> String {
        guard let parentStoredPath, !parentStoredPath.isEmpty else { return name }
        return parentStoredPath + "/" + name
    }

    private static func parentPath(of storedFilename: String) -> String? {
        let parent = (storedFilename as NSString).deletingLastPathComponent
        return parent.isEmpty ? nil : parent
    }

    private static func normalized(_ storedPath: String?) -> String {
        storedPath ?? ""
    }

    /// Appends records while already holding `processLock`; callers of the public
    /// `append(records:)` acquire that lock themselves, so this avoids a re-entrant lock.
    private static func appendLocked(
        records newRecords: [SharedInboxRecord],
        locations: Locations
    ) throws {
        guard !newRecords.isEmpty else { return }
        try updateRecords(at: locations.manifestURL) { currentRecords in
            let currentIDs = Set(currentRecords.map(\.id))
            let currentFilenames = Set(currentRecords.map(\.storedFilename))
            let incomingIDs = Set(newRecords.map(\.id))
            let incomingFilenames = Set(newRecords.map(\.storedFilename))

            guard incomingIDs.count == newRecords.count,
                  incomingFilenames.count == newRecords.count,
                  currentIDs.isDisjoint(with: incomingIDs),
                  currentFilenames.isDisjoint(with: incomingFilenames) else {
                throw InboxError.duplicateRecord
            }

            for record in newRecords {
                let fileURL = try validatedFileURL(
                    storedFilename: record.storedFilename,
                    inboxURL: locations.inboxURL
                )
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    throw InboxError.sourceUnavailable
                }
            }

            currentRecords.append(contentsOf: newRecords)
        }
    }

    private struct Locations {
        let inboxURL: URL
        let manifestURL: URL
    }

    private static func prepareLocations() throws -> Locations {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw InboxError.appGroupUnavailable
        }

        let inboxURL = containerURL.appendingPathComponent(inboxDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(
            at: inboxURL,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        let manifestURL = inboxURL.appendingPathComponent(manifestFilename, isDirectory: false)
        do {
            // `.withoutOverwriting` makes concurrent first launches race safely: one
            // process creates the valid empty manifest and the others keep its file.
            try Data("[]".utf8).write(
                to: manifestURL,
                options: [.withoutOverwriting, .completeFileProtectionUntilFirstUserAuthentication]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Expected once another process (or an earlier launch) created it.
        }

        return Locations(inboxURL: inboxURL, manifestURL: manifestURL)
    }

    /// The Music folder only when it is a real directory with exactly that name; a file,
    /// a symbolic link or a differently-cased folder on a case-insensitive volume all
    /// count as a name collision.
    private static func existingMusicDirectory(inboxURL: URL) throws -> URL {
        let musicURL = inboxURL.appendingPathComponent(musicDirectoryName, isDirectory: true)
        let values = try musicURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
            .canonicalPathKey,
        ])
        guard values.isSymbolicLink != true,
              values.isDirectory == true,
              values.canonicalPath.map({ ($0 as NSString).lastPathComponent }) == musicDirectoryName else {
            throw InboxError.musicFolderUnavailable
        }
        return musicURL
    }

    private static func prepareMusicDirectory(inboxURL: URL) throws -> URL {
        let musicURL = inboxURL.appendingPathComponent(musicDirectoryName, isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: musicURL,
                withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Something already has the name; reuse it only if it is the real folder.
        }
        do {
            return try existingMusicDirectory(inboxURL: inboxURL)
        } catch {
            throw InboxError.musicFolderUnavailable
        }
    }

    private static func readRecords(at manifestURL: URL) throws -> [SharedInboxRecord] {
        var data: Data?
        var bodyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            readingItemAt: manifestURL,
            options: .withoutChanges,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                data = try Data(contentsOf: coordinatedURL)
            } catch {
                bodyError = error
            }
        }
        if let coordinationError {
            throw InboxError.coordinationFailed(coordinationError.localizedDescription)
        }
        if let bodyError { throw bodyError }
        guard let data, !data.isEmpty else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([SharedInboxRecord].self, from: data)
    }

    private static func reconciledRecords(
        _ records: [SharedInboxRecord],
        inboxURL: URL
    ) throws -> [SharedInboxRecord] {
        let fileManager = FileManager.default
        var reconciled: [SharedInboxRecord] = []
        var representedPaths = Set<String>()

        for record in records {
            guard record.storedFilename != legacyManifestFilename else { continue }
            guard let url = try? validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: inboxURL
            ),
            fileManager.fileExists(atPath: url.path),
            let values = try? url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]),
            values.isSymbolicLink != true,
            values.isRegularFile == true || values.isDirectory == true else {
                continue
            }
            reconciled.append(record)
            representedPaths.insert(record.storedFilename)
        }

        guard let enumerator = fileManager.enumerator(
            at: inboxURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsHiddenFiles]
        ) else { return reconciled }

        // Any physical directory or file under the root is adopted here, including ones
        // nested inside an already-tracked folder and legacy/WebHard-written trees that
        // never went through a manifest write (WebHardFileStore creates directories and
        // commits uploads directly against this same root). `.skipsHiddenFiles` already
        // keeps the manifest itself and any dotfile-prefixed internal staging item out of
        // this walk, so nothing here needs a bespoke skip for those.
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ])
            if values.isSymbolicLink == true {
                if values.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true || values.isDirectory == true else { continue }

            let storedFilename = try relativeStoredFilename(for: url, inboxURL: inboxURL)
            guard storedFilename != legacyManifestFilename,
                  !representedPaths.contains(storedFilename) else { continue }

            reconciled.append(
                SharedInboxRecord(
                    id: UUID(),
                    originalFilename: url.lastPathComponent,
                    storedFilename: storedFilename,
                    contentTypeIdentifier: nil,
                    byteCount: values.isDirectory == true ? 0 : Int64(values.fileSize ?? 0),
                    importedAt: values.contentModificationDate ?? Date(),
                    isDirectory: values.isDirectory == true
                )
            )
            representedPaths.insert(storedFilename)
        }

        return reconciled
    }

    /// Holds one cross-process write coordination for the complete read-modify-write.
    private static func updateRecords(
        at manifestURL: URL,
        _ mutation: (inout [SharedInboxRecord]) throws -> Void
    ) throws {
        var bodyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator(filePresenter: nil).coordinate(
            writingItemAt: manifestURL,
            options: .forMerging,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                var records: [SharedInboxRecord]
                if FileManager.default.fileExists(atPath: coordinatedURL.path) {
                    let existingData = try Data(contentsOf: coordinatedURL)
                    if existingData.isEmpty {
                        records = []
                    } else {
                        let decoder = JSONDecoder()
                        decoder.dateDecodingStrategy = .iso8601
                        records = try decoder.decode([SharedInboxRecord].self, from: existingData)
                    }
                } else {
                    records = []
                }

                let originalRecords = records
                try mutation(&records)
                guard records != originalRecords else { return }
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let data = try encoder.encode(records)
                try data.write(to: coordinatedURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                bodyError = error
            }
        }
        if let coordinationError {
            throw InboxError.coordinationFailed(coordinationError.localizedDescription)
        }
        if let bodyError { throw bodyError }
    }

    private static func validatedFileURL(storedFilename: String, inboxURL: URL) throws -> URL {
        let components = storedFilename.split(separator: "/", omittingEmptySubsequences: false)
        guard !storedFilename.isEmpty,
              !storedFilename.hasPrefix("/"),
              !storedFilename.hasSuffix("/"),
              !storedFilename.contains("\\"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw InboxError.unsafeFilename(storedFilename)
        }

        let rootURL = inboxURL.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = components.reduce(rootURL) { partial, component in
            partial.appendingPathComponent(String(component), isDirectory: false)
        }.standardizedFileURL.resolvingSymlinksInPath()
        guard candidate.path.hasPrefix(rootURL.path + "/") else {
            throw InboxError.unsafeFilename(storedFilename)
        }
        return candidate
    }

    private static func relativeStoredFilename(for url: URL, inboxURL: URL) throws -> String {
        let rootPath = inboxURL.standardizedFileURL.resolvingSymlinksInPath().path
        let itemPath = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard itemPath.hasPrefix(rootPath + "/") else {
            throw InboxError.unsafeFilename(url.lastPathComponent)
        }
        return String(itemPath.dropFirst(rootPath.count + 1))
    }

    private static func uniqueStoredFilename(preferredName: String, inboxURL: URL) -> String {
        let fileManager = FileManager.default
        let safeName = preferredName.hasPrefix(".") ? "폰하드 파일" : preferredName
        let requestedURL = inboxURL.appendingPathComponent(safeName, isDirectory: false)
        if !fileManager.fileExists(atPath: requestedURL.path) { return safeName }

        let extensionName = (safeName as NSString).pathExtension
        let stem = (safeName as NSString).deletingPathExtension
        for index in 1...9_999 {
            let candidate = extensionName.isEmpty
                ? "\(stem) (\(index))"
                : "\(stem) (\(index)).\(extensionName)"
            if !fileManager.fileExists(
                atPath: inboxURL.appendingPathComponent(candidate).path
            ) {
                return candidate
            }
        }
        return "\(UUID().uuidString)-\(safeName)"
    }

    private static func displayFilename(_ proposedName: String, fallbackURL: URL) -> String {
        let basename = (proposedName as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basename.isEmpty, basename != ".", basename != "/" {
            return basename
        }

        let fallback = fallbackURL.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? "공유 파일" : fallback
    }

    private static func allocatedByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
        if values.isDirectory != true {
            return Int64(values.fileSize ?? 0)
        }

        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        var total: Int64 = 0
        for case let childURL as URL in enumerator {
            let childValues = try childURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            if childValues.isRegularFile == true {
                total += Int64(childValues.fileSize ?? 0)
            }
        }
        return total
    }

    private static func withProcessLock<T>(_ operation: () throws -> T) rethrows -> T {
        processLock.lock()
        defer { processLock.unlock() }
        return try operation()
    }
}
