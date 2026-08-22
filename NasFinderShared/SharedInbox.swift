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
    private static let manifestFilename = ".nasfinder-manifest.json"
    private static let legacyManifestFilename = "manifest.json"
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
                "이미 있는 폰하드 파일과 식별자가 충돌했습니다."
            case let .coordinationFailed(message):
                "공유 저장소를 조정하지 못했습니다: \(message)"
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
            var identifier: UUID
            var storedFilename: String
            var destinationURL: URL
            repeat {
                identifier = UUID()
                storedFilename = uniqueStoredFilename(
                    preferredName: safeOriginalName,
                    inboxURL: locations.inboxURL
                )
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

    private static func reconciledRecords(
        _ records: [SharedInboxRecord],
        inboxURL: URL
    ) throws -> [SharedInboxRecord] {
        let fileManager = FileManager.default
        var reconciled: [SharedInboxRecord] = []
        var representedPaths = Set<String>()
        var representedDirectories = Set<String>()

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
            if values.isDirectory == true {
                representedDirectories.insert(record.storedFilename)
            }
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
            guard values.isRegularFile == true else { continue }

            let storedFilename = try relativeStoredFilename(for: url, inboxURL: inboxURL)
            guard storedFilename != legacyManifestFilename,
                  !representedPaths.contains(storedFilename),
                  !representedDirectories.contains(where: {
                      storedFilename.hasPrefix($0 + "/")
                  }) else { continue }

            reconciled.append(
                SharedInboxRecord(
                    id: UUID(),
                    originalFilename: url.lastPathComponent,
                    storedFilename: storedFilename,
                    contentTypeIdentifier: nil,
                    byteCount: Int64(values.fileSize ?? 0),
                    importedAt: values.contentModificationDate ?? Date()
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
