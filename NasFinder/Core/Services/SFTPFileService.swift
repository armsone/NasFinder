@preconcurrency import AVFoundation
import Citadel
import Foundation
import ImageIO
import NIO
import UniformTypeIdentifiers

actor SFTPFileService: RemoteFileService {
    nonisolated let connection: RemoteConnection
    nonisolated let capabilities: RemoteFileServiceCapabilities = [
        .createFolder,
        .rename,
        .delete,
        .recursiveDelete,
        .upload,
        .replaceFile,
        .streamingCopy,
        .serverSideMove,
        .streamingMove
    ]
    nonisolated let supportsRangeStreaming = true
    nonisolated let permitsFullDownloadForVideoThumbnail = false
    private let credential: RemoteCredential
    private let cache: DownloadCache

    init(
        connection: RemoteConnection,
        credential: RemoteCredential,
        cache: DownloadCache = .shared
    ) {
        self.connection = connection
        self.credential = credential
        self.cache = cache
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let directory = path ?? connection.normalizedRootPath
        return try await withSFTP { sftp in
            let batches = try await sftp.listDirectory(atPath: directory)
            return batches
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    let permissions = component.attributes.permissions
                    let isDirectory = permissions.map { ($0 & 0o170000) == 0o040000 }
                        ?? component.longname.hasPrefix("d")
                    let remotePath = Self.appending(component.filename, to: directory)
                    let size = component.attributes.size.flatMap(Int64.init(exactly:))

                    return RemoteFileItem(
                        connectionID: self.connection.id,
                        path: remotePath,
                        name: component.filename,
                        kind: isDirectory ? .folder : .file,
                        size: size,
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                        contentTypeIdentifier: nil
                    )
                }
        }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await download(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        // Cache format v2 entries are published only after this service has
        // validated the downloaded payload against a live pre-read stat. The
        // directory-listing size can be stale, so rechecking the trusted file
        // against `item.size` here would discard a valid download forever for
        // the same stale list entry.
        if let cached = await cache.cachedURL(for: item) {
            let cachedSize = try? cached.resourceValues(forKeys: [.fileSizeKey]).fileSize
            let actualByteCount = cachedSize.map(Int64.init)
            let completedByteCount = actualByteCount ?? item.size ?? 0
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: completedByteCount,
                    totalByteCount: actualByteCount ?? item.size
                )
            )
            return cached
        }

        await progress(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: item.size
            )
        )

        let temporaryURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        FileManager.default.createFile(atPath: temporaryURL.path, contents: nil)

        do {
            let liveExpectedByteCount = try await withSFTP(
                closeTransportOnCancellation: true
            ) { sftp in
                // Directory entries can be stale by the time the user opens a
                // preview. Re-read the size on the same connection immediately
                // before opening the file, and use that value for integrity
                // validation so a legitimately replaced file is not rejected.
                let attributes = try await sftp.getAttributes(at: item.path)
                let expectedByteCount = SFTPDownloadSizePolicy.expectedByteCount(
                    liveByteCount: attributes.size,
                    listedByteCount: item.size
                )
                await progress(
                    RemoteDownloadProgress(
                        completedByteCount: 0,
                        totalByteCount: expectedByteCount
                    )
                )

                try await sftp.withFile(filePath: item.path, flags: .read) { file in
                    let handle = try FileHandle(forWritingTo: temporaryURL)
                    defer { try? handle.close() }

                    var offset: UInt64 = 0
                    let chunkSize: UInt32 = 128 * 1_024
                    while !Task.isCancelled {
                        var buffer = try await file.read(from: offset, length: chunkSize)
                        guard buffer.readableBytes > 0 else { break }
                        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                        try handle.write(contentsOf: Data(bytes))
                        offset += UInt64(bytes.count)
                        await progress(
                            RemoteDownloadProgress(
                                completedByteCount: Int64(exactly: offset) ?? Int64.max,
                                totalByteCount: expectedByteCount
                            )
                        )
                    }
                    try Task.checkCancellation()
                }
                return expectedByteCount
            }
            let actualByteCount = Int64(
                try temporaryURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            )
            try RemoteDownloadIntegrityError.validate(
                expectedByteCount: liveExpectedByteCount,
                actualByteCount: actualByteCount
            )
            let cachedURL = try await cache.store(downloadedURL: temporaryURL, for: item)
            let completedByteCount = actualByteCount
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: completedByteCount,
                    totalByteCount: actualByteCount
                )
            )
            return cachedURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard item.connectionID == connection.id,
              !item.isDirectory,
              offset >= 0,
              length > 0,
              let remoteOffset = UInt64(exactly: offset) else {
            throw CocoaError(.fileReadInvalidFileName)
        }

        return try await withSFTP(closeTransportOnCancellation: true) { sftp in
            try await sftp.withFile(filePath: item.path, flags: .read) { file in
                var result = Data()
                result.reserveCapacity(length)
                var currentOffset = remoteOffset
                var remaining = length
                let chunkSize = 256 * 1_024

                while remaining > 0 {
                    try Task.checkCancellation()
                    let requested = UInt32(min(remaining, chunkSize))
                    var buffer = try await file.read(
                        from: currentOffset,
                        length: requested
                    )
                    let readableCount = buffer.readableBytes
                    guard readableCount > 0 else { break }
                    guard let bytes = buffer.readBytes(length: readableCount) else { break }
                    result.append(contentsOf: bytes)
                    currentOffset += UInt64(readableCount)
                    remaining -= readableCount
                }
                return result
            }
        }
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        // Returning nil for photos preserves the existing Quick Look fallback.
        // Videos deliberately use a bounded ranged read so browsing a folder
        // never downloads a multi-gigabyte original just to draw one frame.
        guard !item.isDirectory, item.isVideo else { return nil }

        let temporaryURL = Self.videoThumbnailTemporaryURL(for: item)
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { try? FileManager.default.removeItem(at: temporaryURL) }

        do {
            try await writeSparseVideoPreview(
                for: item,
                size: size,
                to: temporaryURL
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is SFTPVideoThumbnailPreparationError {
            throw RemoteThumbnailError.optimizedPreviewUnavailable
        }

        do {
            try Task.checkCancellation()
            return try await Self.generateVideoThumbnail(
                from: temporaryURL,
                size: size
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Some containers need media bytes outside the bounded head/tail
            // window. Tell the caller not to fall back to the full download.
            throw RemoteThumbnailError.optimizedPreviewUnavailable
        }
    }

    private func writeSparseVideoPreview(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        to temporaryURL: URL
    ) async throws {
        let listedSize = item.size.flatMap { size -> UInt64? in
            guard size > 0 else { return nil }
            return UInt64(exactly: size)
        }

        try await withSFTP(closeTransportOnCancellation: true) { sftp in
            let fileSize: UInt64
            if let listedSize {
                fileSize = listedSize
            } else {
                let attributes = try await sftp.getAttributes(at: item.path)
                guard let attributeSize = attributes.size, attributeSize > 0 else {
                    throw SFTPVideoThumbnailPreparationError.missingFileSize
                }
                fileSize = attributeSize
            }

            let plan = try SFTPVideoThumbnailRangePlan(
                fileSize: fileSize,
                thumbnailSize: size
            )
            let localFile = try FileHandle(forWritingTo: temporaryURL)
            defer { try? localFile.close() }
            try localFile.truncate(atOffset: fileSize)

            try await sftp.withFile(filePath: item.path, flags: .read) { remoteFile in
                for segment in plan.segments {
                    try Task.checkCancellation()
                    try localFile.seek(toOffset: segment.offset)

                    var remoteOffset = segment.offset
                    var remaining = segment.length
                    while remaining > 0 {
                        try Task.checkCancellation()
                        let requestedLength = UInt32(
                            min(remaining, UInt64(Self.thumbnailReadChunkSize))
                        )
                        var buffer = try await remoteFile.read(
                            from: remoteOffset,
                            length: requestedLength
                        )
                        let count = buffer.readableBytes
                        guard count > 0, UInt64(count) <= remaining else {
                            throw SFTPVideoThumbnailPreparationError.incompleteRange
                        }
                        guard let bytes = buffer.readBytes(length: count) else {
                            throw SFTPVideoThumbnailPreparationError.incompleteRange
                        }
                        try localFile.write(contentsOf: Data(bytes))
                        remoteOffset += UInt64(count)
                        remaining -= UInt64(count)
                    }
                }
            }
            try localFile.synchronize()
        }
    }

    private static func generateVideoThumbnail(
        from fileURL: URL,
        size: RemoteThumbnailSize
    ) async throws -> Data {
        let asset = AVURLAsset(
            url: fileURL,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = size.maximumVideoThumbnailDimensions
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity

        return try await withTaskCancellationHandler {
            var generationError: Error?
            for seconds in [0.5, 0, 1] {
                do {
                    try Task.checkCancellation()
                    let result = try await generator.image(
                        at: CMTime(seconds: seconds, preferredTimescale: 600)
                    )
                    return try jpegData(from: result.image)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    generationError = error
                }
            }
            throw generationError ?? SFTPVideoThumbnailPreparationError.imageGenerationFailed
        } onCancel: {
            generator.cancelAllCGImageGeneration()
        }
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw SFTPVideoThumbnailPreparationError.imageEncodingFailed
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.65
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw SFTPVideoThumbnailPreparationError.imageEncodingFailed
        }
        return data as Data
    }

    private static func videoThumbnailTemporaryURL(for item: RemoteFileItem) -> URL {
        let originalExtension = (item.name as NSString).pathExtension.lowercased()
        let isSafeExtension = !originalExtension.isEmpty
            && originalExtension.utf8.count <= 10
            && originalExtension.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
            }
        let fileExtension = isSafeExtension ? originalExtension : "video"
        return FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
            .appendingPathExtension(fileExtension)
    }

    private static let thumbnailReadChunkSize: UInt32 = 256 * 1_024

    private func withSFTP<T: Sendable>(
        closeTransportOnCancellation: Bool = false,
        _ operation: @escaping @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let validator = SSHHostKeyValidator.custom(
            NasFinderSSHHostKeyValidator(expectedKey: connection.trustedHostKey)
        )
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: connection.host,
                port: connection.port,
                authenticationMethod: .passwordBased(
                    username: connection.username,
                    password: credential.password
                ),
                hostKeyValidator: validator,
                reconnect: .never,
                // NIOSSH's bundled set only advertises AES-GCM, elliptic-curve
                // key exchange, and Ed25519/ECDSA host keys. Synology and other
                // established SFTP servers can still require AES-CTR, group14,
                // or an RSA host key. Citadel appends those compatibility
                // algorithms after the modern defaults, so stronger algorithms
                // remain preferred whenever the server supports them.
                algorithms: .all,
                connectTimeout: closeTransportOnCancellation
                    ? .seconds(20)
                    : .seconds(30)
            )
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw error
        }

        let transportCloser = SFTPClientTransportCloser(client: client)
        if Task.isCancelled {
            try? await transportCloser.close()
            throw CancellationError()
        }

        let runOperation = {
            do {
                let sftp = try await client.openSFTP()
                do {
                    let result = try await operation(sftp)
                    try await sftp.close()
                    try await transportCloser.close()
                    return result
                } catch {
                    try? await sftp.close()
                    try? await transportCloser.close()
                    throw error
                }
            } catch {
                try? await transportCloser.close()
                throw error
            }
        }

        guard closeTransportOnCancellation else {
            return try await runOperation()
        }

        return try await SFTPTaskCancellationBridge.run(
            operation: runOperation
        ) {
            // Citadel's in-flight NIO futures do not observe Swift task
            // cancellation. Closing the transport makes a stalled read fail,
            // allowing preview retry/dismissal to release the old SSH session.
            try? await transportCloser.close()
        }
    }

    private static func appending(_ name: String, to directory: String) -> String {
        if directory == "/" { return "/\(name)" }
        if directory == "." { return "./\(name)" }
        return directory.hasSuffix("/") ? "\(directory)\(name)" : "\(directory)/\(name)"
    }
}

/// Bridges Swift task cancellation to transports backed by NIO futures.
/// Those futures do not necessarily resume merely because their awaiting task
/// was cancelled, so the caller supplies an async action that tears down the
/// transport and makes the pending operation finish.
enum SFTPTaskCancellationBridge {
    static func run<Value: Sendable>(
        operation: @escaping () async throws -> Value,
        onCancel: @escaping @Sendable () async -> Void
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                let value = try await operation()
                try Task.checkCancellation()
                return value
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
        } onCancel: {
            Task {
                await onCancel()
            }
        }
    }
}

private final class SFTPClientTransportCloser: @unchecked Sendable {
    let client: SSHClient
    private let lock = NSLock()
    private var didStartClosing = false

    init(client: SSHClient) {
        self.client = client
    }

    func close() async throws {
        let shouldClose = lock.withLock {
            guard !didStartClosing else { return false }
            didStartClosing = true
            return true
        }
        guard shouldClose else { return }
        try await client.close()
    }
}

enum SFTPDownloadSizePolicy {
    static func expectedByteCount(
        liveByteCount: UInt64?,
        listedByteCount: Int64?
    ) -> Int64? {
        liveByteCount.flatMap(Int64.init(exactly:)) ?? listedByteCount
    }
}

extension SFTPFileService {
    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let name = try RemotePath.validatedName(name)
        let rootPath = connection.normalizedRootPath
        let directoryPath = try RemotePath.normalize(
            directoryPath,
            within: rootPath
        )
        let destinationPath = try RemotePath.appending(
            name: name,
            to: directoryPath,
            within: rootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: .createFolder,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: destinationPath
        )

        let entry = try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                directoryPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let entries = try await Self.entries(
                in: directoryPath,
                rootPath: rootPath,
                using: sftp
            )
            guard !entries.contains(where: { $0.name == name }) else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: destinationPath,
                    destinationPath: destinationPath
                )
            }

            try context.checkCancellation()
            try await sftp.createDirectory(atPath: destinationPath)
            guard let created = try await Self.entry(
                named: name,
                in: directoryPath,
                rootPath: rootPath,
                using: sftp
            ), created.isDirectory else {
                throw SFTPFileMutationError.verificationFailed
            }
            return created
        }

        await context.report(
            operation: .createFolder,
            phase: .completed,
            unit: .items,
            completedUnitCount: 1,
            totalUnitCount: 1,
            currentPath: destinationPath
        )
        return entry.remoteItem(connectionID: connection.id)
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try requireMatchingConnection(item)
        let newName = try RemotePath.validatedName(newName)
        let rootPath = connection.normalizedRootPath
        let sourcePath = try RemotePath.normalize(item.path, within: rootPath)
        let sourceParts = try SFTPPathSafety.parts(
            of: sourcePath,
            within: rootPath
        )
        let destinationPath = try RemotePath.appending(
            name: newName,
            to: sourceParts.parent,
            within: rootPath
        )
        if sourcePath == destinationPath { return item }

        try context.checkCancellation()
        await context.report(
            operation: .rename,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: sourcePath
        )

        let renamed = try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                sourceParts.parent,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let entries = try await Self.entries(
                in: sourceParts.parent,
                rootPath: rootPath,
                using: sftp
            )
            guard entries.contains(where: { $0.name == sourceParts.name }) else {
                throw RemoteFileOperationError.notFound(path: sourcePath)
            }
            guard !entries.contains(where: { $0.name == newName }) else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath
                )
            }

            try context.checkCancellation()
            return try await Self.renameVerified(
                from: sourcePath,
                to: destinationPath,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
        }

        await context.report(
            operation: .rename,
            phase: .completed,
            unit: .items,
            completedUnitCount: 1,
            totalUnitCount: 1,
            currentPath: destinationPath
        )
        return renamed.remoteItem(connectionID: connection.id)
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try requireMatchingConnection(item)
        let rootPath = connection.normalizedRootPath
        let sourcePath = try RemotePath.normalize(item.path, within: rootPath)
        let sourceParts = try SFTPPathSafety.parts(
            of: sourcePath,
            within: rootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: .delete,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            currentPath: sourcePath
        )

        let outcomes = try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                sourceParts.parent,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            guard let entry = try await Self.entry(
                named: sourceParts.name,
                in: sourceParts.parent,
                rootPath: rootPath,
                using: sftp
            ) else {
                throw RemoteFileOperationError.notFound(path: sourcePath)
            }
            return try await Self.deleteEntry(
                entry,
                recursive: recursive,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                operationID: context.operationID,
                context: context,
                using: sftp
            )
        }

        return RemoteOperationResult(
            operationID: context.operationID,
            operation: .delete,
            outcomes: outcomes
        )
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let startedSecurityScope = localURL.startAccessingSecurityScopedResource()
        defer {
            if startedSecurityScope {
                localURL.stopAccessingSecurityScopedResource()
            }
        }

        let resourceValues = try localURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard resourceValues.isRegularFile == true,
              let localFileSize = resourceValues.fileSize,
              localFileSize >= 0 else {
            throw SFTPFileMutationError.localSourceIsNotRegularFile
        }
        let expectedSize = UInt64(localFileSize)
        let requestedName = try RemotePath.validatedName(
            preferredName ?? localURL.lastPathComponent
        )
        let rootPath = connection.normalizedRootPath
        let directoryPath = try RemotePath.normalize(
            directoryPath,
            within: rootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: .upload,
            phase: .preparing,
            unit: .bytes,
            completedUnitCount: 0,
            totalUnitCount: Int64(exactly: expectedSize),
            currentPath: directoryPath
        )

        return try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                directoryPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let entries = try await Self.entries(
                in: directoryPath,
                rootPath: rootPath,
                using: sftp
            )
            let decision = try SFTPDestinationDecision.resolve(
                originalName: requestedName,
                sourcePath: localURL.lastPathComponent,
                directoryPath: directoryPath,
                entries: entries,
                conflictPolicy: conflictPolicy,
                rootPath: rootPath
            )
            switch decision {
            case .skip(let path):
                return RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .upload,
                    outcomes: [
                        .skipped(
                            sourcePath: localURL.lastPathComponent,
                            destinationPath: path,
                            issue: RemoteOperationIssue(
                                code: .conflict,
                                message: "같은 이름의 항목이 있어 건너뛰었습니다."
                            )
                        )
                    ]
                )
            case .use(let name, let replacing):
                let destinationPath = try RemotePath.appending(
                    name: name,
                    to: directoryPath,
                    within: rootPath
                )
                let stagingPath = try Self.temporaryPath(
                    kind: "upload",
                    in: directoryPath,
                    rootPath: rootPath
                )
                do {
                    try context.checkCancellation()
                    try await Self.streamLocalFile(
                        at: localURL,
                        expectedSize: expectedSize,
                        to: stagingPath,
                        operation: .upload,
                        context: context,
                        using: sftp
                    )
                    try context.checkCancellation()
                    await context.report(
                        operation: .upload,
                        phase: .committing,
                        unit: .bytes,
                        completedUnitCount: Int64(exactly: expectedSize) ?? Int64.max,
                        totalUnitCount: Int64(exactly: expectedSize),
                        currentPath: destinationPath
                    )
                    let commit = try await Self.commitStagedFile(
                        stagingPath: stagingPath,
                        destinationPath: destinationPath,
                        replacing: replacing,
                        expectedSize: expectedSize,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                    await context.report(
                        operation: .upload,
                        phase: .completed,
                        unit: .bytes,
                        completedUnitCount: Int64(exactly: expectedSize) ?? Int64.max,
                        totalUnitCount: Int64(exactly: expectedSize),
                        currentPath: destinationPath
                    )
                    return RemoteOperationResult(
                        operationID: context.operationID,
                        operation: .upload,
                        outcomes: [
                            .succeeded(
                                sourcePath: localURL.lastPathComponent,
                                destinationPath: destinationPath,
                                resultingItem: commit.entry.remoteItem(
                                    connectionID: self.connection.id
                                )
                            )
                        ],
                        rollbackState: commit.cleanupState
                    )
                } catch let commitError as SFTPAtomicCommitError {
                    try? await Self.removeTemporaryIfPresent(
                        at: stagingPath,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                    if commitError.rollbackState == .failed {
                        throw Self.interrupted(
                            reason: .unrecoverableFailure,
                            operationID: context.operationID,
                            operation: .upload,
                            outcomes: [
                                .failed(
                                    sourcePath: localURL.lastPathComponent,
                                    destinationPath: destinationPath,
                                    issue: Self.issue(for: commitError)
                                )
                            ],
                            rollbackState: .failed
                        )
                    }
                    throw commitError
                } catch is CancellationError {
                    do {
                        try await Self.removeTemporaryIfPresent(
                            at: stagingPath,
                            rootPath: rootPath,
                            canonicalRoot: canonicalRoot,
                            using: sftp
                        )
                    } catch {
                        throw Self.interrupted(
                            reason: .cancelled,
                            operationID: context.operationID,
                            operation: .upload,
                            outcomes: [
                                .failed(
                                    sourcePath: localURL.lastPathComponent,
                                    destinationPath: destinationPath,
                                    issue: Self.issue(for: error)
                                )
                            ],
                            wasCancelled: true,
                            rollbackState: .failed
                        )
                    }
                    throw CancellationError()
                } catch {
                    try? await Self.removeTemporaryIfPresent(
                        at: stagingPath,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                    throw Self.translated(error, path: destinationPath)
                }
            }
        }
    }

    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        // This must happen before any mutation. In particular, a folder can
        // never use replace even when the destination does not exist yet.
        try conflictPolicy.validate(
            for: item,
            destinationPath: directoryPath
        )
        try requireMatchingConnection(item)
        guard strategy != .serverSideOnly else {
            throw RemoteFileOperationError.unsupported(operation: .copy)
        }

        let rootPath = connection.normalizedRootPath
        let sourcePath = try RemotePath.normalize(item.path, within: rootPath)
        let sourceParts = try SFTPPathSafety.parts(
            of: sourcePath,
            within: rootPath
        )
        let directoryPath = try RemotePath.normalize(
            directoryPath,
            within: rootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: .copy,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            currentPath: sourcePath
        )

        return try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                sourceParts.parent,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let resolvedDestinationDirectory = try await Self.resolvedPathInsideRoot(
                directoryPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            guard let source = try await Self.entry(
                named: sourceParts.name,
                in: sourceParts.parent,
                rootPath: rootPath,
                using: sftp
            ) else {
                throw RemoteFileOperationError.notFound(path: sourcePath)
            }
            guard !source.isSymbolicLink else {
                throw SFTPFileMutationError.symbolicLinkTransferUnsupported
            }
            let resolvedSource = try await Self.resolvedPathInsideRoot(
                source.path,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let destinationEntries = try await Self.entries(
                in: directoryPath,
                rootPath: rootPath,
                using: sftp
            )
            let decision = try SFTPDestinationDecision.resolve(
                originalName: source.name,
                sourcePath: source.path,
                directoryPath: directoryPath,
                entries: destinationEntries,
                conflictPolicy: conflictPolicy,
                rootPath: rootPath
            )
            switch decision {
            case .skip(let path):
                return RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .copy,
                    outcomes: [
                        .skipped(
                            sourcePath: source.path,
                            destinationPath: path,
                            issue: RemoteOperationIssue(
                                code: .conflict,
                                message: "같은 이름의 항목이 있어 건너뛰었습니다."
                            )
                        )
                    ]
                )
            case .use(let name, let replacing):
                let destinationPath = try RemotePath.appending(
                    name: name,
                    to: directoryPath,
                    within: rootPath
                )
                let canonicalDestination = Self.appendingCanonicalName(
                    name,
                    to: resolvedDestinationDirectory
                )
                if source.isDirectory,
                   SFTPPathSafety.isCanonicalPath(
                    canonicalDestination,
                    inside: resolvedSource
                   ) {
                    throw RemoteFileOperationError.conflict(
                        sourcePath: source.path,
                        destinationPath: destinationPath
                    )
                }

                let execution: SFTPCopyExecution
                do {
                    execution = try await Self.copyEntry(
                        source,
                        to: destinationPath,
                        replacing: replacing,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        connectionID: self.connection.id,
                        operation: .copy,
                        context: context,
                        using: sftp
                    )
                } catch let commitError as SFTPAtomicCommitError
                    where commitError.rollbackState == .failed {
                    throw Self.interrupted(
                        reason: .unrecoverableFailure,
                        operationID: context.operationID,
                        operation: .copy,
                        outcomes: [
                            .failed(
                                sourcePath: source.path,
                                destinationPath: destinationPath,
                                issue: Self.issue(for: commitError)
                            )
                        ],
                        rollbackState: .failed
                    )
                }
                return RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .copy,
                    outcomes: execution.outcomes,
                    rollbackState: execution.cleanupState
                )
            }
        }
    }

    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try conflictPolicy.validate(
            for: item,
            destinationPath: directoryPath
        )
        try requireMatchingConnection(item)

        let rootPath = connection.normalizedRootPath
        let sourcePath = try RemotePath.normalize(item.path, within: rootPath)
        let sourceParts = try SFTPPathSafety.parts(
            of: sourcePath,
            within: rootPath
        )
        let directoryPath = try RemotePath.normalize(
            directoryPath,
            within: rootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: .move,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            currentPath: sourcePath
        )

        return try await withSFTP { sftp in
            let canonicalRoot = try await Self.canonicalRoot(
                rootPath,
                using: sftp
            )
            try await Self.requireDirectoryInsideRoot(
                sourceParts.parent,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let resolvedDestinationDirectory = try await Self.resolvedPathInsideRoot(
                directoryPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            guard let source = try await Self.entry(
                named: sourceParts.name,
                in: sourceParts.parent,
                rootPath: rootPath,
                using: sftp
            ) else {
                throw RemoteFileOperationError.notFound(path: sourcePath)
            }
            let destinationEntries = try await Self.entries(
                in: directoryPath,
                rootPath: rootPath,
                using: sftp
            )
            let decision = try SFTPDestinationDecision.resolve(
                originalName: source.name,
                sourcePath: source.path,
                directoryPath: directoryPath,
                entries: destinationEntries,
                conflictPolicy: conflictPolicy,
                rootPath: rootPath
            )
            switch decision {
            case .skip(let path):
                return RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .move,
                    outcomes: [
                        .skipped(
                            sourcePath: source.path,
                            destinationPath: path,
                            issue: RemoteOperationIssue(
                                code: .conflict,
                                message: "같은 이름의 항목이 있어 건너뛰었습니다."
                            )
                        )
                    ]
                )
            case .use(let name, let replacing):
                let destinationPath = try RemotePath.appending(
                    name: name,
                    to: directoryPath,
                    within: rootPath
                )
                if source.path == destinationPath {
                    return RemoteOperationResult(
                        operationID: context.operationID,
                        operation: .move,
                        outcomes: [
                            .skipped(
                                sourcePath: source.path,
                                destinationPath: destinationPath
                            )
                        ]
                    )
                }
                if source.isDirectory {
                    let resolvedSource = try await Self.resolvedPathInsideRoot(
                        source.path,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                    let canonicalDestination = Self.appendingCanonicalName(
                        name,
                        to: resolvedDestinationDirectory
                    )
                    if SFTPPathSafety.isCanonicalPath(
                        canonicalDestination,
                        inside: resolvedSource
                    ) {
                        throw RemoteFileOperationError.conflict(
                            sourcePath: source.path,
                            destinationPath: destinationPath
                        )
                    }
                }

                if strategy != .streaming {
                    do {
                        let serverMove = try await Self.serverSideMove(
                            source,
                            to: destinationPath,
                            replacing: replacing,
                            rootPath: rootPath,
                            canonicalRoot: canonicalRoot,
                            connectionID: self.connection.id,
                            context: context,
                            using: sftp
                        )
                        return RemoteOperationResult(
                            operationID: context.operationID,
                            operation: .move,
                            outcomes: [serverMove.outcome],
                            rollbackState: serverMove.cleanupState
                        )
                    } catch is SFTPServerSideMoveUnavailable {
                        if strategy == .serverSideOnly {
                            throw RemoteFileOperationError.unsupported(operation: .move)
                        }
                        // Automatic moves fall back only after the helper has
                        // proved that no destination-side mutation remains.
                    } catch let commitError as SFTPAtomicCommitError {
                        throw Self.interrupted(
                            reason: .unrecoverableFailure,
                            operationID: context.operationID,
                            operation: .move,
                            outcomes: [
                                .failed(
                                    sourcePath: source.path,
                                    destinationPath: destinationPath,
                                    issue: Self.issue(for: commitError)
                                )
                            ],
                            rollbackState: commitError.rollbackState
                        )
                    }
                }

                guard !source.isSymbolicLink else {
                    throw SFTPFileMutationError.symbolicLinkTransferUnsupported
                }
                let copied = try await Self.copyEntry(
                    source,
                    to: destinationPath,
                    replacing: replacing,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    connectionID: self.connection.id,
                    operation: .move,
                    context: context,
                    using: sftp
                )
                let currentSnapshots = try await Self.snapshotTree(
                    rootedAt: source,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
                guard Set(currentSnapshots) == Set(copied.sourceSnapshots) else {
                    throw Self.interrupted(
                        reason: .unrecoverableFailure,
                        operationID: context.operationID,
                        operation: .move,
                        outcomes: copied.outcomes + [
                            .failed(
                                sourcePath: source.path,
                                destinationPath: destinationPath,
                                issue: Self.issue(
                                    for: SFTPFileMutationError.sourceChangedDuringTransfer
                                )
                            )
                        ],
                        rollbackState: copied.cleanupState
                    )
                }
                await context.report(
                    operation: .move,
                    phase: .deleting,
                    unit: .items,
                    completedUnitCount: Int64(copied.outcomes.count),
                    currentPath: source.path
                )

                do {
                    // Once the destination is committed, finish the delete as
                    // one critical section even if cancellation arrives. This
                    // prevents a cancelled move from silently becoming a copy.
                    try await Self.cleanupTree(
                        source,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                } catch {
                    throw Self.interrupted(
                        reason: .unrecoverableFailure,
                        operationID: context.operationID,
                        operation: .move,
                        outcomes: copied.outcomes + [
                            .failed(
                                sourcePath: source.path,
                                destinationPath: destinationPath,
                                issue: Self.issue(for: error)
                            )
                        ],
                        rollbackState: copied.cleanupState
                    )
                }
                await context.report(
                    operation: .move,
                    phase: .completed,
                    unit: .items,
                    completedUnitCount: Int64(copied.outcomes.count),
                    currentPath: destinationPath
                )
                return RemoteOperationResult(
                    operationID: context.operationID,
                    operation: .move,
                    outcomes: copied.outcomes,
                    rollbackState: copied.cleanupState
                )
            }
        }
    }
}

private extension SFTPFileService {
    func requireMatchingConnection(_ item: RemoteFileItem) throws {
        guard item.connectionID == connection.id else {
            throw SFTPFileMutationError.verificationFailed
        }
    }

    static func canonicalRoot(
        _ rootPath: String,
        using sftp: SFTPClient
    ) async throws -> String {
        try await sftp.getRealPath(atPath: rootPath)
    }

    static func requireDirectoryInsideRoot(
        _ directoryPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws {
        _ = try await resolvedPathInsideRoot(
            directoryPath,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
    }

    static func resolvedPathInsideRoot(
        _ path: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws -> String {
        let resolved = try await sftp.getRealPath(atPath: path)
        guard SFTPPathSafety.isCanonicalPath(resolved, inside: canonicalRoot) else {
            throw RemoteFileOperationError.pathOutsideRoot(
                path: path,
                rootPath: canonicalRoot
            )
        }
        return resolved
    }

    static func requireSourceInsideRoot(
        _ sourcePath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws {
        _ = try await resolvedPathInsideRoot(
            sourcePath,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
    }

    static func entries(
        in directoryPath: String,
        rootPath: String,
        using sftp: SFTPClient
    ) async throws -> [SFTPRemoteEntry] {
        let batches = try await sftp.listDirectory(atPath: directoryPath)
        return try batches
            .flatMap(\.components)
            .filter { $0.filename != "." && $0.filename != ".." }
            .map { component in
                let path = try RemotePath.appending(
                    name: component.filename,
                    to: directoryPath,
                    within: rootPath
                )
                return SFTPRemoteEntry(
                    path: path,
                    name: component.filename,
                    longname: component.longname,
                    attributes: component.attributes
                )
            }
    }

    static func entry(
        named name: String,
        in directoryPath: String,
        rootPath: String,
        using sftp: SFTPClient
    ) async throws -> SFTPRemoteEntry? {
        try await entries(
            in: directoryPath,
            rootPath: rootPath,
            using: sftp
        ).first { $0.name == name }
    }

    static func entry(
        at path: String,
        rootPath: String,
        using sftp: SFTPClient
    ) async throws -> SFTPRemoteEntry? {
        let parts = try SFTPPathSafety.parts(of: path, within: rootPath)
        return try await entry(
            named: parts.name,
            in: parts.parent,
            rootPath: rootPath,
            using: sftp
        )
    }

    static func renameVerified(
        from sourcePath: String,
        to destinationPath: String,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws -> SFTPRemoteEntry {
        let sourceParts = try SFTPPathSafety.parts(
            of: sourcePath,
            within: rootPath
        )
        let destinationParts = try SFTPPathSafety.parts(
            of: destinationPath,
            within: rootPath
        )
        try await requireDirectoryInsideRoot(
            sourceParts.parent,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
        if sourceParts.parent != destinationParts.parent {
            try await requireDirectoryInsideRoot(
                destinationParts.parent,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
        }

        try await sftp.rename(at: sourcePath, to: destinationPath)
        let sourceStillExists = try await entry(
            named: sourceParts.name,
            in: sourceParts.parent,
            rootPath: rootPath,
            using: sftp
        ) != nil
        guard !sourceStillExists,
              let destination = try await entry(
                named: destinationParts.name,
                in: destinationParts.parent,
                rootPath: rootPath,
                using: sftp
              ) else {
            throw SFTPFileMutationError.verificationFailed
        }
        return destination
    }

    static func removeVerified(
        _ entry: SFTPRemoteEntry,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws {
        let parts = try SFTPPathSafety.parts(of: entry.path, within: rootPath)
        try await requireDirectoryInsideRoot(
            parts.parent,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
        if entry.isDirectory {
            try await sftp.rmdir(at: entry.path)
        } else {
            // A symbolic link is intentionally handled here as a file. SFTP
            // REMOVE unlinks the directory entry without traversing its target.
            try await sftp.remove(at: entry.path)
        }
        guard try await Self.entry(
            named: parts.name,
            in: parts.parent,
            rootPath: rootPath,
            using: sftp
        ) == nil else {
            throw SFTPFileMutationError.verificationFailed
        }
    }

    static func temporaryPath(
        kind: String,
        in directoryPath: String,
        rootPath: String
    ) throws -> String {
        try RemotePath.appending(
            name: ".nasfinder-\(kind)-\(UUID().uuidString.lowercased()).tmp",
            to: directoryPath,
            within: rootPath
        )
    }

    static func appendingCanonicalName(_ name: String, to directory: String) -> String {
        directory == "/" ? "/\(name)" : "\(directory)/\(name)"
    }

    static func copyEntry(
        _ source: SFTPRemoteEntry,
        to destinationPath: String,
        replacing: SFTPRemoteEntry?,
        rootPath: String,
        canonicalRoot: String,
        connectionID: UUID,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> SFTPCopyExecution {
        guard !source.isSymbolicLink else {
            throw SFTPFileMutationError.symbolicLinkTransferUnsupported
        }
        if source.isDirectory {
            guard replacing == nil else {
                throw RemoteFileOperationError.folderReplacementNotAllowed(
                    path: destinationPath
                )
            }
            return try await copyDirectoryTransactionally(
                source,
                to: destinationPath,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                connectionID: connectionID,
                operation: operation,
                context: context,
                using: sftp
            )
        }

        let fileCopy = try await copyFile(
            source,
            to: destinationPath,
            replacing: replacing,
            rootPath: rootPath,
            canonicalRoot: canonicalRoot,
            connectionID: connectionID,
            operation: operation,
            context: context,
            using: sftp
        )
        return SFTPCopyExecution(
            outcomes: [fileCopy.outcome],
            cleanupState: fileCopy.cleanupState,
            sourceSnapshots: [fileCopy.sourceSnapshot]
        )
    }

    static func serverSideMove(
        _ source: SFTPRemoteEntry,
        to destinationPath: String,
        replacing: SFTPRemoteEntry?,
        rootPath: String,
        canonicalRoot: String,
        connectionID: UUID,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> SFTPServerMoveExecution {
        try context.checkCancellation()
        await context.report(
            operation: .move,
            phase: .committing,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: source.path
        )

        if let replacing {
            let destinationParts = try SFTPPathSafety.parts(
                of: destinationPath,
                within: rootPath
            )
            let backupPath = try temporaryPath(
                kind: "backup",
                in: destinationParts.parent,
                rootPath: rootPath
            )
            do {
                _ = try await renameVerified(
                    from: replacing.path,
                    to: backupPath,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
            } catch {
                let destinationExists = try? await entry(
                    at: destinationPath,
                    rootPath: rootPath,
                    using: sftp
                )
                let backupExists = try? await entry(
                    at: backupPath,
                    rootPath: rootPath,
                    using: sftp
                )
                if destinationExists != nil, backupExists == nil {
                    throw SFTPServerSideMoveUnavailable()
                }
                throw SFTPAtomicCommitError(
                    rollbackState: .failed,
                    message: "이동 준비 상태를 확인하지 못했습니다."
                )
            }

            do {
                let moved = try await renameVerified(
                    from: source.path,
                    to: destinationPath,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
                var cleanupState: RemoteRollbackState = .notNeeded
                do {
                    try await removeTemporaryIfPresent(
                        at: backupPath,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                } catch {
                    cleanupState = .failed
                }
                await context.report(
                    operation: .move,
                    phase: .completed,
                    unit: .items,
                    completedUnitCount: 1,
                    totalUnitCount: 1,
                    currentPath: destinationPath
                )
                return SFTPServerMoveExecution(
                    outcome: .succeeded(
                        sourcePath: source.path,
                        destinationPath: destinationPath,
                        resultingItem: moved.remoteItem(connectionID: connectionID)
                    ),
                    cleanupState: cleanupState
                )
            } catch {
                let destinationAfterFailure = try await entry(
                    at: destinationPath,
                    rootPath: rootPath,
                    using: sftp
                )
                let sourceAfterFailure = try await entry(
                    at: source.path,
                    rootPath: rootPath,
                    using: sftp
                )
                if destinationAfterFailure == nil, sourceAfterFailure != nil {
                    do {
                        _ = try await renameVerified(
                            from: backupPath,
                            to: destinationPath,
                            rootPath: rootPath,
                            canonicalRoot: canonicalRoot,
                            using: sftp
                        )
                        throw SFTPServerSideMoveUnavailable()
                    } catch is SFTPServerSideMoveUnavailable {
                        throw SFTPServerSideMoveUnavailable()
                    } catch {
                        throw SFTPAtomicCommitError(
                            rollbackState: .failed,
                            message: "실패한 이동에서 기존 파일을 복원하지 못했습니다."
                        )
                    }
                }
                throw SFTPAtomicCommitError(
                    rollbackState: .failed,
                    message: "이동 결과를 안전하게 확인하지 못했습니다."
                )
            }
        }

        do {
            let moved = try await renameVerified(
                from: source.path,
                to: destinationPath,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            await context.report(
                operation: .move,
                phase: .completed,
                unit: .items,
                completedUnitCount: 1,
                totalUnitCount: 1,
                currentPath: destinationPath
            )
            return SFTPServerMoveExecution(
                outcome: .succeeded(
                    sourcePath: source.path,
                    destinationPath: destinationPath,
                    resultingItem: moved.remoteItem(connectionID: connectionID)
                ),
                cleanupState: .notNeeded
            )
        } catch {
            let sourceStillExists = try await entry(
                at: source.path,
                rootPath: rootPath,
                using: sftp
            ) != nil
            let destinationExists = try await entry(
                at: destinationPath,
                rootPath: rootPath,
                using: sftp
            ) != nil
            if sourceStillExists, !destinationExists {
                throw SFTPServerSideMoveUnavailable()
            }
            throw SFTPAtomicCommitError(
                rollbackState: .failed,
                message: "서버 측 이동 결과를 확인하지 못했습니다."
            )
        }
    }

    static func copyFile(
        _ source: SFTPRemoteEntry,
        to destinationPath: String,
        replacing: SFTPRemoteEntry?,
        rootPath: String,
        canonicalRoot: String,
        connectionID: UUID,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> SFTPFileCopyExecution {
        try await requireSourceInsideRoot(
            source.path,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
        let destinationParts = try SFTPPathSafety.parts(
            of: destinationPath,
            within: rootPath
        )
        let stagingPath = try temporaryPath(
            kind: "copy",
            in: destinationParts.parent,
            rootPath: rootPath
        )

        do {
            try context.checkCancellation()
            let transferredSize = try await streamRemoteFile(
                source,
                to: stagingPath,
                operation: operation,
                context: context,
                using: sftp
            )
            try context.checkCancellation()
            await context.report(
                operation: operation,
                phase: .committing,
                unit: .bytes,
                completedUnitCount: Int64(exactly: transferredSize) ?? Int64.max,
                totalUnitCount: Int64(exactly: transferredSize),
                currentPath: destinationPath
            )
            let commit = try await commitStagedFile(
                stagingPath: stagingPath,
                destinationPath: destinationPath,
                replacing: replacing,
                expectedSize: transferredSize,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            await context.report(
                operation: operation,
                phase: .completed,
                unit: .bytes,
                completedUnitCount: Int64(exactly: transferredSize) ?? Int64.max,
                totalUnitCount: Int64(exactly: transferredSize),
                currentPath: destinationPath
            )
            return SFTPFileCopyExecution(
                outcome: .succeeded(
                    sourcePath: source.path,
                    destinationPath: destinationPath,
                    resultingItem: commit.entry.remoteItem(
                        connectionID: connectionID
                    )
                ),
                cleanupState: commit.cleanupState,
                sourceSnapshot: SFTPSourceSnapshot(source)
            )
        } catch is CancellationError {
            do {
                try await removeTemporaryIfPresent(
                    at: stagingPath,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
            } catch {
                throw SFTPAtomicCommitError(
                    rollbackState: .failed,
                    message: "취소한 복사의 임시 파일을 정리하지 못했습니다."
                )
            }
            throw CancellationError()
        } catch {
            try? await removeTemporaryIfPresent(
                at: stagingPath,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            throw translated(error, path: destinationPath)
        }
    }

    static func streamRemoteFile(
        _ source: SFTPRemoteEntry,
        to stagingPath: String,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> UInt64 {
        let sourceFile = try await sftp.openFile(
            filePath: source.path,
            flags: .read
        )
        let destinationFile: SFTPFile
        do {
            destinationFile = try await sftp.openFile(
                filePath: stagingPath,
                flags: [.write, .create, .truncate, .forceCreate]
            )
        } catch {
            try? await sourceFile.close()
            throw error
        }

        let declaredSize = source.attributes.size
        var offset: UInt64 = 0
        do {
            while true {
                try context.checkCancellation()
                let buffer = try await sourceFile.read(
                    from: offset,
                    length: UInt32(transferChunkSize)
                )
                let count = buffer.readableBytes
                guard count > 0 else { break }
                guard offset <= UInt64.max - UInt64(count) else {
                    throw SFTPFileMutationError.sourceChangedDuringTransfer
                }
                try await destinationFile.write(buffer, at: offset)
                offset += UInt64(count)
                await context.report(
                    operation: operation,
                    phase: .writing,
                    unit: .bytes,
                    completedUnitCount: Int64(exactly: offset) ?? Int64.max,
                    totalUnitCount: declaredSize.flatMap(Int64.init(exactly:)),
                    currentPath: source.path
                )
            }
            try await sourceFile.close()
            try await destinationFile.close()
        } catch {
            try? await sourceFile.close()
            try? await destinationFile.close()
            throw error
        }

        if let declaredSize, declaredSize != offset {
            throw SFTPFileMutationError.sourceChangedDuringTransfer
        }
        let stagedAttributes = try await sftp.getAttributes(at: stagingPath)
        guard stagedAttributes.size == offset else {
            throw SFTPFileMutationError.verificationFailed
        }
        return offset
    }

    static func copyDirectoryTransactionally(
        _ source: SFTPRemoteEntry,
        to destinationPath: String,
        rootPath: String,
        canonicalRoot: String,
        connectionID: UUID,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> SFTPCopyExecution {
        let destinationParts = try SFTPPathSafety.parts(
            of: destinationPath,
            within: rootPath
        )
        let createdRoot: SFTPRemoteEntry
        do {
            try await sftp.createDirectory(atPath: destinationPath)
            guard let verified = try await entry(
                named: destinationParts.name,
                in: destinationParts.parent,
                rootPath: rootPath,
                using: sftp
            ), verified.isDirectory else {
                throw SFTPFileMutationError.verificationFailed
            }
            createdRoot = verified
        } catch {
            throw translated(error, path: destinationPath)
        }

        var outcomes: [RemoteOperationItemOutcome] = [
            .succeeded(
                sourcePath: source.path,
                destinationPath: destinationPath,
                resultingItem: createdRoot.remoteItem(connectionID: connectionID)
            )
        ]
        var sourceSnapshots = [SFTPSourceSnapshot(source)]
        var cleanupState: RemoteRollbackState = .notNeeded
        do {
            let descendants = try await copyDirectoryContents(
                source,
                to: createdRoot,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                connectionID: connectionID,
                operation: operation,
                context: context,
                using: sftp
            )
            outcomes += descendants.outcomes
            sourceSnapshots += descendants.sourceSnapshots
            if descendants.cleanupState == .failed {
                cleanupState = .failed
            }
            return SFTPCopyExecution(
                outcomes: outcomes,
                cleanupState: cleanupState,
                sourceSnapshots: sourceSnapshots
            )
        } catch {
            let wasCancelled = error is CancellationError
            do {
                try await cleanupTree(
                    createdRoot,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
            } catch let cleanupError {
                outcomes.append(
                    .failed(
                        sourcePath: source.path,
                        destinationPath: destinationPath,
                        issue: issue(for: cleanupError)
                    )
                )
                throw interrupted(
                    reason: wasCancelled ? .cancelled : .unrecoverableFailure,
                    operationID: context.operationID,
                    operation: operation,
                    outcomes: outcomes,
                    wasCancelled: wasCancelled,
                    rollbackState: .failed
                )
            }
            if wasCancelled { throw CancellationError() }
            throw error
        }
    }

    static func copyDirectoryContents(
        _ sourceDirectory: SFTPRemoteEntry,
        to destinationDirectory: SFTPRemoteEntry,
        rootPath: String,
        canonicalRoot: String,
        connectionID: UUID,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> SFTPCopyExecution {
        try context.checkCancellation()
        try await requireDirectoryInsideRoot(
            sourceDirectory.path,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
        let children = try await entries(
            in: sourceDirectory.path,
            rootPath: rootPath,
            using: sftp
        )
        var outcomes: [RemoteOperationItemOutcome] = []
        var sourceSnapshots: [SFTPSourceSnapshot] = []
        var cleanupState: RemoteRollbackState = .notNeeded
        for child in children {
            try context.checkCancellation()
            guard !child.isSymbolicLink else {
                throw SFTPFileMutationError.symbolicLinkTransferUnsupported
            }
            sourceSnapshots.append(SFTPSourceSnapshot(child))
            let childDestinationPath = try RemotePath.appending(
                name: child.name,
                to: destinationDirectory.path,
                within: rootPath
            )
            if child.isDirectory {
                try await sftp.createDirectory(atPath: childDestinationPath)
                guard let created = try await entry(
                    named: child.name,
                    in: destinationDirectory.path,
                    rootPath: rootPath,
                    using: sftp
                ), created.isDirectory else {
                    throw SFTPFileMutationError.verificationFailed
                }
                outcomes.append(
                    .succeeded(
                        sourcePath: child.path,
                        destinationPath: childDestinationPath,
                        resultingItem: created.remoteItem(connectionID: connectionID)
                    )
                )
                let nested = try await copyDirectoryContents(
                    child,
                    to: created,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    connectionID: connectionID,
                    operation: operation,
                    context: context,
                    using: sftp
                )
                outcomes += nested.outcomes
                sourceSnapshots += nested.sourceSnapshots
                if nested.cleanupState == .failed { cleanupState = .failed }
            } else {
                let copied = try await copyFile(
                    child,
                    to: childDestinationPath,
                    replacing: nil,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    connectionID: connectionID,
                    operation: operation,
                    context: context,
                    using: sftp
                )
                outcomes.append(copied.outcome)
                if copied.cleanupState == .failed { cleanupState = .failed }
            }
        }
        return SFTPCopyExecution(
            outcomes: outcomes,
            cleanupState: cleanupState,
            sourceSnapshots: sourceSnapshots
        )
    }

    static func snapshotTree(
        rootedAt originalRoot: SFTPRemoteEntry,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws -> [SFTPSourceSnapshot] {
        guard let currentRoot = try await entry(
            at: originalRoot.path,
            rootPath: rootPath,
            using: sftp
        ) else {
            throw RemoteFileOperationError.notFound(path: originalRoot.path)
        }
        var snapshots = [SFTPSourceSnapshot(currentRoot)]
        if currentRoot.isDirectory {
            try await requireDirectoryInsideRoot(
                currentRoot.path,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let children = try await entries(
                in: currentRoot.path,
                rootPath: rootPath,
                using: sftp
            )
            for child in children {
                if child.isDirectory {
                    snapshots += try await snapshotTree(
                        rootedAt: child,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                } else {
                    snapshots.append(SFTPSourceSnapshot(child))
                }
            }
        }
        return snapshots
    }

    static func cleanupTree(
        _ entry: SFTPRemoteEntry,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws {
        if entry.isDirectory {
            try await requireDirectoryInsideRoot(
                entry.path,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            let children = try await entries(
                in: entry.path,
                rootPath: rootPath,
                using: sftp
            )
            for child in children {
                try await cleanupTree(
                    child,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
            }
        }
        try await removeVerified(
            entry,
            rootPath: rootPath,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
    }

    static func streamLocalFile(
        at localURL: URL,
        expectedSize: UInt64,
        to stagingPath: String,
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws {
        let localFile = try FileHandle(forReadingFrom: localURL)
        defer { try? localFile.close() }
        let remoteFile = try await sftp.openFile(
            filePath: stagingPath,
            flags: [.write, .create, .truncate, .forceCreate]
        )

        var offset: UInt64 = 0
        do {
            while let data = try localFile.read(upToCount: transferChunkSize),
                  !data.isEmpty {
                try context.checkCancellation()
                guard data.count <= transferChunkSize,
                      offset <= UInt64.max - UInt64(data.count) else {
                    throw SFTPFileMutationError.sourceChangedDuringTransfer
                }
                var buffer = ByteBuffer()
                buffer.writeBytes(data)
                try await remoteFile.write(buffer, at: offset)
                offset += UInt64(data.count)
                await context.report(
                    operation: operation,
                    phase: .writing,
                    unit: .bytes,
                    completedUnitCount: Int64(exactly: offset) ?? Int64.max,
                    totalUnitCount: Int64(exactly: expectedSize),
                    currentPath: stagingPath
                )
            }
            try await remoteFile.close()
        } catch {
            try? await remoteFile.close()
            throw error
        }

        guard offset == expectedSize else {
            throw SFTPFileMutationError.sourceChangedDuringTransfer
        }
        let attributes = try await sftp.getAttributes(at: stagingPath)
        guard attributes.size == offset else {
            throw SFTPFileMutationError.verificationFailed
        }
    }

    static func commitStagedFile(
        stagingPath: String,
        destinationPath: String,
        replacing: SFTPRemoteEntry?,
        expectedSize: UInt64,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws -> SFTPFileCommitResult {
        if let replacing {
            let destinationParts = try SFTPPathSafety.parts(
                of: destinationPath,
                within: rootPath
            )
            let backupPath = try temporaryPath(
                kind: "backup",
                in: destinationParts.parent,
                rootPath: rootPath
            )
            do {
                _ = try await renameVerified(
                    from: replacing.path,
                    to: backupPath,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
            } catch {
                throw SFTPAtomicCommitError(
                    rollbackState: .notNeeded,
                    message: "기존 파일을 안전하게 보관하지 못했습니다."
                )
            }

            do {
                let committed = try await renameVerified(
                    from: stagingPath,
                    to: destinationPath,
                    rootPath: rootPath,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
                guard committed.attributes.size == expectedSize else {
                    throw SFTPFileMutationError.verificationFailed
                }

                var cleanupState: RemoteRollbackState = .notNeeded
                do {
                    try await removeTemporaryIfPresent(
                        at: backupPath,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                } catch {
                    cleanupState = .failed
                }
                return SFTPFileCommitResult(
                    entry: committed,
                    cleanupState: cleanupState
                )
            } catch {
                do {
                    let destinationAfterFailure = try await entry(
                        at: destinationPath,
                        rootPath: rootPath,
                        using: sftp
                    )
                    let stagingStillExists = try await entry(
                        at: stagingPath,
                        rootPath: rootPath,
                        using: sftp
                    ) != nil

                    // A lost verification response can make a successful
                    // rename look failed. Accept it only when the staged name
                    // disappeared and the destination has the exact size.
                    if let destinationAfterFailure,
                       !stagingStillExists,
                       destinationAfterFailure.attributes.size == expectedSize {
                        var cleanupState: RemoteRollbackState = .notNeeded
                        do {
                            try await removeTemporaryIfPresent(
                                at: backupPath,
                                rootPath: rootPath,
                                canonicalRoot: canonicalRoot,
                                using: sftp
                            )
                        } catch {
                            cleanupState = .failed
                        }
                        return SFTPFileCommitResult(
                            entry: destinationAfterFailure,
                            cleanupState: cleanupState
                        )
                    }

                    // Never delete an unexpected destination created by a
                    // concurrent client. In that race, preserve both it and
                    // our backup and report that rollback needs attention.
                    guard destinationAfterFailure == nil else {
                        throw SFTPAtomicCommitError(
                            rollbackState: .failed,
                            message: "파일 교체 중 다른 변경이 감지되었습니다."
                        )
                    }
                    _ = try await renameVerified(
                        from: backupPath,
                        to: destinationPath,
                        rootPath: rootPath,
                        canonicalRoot: canonicalRoot,
                        using: sftp
                    )
                    throw SFTPAtomicCommitError(
                        rollbackState: .succeeded,
                        message: "새 파일을 게시하지 못해 기존 파일을 복원했습니다."
                    )
                } catch let commitError as SFTPAtomicCommitError {
                    throw commitError
                } catch {
                    throw SFTPAtomicCommitError(
                        rollbackState: .failed,
                        message: "파일 교체를 복구하지 못했습니다."
                    )
                }
            }
        }

        let committed = try await renameVerified(
            from: stagingPath,
            to: destinationPath,
            rootPath: rootPath,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
        guard committed.attributes.size == expectedSize else {
            throw SFTPAtomicCommitError(
                rollbackState: .notNeeded,
                message: "게시한 파일의 크기를 확인하지 못했습니다."
            )
        }
        return SFTPFileCommitResult(entry: committed, cleanupState: .notNeeded)
    }

    static func removeTemporaryIfPresent(
        at path: String,
        rootPath: String,
        canonicalRoot: String,
        using sftp: SFTPClient
    ) async throws {
        guard let temporary = try await entry(
            at: path,
            rootPath: rootPath,
            using: sftp
        ) else { return }
        guard !temporary.isDirectory else {
            throw SFTPFileMutationError.cleanupFailed
        }
        try await removeVerified(
            temporary,
            rootPath: rootPath,
            canonicalRoot: canonicalRoot,
            using: sftp
        )
    }

    static let transferChunkSize = 256 * 1_024

    static func deleteEntry(
        _ entry: SFTPRemoteEntry,
        recursive: Bool,
        rootPath: String,
        canonicalRoot: String,
        operationID: UUID,
        context: RemoteOperationContext,
        using sftp: SFTPClient
    ) async throws -> [RemoteOperationItemOutcome] {
        var outcomes: [RemoteOperationItemOutcome] = []

        do {
            try context.checkCancellation()
            if entry.isDirectory {
                try await requireDirectoryInsideRoot(
                    entry.path,
                    canonicalRoot: canonicalRoot,
                    using: sftp
                )
                let children = try await entries(
                    in: entry.path,
                    rootPath: rootPath,
                    using: sftp
                )
                if !recursive, !children.isEmpty {
                    throw RemoteFileOperationError.directoryNotEmpty(path: entry.path)
                }
                if recursive {
                    for child in children {
                        do {
                            outcomes += try await deleteEntry(
                                child,
                                recursive: true,
                                rootPath: rootPath,
                                canonicalRoot: canonicalRoot,
                                operationID: operationID,
                                context: context,
                                using: sftp
                            )
                        } catch let interruption as RemoteOperationInterruptedError {
                            throw interruptionByPrepending(
                                outcomes,
                                to: interruption,
                                operationID: operationID,
                                operation: .delete
                            )
                        } catch is CancellationError {
                            if outcomes.isEmpty { throw CancellationError() }
                            throw interrupted(
                                reason: .cancelled,
                                operationID: operationID,
                                operation: .delete,
                                outcomes: outcomes,
                                wasCancelled: true
                            )
                        } catch {
                            let failed = RemoteOperationItemOutcome.failed(
                                sourcePath: child.path,
                                issue: issue(for: error)
                            )
                            if outcomes.isEmpty { throw translated(error, path: child.path) }
                            throw interrupted(
                                reason: .unrecoverableFailure,
                                operationID: operationID,
                                operation: .delete,
                                outcomes: outcomes + [failed]
                            )
                        }
                    }
                }
            }

            try context.checkCancellation()
            await context.report(
                operation: .delete,
                phase: .deleting,
                unit: .items,
                completedUnitCount: Int64(outcomes.count),
                currentPath: entry.path
            )
            try await removeVerified(
                entry,
                rootPath: rootPath,
                canonicalRoot: canonicalRoot,
                using: sftp
            )
            outcomes.append(.succeeded(sourcePath: entry.path))
            await context.report(
                operation: .delete,
                phase: .completed,
                unit: .items,
                completedUnitCount: Int64(outcomes.count),
                currentPath: entry.path
            )
            return outcomes
        } catch let interruption as RemoteOperationInterruptedError {
            throw interruption
        } catch is CancellationError {
            if outcomes.isEmpty { throw CancellationError() }
            throw interrupted(
                reason: .cancelled,
                operationID: operationID,
                operation: .delete,
                outcomes: outcomes,
                wasCancelled: true
            )
        } catch {
            if outcomes.isEmpty { throw translated(error, path: entry.path) }
            throw interrupted(
                reason: .unrecoverableFailure,
                operationID: operationID,
                operation: .delete,
                outcomes: outcomes + [
                    .failed(
                        sourcePath: entry.path,
                        issue: issue(for: error)
                    )
                ]
            )
        }
    }

    static func interrupted(
        reason: RemoteOperationInterruptionReason,
        operationID: UUID,
        operation: RemoteOperationKind,
        outcomes: [RemoteOperationItemOutcome],
        wasCancelled: Bool = false,
        rollbackState: RemoteRollbackState = .notNeeded
    ) -> RemoteOperationInterruptedError {
        RemoteOperationInterruptedError(
            reason: reason,
            partialResult: RemoteOperationResult(
                operationID: operationID,
                operation: operation,
                outcomes: outcomes,
                wasCancelled: wasCancelled,
                rollbackState: rollbackState
            )
        )
    }

    static func interruptionByPrepending(
        _ prefix: [RemoteOperationItemOutcome],
        to interruption: RemoteOperationInterruptedError,
        operationID: UUID,
        operation: RemoteOperationKind
    ) -> RemoteOperationInterruptedError {
        interrupted(
            reason: interruption.reason,
            operationID: operationID,
            operation: operation,
            outcomes: prefix + interruption.partialResult.outcomes,
            wasCancelled: interruption.partialResult.wasCancelled,
            rollbackState: interruption.partialResult.rollbackState
        )
    }

    static func translated(_ error: Error, path: String) -> Error {
        guard case .errorStatus(let status) = error as? SFTPError else {
            return error
        }
        switch status.errorCode {
        case .permissionDenied:
            return RemoteFileOperationError.permissionDenied(path: path)
        case .noSuchFile:
            return RemoteFileOperationError.notFound(path: path)
        default:
            return error
        }
    }

    static func issue(for error: Error) -> RemoteOperationIssue {
        if let operationError = error as? RemoteFileOperationError {
            let code: RemoteOperationIssueCode
            switch operationError {
            case .conflict, .folderReplacementNotAllowed:
                code = .conflict
            case .permissionDenied:
                code = .permissionDenied
            case .notFound:
                code = .notFound
            case .directoryNotEmpty:
                code = .directoryNotEmpty
            case .unsupported:
                code = .unsupported
            default:
                code = .unknown
            }
            return RemoteOperationIssue(
                code: code,
                message: operationError.localizedDescription
            )
        }
        if case .errorStatus(let status) = error as? SFTPError {
            let code: RemoteOperationIssueCode
            switch status.errorCode {
            case .permissionDenied: code = .permissionDenied
            case .noSuchFile: code = .notFound
            case .noConnection, .connectionLost: code = .network
            case .unsupportedOperation: code = .unsupported
            default: code = .server
            }
            return RemoteOperationIssue(
                code: code,
                message: "SFTP 서버가 파일 작업을 완료하지 못했습니다."
            )
        }
        if error is CancellationError {
            return RemoteOperationIssue(
                code: .unknown,
                message: "작업이 취소되었습니다."
            )
        }
        return RemoteOperationIssue(
            code: .unknown,
            message: "파일 작업을 완료하지 못했습니다."
        )
    }
}

private struct SFTPFileCommitResult: Sendable {
    let entry: SFTPRemoteEntry
    let cleanupState: RemoteRollbackState
}

private struct SFTPFileCopyExecution: Sendable {
    let outcome: RemoteOperationItemOutcome
    let cleanupState: RemoteRollbackState
    let sourceSnapshot: SFTPSourceSnapshot
}

private struct SFTPCopyExecution: Sendable {
    let outcomes: [RemoteOperationItemOutcome]
    let cleanupState: RemoteRollbackState
    let sourceSnapshots: [SFTPSourceSnapshot]
}

private struct SFTPSourceSnapshot: Hashable, Sendable {
    let path: String
    let isDirectory: Bool
    let isSymbolicLink: Bool
    let size: UInt64?
    let modificationTime: Date?

    init(_ entry: SFTPRemoteEntry) {
        path = entry.path
        isDirectory = entry.isDirectory
        isSymbolicLink = entry.isSymbolicLink
        size = entry.attributes.size
        modificationTime = entry.attributes.accessModificationTime?.modificationTime
    }
}

private struct SFTPServerMoveExecution: Sendable {
    let outcome: RemoteOperationItemOutcome
    let cleanupState: RemoteRollbackState
}

private struct SFTPServerSideMoveUnavailable: Error, Sendable {}

private struct SFTPAtomicCommitError: LocalizedError, Sendable {
    let rollbackState: RemoteRollbackState
    let message: String

    var errorDescription: String? { message }
}

struct SFTPVideoThumbnailRangePlan: Equatable, Sendable {
    struct Segment: Equatable, Sendable {
        let offset: UInt64
        let length: UInt64
    }

    static let maximumTotalBytes: UInt64 = 1_536 * 1_024

    let fileSize: UInt64
    let segments: [Segment]

    init(fileSize: UInt64, thumbnailSize: RemoteThumbnailSize) throws {
        guard fileSize > 0, fileSize <= UInt64(Int64.max) else {
            throw SFTPVideoThumbnailPreparationError.invalidFileSize
        }

        let limits = thumbnailSize.videoThumbnailRangeLimits
        let headLength = min(fileSize, limits.head)
        let remainingAfterHead = fileSize - headLength
        let tailLength = min(remainingAfterHead, limits.tail)
        var segments = [Segment(offset: 0, length: headLength)]
        if tailLength > 0 {
            segments.append(
                Segment(offset: fileSize - tailLength, length: tailLength)
            )
        }

        precondition(
            segments.reduce(UInt64(0)) { $0 + $1.length }
                <= limits.head + limits.tail
        )
        self.fileSize = fileSize
        self.segments = segments
    }
}

private enum SFTPVideoThumbnailPreparationError: Error {
    case missingFileSize
    case invalidFileSize
    case incompleteRange
    case imageGenerationFailed
    case imageEncodingFailed
}

private extension RemoteThumbnailSize {
    var videoThumbnailRangeLimits: (head: UInt64, tail: UInt64) {
        switch self {
        case .small:
            (512 * 1_024, 128 * 1_024)
        case .medium:
            (768 * 1_024, 256 * 1_024)
        case .large:
            (1_024 * 1_024, 512 * 1_024)
        }
    }

    var maximumVideoThumbnailDimensions: CGSize {
        switch self {
        case .small:
            CGSize(width: 192, height: 192)
        case .medium:
            CGSize(width: 384, height: 384)
        case .large:
            CGSize(width: 720, height: 720)
        }
    }
}
