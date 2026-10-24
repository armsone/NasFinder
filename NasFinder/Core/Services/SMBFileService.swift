import Foundation
@preconcurrency import SMBClient

/// SMB 2 driver used by ipTIME NAS/router shares, Windows file sharing and
/// other standards-compliant NAS products. The first path component is the
/// share name; `/` lists the shares visible to the account.
actor SMBFileService: RemoteFileService {
    nonisolated let connection: RemoteConnection
    private let credential: RemoteCredential

    /// SMB 업로드는 같은 이름이 있으면 새로 만들기에 실패하므로 덮어쓰기(replaceFile)는 광고하지 않는다.
    /// 폴더 삭제는 비어 있는 폴더만 가능하므로 재귀 삭제도 광고하지 않는다.
    nonisolated var capabilities: RemoteFileServiceCapabilities {
        [.createFolder, .rename, .delete, .upload, .serverSideMove]
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
        try context.checkCancellation()
        let location = try split(item.path)
        let client = try await loggedInClient()
        do {
            try await client.connectShare(location.share)
            if item.isDirectory {
                // 하위 항목까지 지우는 기능은 없다. 안에 항목이 있으면 아무것도 지우지 않고 알린다.
                let children = try await client.listDirectory(path: location.relativePath)
                    .filter { $0.name != "." && $0.name != ".." }
                guard children.isEmpty else {
                    throw RemoteFileOperationError.directoryNotEmpty(path: item.path)
                }
                try await client.deleteDirectory(path: location.relativePath)
            } else {
                try await client.deleteFile(path: location.relativePath)
            }
        } catch {
            await close(client)
            throw error
        }
        await close(client)
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
        try context.checkCancellation()
        let requestedName = preferredName ?? localURL.lastPathComponent
        // 충돌 정책을 대상 폴더의 현재 목록으로 먼저 적용한다(FTP와 같은 방식).
        let siblings = try await list(directory: directoryPath)
        let decision = try RemotePath.conflictDecision(
            for: requestedName,
            sourceIsDirectory: false,
            siblings: siblings,
            policy: conflictPolicy,
            sourcePath: localURL.path,
            destinationPath: appending(requestedName, to: directoryPath),
            caseSensitive: false
        )
        let name: String
        switch decision {
        case .skip(let existingPath):
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: .upload,
                outcomes: [.skipped(
                    sourcePath: localURL.path,
                    destinationPath: existingPath,
                    issue: .init(code: .conflict, message: "같은 이름의 파일이 이미 있습니다.")
                )]
            )
        case .proceed(let resolvedName, let replacesExisting):
            // SMB 새 파일 만들기는 기존 파일을 덮어쓰지 않는다. 덮어쓰기는 기존 파일을 지우지 않고 충돌로 알린다.
            guard !replacesExisting else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: localURL.path,
                    destinationPath: appending(resolvedName, to: directoryPath)
                )
            }
            name = resolvedName
        }
        let destination = appending(name, to: directoryPath)
        let location = try split(destination)
        let client = try await loggedInClient()
        do {
            try await client.connectShare(location.share)
            try await client.upload(localPath: localURL, remotePath: location.relativePath)
        } catch {
            await close(client)
            throw error
        }
        await close(client)
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [.succeeded(sourcePath: localURL.path, destinationPath: destination)]
        )
    }

    /// 같은 공유 폴더 안에서 서버의 이름 바꾸기(SMB2 FileRenameInformation, 기존 항목 대체 안 함)로 옮긴다.
    /// 다른 공유 폴더로는 옮기지 않는다. 내용을 내려받아 다시 올리는 이동은 하지 않는다.
    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try context.checkCancellation()
        guard strategy != .streaming else {
            throw RemoteFileOperationError.unsupported(operation: .move)
        }
        try conflictPolicy.validate(for: item, destinationPath: directoryPath)
        let sourcePath = normalized(item.path)
        let targetDirectory = normalized(directoryPath)
        if normalized((sourcePath as NSString).deletingLastPathComponent) == targetDirectory {
            // 이미 그 폴더에 있다. 아무것도 바꾸지 않는다.
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.succeeded(sourcePath: item.path, destinationPath: item.path, resultingItem: item)]
            )
        }
        if item.isDirectory, RemotePath.isSameOrDescendant(targetDirectory, of: sourcePath) {
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.failed(
                    sourcePath: item.path,
                    destinationPath: targetDirectory,
                    issue: .init(code: .unsupported, message: "\(item.name): 폴더를 자기 자신이나 하위 폴더로 옮길 수 없습니다.")
                )]
            )
        }
        let siblings = try await list(directory: targetDirectory)
        let decision = try RemotePath.conflictDecision(
            for: item.name,
            sourceIsDirectory: item.isDirectory,
            siblings: siblings,
            policy: conflictPolicy,
            sourcePath: item.path,
            destinationPath: appending(item.name, to: targetDirectory),
            caseSensitive: false
        )
        let name: String
        switch decision {
        case .skip(let existingPath):
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.skipped(
                    sourcePath: item.path,
                    destinationPath: existingPath,
                    issue: .init(code: .conflict, message: "같은 이름의 항목이 이미 있습니다.")
                )]
            )
        case .proceed(let resolvedName, let replacesExisting):
            guard !replacesExisting else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: item.path,
                    destinationPath: appending(resolvedName, to: targetDirectory)
                )
            }
            name = resolvedName
        }
        let destination = appending(name, to: targetDirectory)
        let source = try split(sourcePath)
        let target = try split(destination)
        guard source.share == target.share,
              !source.relativePath.isEmpty,
              !target.relativePath.isEmpty else {
            throw RemoteFileOperationError.unsupported(operation: .move)
        }
        let client = try await loggedInClient()
        do {
            try await client.connectShare(source.share)
            try await client.move(from: source.relativePath, to: target.relativePath)
        } catch {
            await close(client)
            throw error
        }
        await close(client)
        let moved = RemoteFileItem(
            connectionID: item.connectionID,
            path: destination,
            name: name,
            kind: item.kind,
            size: item.size,
            modifiedAt: item.modifiedAt,
            contentTypeIdentifier: item.contentTypeIdentifier
        )
        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .move,
            outcomes: [.succeeded(sourcePath: item.path, destinationPath: destination, resultingItem: moved)]
        )
    }

    /// 실패한 경우에도 공유 연결과 로그인 세션을 닫는다.
    private func close(_ client: SMBClient) async {
        _ = try? await client.disconnectShare()
        _ = try? await client.logoff()
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
