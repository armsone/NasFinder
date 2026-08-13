import CryptoKit
import FileProvider
import Foundation
import Security
import UniformTypeIdentifiers

enum NasFinderFileProviderIdentifiers {
    static let appGroup = "group.com.armsone.nasfinder"
    static let connectionStorageKey = "connections.v1"
    static let keychainAccessGroupInfoKey = "NasFinderKeychainAccessGroup"

    private static let remotePrefix = "remote-path:"

    static func identifier(forRemotePath path: String) -> NSFileProviderItemIdentifier {
        let encoded = Data(path.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return NSFileProviderItemIdentifier(remotePrefix + encoded)
    }

    static func remotePath(for identifier: NSFileProviderItemIdentifier) -> String? {
        let rawValue = identifier.rawValue
        guard rawValue.hasPrefix(remotePrefix) else { return nil }

        var encoded = String(rawValue.dropFirst(remotePrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = encoded.count % 4
        if remainder != 0 {
            encoded.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: encoded),
              let path = String(data: data, encoding: .utf8),
              !path.isEmpty else {
            return nil
        }
        return path
    }
}

enum ProviderConnectionKind: String, Codable, Sendable {
    case synology
    case sftp
    case smb
    case webDAV
    case ftp
}

struct ProviderConnection: Codable, Sendable {
    let id: UUID
    let name: String
    let kind: ProviderConnectionKind
    let host: String
    let port: Int
    let username: String
    let rootPath: String
    let usesTLS: Bool
    let trustedHostKey: String?
    let createdAt: Date

    var normalizedRootPath: String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .synology:
            guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
            return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        case .sftp:
            return trimmed.isEmpty ? "." : trimmed
        case .smb, .webDAV, .ftp:
            guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
            return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
        }
    }
}

struct ProviderRemoteNode: Sendable {
    let path: String
    let name: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
}

protocol ProviderRemoteBackend: Sendable {
    var supportsMutations: Bool { get }
    func list(directory: String) async throws -> [ProviderRemoteNode]
    func download(path: String, to destinationURL: URL) async throws
    func thumbnail(path: String, size: ProviderThumbnailSize) async throws -> Data?
    func createFolder(path: String) async throws
    func upload(localURL: URL, to path: String) async throws
    func rename(from sourcePath: String, to destinationPath: String) async throws
    func delete(path: String, isDirectory: Bool) async throws
}

extension ProviderRemoteBackend {
    var supportsMutations: Bool { false }
    func thumbnail(path: String, size: ProviderThumbnailSize) async throws -> Data? { nil }
    func createFolder(path: String) async throws { throw NasFinderFileProviderErrors.readOnly }
    func upload(localURL: URL, to path: String) async throws { throw NasFinderFileProviderErrors.readOnly }
    func rename(from sourcePath: String, to destinationPath: String) async throws {
        throw NasFinderFileProviderErrors.readOnly
    }
    func delete(path: String, isDirectory: Bool) async throws {
        throw NasFinderFileProviderErrors.readOnly
    }
}

enum ProviderThumbnailSize: String, Sendable {
    case small
    case medium
    case large
}

struct ProviderSnapshot: @unchecked Sendable {
    let items: [NasFinderFileProviderItem]
    let anchor: NSFileProviderSyncAnchor
}

struct ProviderChanges: @unchecked Sendable {
    let updatedItems: [NasFinderFileProviderItem]
    let deletedIdentifiers: [NSFileProviderItemIdentifier]
    let anchor: NSFileProviderSyncAnchor
}

struct ProviderCreateRequest: Sendable {
    let parentIdentifier: String
    let filename: String
    let contentTypeIdentifier: String
}

struct ProviderModifyRequest: Sendable {
    let identifier: String
    let parentIdentifier: String
    let filename: String
    let changesFilename: Bool
    let changesParent: Bool
    let changesContents: Bool
}

actor NasFinderFileProviderStorage {
    private struct Context: Sendable {
        let connection: ProviderConnection
        let backend: any ProviderRemoteBackend
    }

    private let contextResult: Result<Context, Error>
    private let thumbnailCache = ProviderThumbnailCache()
    private var identifiersByAnchor: [Data: Set<String>] = [:]

    init(domainIdentifier: NSFileProviderDomainIdentifier) {
        contextResult = Result {
            let connection = try Self.loadConnection(
                matching: domainIdentifier.rawValue
            )
            let password = try SharedKeychainCredentialReader().password(
                for: connection.id
            )
            let backend: any ProviderRemoteBackend
            switch connection.kind {
            case .synology:
                backend = SynologyProviderBackend(
                    connection: connection,
                    password: password
                )
            case .sftp:
                backend = SFTPProviderBackend(
                    connection: connection,
                    password: password
                )
            case .smb, .webDAV, .ftp:
                throw NasFinderFileProviderErrors.unsupportedConnection
            }
            return Context(connection: connection, backend: backend)
        }
    }

    func item(for identifier: NSFileProviderItemIdentifier) async throws -> NasFinderFileProviderItem {
        let context = try contextResult.get()
        if identifier == .rootContainer {
            return rootItem(for: context.connection)
        }

        guard let path = NasFinderFileProviderIdentifiers.remotePath(for: identifier),
              let parentPath = Self.parentPath(
                of: path,
                rootedAt: context.connection.normalizedRootPath
              ) else {
            throw NasFinderFileProviderErrors.noSuchItem
        }

        let nodes = try await context.backend.list(directory: parentPath)
        guard let node = nodes.first(where: {
            $0.path == path && ProviderFileVisibilityPolicy.shouldDisplay(filename: $0.name)
        }) else {
            throw NasFinderFileProviderErrors.noSuchItem
        }
        return fileProviderItem(node, connection: context.connection)
    }

    func snapshot(for containerIdentifier: NSFileProviderItemIdentifier) async throws -> ProviderSnapshot {
        let context = try contextResult.get()
        let remoteDirectory: String
        switch containerIdentifier {
        case .rootContainer, .workingSet:
            remoteDirectory = context.connection.normalizedRootPath
        default:
            guard let decodedPath = NasFinderFileProviderIdentifiers.remotePath(
                for: containerIdentifier
            ) else {
                throw NasFinderFileProviderErrors.noSuchItem
            }
            remoteDirectory = decodedPath
        }

        let nodes = try await context.backend.list(directory: remoteDirectory)
        let items = nodes
            .filter { ProviderFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
            .map { fileProviderItem($0, connection: context.connection) }
            .sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }
        let snapshot = ProviderSnapshot(items: items, anchor: Self.syncAnchor(for: items))
        remember(snapshot)
        return snapshot
    }

    func changes(
        for containerIdentifier: NSFileProviderItemIdentifier,
        from syncAnchor: NSFileProviderSyncAnchor
    ) async throws -> ProviderChanges {
        guard let previousIdentifiers = identifiersByAnchor[syncAnchor.rawValue] else {
            // Extension processes are short-lived. An anchor remembered only
            // by a previous process cannot produce a trustworthy deletion
            // delta, so require Files to perform a fresh enumeration.
            throw NSFileProviderError(.syncAnchorExpired)
        }
        let current = try await snapshot(for: containerIdentifier)
        let currentIdentifiers = Set(current.items.map { $0.itemIdentifier.rawValue })
        let deletedIdentifiers = previousIdentifiers
            .subtracting(currentIdentifiers)
            .sorted()
            .map { NSFileProviderItemIdentifier($0) }
        return ProviderChanges(
            updatedItems: syncAnchor == current.anchor ? [] : current.items,
            deletedIdentifiers: deletedIdentifiers,
            anchor: current.anchor
        )
    }

    func materialize(
        identifier: NSFileProviderItemIdentifier,
        in temporaryDirectory: URL
    ) async throws -> (URL, NasFinderFileProviderItem) {
        try Task.checkCancellation()
        let context = try contextResult.get()
        let item = try await item(for: identifier)
        guard item.contentType != .folder,
              let remotePath = NasFinderFileProviderIdentifiers.remotePath(for: identifier) else {
            throw NasFinderFileProviderErrors.noSuchItem
        }

        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        let destinationURL = temporaryDirectory.appendingPathComponent(
            Self.safeFilename(item.filename),
            isDirectory: false
        )
        try await context.backend.download(path: remotePath, to: destinationURL)
        try Task.checkCancellation()
        return (destinationURL, item)
    }

    func thumbnail(
        for identifier: NSFileProviderItemIdentifier,
        requestedSize: CGSize
    ) async throws -> Data? {
        try Task.checkCancellation()
        let context = try contextResult.get()
        guard let path = NasFinderFileProviderIdentifiers.remotePath(for: identifier),
              let parentPath = Self.parentPath(
                of: path,
                rootedAt: context.connection.normalizedRootPath
              ) else { return nil }
        let nodes = try await context.backend.list(directory: parentPath)
        guard let node = nodes.first(where: { $0.path == path }),
              !node.isDirectory,
              Self.supportsThumbnail(filename: node.name) else { return nil }

        let size = Self.thumbnailSize(for: requestedSize)
        let key = Self.thumbnailCacheKey(
            for: node,
            connectionID: context.connection.id,
            size: size
        )
        if let cached = thumbnailCache.data(forKey: key) { return cached }

        try Task.checkCancellation()
        guard let data = try await context.backend.thumbnail(path: path, size: size) else {
            return nil
        }
        try Task.checkCancellation()
        thumbnailCache.store(data, forKey: key)
        return data
    }

    func create(
        request: ProviderCreateRequest,
        contents: URL?
    ) async throws -> NasFinderFileProviderItem {
        let context = try contextResult.get()
        guard context.backend.supportsMutations else {
            throw NasFinderFileProviderErrors.readOnly
        }
        let parentPath = try remoteDirectoryPath(
            for: NSFileProviderItemIdentifier(request.parentIdentifier),
            connection: context.connection
        )
        let name = try Self.validatedFilename(request.filename)
        let path = Self.appending(name, to: parentPath)
        if UTType(request.contentTypeIdentifier) == .folder {
            try await context.backend.createFolder(path: path)
        } else {
            guard let contents else { throw NasFinderFileProviderErrors.noSuchItem }
            try await context.backend.upload(localURL: contents, to: path)
        }
        return try await itemForPath(path, context: context)
    }

    func modify(
        request: ProviderModifyRequest,
        contents: URL?
    ) async throws -> NasFinderFileProviderItem {
        let context = try contextResult.get()
        guard context.backend.supportsMutations,
              let sourcePath = NasFinderFileProviderIdentifiers.remotePath(
                  for: NSFileProviderItemIdentifier(request.identifier)
              ) else {
            throw NasFinderFileProviderErrors.readOnly
        }

        var destinationPath = sourcePath
        if request.changesFilename || request.changesParent {
            let parentPath = try remoteDirectoryPath(
                for: NSFileProviderItemIdentifier(request.parentIdentifier),
                connection: context.connection
            )
            destinationPath = Self.appending(
                try Self.validatedFilename(request.filename),
                to: parentPath
            )
            if destinationPath != sourcePath {
                try await context.backend.rename(
                    from: sourcePath,
                    to: destinationPath
                )
            }
        }
        if request.changesContents, let contents {
            try await context.backend.upload(
                localURL: contents,
                to: destinationPath
            )
        }
        return try await itemForPath(destinationPath, context: context)
    }

    func delete(identifier: NSFileProviderItemIdentifier) async throws {
        let context = try contextResult.get()
        guard context.backend.supportsMutations,
              let path = NasFinderFileProviderIdentifiers.remotePath(for: identifier) else {
            throw NasFinderFileProviderErrors.readOnly
        }
        let existing = try await item(for: identifier)
        try await context.backend.delete(
            path: path,
            isDirectory: existing.contentType == .folder
        )
    }

    private func remoteDirectoryPath(
        for identifier: NSFileProviderItemIdentifier,
        connection: ProviderConnection
    ) throws -> String {
        if identifier == .rootContainer { return connection.normalizedRootPath }
        guard let path = NasFinderFileProviderIdentifiers.remotePath(for: identifier) else {
            throw NasFinderFileProviderErrors.noSuchItem
        }
        return path
    }

    private func itemForPath(
        _ path: String,
        context: Context
    ) async throws -> NasFinderFileProviderItem {
        let parent = (path as NSString).deletingLastPathComponent
        let nodes = try await context.backend.list(directory: parent.isEmpty ? "." : parent)
        guard let node = nodes.first(where: { $0.path == path }) else {
            throw NasFinderFileProviderErrors.noSuchItem
        }
        return fileProviderItem(node, connection: context.connection)
    }

    private static func loadConnection(matching rawDomainIdentifier: String) throws -> ProviderConnection {
        guard let connectionID = UUID(uuidString: rawDomainIdentifier) else {
            throw NasFinderFileProviderErrors.invalidDomain
        }
        guard let defaults = UserDefaults(
            suiteName: NasFinderFileProviderIdentifiers.appGroup
        ), let data = defaults.data(
            forKey: NasFinderFileProviderIdentifiers.connectionStorageKey
        ) else {
            throw NasFinderFileProviderErrors.connectionMissing
        }

        let connections = try JSONDecoder().decode([ProviderConnection].self, from: data)
        guard let connection = connections.first(where: { $0.id == connectionID }) else {
            throw NasFinderFileProviderErrors.connectionMissing
        }
        guard !connection.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !connection.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1...65_535).contains(connection.port) else {
            throw NasFinderFileProviderErrors.invalidConfiguration
        }
        return connection
    }

    private func rootItem(for connection: ProviderConnection) -> NasFinderFileProviderItem {
        let version = Self.versionData(
            "root|\(connection.id.uuidString)|\(connection.name)|\(connection.normalizedRootPath)"
        )
        return NasFinderFileProviderItem(
            identifier: .rootContainer,
            parentIdentifier: .rootContainer,
            filename: connection.name,
            contentType: .folder,
            capabilities: connection.kind == .sftp
                ? [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating]
                : [.allowsReading],
            creationDate: connection.createdAt,
            contentModificationDate: connection.createdAt,
            contentVersion: version,
            metadataVersion: version
        )
    }

    private func fileProviderItem(
        _ node: ProviderRemoteNode,
        connection: ProviderConnection
    ) -> NasFinderFileProviderItem {
        let rootPath = connection.normalizedRootPath
        let parentPath = Self.parentPath(of: node.path, rootedAt: rootPath)
        let parentIdentifier: NSFileProviderItemIdentifier
        if parentPath == nil || parentPath == rootPath {
            parentIdentifier = .rootContainer
        } else {
            parentIdentifier = NasFinderFileProviderIdentifiers.identifier(
                forRemotePath: parentPath!
            )
        }

        let version = Self.versionData(
            "\(node.path)|\(node.isDirectory)|\(node.size ?? -1)|\(node.modifiedAt?.timeIntervalSince1970 ?? -1)"
        )
        let type = node.isDirectory
            ? UTType.folder
            : UTType(filenameExtension: (node.name as NSString).pathExtension) ?? .data
        let capabilities: NSFileProviderItemCapabilities
        if connection.kind == .sftp {
            capabilities = node.isDirectory
                ? [.allowsReading, .allowsAddingSubItems, .allowsContentEnumerating, .allowsRenaming, .allowsReparenting, .allowsDeleting]
                : [.allowsReading, .allowsWriting, .allowsRenaming, .allowsReparenting, .allowsDeleting]
        } else {
            capabilities = [.allowsReading]
        }
        return NasFinderFileProviderItem(
            identifier: NasFinderFileProviderIdentifiers.identifier(forRemotePath: node.path),
            parentIdentifier: parentIdentifier,
            filename: node.name,
            contentType: type,
            capabilities: capabilities,
            documentSize: node.size.map(NSNumber.init(value:)),
            contentModificationDate: node.modifiedAt,
            contentVersion: version,
            metadataVersion: version
        )
    }

    private static func validatedFilename(_ filename: String) throws -> String {
        let trimmed = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed != ".",
              trimmed != "..",
              !trimmed.contains("/"),
              !trimmed.contains("\0") else {
            throw NasFinderFileProviderErrors.invalidConfiguration
        }
        return trimmed
    }

    private static func supportsThumbnail(filename: String) -> Bool {
        let type = UTType(filenameExtension: (filename as NSString).pathExtension)
        return type?.conforms(to: .image) == true
            || type?.conforms(to: .movie) == true
            || type?.conforms(to: .video) == true
    }

    private static func thumbnailSize(for requestedSize: CGSize) -> ProviderThumbnailSize {
        let maximumDimension = max(requestedSize.width, requestedSize.height)
        if maximumDimension <= 128 { return .small }
        if maximumDimension <= 512 { return .medium }
        return .large
    }

    private static func thumbnailCacheKey(
        for node: ProviderRemoteNode,
        connectionID: UUID,
        size: ProviderThumbnailSize
    ) -> String {
        let itemID = "\(connectionID.uuidString):\(node.path)"
        let version = node.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(itemID)|\(version)|\(node.size ?? -1)|\(size.rawValue)"
    }

    private static func appending(_ name: String, to directory: String) -> String {
        if directory == "/" { return "/\(name)" }
        if directory == "." { return "./\(name)" }
        return directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
    }

    private static func parentPath(of path: String, rootedAt rootPath: String) -> String? {
        guard path != rootPath else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty {
            return rootPath
        }
        if parent == "/" || parent == "." {
            return parent
        }
        return parent
    }

    private static func syncAnchor(
        for items: [NasFinderFileProviderItem]
    ) -> NSFileProviderSyncAnchor {
        var hasher = SHA256()
        for item in items.sorted(by: { $0.itemIdentifier.rawValue < $1.itemIdentifier.rawValue }) {
            hasher.update(data: Data(item.itemIdentifier.rawValue.utf8))
            hasher.update(data: item.itemVersion.metadataVersion)
            hasher.update(data: item.itemVersion.contentVersion)
        }
        return NSFileProviderSyncAnchor(Data(hasher.finalize()))
    }

    private static func safeFilename(_ filename: String) -> String {
        let sanitized = filename
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
        return sanitized.isEmpty ? "download" : sanitized
    }

    private static func versionData(_ source: String) -> Data {
        Data(SHA256.hash(data: Data(source.utf8)))
    }

    private func remember(_ snapshot: ProviderSnapshot) {
        identifiersByAnchor[snapshot.anchor.rawValue] = Set(
            snapshot.items.map { $0.itemIdentifier.rawValue }
        )
        if identifiersByAnchor.count > 12 {
            let currentAnchor = snapshot.anchor.rawValue
            identifiersByAnchor = identifiersByAnchor.filter { key, _ in
                key == currentAnchor
            }
        }
    }
}

private enum ProviderFileVisibilityPolicy {
    static func shouldDisplay(filename: String) -> Bool {
        !filename.hasPrefix(".")
    }
}

private struct SharedKeychainCredentialReader {
    private enum LookupResult {
        case success(String)
        case failure(OSStatus)
    }

    private let service = "com.armsone.nasfinder.credentials"

    func password(for connectionID: UUID) throws -> String {
        let configuredGroup = Bundle.main.object(
            forInfoDictionaryKey: NasFinderFileProviderIdentifiers.keychainAccessGroupInfoKey
        ) as? String

        if let configuredGroup,
           configuredGroup.hasSuffix("com.armsone.nasfinder.shared") {
            let result = copyPassword(for: connectionID, accessGroup: configuredGroup)
            switch result {
            case .success(let password):
                return password
            case .failure(let status) where status != errSecItemNotFound && status != errSecMissingEntitlement:
                throw keychainError(status)
            case .failure:
                break
            }
        }

        let fallback = copyPassword(for: connectionID, accessGroup: nil)
        switch fallback {
        case .success(let password):
            return password
        case .failure(let status) where status == errSecItemNotFound:
            throw NasFinderFileProviderErrors.credentialsMissing
        case .failure(let status):
            throw keychainError(status)
        }
    }

    private func copyPassword(
        for connectionID: UUID,
        accessGroup: String?
    ) -> LookupResult {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            return .failure(errSecDecode)
        }
        return .success(password)
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error (\(status))"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum NasFinderFileProviderErrors {
    static var readOnly: Error {
        CocoaError(
            .featureUnsupported,
            userInfo: [NSLocalizedDescriptionKey: "NasFinder's remote locations are read-only."]
        )
    }

    static var noSuchItem: Error {
        NSFileProviderError(.noSuchItem)
    }

    static var connectionMissing: Error {
        NSFileProviderError(
            .notAuthenticated,
            userInfo: [
                NSLocalizedDescriptionKey: "Open NasFinder and add this connection again."
            ]
        )
    }

    static var credentialsMissing: Error {
        NSFileProviderError(
            .notAuthenticated,
            userInfo: [
                NSLocalizedDescriptionKey: "The saved password is unavailable. Open NasFinder and reconnect."
            ]
        )
    }

    static var invalidDomain: Error {
        CocoaError(
            .fileReadCorruptFile,
            userInfo: [NSLocalizedDescriptionKey: "The NasFinder domain identifier is invalid."]
        )
    }

    static var invalidConfiguration: Error {
        CocoaError(
            .fileReadUnknown,
            userInfo: [NSLocalizedDescriptionKey: "The NasFinder connection settings are incomplete."]
        )
    }

    static var unsupportedConnection: Error {
        CocoaError(
            .featureUnsupported,
            userInfo: [
                NSLocalizedDescriptionKey: "Open this location in NasFinder. Files integration is not available for this connection type yet."
            ]
        )
    }
}
