import Foundation

enum WebDAVServiceError: LocalizedError, Sendable {
    case invalidAddress
    case unexpectedResponse
    case httpStatus(Int)
    case invalidDirectoryResponse

    var errorDescription: String? {
        switch self {
        case .invalidAddress: "WebDAV 서버 주소를 만들 수 없습니다."
        case .unexpectedResponse: "WebDAV 서버가 올바른 응답을 보내지 않았습니다."
        case .httpStatus(let code): "WebDAV 서버가 요청을 거부했습니다. (HTTP \(code))"
        case .invalidDirectoryResponse: "WebDAV 폴더 목록을 해석하지 못했습니다."
        }
    }
}

struct WebDAVFileService: RemoteFileService, @unchecked Sendable {
    let connection: RemoteConnection
    private let credential: RemoteCredential
    private let sessionDelegate: WebDAVSessionDelegate
    private let session: URLSession

    var capabilities: RemoteFileServiceCapabilities {
        [.createFolder, .rename, .delete, .recursiveDelete, .upload, .replaceFile, .serverSideMove]
    }
    var supportsRangeStreaming: Bool { true }
    var permitsFullDownloadForVideoThumbnail: Bool { false }

    init(connection: RemoteConnection, credential: RemoteCredential) {
        self.connection = connection
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 120
        let sessionDelegate = WebDAVSessionDelegate(
            username: connection.username,
            password: credential.password
        )
        self.sessionDelegate = sessionDelegate
        session = URLSession(
            configuration: configuration,
            delegate: sessionDelegate,
            delegateQueue: nil
        )
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        let requestedPath = normalized(path ?? connection.normalizedRootPath)
        var request = try authorizedRequest(path: requestedPath, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(
            """
            <?xml version="1.0" encoding="utf-8"?>
            <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/><d:getlastmodified/></d:prop></d:propfind>
            """.utf8
        )
        let (data, response) = try await session.data(for: request)
        try validate(response, allowing: [207])
        let entries = try WebDAVMultistatusParser.parse(data)
        let requestedURL = try url(for: requestedPath)
        return entries.compactMap { entry in
            guard let entryURL = URL(string: entry.href, relativeTo: requestedURL)?.absoluteURL else {
                return nil
            }
            let decodedPath = entryURL.path.removingPercentEncoding ?? entryURL.path
            let basePath = requestedURL.path.removingPercentEncoding ?? requestedURL.path
            guard normalized(decodedPath) != normalized(basePath) else { return nil }
            let name = decodedPath.split(separator: "/").last.map(String.init) ?? ""
            guard !name.isEmpty else { return nil }
            return RemoteFileItem(
                connectionID: connection.id,
                path: normalized(decodedPath),
                name: name,
                kind: entry.isDirectory ? .folder : .file,
                size: entry.isDirectory ? nil : entry.size,
                modifiedAt: entry.modifiedAt,
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
        let downloader = URLSessionProgressDownloader(
            configuration: session.configuration,
            authenticationCredential: URLCredential(
                user: connection.username,
                password: credential.password,
                persistence: .forSession
            ),
            progressHandler: progress
        )
        let result = try await downloader.download(
            try authorizedRequest(path: item.path, method: "GET")
        )
        try validate(result.response, allowing: [200])
        return result.temporaryURL
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        guard offset >= 0, length > 0 else { return Data() }
        let requestedEnd = offset.addingReportingOverflow(Int64(length - 1))
        guard !requestedEnd.overflow else { throw WebDAVServiceError.unexpectedResponse }
        var request = try authorizedRequest(path: item.path, method: "GET")
        request.setValue(
            "bytes=\(offset)-\(requestedEnd.partialValue)",
            forHTTPHeaderField: "Range"
        )
        // The bounded reader rejects a server that ignores Range (200) and stops
        // buffering at `length`, so a range read never pulls the whole body.
        let reader = URLSessionBoundedRangeReader(
            configuration: session.configuration,
            expectedOffset: offset,
            maximumByteCount: length,
            authenticationCredential: URLCredential(
                user: connection.username,
                password: credential.password,
                persistence: .forSession
            )
        )
        let result = try await reader.read(request)
        try validate(result.response, allowing: [206])
        return result.data
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let destination = appending(name, to: directoryPath)
        let (_, response) = try await session.data(
            for: authorizedRequest(path: destination, method: "MKCOL")
        )
        try validate(response, allowing: [201])
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
        try await moveRequest(from: item.path, to: destination)
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
        let (_, response) = try await session.data(
            for: authorizedRequest(path: item.path, method: "DELETE")
        )
        try validate(response, allowing: [200, 204])
        return .init(
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
        // PUT은 같은 이름의 파일을 대체하므로 충돌 정책을 대상 폴더의 현재 목록으로 먼저 적용한다(FTP와 같은 방식).
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
        let replacesExisting: Bool
        switch decision {
        case .skip(let existingPath):
            return .init(
                operationID: context.operationID,
                operation: .upload,
                outcomes: [.skipped(
                    sourcePath: localURL.path,
                    destinationPath: existingPath,
                    issue: .init(code: .conflict, message: "같은 이름의 파일이 이미 있습니다.")
                )]
            )
        case .proceed(let resolvedName, let replaces):
            // 덮어쓰기(replace)를 고른 경우에만 기존 파일 이름 그대로 PUT한다.
            // 대소문자만 다른 파일은 서버마다 결과가 달라 덮어쓰지 않고 충돌로 알린다.
            guard !replaces || resolvedName == requestedName else {
                throw RemoteFileOperationError.conflict(
                    sourcePath: localURL.path,
                    destinationPath: appending(resolvedName, to: directoryPath)
                )
            }
            name = resolvedName
            replacesExisting = replaces
        }
        let destination = appending(name, to: directoryPath)
        var request = try authorizedRequest(path: destination, method: "PUT")
        if !replacesExisting {
            // 목록 확인 뒤 다른 곳에서 같은 이름이 생겼다면 이 조건을 지키는 서버는 412로 거절하고 기존 파일을 그대로 둔다(RFC 9110).
            request.setValue("*", forHTTPHeaderField: "If-None-Match")
        }
        request.httpBody = try Data(contentsOf: localURL, options: .mappedIfSafe)
        try context.checkCancellation()
        let (_, response) = try await session.data(for: request)
        if !replacesExisting, (response as? HTTPURLResponse)?.statusCode == 412 {
            throw RemoteFileOperationError.conflict(sourcePath: localURL.path, destinationPath: destination)
        }
        try validate(response, allowing: [200, 201, 204])
        return .init(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [.succeeded(sourcePath: localURL.path, destinationPath: destination)]
        )
    }

    private func moveRequest(from source: String, to destination: String, overwrite: Bool = false) async throws {
        var request = try authorizedRequest(path: source, method: "MOVE")
        request.setValue(try url(for: destination).absoluteString, forHTTPHeaderField: "Destination")
        request.setValue(overwrite ? "T" : "F", forHTTPHeaderField: "Overwrite")
        let (_, response) = try await session.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 412 {
            // Overwrite: F인데 대상이 이미 있다(RFC 4918). 기존 항목은 그대로다.
            throw RemoteFileOperationError.conflict(sourcePath: source, destinationPath: destination)
        }
        try validate(response, allowing: [201, 204])
    }

    /// 같은 서버 안에서 WebDAV MOVE로 옮긴다. 내용을 내려받아 다시 올리지 않는다.
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
            return .init(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.succeeded(sourcePath: item.path, destinationPath: item.path, resultingItem: item)]
            )
        }
        if item.isDirectory, RemotePath.isSameOrDescendant(targetDirectory, of: sourcePath) {
            return .init(
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
        switch decision {
        case .skip(let existingPath):
            return .init(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.skipped(
                    sourcePath: item.path,
                    destinationPath: existingPath,
                    issue: .init(code: .conflict, message: "같은 이름의 항목이 이미 있습니다.")
                )]
            )
        case .proceed(let name, let replacesExisting):
            let destination = appending(name, to: targetDirectory)
            // 대소문자만 다른 항목을 Overwrite: T로 대체하지 않는다. 기존 항목은 그대로 두고 충돌로 알린다.
            guard !replacesExisting || name == item.name else {
                throw RemoteFileOperationError.conflict(sourcePath: item.path, destinationPath: destination)
            }
            try context.checkCancellation()
            try await moveRequest(from: sourcePath, to: destination, overwrite: replacesExisting)
            let moved = RemoteFileItem(
                connectionID: item.connectionID,
                path: destination,
                name: name,
                kind: item.kind,
                size: item.size,
                modifiedAt: item.modifiedAt,
                contentTypeIdentifier: item.contentTypeIdentifier
            )
            return .init(
                operationID: context.operationID,
                operation: .move,
                outcomes: [.succeeded(sourcePath: item.path, destinationPath: destination, resultingItem: moved)]
            )
        }
    }

    /// Credential-free original address (no user info, no app headers); read-only, no download.
    func externalPlaybackTarget(for item: RemoteFileItem) -> RemoteExternalPlaybackTarget {
        guard item.connectionID == connection.id else {
            return .unavailable(reason: ExternalPlayerHandoff.unsafeAddressReason)
        }
        guard let address = try? url(for: item.path),
              let safe = ExternalPlayerHandoff.safeOriginalURL(address) else {
            return .unavailable(reason: ExternalPlayerHandoff.unsafeAddressReason)
        }
        // 로그인이 필요한 서버도 주소에는 계정·비밀번호를 넣지 않는다. 플레이어가 직접 로그인을 묻게 한다.
        let needsLogin = !(connection.username.isEmpty && credential.password.isEmpty)
        return needsLogin ? .remoteURLRequiresPlayerLogin(safe) : .remoteURL(safe)
    }

    private func authorizedRequest(path: String, method: String) throws -> URLRequest {
        var request = URLRequest(url: try url(for: path))
        request.httpMethod = method
        let token = Data("\(connection.username):\(credential.password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("NasFinder/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    private func url(for path: String) throws -> URL {
        var components = URLComponents()
        components.scheme = connection.usesTLS ? "https" : "http"
        components.host = connection.host
        components.port = connection.port
        components.percentEncodedPath = normalized(path)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        components.percentEncodedPath = "/" + components.percentEncodedPath
        guard let url = components.url else { throw WebDAVServiceError.invalidAddress }
        return url
    }

    private func validate(_ response: URLResponse, allowing statuses: Set<Int>) throws {
        guard let response = response as? HTTPURLResponse else {
            throw WebDAVServiceError.unexpectedResponse
        }
        guard statuses.contains(response.statusCode) else {
            throw WebDAVServiceError.httpStatus(response.statusCode)
        }
    }

    private func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func appending(_ name: String, to path: String) -> String {
        let base = normalized(path)
        return base == "/" ? "/\(name)" : "\(base)/\(name)"
    }
}

private final class WebDAVSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodHTTPBasic,
             NSURLAuthenticationMethodHTTPDigest,
             NSURLAuthenticationMethodDefault:
            completionHandler(
                .useCredential,
                URLCredential(
                    user: username,
                    password: password,
                    persistence: .forSession
                )
            )
        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private struct WebDAVEntry {
    let href: String
    let isDirectory: Bool
    let size: Int64?
    let modifiedAt: Date?
}

private final class WebDAVMultistatusParser: NSObject, XMLParserDelegate {
    private var entries: [WebDAVEntry] = []
    private var currentElement = ""
    private var text = ""
    private var href = ""
    private var isDirectory = false
    private var size: Int64?
    private var modifiedAt: Date?

    static func parse(_ data: Data) throws -> [WebDAVEntry] {
        let delegate = WebDAVMultistatusParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw WebDAVServiceError.invalidDirectoryResponse }
        return delegate.entries
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        text = ""
        if currentElement.hasSuffix("response") {
            href = ""
            isDirectory = false
            size = nil
            modifiedAt = nil
        } else if currentElement.hasSuffix("collection") {
            isDirectory = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let element = elementName.lowercased()
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if element.hasSuffix("href") {
            href = value
        } else if element.hasSuffix("getcontentlength") {
            size = Int64(value)
        } else if element.hasSuffix("getlastmodified") {
            modifiedAt = Self.httpDateFormatter.date(from: value)
        } else if element.hasSuffix("response"), !href.isEmpty {
            entries.append(.init(href: href, isDirectory: isDirectory, size: size, modifiedAt: modifiedAt))
        }
        text = ""
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}
