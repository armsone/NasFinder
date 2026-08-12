import Foundation

actor SynologyFileService: RemoteFileService {
    nonisolated let connection: RemoteConnection
    nonisolated let capabilities: RemoteFileServiceCapabilities = .all
    nonisolated let permitsFullDownloadForVideoThumbnail = false
    nonisolated let supportsRangeStreaming = true

    private let credential: RemoteCredential
    private let session: URLSession
    private let cache: DownloadCache
    private let pollInterval: Duration
    private var sessionID: String?

    /// File Station thumbnails are small responses. If DSM cannot provide one
    /// promptly, keeping a grid cell (and the global progress indicator) alive
    /// for the general 30-second API timeout makes the browser look frozen.
    private static let thumbnailRequestTimeout: TimeInterval = 12
    private static let directoryListingRequestTimeout: TimeInterval = 12

    init(
        connection: RemoteConnection,
        credential: RemoteCredential,
        session: URLSession = .shared,
        cache: DownloadCache = .shared,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.connection = connection
        self.credential = credential
        self.session = session
        self.cache = cache
        self.pollInterval = pollInterval
    }

    /// Tests each DSM layer separately so the UI can distinguish a closed web
    /// port from TLS, authentication, File Station, and root-path failures.
    func testConnection() async throws {
        sessionID = nil

        try await connectionTestStage(.webAPI) {
            try await self.probeWebAPI()
        }
        try await connectionTestStage(.authentication) {
            _ = try await self.validSessionID()
        }
        try await connectionTestStage(.rootPath) {
            _ = try await self.list(directory: self.connection.normalizedRootPath)
        }
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let targetPath = path ?? connection.normalizedRootPath
        return try await authenticatedRequest { sid in
            let isRoot = targetPath == "/"
            var parameters = self.commonParameters(
                api: "SYNO.FileStation.List",
                version: "2",
                method: isRoot ? "list_share" : "list",
                sid: sid
            )
            if !isRoot {
                parameters["folder_path"] = targetPath
            }
            parameters["additional"] = "[\"size\",\"time\"]"
            parameters["sort_by"] = "name"
            parameters["sort_direction"] = "asc"

            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.timeoutInterval = Self.directoryListingRequestTimeout
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTP(response)
            let envelope = try JSONDecoder().decode(SynologyEnvelope<SynologyListData>.self, from: data)
            try self.validate(envelope)
            let nodes = envelope.data?.files ?? envelope.data?.shares ?? []
            return nodes.map { node in
                RemoteFileItem(
                    connectionID: self.connection.id,
                    path: node.path,
                    name: node.name,
                    kind: node.isDirectory ? .folder : .file,
                    size: node.additional?.size ?? node.size,
                    modifiedAt: node.additional?.time?.modifiedDate,
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

        return try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Download",
                version: "2",
                method: "download",
                sid: sid
            ).merging([
                "path": item.path,
                "mode": "download"
            ]) { _, new in new }
            let request = try self.request(script: "entry.cgi", parameters: parameters)
            let downloader = URLSessionProgressDownloader(
                configuration: self.session.configuration
            ) { update in
                await progress(
                    RemoteDownloadProgress(
                        completedByteCount: update.completedByteCount,
                        totalByteCount: update.totalByteCount ?? item.size
                    )
                )
            }
            let download = try await downloader.download(request)
            defer { try? FileManager.default.removeItem(at: download.temporaryURL) }
            try self.validateHTTP(download.response)
            try self.validateDownload(
                at: download.temporaryURL,
                response: download.response
            )
            let cachedURL = try await self.cache.store(
                downloadedURL: download.temporaryURL,
                for: item
            )
            let actualByteCount = (try? cachedURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                .map(Int64.init)
            let completedByteCount = actualByteCount ?? item.size ?? 0
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: completedByteCount,
                    totalByteCount: actualByteCount ?? item.size
                )
            )
            return cachedURL
        }
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else {
            throw NasFinderError.invalidResponse
        }
        let requestedEnd = offset.addingReportingOverflow(Int64(length - 1))
        guard !requestedEnd.overflow else {
            throw NasFinderError.invalidResponse
        }

        return try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Download",
                version: "2",
                method: "download",
                sid: sid
            ).merging([
                "path": item.path,
                "mode": "download"
            ]) { _, new in new }
            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.setValue(
                "bytes=\(offset)-\(requestedEnd.partialValue)",
                forHTTPHeaderField: "Range"
            )
            let reader = URLSessionBoundedRangeReader(
                configuration: self.session.configuration,
                expectedOffset: offset,
                maximumByteCount: length
            )
            let result = try await reader.read(request)
            try self.validateHTTP(result.response)
            return result.data
        }
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        try await thumbnailData(
            for: item,
            size: size,
            maximumByteCount: nil
        )
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int
    ) async throws -> Data? {
        try await thumbnailData(
            for: item,
            size: size,
            maximumByteCount: Optional(maximumByteCount)
        )
    }

    private func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int?
    ) async throws -> Data? {
        guard !item.isDirectory, item.isImage || item.isVideo else { return nil }

        return try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Thumb",
                version: "2",
                method: "get",
                sid: sid
            ).merging([
                "path": item.path,
                "size": size.rawValue,
                "rotate": "0"
            ]) { _, new in new }
            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.timeoutInterval = Self.thumbnailRequestTimeout
            let data: Data
            let response: URLResponse
            if let maximumByteCount {
                let result = try await self.boundedData(
                    for: request,
                    maximumByteCount: maximumByteCount
                )
                data = result.0
                response = result.1
            } else {
                (data, response) = try await self.session.data(for: request)
            }
            try self.validateHTTP(response)

            let contentType = response.mimeType?.lowercased()
            if contentType == "application/json" || contentType?.hasSuffix("+json") == true {
                let envelope = try JSONDecoder().decode(
                    SynologyEnvelope<SynologyEmptyData>.self,
                    from: data
                )
                try self.validate(envelope)
                return nil
            }

            return data.isEmpty ? nil : data
        }
    }

    private func boundedData(
        for request: URLRequest,
        maximumByteCount: Int
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        var data = Data()
        data.reserveCapacity(min(max(maximumByteCount, 0), 256 * 1_024))
        for try await byte in bytes {
            guard data.count < maximumByteCount else {
                throw RemoteThumbnailError.responseTooLarge
            }
            data.append(byte)
        }
        return (data, response)
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let directory = try validatedDirectory(directoryPath)
        let name = try RemotePath.validatedName(name)
        let destinationPath = try RemotePath.appending(
            name: name,
            to: directory,
            within: connection.normalizedRootPath
        )
        try context.checkCancellation()

        if try await existingItem(named: name, in: directory) != nil {
            throw RemoteFileOperationError.conflict(
                sourcePath: destinationPath,
                destinationPath: destinationPath
            )
        }

        await context.report(
            operation: .createFolder,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: destinationPath
        )

        do {
            let data: SynologyCreateFolderData? = try await apiRequest(
                api: "SYNO.FileStation.CreateFolder",
                version: "2",
                method: "create",
                parameters: [
                    "folder_path": try jsonArray([directory]),
                    "name": try jsonArray([name]),
                    "force_parent": "false",
                    "additional": "[\"size\",\"time\",\"type\"]"
                ]
            )
            guard let node = data?.folders.first else {
                throw NasFinderError.invalidResponse
            }
            let item = remoteItem(from: node)
            await context.report(
                operation: .createFolder,
                phase: .completed,
                unit: .items,
                completedUnitCount: 1,
                totalUnitCount: 1,
                currentPath: item.path
            )
            return item
        } catch {
            throw translatedOperationError(
                error,
                sourcePath: destinationPath,
                destinationPath: destinationPath
            )
        }
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let sourcePath = try validatedItemPath(item, allowConnectionRoot: false)
        let newName = try RemotePath.validatedName(newName)
        let parentDirectory = parentPath(of: sourcePath)
        let destinationPath = try RemotePath.appending(
            name: newName,
            to: parentDirectory,
            within: connection.normalizedRootPath
        )
        try context.checkCancellation()

        if destinationPath != sourcePath,
           try await existingItem(named: newName, in: parentDirectory) != nil {
            throw RemoteFileOperationError.conflict(
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }

        await context.report(
            operation: .rename,
            phase: .preparing,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: sourcePath
        )

        do {
            let data: SynologyRenameData? = try await apiRequest(
                api: "SYNO.FileStation.Rename",
                version: "2",
                method: "rename",
                parameters: [
                    "path": try jsonArray([sourcePath]),
                    "name": try jsonArray([newName]),
                    "additional": "[\"size\",\"time\",\"type\"]"
                ]
            )
            guard let node = data?.files.first else {
                throw NasFinderError.invalidResponse
            }
            let renamed = remoteItem(from: node)
            await context.report(
                operation: .rename,
                phase: .completed,
                unit: .items,
                completedUnitCount: 1,
                totalUnitCount: 1,
                currentPath: renamed.path
            )
            return renamed
        } catch {
            throw translatedOperationError(
                error,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await performDelete(
            item,
            recursive: recursive,
            context: context,
            resultOperation: .delete
        )
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let directory = try validatedDirectory(directoryPath)
        let requestedName = try RemotePath.validatedName(
            preferredName ?? localURL.lastPathComponent
        )
        let siblings = try await list(directory: directory)
        let existing = siblings.first { $0.name == requestedName }
        let sourcePath = localURL.path

        let finalName: String
        switch conflictPolicy {
        case .fail:
            if existing != nil {
                throw RemoteFileOperationError.conflict(
                    sourcePath: sourcePath,
                    destinationPath: try RemotePath.appending(
                        name: requestedName,
                        to: directory,
                        within: connection.normalizedRootPath
                    )
                )
            }
            finalName = requestedName
        case .skip:
            if let existing {
                return skippedResult(
                    operation: .upload,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: existing.path
                )
            }
            finalName = requestedName
        case .replace:
            if let existing, existing.isDirectory {
                throw RemoteFileOperationError.folderReplacementNotAllowed(
                    path: existing.path
                )
            }
            finalName = requestedName
        case .keepBoth:
            finalName = try RemotePath.keepBothName(
                for: requestedName,
                existingNames: siblings.map(\.name)
            )
        }

        return try await performUpload(
            localURL: localURL,
            sourcePath: sourcePath,
            to: directory,
            fileName: finalName,
            conflictPolicy: conflictPolicy == .keepBoth ? .fail : conflictPolicy,
            context: context,
            operation: .upload
        )
    }

    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await transfer(
            item,
            to: directoryPath,
            conflictPolicy: conflictPolicy,
            strategy: strategy,
            context: context,
            operation: .copy
        )
    }

    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await transfer(
            item,
            to: directoryPath,
            conflictPolicy: conflictPolicy,
            strategy: strategy,
            context: context,
            operation: .move
        )
    }

    private func transfer(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> RemoteOperationResult {
        try conflictPolicy.validate(for: item, destinationPath: directoryPath)
        let sourcePath = try validatedItemPath(item, allowConnectionRoot: false)
        let directory = try validatedDirectory(directoryPath)
        let siblings = try await list(directory: directory)
        let existing = siblings.first { $0.name == item.name }
        let originalDestinationPath = try RemotePath.appending(
            name: item.name,
            to: directory,
            within: connection.normalizedRootPath
        )

        if existing?.path == sourcePath {
            throw RemoteFileOperationError.conflict(
                sourcePath: sourcePath,
                destinationPath: originalDestinationPath
            )
        }

        let finalName: String
        switch conflictPolicy {
        case .fail:
            if existing != nil {
                throw RemoteFileOperationError.conflict(
                    sourcePath: sourcePath,
                    destinationPath: originalDestinationPath
                )
            }
            finalName = item.name
        case .skip:
            if existing != nil {
                return skippedResult(
                    operation: operation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: originalDestinationPath
                )
            }
            finalName = item.name
        case .replace:
            if let existing, existing.isDirectory {
                throw RemoteFileOperationError.folderReplacementNotAllowed(
                    path: existing.path
                )
            }
            finalName = item.name
        case .keepBoth:
            finalName = try RemotePath.keepBothName(
                for: item.name,
                existingNames: siblings.map(\.name)
            )
        }

        let needsAlternateName = finalName != item.name
        switch strategy {
        case .streaming:
            return try await streamingTransfer(
                item,
                sourcePath: sourcePath,
                to: directory,
                finalName: finalName,
                conflictPolicy: conflictPolicy,
                context: context,
                operation: operation
            )
        case .serverSideOnly where needsAlternateName:
            throw RemoteFileOperationError.unsupported(operation: operation)
        case .automatic where needsAlternateName:
            return try await streamingTransfer(
                item,
                sourcePath: sourcePath,
                to: directory,
                finalName: finalName,
                conflictPolicy: .fail,
                context: context,
                operation: operation
            )
        case .automatic, .serverSideOnly:
            return try await serverSideTransfer(
                item,
                sourcePath: sourcePath,
                to: directory,
                conflictPolicy: conflictPolicy,
                context: context,
                operation: operation
            )
        }
    }

    private func serverSideTransfer(
        _ item: RemoteFileItem,
        sourcePath: String,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> RemoteOperationResult {
        let destinationPath = try RemotePath.appending(
            name: item.name,
            to: directoryPath,
            within: connection.normalizedRootPath
        )
        await context.report(
            operation: operation,
            phase: .preparing,
            unit: .bytes,
            completedUnitCount: 0,
            totalUnitCount: item.size,
            currentPath: sourcePath
        )

        var parameters = [
            "path": try jsonArray([sourcePath]),
            "dest_folder_path": try jsonString(directoryPath),
            "remove_src": operation == .move ? "true" : "false",
            "accurate_progress": "true"
        ]
        switch conflictPolicy {
        case .skip:
            parameters["overwrite"] = "false"
        case .replace:
            parameters["overwrite"] = "true"
        case .fail, .keepBoth:
            break
        }

        var taskID: String?
        do {
            let start: SynologyTaskStartData? = try await apiRequest(
                api: "SYNO.FileStation.CopyMove",
                version: "3",
                method: "start",
                parameters: parameters
            )
            guard let startedTaskID = start?.taskid else {
                throw NasFinderError.invalidResponse
            }
            taskID = startedTaskID
            _ = try await pollCopyMoveTask(
                taskID: startedTaskID,
                context: context,
                operation: operation
            )

            let resultingItem = RemoteFileItem(
                connectionID: connection.id,
                path: destinationPath,
                name: item.name,
                kind: item.kind,
                size: item.size,
                modifiedAt: item.modifiedAt,
                contentTypeIdentifier: item.contentTypeIdentifier
            )
            await context.report(
                operation: operation,
                phase: .completed,
                unit: .items,
                completedUnitCount: 1,
                totalUnitCount: 1,
                currentPath: destinationPath
            )
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: operation,
                outcomes: [
                    .succeeded(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        resultingItem: resultingItem
                    )
                ]
            )
        } catch {
            if let taskID {
                await stopBackgroundTaskIndependently(
                    api: "SYNO.FileStation.CopyMove",
                    version: "3",
                    taskID: taskID
                )
            }
            if isCancellation(error) {
                throw interruptedError(
                    operation: operation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    reason: .cancelled
                )
            }
            if taskID != nil, isConnectionFailure(error) {
                throw interruptedError(
                    operation: operation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    reason: .connectionLost
                )
            }
            throw translatedOperationError(
                error,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }
    }

    private func streamingTransfer(
        _ item: RemoteFileItem,
        sourcePath: String,
        to directoryPath: String,
        finalName: String,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> RemoteOperationResult {
        guard !item.isDirectory else {
            throw RemoteFileOperationError.unsupported(operation: operation)
        }
        try context.checkCancellation()
        await context.report(
            operation: operation,
            phase: .reading,
            unit: .bytes,
            completedUnitCount: 0,
            totalUnitCount: item.size,
            currentPath: sourcePath
        )
        let localURL = try await download(item)
        try context.checkCancellation()
        await context.report(
            operation: operation,
            phase: .reading,
            unit: .bytes,
            completedUnitCount: item.size ?? 0,
            totalUnitCount: item.size,
            currentPath: sourcePath
        )

        let uploadResult = try await performUpload(
            localURL: localURL,
            sourcePath: sourcePath,
            to: directoryPath,
            fileName: finalName,
            conflictPolicy: conflictPolicy == .keepBoth ? .fail : conflictPolicy,
            context: context,
            operation: operation
        )
        guard operation == .move, uploadResult.skipped.isEmpty else {
            return uploadResult
        }

        do {
            try context.checkCancellation()
            _ = try await performDelete(
                item,
                recursive: false,
                context: context,
                resultOperation: .move
            )
            return uploadResult
        } catch {
            let destinationPath = uploadResult.succeeded.first?.destinationPath
            let issue = RemoteOperationIssue(
                code: isCancellation(error) ? .unknown : .server,
                message: error.localizedDescription
            )
            let partial = RemoteOperationResult(
                operationID: context.operationID,
                operation: .move,
                outcomes: uploadResult.outcomes + [
                    .failed(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        issue: issue
                    )
                ],
                wasCancelled: isCancellation(error),
                rollbackState: .notAttempted
            )
            throw RemoteOperationInterruptedError(
                reason: isCancellation(error) ? .cancelled : .unrecoverableFailure,
                partialResult: partial
            )
        }
    }

    private func performUpload(
        localURL: URL,
        sourcePath: String,
        to directoryPath: String,
        fileName: String,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> RemoteOperationResult {
        let destinationPath = try RemotePath.appending(
            name: fileName,
            to: directoryPath,
            within: connection.normalizedRootPath
        )
        try context.checkCancellation()
        await context.report(
            operation: operation,
            phase: .preparing,
            unit: .bytes,
            completedUnitCount: 0,
            totalUnitCount: nil,
            currentPath: destinationPath
        )

        do {
            try await authenticatedRequest { sid in
                var fields: [(name: String, value: String)] = [
                    ("api", "SYNO.FileStation.Upload"),
                    ("version", "2"),
                    ("method", "upload"),
                    ("_sid", sid),
                    ("path", directoryPath),
                    ("create_parents", "false")
                ]
                switch conflictPolicy {
                case .skip:
                    fields.append(("overwrite", "false"))
                case .replace:
                    fields.append(("overwrite", "true"))
                case .fail, .keepBoth:
                    break
                }

                let multipart = try await SynologyMultipartFormData.build(
                    fields: fields,
                    fileURL: localURL,
                    fileName: fileName,
                    context: context,
                    operation: operation
                )
                defer { multipart.removeTemporaryFile() }

                var request = try self.multipartRequest(
                    boundary: multipart.boundary,
                    contentLength: multipart.contentLength
                )
                request.timeoutInterval = 3_600
                await context.report(
                    operation: operation,
                    phase: .writing,
                    unit: .bytes,
                    completedUnitCount: 0,
                    totalUnitCount: try? self.localFileSize(at: localURL),
                    currentPath: destinationPath
                )
                let (data, response) = try await self.session.upload(
                    for: request,
                    fromFile: multipart.bodyURL
                )
                try self.validateHTTP(response)
                let envelope = try JSONDecoder().decode(
                    SynologyEnvelope<SynologyEmptyData>.self,
                    from: data
                )
                try self.validate(envelope)
            }

            let fileSize = try? localFileSize(at: localURL)
            let modifiedAt = try? localURL.resourceValues(
                forKeys: [.contentModificationDateKey]
            ).contentModificationDate
            let resultingItem = RemoteFileItem(
                connectionID: connection.id,
                path: destinationPath,
                name: fileName,
                kind: .file,
                size: fileSize,
                modifiedAt: modifiedAt,
                contentTypeIdentifier: nil
            )
            await context.report(
                operation: operation,
                phase: .completed,
                unit: .bytes,
                completedUnitCount: fileSize ?? 0,
                totalUnitCount: fileSize,
                currentPath: destinationPath
            )
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: operation,
                outcomes: [
                    .succeeded(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        resultingItem: resultingItem
                    )
                ]
            )
        } catch {
            if isCancellation(error) {
                throw interruptedError(
                    operation: operation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    reason: .cancelled
                )
            }
            if isConnectionFailure(error) {
                throw interruptedError(
                    operation: operation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    reason: .connectionLost
                )
            }
            throw translatedOperationError(
                error,
                sourcePath: sourcePath,
                destinationPath: destinationPath
            )
        }
    }

    private func performDelete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext,
        resultOperation: RemoteOperationKind
    ) async throws -> RemoteOperationResult {
        let sourcePath = try validatedItemPath(item, allowConnectionRoot: false)
        try context.checkCancellation()
        await context.report(
            operation: resultOperation,
            phase: .deleting,
            unit: .items,
            completedUnitCount: 0,
            totalUnitCount: 1,
            currentPath: sourcePath
        )

        var taskID: String?
        do {
            let start: SynologyTaskStartData? = try await apiRequest(
                api: "SYNO.FileStation.Delete",
                version: "2",
                method: "start",
                parameters: [
                    "path": try jsonArray([sourcePath]),
                    "accurate_progress": "true",
                    "recursive": recursive ? "true" : "false"
                ]
            )
            guard let startedTaskID = start?.taskid else {
                throw NasFinderError.invalidResponse
            }
            taskID = startedTaskID
            _ = try await pollDeleteTask(
                taskID: startedTaskID,
                context: context,
                operation: resultOperation
            )
            await context.report(
                operation: resultOperation,
                phase: .completed,
                unit: .items,
                completedUnitCount: 1,
                totalUnitCount: 1,
                currentPath: sourcePath
            )
            return RemoteOperationResult(
                operationID: context.operationID,
                operation: resultOperation,
                outcomes: [.succeeded(sourcePath: sourcePath)]
            )
        } catch {
            if let taskID {
                await stopBackgroundTaskIndependently(
                    api: "SYNO.FileStation.Delete",
                    version: "2",
                    taskID: taskID
                )
            }
            if isCancellation(error) {
                throw interruptedError(
                    operation: resultOperation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: nil,
                    reason: .cancelled
                )
            }
            if taskID != nil, isConnectionFailure(error) {
                throw interruptedError(
                    operation: resultOperation,
                    context: context,
                    sourcePath: sourcePath,
                    destinationPath: nil,
                    reason: .connectionLost
                )
            }
            let translated = translatedOperationError(
                error,
                sourcePath: sourcePath,
                destinationPath: nil
            )
            throw translated
        }
    }

    private func pollDeleteTask(
        taskID: String,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> SynologyDeleteStatusData {
        while true {
            try context.checkCancellation()
            let status: SynologyDeleteStatusData? = try await apiRequest(
                api: "SYNO.FileStation.Delete",
                version: "2",
                method: "status",
                parameters: ["taskid": try jsonString(taskID)]
            )
            guard let status else { throw NasFinderError.invalidResponse }
            await context.report(
                operation: operation,
                phase: .deleting,
                unit: .items,
                completedUnitCount: status.processedNumber,
                totalUnitCount: status.total >= 0 ? status.total : nil,
                currentPath: status.processingPath ?? status.path
            )
            if status.finished { return status }
            try await waitBeforePollingAgain()
        }
    }

    private func pollCopyMoveTask(
        taskID: String,
        context: RemoteOperationContext,
        operation: RemoteOperationKind
    ) async throws -> SynologyCopyMoveStatusData {
        while true {
            try context.checkCancellation()
            let status: SynologyCopyMoveStatusData? = try await apiRequest(
                api: "SYNO.FileStation.CopyMove",
                version: "3",
                method: "status",
                parameters: ["taskid": try jsonString(taskID)]
            )
            guard let status else { throw NasFinderError.invalidResponse }
            await context.report(
                operation: operation,
                phase: .writing,
                unit: .bytes,
                completedUnitCount: status.processedSize,
                totalUnitCount: status.total >= 0 ? status.total : nil,
                currentPath: status.path
            )
            if status.finished { return status }
            try await waitBeforePollingAgain()
        }
    }

    private func waitBeforePollingAgain() async throws {
        if pollInterval == .zero {
            await Task.yield()
        } else {
            try await Task.sleep(for: pollInterval)
        }
    }

    private func stopBackgroundTask(
        api: String,
        version: String,
        taskID: String
    ) async throws {
        let _: SynologyEmptyData? = try await apiRequest(
            api: api,
            version: version,
            method: "stop",
            parameters: ["taskid": try jsonString(taskID)]
        )
    }

    private func stopBackgroundTaskIndependently(
        api: String,
        version: String,
        taskID: String
    ) async {
        let service = self
        _ = await Task.detached(priority: .utility) {
            do {
                try await service.stopBackgroundTask(
                    api: api,
                    version: version,
                    taskID: taskID
                )
                return true
            } catch {
                return false
            }
        }.value
    }

    private func apiRequest<Payload: Decodable>(
        api: String,
        version: String,
        method: String,
        parameters: [String: String]
    ) async throws -> Payload? {
        try await authenticatedRequest { sid in
            let allParameters = self.commonParameters(
                api: api,
                version: version,
                method: method,
                sid: sid
            ).merging(parameters) { _, new in new }
            let request = try self.request(
                script: "entry.cgi",
                parameters: allParameters
            )
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTP(response)
            let envelope = try JSONDecoder().decode(
                SynologyEnvelope<Payload>.self,
                from: data
            )
            try self.validate(envelope)
            return envelope.data
        }
    }

    private func validatedDirectory(_ path: String) throws -> String {
        try RemotePath.normalize(path, within: connection.normalizedRootPath)
    }

    private func validatedItemPath(
        _ item: RemoteFileItem,
        allowConnectionRoot: Bool
    ) throws -> String {
        guard item.connectionID == connection.id else {
            throw RemoteFileOperationError.pathOutsideRoot(
                path: item.path,
                rootPath: connection.normalizedRootPath
            )
        }
        let path = try RemotePath.normalize(
            item.path,
            within: connection.normalizedRootPath
        )
        if !allowConnectionRoot, path == connection.normalizedRootPath {
            throw RemoteFileOperationError.permissionDenied(path: path)
        }
        return path
    }

    private func existingItem(
        named name: String,
        in directoryPath: String
    ) async throws -> RemoteFileItem? {
        try await list(directory: directoryPath).first { $0.name == name }
    }

    private func remoteItem(from node: SynologyNode) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connection.id,
            path: node.path,
            name: node.name,
            kind: node.isDirectory ? .folder : .file,
            size: node.additional?.size ?? node.size,
            modifiedAt: node.additional?.time?.modifiedDate,
            contentTypeIdentifier: nil
        )
    }

    private func parentPath(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    private func jsonArray(_ values: [String]) throws -> String {
        let data = try JSONEncoder().encode(values)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NasFinderError.invalidResponse
        }
        return value
    }

    private func jsonString(_ value: String) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let value = String(data: data, encoding: .utf8) else {
            throw NasFinderError.invalidResponse
        }
        return value
    }

    private func localFileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let size = values.fileSize else {
            throw NasFinderError.invalidConfiguration("파일 크기를 확인할 수 없습니다.")
        }
        return Int64(size)
    }

    private func skippedResult(
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        sourcePath: String,
        destinationPath: String
    ) -> RemoteOperationResult {
        RemoteOperationResult(
            operationID: context.operationID,
            operation: operation,
            outcomes: [
                .skipped(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    issue: RemoteOperationIssue(
                        code: .conflict,
                        message: "같은 이름의 항목이 있어 건너뛰었습니다."
                    )
                )
            ]
        )
    }

    private func interruptedError(
        operation: RemoteOperationKind,
        context: RemoteOperationContext,
        sourcePath: String,
        destinationPath: String?,
        reason: RemoteOperationInterruptionReason
    ) -> RemoteOperationInterruptedError {
        let issueCode: RemoteOperationIssueCode = reason == .connectionLost
            ? .network
            : .unknown
        let message = reason == .connectionLost
            ? "연결이 끊겨 서버 작업의 완료 여부를 확인할 수 없습니다."
            : "작업이 취소되었습니다."
        return RemoteOperationInterruptedError(
            reason: reason,
            partialResult: RemoteOperationResult(
                operationID: context.operationID,
                operation: operation,
                outcomes: [
                    .failed(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        issue: RemoteOperationIssue(
                            code: issueCode,
                            message: message
                        )
                    )
                ],
                wasCancelled: reason == .cancelled,
                rollbackState: .notAttempted
            )
        )
    }

    private func translatedOperationError(
        _ error: Error,
        sourcePath: String,
        destinationPath: String?
    ) -> Error {
        guard let synology = error as? SynologyAPIError else { return error }
        let allCodes = synology.details.map(\.code) + [synology.code]
        if allCodes.contains(where: { [403, 404, 405, 406, 407, 411].contains($0) }) {
            return RemoteFileOperationError.permissionDenied(path: sourcePath)
        }
        if allCodes.contains(408) {
            return RemoteFileOperationError.notFound(path: sourcePath)
        }
        if allCodes.contains(where: { [414, 1003, 1805].contains($0) }) {
            return RemoteFileOperationError.conflict(
                sourcePath: sourcePath,
                destinationPath: destinationPath ?? sourcePath
            )
        }
        if allCodes.contains(1004) {
            return RemoteFileOperationError.folderReplacementNotAllowed(
                path: destinationPath ?? sourcePath
            )
        }
        return synology
    }

    private func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return Task.isCancelled
            || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            || (error as? SynologyAPIError)?.code == 1803
    }

    private func isConnectionFailure(_ error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return [
            NSURLErrorTimedOut,
            NSURLErrorCannotFindHost,
            NSURLErrorCannotConnectToHost,
            NSURLErrorNetworkConnectionLost,
            NSURLErrorNotConnectedToInternet
        ].contains(nsError.code)
    }

    private func authenticatedRequest<T>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        do {
            let sid = try await validSessionID()
            return try await operation(sid)
        } catch let error as SynologyAPIError where error.isAuthenticationError {
            sessionID = nil
            do {
                return try await operation(validSessionID())
            } catch {
                throw RemoteRequestCancellation.normalized(error)
            }
        } catch {
            throw RemoteRequestCancellation.normalized(error)
        }
    }

    private func validSessionID() async throws -> String {
        if let sessionID { return sessionID }

        let parameters = [
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "account": connection.username,
            "passwd": credential.password,
            "session": "FileStation",
            "format": "sid"
        ]
        let request = try request(script: "auth.cgi", parameters: parameters)
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let envelope = try JSONDecoder().decode(SynologyEnvelope<SynologyAuthData>.self, from: data)
        guard envelope.success else {
            if let code = envelope.error?.code {
                throw SynologyAuthenticationError(code: code)
            }
            throw NasFinderError.authenticationFailed
        }
        guard let sid = envelope.data?.sid else { throw NasFinderError.authenticationFailed }
        sessionID = sid
        return sid
    }

    private func probeWebAPI() async throws {
        var request = try request(
            script: "query.cgi",
            parameters: [
                "api": "SYNO.API.Info",
                "version": "1",
                "method": "query",
                "query": "SYNO.API.Auth,SYNO.FileStation.List"
            ]
        )
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SynologyConnectionProbeError.invalidWebAPIResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SynologyConnectionProbeError.httpStatus(http.statusCode)
        }

        let envelope: SynologyEnvelope<[String: SynologyAPIInfo]>
        do {
            envelope = try JSONDecoder().decode(
                SynologyEnvelope<[String: SynologyAPIInfo]>.self,
                from: data
            )
        } catch {
            throw SynologyConnectionProbeError.invalidWebAPIResponse
        }
        guard envelope.success, let APIs = envelope.data else {
            throw SynologyConnectionProbeError.invalidWebAPIResponse
        }
        guard APIs["SYNO.API.Auth"] != nil else {
            throw SynologyConnectionProbeError.authenticationAPIUnavailable
        }
        guard APIs["SYNO.FileStation.List"] != nil else {
            throw SynologyConnectionProbeError.fileStationAPIUnavailable
        }
    }

    private func connectionTestStage<T>(
        _ stage: SynologyDiagnosticStage,
        operation: () async throws -> T
    ) async throws -> T {
        do {
            return try await operation()
        } catch let failure as SynologyConnectionTestFailure {
            throw failure
        } catch {
            throw SynologyConnectionTestFailure(stage: stage, underlying: error)
        }
    }

    private func request(script: String, parameters: [String: String]) throws -> URLRequest {
        let url = try endpointURL(script: script)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(parameters)
        request.timeoutInterval = 30
        return request
    }

    private func multipartRequest(
        boundary: String,
        contentLength: Int64
    ) throws -> URLRequest {
        var request = URLRequest(url: try endpointURL(script: "entry.cgi"))
        request.httpMethod = "POST"
        request.setValue(
            "multipart/form-data; boundary=\(boundary)",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            String(contentLength),
            forHTTPHeaderField: "Content-Length"
        )
        return request
    }

    private func endpointURL(script: String) throws -> URL {
        var components = URLComponents()
        components.scheme = connection.usesTLS ? "https" : "http"
        components.host = connection.host
        components.port = connection.port
        components.path = "/webapi/\(script)"

        guard !connection.host.isEmpty, let url = components.url else {
            throw NasFinderError.invalidConfiguration("NAS 주소를 확인해 주세요.")
        }
        return url
    }

    private func commonParameters(api: String, version: String, method: String, sid: String) -> [String: String] {
        [
            "api": api,
            "version": version,
            "method": method,
            "_sid": sid
        ]
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw NasFinderError.server("NAS에 연결할 수 없습니다.")
        }
    }

    private func validateDownload(at url: URL, response: URLResponse) throws {
        guard let contentType = response.mimeType?.lowercased(),
              contentType == "application/json" || contentType.hasSuffix("+json") else {
            return
        }

        let data = try Data(contentsOf: url)
        let envelope = try JSONDecoder().decode(SynologyEnvelope<SynologyEmptyData>.self, from: data)
        try validate(envelope)
        throw NasFinderError.invalidResponse
    }

    private func validate<T>(_ envelope: SynologyEnvelope<T>) throws {
        guard envelope.success else {
            if let code = envelope.error?.code {
                throw SynologyAPIError(
                    code: code,
                    details: envelope.error?.errors ?? []
                )
            }
            throw NasFinderError.invalidResponse
        }
    }
}

private struct SynologyEnvelope<Payload: Decodable>: Decodable {
    let success: Bool
    let data: Payload?
    let error: SynologyErrorPayload?
}

private struct SynologyErrorPayload: Decodable {
    let code: Int
    let errors: [SynologyErrorDetail]?
}

private struct SynologyErrorDetail: Decodable, Sendable {
    let code: Int
    let path: String?
    let name: String?
}

private struct SynologyAuthData: Decodable {
    let sid: String
}

private struct SynologyAPIInfo: Decodable {
    let path: String?
    let minVersion: Int?
    let maxVersion: Int?

    private enum CodingKeys: String, CodingKey {
        case path
        case minVersion
        case maxVersion
    }
}

private struct SynologyEmptyData: Decodable {}

private struct SynologyCreateFolderData: Decodable {
    let folders: [SynologyNode]
}

private struct SynologyRenameData: Decodable {
    let files: [SynologyNode]
}

private struct SynologyTaskStartData: Decodable {
    let taskid: String
}

private struct SynologyDeleteStatusData: Decodable {
    let processedNumber: Int64
    let total: Int64
    let path: String?
    let processingPath: String?
    let finished: Bool

    enum CodingKeys: String, CodingKey {
        case processedNumber = "processed_num"
        case total
        case path
        case processingPath = "processing_path"
        case finished
    }
}

private struct SynologyCopyMoveStatusData: Decodable {
    let processedSize: Int64
    let total: Int64
    let path: String?
    let finished: Bool

    enum CodingKeys: String, CodingKey {
        case processedSize = "processed_size"
        case total
        case path
        case finished
    }
}

private struct SynologyListData: Decodable {
    let files: [SynologyNode]?
    let shares: [SynologyNode]?
}

private struct SynologyNode: Decodable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let additional: SynologyAdditional?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "isdir"
        case size
        case additional
    }
}

private struct SynologyAdditional: Decodable {
    let size: Int64?
    let time: SynologyTime?
}

private struct SynologyTime: Decodable {
    let mtime: TimeInterval?
    var modifiedDate: Date? { mtime.map(Date.init(timeIntervalSince1970:)) }
}

private struct SynologyAPIError: LocalizedError, Sendable {
    let code: Int
    let details: [SynologyErrorDetail]

    init(code: Int, details: [SynologyErrorDetail] = []) {
        self.code = code
        self.details = details
    }

    var isAuthenticationError: Bool { [106, 107, 119].contains(code) }

    var errorDescription: String? {
        switch code {
        case 100: "Synology에서 알 수 없는 오류가 발생했습니다."
        case 101: "API·메서드 또는 버전 매개변수가 누락됐습니다."
        case 102: "NAS가 요청한 File Station API를 지원하지 않습니다."
        case 103: "NAS가 요청한 File Station 작업을 지원하지 않습니다."
        case 104: "NAS가 이 API 버전의 기능을 지원하지 않습니다."
        case 105: "이 계정에는 File Station을 사용할 권한이 없습니다."
        case 106, 107, 119: "DSM 로그인이 만료되었습니다."
        case 400: "파일 요청 형식이 올바르지 않습니다."
        case 401: "File Station이 파일 작업을 완료하지 못했습니다."
        case 402: "NAS가 사용 중입니다. 잠시 후 다시 시도해 주세요."
        case 403...407, 411: "파일 작업을 실행할 권한이 없습니다."
        case 408: "원격 파일 또는 폴더가 없습니다."
        case 409: "NAS 파일 시스템이 이 작업을 지원하지 않습니다."
        case 410: "NAS의 원격 파일 시스템에 연결할 수 없습니다."
        case 412, 413: "파일 이름이 너무 깁니다."
        case 414: "같은 이름의 항목이 이미 있습니다."
        case 415: "NAS 사용량 할당량을 초과했습니다."
        case 416: "NAS에 여유 공간이 없습니다."
        case 417: "NAS 입출력 오류로 작업을 완료하지 못했습니다."
        case 418...420: "NAS에서 사용할 수 없는 이름 또는 경로입니다."
        case 421: "NAS 파일 또는 장치가 사용 중입니다."
        case 599: "NAS에서 해당 백그라운드 작업을 찾지 못했습니다."
        case 900: "파일 또는 폴더를 삭제하지 못했습니다."
        case 1000: "파일 또는 폴더를 복사하지 못했습니다."
        case 1001: "파일 또는 폴더를 이동하지 못했습니다."
        case 1002: "대상 폴더에서 파일 작업을 완료하지 못했습니다."
        case 1003, 1805: "같은 이름의 항목이 있습니다. 충돌 처리 방법을 선택해 주세요."
        case 1004: "파일과 폴더는 서로 덮어쓸 수 없습니다."
        case 1006: "FAT32에서 지원하지 않는 특수 문자가 있습니다."
        case 1007: "FAT32에는 4GB보다 큰 파일을 저장할 수 없습니다."
        case 1100: "폴더를 만들지 못했습니다."
        case 1101: "한 폴더에 만들 수 있는 하위 폴더 수를 초과했습니다."
        case 1200: "이름을 변경하지 못했습니다."
        case 1800: "업로드 크기 정보가 실제 파일과 다릅니다."
        case 1801: "업로드 데이터 수신 시간을 초과했습니다."
        case 1802: "업로드 파일 이름이 누락됐습니다."
        case 1803: "업로드가 취소되었습니다."
        case 1804: "FAT 파일 시스템에 저장하기에 파일이 너무 큽니다."
        default: "Synology 오류가 발생했습니다. (코드 \(code))"
        }
    }
}

struct SynologyAuthenticationError: LocalizedError, Sendable {
    let code: Int

    var errorDescription: String? {
        switch code {
        case 400:
            "DSM 사용자 이름 또는 비밀번호가 올바르지 않습니다."
        case 401:
            "DSM 계정이 비활성화되었습니다."
        case 402:
            "이 DSM 계정에는 로그인 권한이 없습니다."
        case 403, 404, 405, 406:
            "이 계정은 2단계 인증이 필요합니다. 현재 버전에서는 OTP 로그인을 지원하지 않습니다."
        case 407:
            "로그인 시도가 차단되었습니다. DSM의 자동 차단 설정을 확인해 주세요."
        default:
            "DSM 인증에 실패했습니다. (코드 \(code))"
        }
    }
}
