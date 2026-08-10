import Foundation

public struct SharedInboxRecord: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalFilename: String
    public let storedFilename: String
    public let contentTypeIdentifier: String?
    public let byteCount: Int64
    public let importedAt: Date

    public init(
        id: UUID,
        originalFilename: String,
        storedFilename: String,
        contentTypeIdentifier: String?,
        byteCount: Int64,
        importedAt: Date
    ) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.importedAt = importedAt
    }
}

public enum SharedInbox {
    public static let appGroupIdentifier = "group.com.armsone.nasfinder"

    private static let inboxDirectoryName = "SharedInbox"
    private static let manifestFilename = "manifest.json"
    private static let processLock = NSLock()

    public enum InboxError: LocalizedError, Sendable {
        case appGroupUnavailable
        case unsafeFilename(String)
        case sourceUnavailable
        case duplicateRecord
        case coordinationFailed(String)

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable:
                "NasFinder App Group 저장소를 열 수 없습니다."
            case let .unsafeFilename(filename):
                "안전하지 않은 파일 이름입니다: \(filename)"
            case .sourceUnavailable:
                "공유된 임시 파일을 읽을 수 없습니다."
            case .duplicateRecord:
                "이미 받은 파일과 식별자가 충돌했습니다."
            case let .coordinationFailed(message):
                "공유 저장소를 조정하지 못했습니다: \(message)"
            }
        }
    }

    public static func records() throws -> [SharedInboxRecord] {
        try withProcessLock {
            let locations = try prepareLocations()
            return try readRecords(at: locations.manifestURL)
        }
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

    /// Copies a provider-owned temporary item into the durable App Group inbox.
    /// The caller commits one or more returned records with `append(records:)`.
    @discardableResult
    public static func importTemporaryFile(
        at sourceURL: URL,
        originalFilename: String,
        contentTypeIdentifier: String?
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

            let existingIDs = Set(try readRecords(at: locations.manifestURL).map(\.id))
            let safeOriginalName = displayFilename(originalFilename, fallbackURL: sourceURL)
            let safeExtension = safePathExtension(
                from: safeOriginalName,
                fallbackURL: sourceURL,
                isDirectory: sourceValues.isDirectory == true
            )

            var identifier: UUID
            var storedFilename: String
            var destinationURL: URL
            repeat {
                identifier = UUID()
                storedFilename = identifier.uuidString.lowercased()
                if !safeExtension.isEmpty {
                    storedFilename += ".\(safeExtension)"
                }
                destinationURL = try validatedFileURL(
                    storedFilename: storedFilename,
                    inboxURL: locations.inboxURL
                )
            } while existingIDs.contains(identifier) || fileManager.fileExists(atPath: destinationURL.path)

            var bodyError: Error?
            var coordinationError: NSError?
            let coordinator = NSFileCoordinator(filePresenter: nil)
            coordinator.coordinate(
                readingItemAt: sourceURL,
                options: .withoutChanges,
                writingItemAt: destinationURL,
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
                try? fileManager.removeItem(at: destinationURL)
                throw InboxError.coordinationFailed(coordinationError.localizedDescription)
            }
            if let bodyError {
                try? fileManager.removeItem(at: destinationURL)
                throw bodyError
            }

            do {
                let byteCount = try allocatedByteCount(at: destinationURL)
                return SharedInboxRecord(
                    id: identifier,
                    originalFilename: safeOriginalName,
                    storedFilename: storedFilename,
                    contentTypeIdentifier: contentTypeIdentifier,
                    byteCount: byteCount,
                    importedAt: Date()
                )
            } catch {
                try? fileManager.removeItem(at: destinationURL)
                throw error
            }
        }
    }

    /// Atomically commits a batch so the host app never observes a half-finished share.
    public static func append(records newRecords: [SharedInboxRecord]) throws {
        guard !newRecords.isEmpty else { return }

        try withProcessLock {
            let locations = try prepareLocations()
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
    }

    public static func delete(_ record: SharedInboxRecord) throws {
        try withProcessLock {
            let locations = try prepareLocations()
            let storedURL = try validatedFileURL(
                storedFilename: record.storedFilename,
                inboxURL: locations.inboxURL
            )
            try updateRecords(at: locations.manifestURL) { records in
                records.removeAll {
                    $0.id == record.id || $0.storedFilename == record.storedFilename
                }
            }

            // Commit the manifest first. A failed file removal can only leave an orphan,
            // never a manifest entry pointing at a missing item.
            guard FileManager.default.fileExists(atPath: storedURL.path) else { return }
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

                try mutation(&records)
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
        let basename = (storedFilename as NSString).lastPathComponent
        guard !storedFilename.isEmpty,
              basename == storedFilename,
              storedFilename != ".",
              storedFilename != "..",
              !storedFilename.contains("/"),
              !storedFilename.contains("\\") else {
            throw InboxError.unsafeFilename(storedFilename)
        }

        let standardizedInboxURL = inboxURL.standardizedFileURL
        let candidate = standardizedInboxURL
            .appendingPathComponent(storedFilename, isDirectory: false)
            .standardizedFileURL
        guard candidate.deletingLastPathComponent() == standardizedInboxURL else {
            throw InboxError.unsafeFilename(storedFilename)
        }
        return candidate
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

    private static func safePathExtension(
        from filename: String,
        fallbackURL: URL,
        isDirectory: Bool
    ) -> String {
        let proposed = (filename as NSString).pathExtension.isEmpty
            ? fallbackURL.pathExtension
            : (filename as NSString).pathExtension
        let allowed = CharacterSet.alphanumerics
        let filteredScalars = proposed.unicodeScalars.filter { allowed.contains($0) }
        let filtered = String(String.UnicodeScalarView(filteredScalars)).lowercased()
        if !filtered.isEmpty { return String(filtered.prefix(20)) }
        return isDirectory ? "livephoto" : ""
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
