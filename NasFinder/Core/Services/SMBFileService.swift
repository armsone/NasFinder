import Foundation
@preconcurrency import SMBClient

/// SMB 2 driver used by ipTIME NAS/router shares, Windows file sharing and
/// other standards-compliant NAS products. The first path component is the
/// share name; `/` lists the shares visible to the account.
actor SMBFileService: RemoteFileService {
    nonisolated let connection: RemoteConnection
    private let credential: RemoteCredential

    nonisolated var capabilities: RemoteFileServiceCapabilities {
        [.createFolder, .rename, .delete, .upload, .replaceFile, .serverSideMove]
    }
    nonisolated var supportsRangeStreaming: Bool { true }
    nonisolated var permitsFullDownloadForVideoThumbnail: Bool { false }

    init(connection: RemoteConnection, credential: RemoteCredential) {
        self.connection = connection
        self.credential = credential
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let remotePath = normalized(path ?? connection.normalizedRootPath)
        let client = try await loggedInClient()
        if remotePath == "/" {
            let shares = try await client.listShares()
            _ = try? await client.logoff()
            return shares
                .filter { !$0.name.hasSuffix("$") }
                .map { share in
                    RemoteFileItem(
                        connectionID: connection.id,
                        path: "/\(share.name)",
                        name: share.name,
                        kind: .folder,
                        size: nil,
                        modifiedAt: nil,
                        contentTypeIdentifier: nil
                    )
                }
        }

        let location = try split(remotePath)
        try await client.connectShare(location.share)
        let files = try await client.listDirectory(path: location.relativePath)
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return files
            .filter { $0.name != "." && $0.name != ".." }
            .map { file in
                RemoteFileItem(
                    connectionID: connection.id,
                    path: appending(file.name, to: remotePath),
                    name: file.name,
                    kind: file.isDirectory ? .folder : .file,
                    size: file.isDirectory ? nil : Int64(clamping: file.size),
                    modifiedAt: file.lastWriteTime,
                    contentTypeIdentifier: nil
                )
            }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await download(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        let location = try split(item.path)
        let client = try await loggedInClient()
        try await client.connectShare(location.share)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent(item.name)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        await progress(.init(completedByteCount: 0, totalByteCount: item.size))
        try await client.download(
            path: location.relativePath,
            localPath: destination,
            overwrite: true
        ) { fraction in
            let completed = Int64(Double(item.size ?? 0) * fraction)
            Task { await progress(.init(completedByteCount: completed, totalByteCount: item.size)) }
        }
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        let actual = Int64(
            try destination.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        try RemoteDownloadIntegrityError.validate(
            expectedByteCount: item.size,
            actualByteCount: actual
        )
        await progress(.init(completedByteCount: actual, totalByteCount: actual))
        return destination
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let location = try split(item.path)
        let client = try await loggedInClient()
        try await client.connectShare(location.share)
        let reader = client.fileReader(path: location.relativePath)
        let data = try await reader.read(
            offset: UInt64(offset),
            length: UInt32(min(length, Int(UInt32.max)))
        )
        try? await reader.close()
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return data
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try context.checkCancellation()
        let destination = appending(name, to: directoryPath)
        let location = try split(destination)
        let client = try await loggedInClient()
        try await client.connectShare(location.share)
        try await client.createDirectory(path: location.relativePath)
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return RemoteFileItem(
            connectionID: connection.id,
            path: destination,
            name: name,
            kind: .folder,
            size: nil,
            modifiedAt: .now,
            contentTypeIdentifier: nil
        )
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let destination = appending(
            newName,
            to: (item.path as NSString).deletingLastPathComponent
        )
        let source = try split(item.path)
        let target = try split(destination)
        guard source.share == target.share else {
            throw RemoteFileOperationError.unsupported(operation: .rename)
        }
        let client = try await loggedInClient()
        try await client.connectShare(source.share)
        try await client.rename(from: source.relativePath, to: target.relativePath)
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return RemoteFileItem(
            connectionID: item.connectionID,
            path: destination,
            name: newName,
            kind: item.kind,
            size: item.size,
            modifiedAt: item.modifiedAt,
            contentTypeIdentifier: item.contentTypeIdentifier
        )
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let location = try split(item.path)
        let client = try await loggedInClient()
        try await client.connectShare(location.share)
        if item.isDirectory {
            try await client.deleteDirectory(path: location.relativePath)
        } else {
            try await client.deleteFile(path: location.relativePath)
        }
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .delete,
            outcomes: [.succeeded(sourcePath: item.path)]
        )
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let name = preferredName ?? localURL.lastPathComponent
        let destination = appending(name, to: directoryPath)
        let location = try split(destination)
        let client = try await loggedInClient()
        try await client.connectShare(location.share)
        try await client.upload(localPath: localURL, remotePath: location.relativePath)
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [.succeeded(sourcePath: localURL.path, destinationPath: destination)]
        )
    }

    private func loggedInClient() async throws -> SMBClient {
        let client = SMBClient(host: connection.host, port: connection.port)
        try await client.login(
            username: connection.username,
            password: credential.password
        )
        return client
    }

    private func split(_ path: String) throws -> (share: String, relativePath: String) {
        let components = normalized(path).split(separator: "/").map(String.init)
        guard let share = components.first else {
            throw RemoteFileOperationError.invalidPath(
                path: path,
                reason: .empty
            )
        }
        return (share, components.dropFirst().joined(separator: "/"))
    }

    private func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        return "/" + trimmed.split(separator: "/").joined(separator: "/")
    }

    private func appending(_ name: String, to path: String) -> String {
        let base = normalized(path)
        return base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}
