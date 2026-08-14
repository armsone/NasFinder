import Darwin
import Foundation
import Network
import UniformTypeIdentifiers

struct WebHardNetworkAddress: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case wifi
        case cellular
        case ethernet
        case other

        var title: String {
            switch self {
            case .wifi: "Wi-Fi"
            case .cellular: "셀룰러"
            case .ethernet: "이더넷"
            case .other: "네트워크"
            }
        }

        var systemImage: String {
            switch self {
            case .wifi: "wifi"
            case .cellular: "antenna.radiowaves.left.and.right"
            case .ethernet: "cable.connector"
            case .other: "network"
            }
        }
    }

    let interfaceName: String
    let address: String
    let kind: Kind

    var id: String { "\(interfaceName)|\(address)" }

    var urlHost: String {
        address.contains(":") ? "[\(address)]" : address
    }
}

struct WebHardUploadProgress: Identifiable, Equatable, Sendable {
    let id: String
    let filename: String
    let receivedBytes: Int64
    let totalBytes: Int64

    var fractionCompleted: Double {
        guard totalBytes > 0 else { return 0 }
        return min(max(Double(receivedBytes) / Double(totalBytes), 0), 1)
    }
}

enum WebHardServerEvent: Sendable {
    case uploadChanged(WebHardUploadProgress)
    case uploadEnded(id: String)
    case contentsChanged
}

enum WebHardNetworkAddressDiscovery {
    static func availableAddresses() -> [WebHardNetworkAddress] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var results: [WebHardNetworkAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = firstAddress
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }
            guard let addressPointer = interface.ifa_addr else { continue }
            let family = Int32(addressPointer.pointee.sa_family)
            guard family == AF_INET else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  flags & IFF_LOOPBACK == 0 else { continue }

            let name = String(cString: interface.ifa_name)
            let kind = kind(for: name)
            guard kind == .wifi || kind == .ethernet else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(
                addressPointer,
                length,
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0 else { continue }
            let terminator = host.firstIndex(of: 0) ?? host.endIndex
            let address = String(
                decoding: host[..<terminator].map { UInt8(bitPattern: $0) },
                as: UTF8.self
            )
            guard isUsableIPv4Address(address) else {
                continue
            }
            results.append(
                WebHardNetworkAddress(
                    interfaceName: name,
                    address: address,
                    kind: kind
                )
            )
        }

        let sorted = Array(Set(results)).sorted {
            if $0.kind != $1.kind { return $0.kind == .wifi }
            if $0.interfaceName != $1.interfaceName {
                return $0.interfaceName.localizedStandardCompare($1.interfaceName) == .orderedAscending
            }
            return $0.address.localizedStandardCompare($1.address) == .orderedAscending
        }
        var includedKinds = Set<WebHardNetworkAddress.Kind>()
        return sorted.filter { includedKinds.insert($0.kind).inserted }
    }

    private static func kind(for interfaceName: String) -> WebHardNetworkAddress.Kind {
        if interfaceName.hasPrefix("pdp_ip") { return .cellular }
        if interfaceName == "en0" { return .wifi }
        if interfaceName.hasPrefix("en") { return .ethernet }
        return .other
    }

    private static func isUsableIPv4Address(_ address: String) -> Bool {
        let octets = address.split(separator: ".").compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        return octets[0] != 0
            && octets[0] != 127
            && octets[0] < 224
            && !(octets[0] == 169 && octets[1] == 254)
    }
}

enum WebHardServerState: Equatable, Sendable {
    case stopped
    case starting
    case ready(port: UInt16)
    case failed(String)
}

final class WebHardHTTPServer: @unchecked Sendable {
    typealias StateHandler = @Sendable (WebHardServerState) -> Void

    private let queue = DispatchQueue(label: "com.armsone.nasfinder.webhard.server")
    private let store: WebHardFileStore
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: WebHardHTTPConnection] = [:]
    private var eventHandler: (@Sendable (WebHardServerEvent) -> Void)?

    init(store: WebHardFileStore) {
        self.store = store
    }

    func start(
        address: WebHardNetworkAddress,
        password: String,
        eventHandler: (@Sendable (WebHardServerEvent) -> Void)? = nil,
        stateHandler: @escaping StateHandler
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopLocked()
            self.eventHandler = eventHandler
            stateHandler(.starting)
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                parameters.requiredLocalEndpoint = .hostPort(
                    host: NWEndpoint.Host(address.address),
                    port: .any
                )
                let listener = try NWListener(using: parameters, on: .any)
                self.listener = listener
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self, let listener else { return }
                    self.queue.async {
                        guard self.listener === listener else { return }
                        switch state {
                        case .ready:
                            stateHandler(.ready(port: listener.port?.rawValue ?? 0))
                        case let .waiting(error):
                            stateHandler(.failed(self.message(for: error)))
                        case let .failed(error):
                            stateHandler(.failed(self.message(for: error)))
                            self.stopLocked()
                        case .cancelled:
                            stateHandler(.stopped)
                        case .setup:
                            break
                        @unknown default:
                            stateHandler(.failed("알 수 없는 네트워크 상태입니다."))
                        }
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection, password: password)
                }
                listener.start(queue: queue)
            } catch {
                stateHandler(.failed(error.localizedDescription))
                stopLocked()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    private func accept(_ connection: NWConnection, password: String) {
        let client = WebHardHTTPConnection(
            connection: connection,
            store: store,
            password: password,
            queue: queue,
            eventHandler: { [weak self] event in
                self?.eventHandler?(event)
            },
            completion: { [weak self] identifier in
                self?.clients.removeValue(forKey: identifier)
            }
        )
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    private func stopLocked() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in clients.values { client.cancel() }
        clients.removeAll()
        eventHandler = nil
    }

    private func message(for error: NWError) -> String {
        if case let .posix(code) = error, code == .EACCES {
            return "로컬 네트워크 접근이 허용되지 않았습니다. iPhone 설정에서 NasFinder의 로컬 네트워크 접근을 켜 주세요."
        }
        return "파일 서버를 시작하지 못했습니다: \(error.localizedDescription)"
    }
}

private struct WebHardHTTPRequestHead {
    let method: String
    let target: String
    let headers: [String: String]

    var contentLength: Int64? {
        headers["content-length"].flatMap(Int64.init)
    }
}

private final class WebHardHTTPConnection: @unchecked Sendable {
    private enum ReceiveState {
        case header(Data)
        case upload(
            request: WebHardHTTPRequestHead,
            prepared: WebHardPreparedUpload,
            handle: FileHandle,
            remaining: Int64
        )
        case responding
    }

    private let connection: NWConnection
    private let store: WebHardFileStore
    private let password: String
    private let queue: DispatchQueue
    private let eventHandler: @Sendable (WebHardServerEvent) -> Void
    private let completion: @Sendable (ObjectIdentifier) -> Void
    private var state: ReceiveState = .header(Data())
    private var completed = false

    init(
        connection: NWConnection,
        store: WebHardFileStore,
        password: String,
        queue: DispatchQueue,
        eventHandler: @escaping @Sendable (WebHardServerEvent) -> Void,
        completion: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.store = store
        self.password = password
        self.queue = queue
        self.eventHandler = eventHandler
        self.completion = completion
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receive()
            case .failed, .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        if case let .upload(_, prepared, handle, _) = state {
            try? handle.close()
            store.discardUpload(prepared)
            eventHandler(.uploadEnded(id: prepared.temporaryURL.lastPathComponent))
        }
        state = .responding
        connection.cancel()
        finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            do {
                if let data, !data.isEmpty { try self.consume(data) }
                if isComplete || error != nil {
                    if case let .upload(_, prepared, handle, _) = self.state {
                        try? handle.close()
                        self.store.discardUpload(prepared)
                        self.eventHandler(.uploadEnded(id: prepared.temporaryURL.lastPathComponent))
                    }
                    self.finish()
                    return
                }
                if case .responding = self.state { return }
                self.receive()
            } catch {
                self.sendError(error)
            }
        }
    }

    private func consume(_ data: Data) throws {
        switch state {
        case let .header(existing):
            var buffer = existing
            buffer.append(data)
            guard buffer.count <= 32 * 1_024 else {
                throw WebHardHTTPError.badRequest("요청 헤더가 너무 큽니다.")
            }
            guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                state = .header(buffer)
                return
            }
            let headData = buffer[..<range.lowerBound]
            let bodyData = buffer[range.upperBound...]
            let request = try parseHead(Data(headData))
            try route(request, initialBody: Data(bodyData))
        case let .upload(request, prepared, handle, remaining):
            try consumeUpload(
                request: request,
                prepared: prepared,
                handle: handle,
                remaining: remaining,
                data: data
            )
        case .responding:
            break
        }
    }

    private func parseHead(_ data: Data) throws -> WebHardHTTPRequestHead {
        guard let string = String(data: data, encoding: .isoLatin1) else {
            throw WebHardHTTPError.badRequest("요청을 읽을 수 없습니다.")
        }
        let lines = string.components(separatedBy: "\r\n")
        let requestParts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard requestParts.count == 3, requestParts[2].hasPrefix("HTTP/1.") else {
            throw WebHardHTTPError.badRequest("올바른 HTTP 요청이 아닙니다.")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else {
                throw WebHardHTTPError.badRequest("올바른 HTTP 헤더가 아닙니다.")
            }
            let name = line[..<separator].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        return WebHardHTTPRequestHead(
            method: String(requestParts[0]).uppercased(),
            target: String(requestParts[1]),
            headers: headers
        )
    }

    private func route(_ request: WebHardHTTPRequestHead, initialBody: Data) throws {
        guard let components = URLComponents(string: "http://localhost\(request.target)") else {
            throw WebHardHTTPError.badRequest("올바른 주소가 아닙니다.")
        }
        let path = components.path
        if request.method == "GET", path == "/" {
            send(status: 200, contentType: "text/html; charset=utf-8", body: Data(Self.page.utf8))
            return
        }
        guard isAuthorized(request, components: components) else {
            throw WebHardHTTPError.unauthorized
        }
        let requestedPath = queryValue("path", in: components) ?? "/"

        switch (request.method, path) {
        case ("GET", "/api/list"):
            let items = try store.list(path: requestedPath)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            send(status: 200, contentType: "application/json", body: try encoder.encode(items))
        case ("GET", "/api/file"):
            try sendFile(store.fileURL(path: requestedPath), deleteAfterSending: false)
        case ("GET", "/api/preview"):
            try sendFile(
                store.fileURL(path: requestedPath),
                deleteAfterSending: false,
                asAttachment: false
            )
        case ("POST", "/api/folder"):
            try store.createDirectory(path: requestedPath)
            eventHandler(.contentsChanged)
            sendJSONMessage(status: 201, message: "폴더를 만들었습니다.")
        case ("DELETE", "/api/item"):
            try store.delete(path: requestedPath)
            eventHandler(.contentsChanged)
            sendJSONMessage(status: 200, message: "삭제했습니다.")
        case ("PUT", "/api/file"):
            try beginUpload(request, path: requestedPath, initialBody: initialBody)
        default:
            throw WebHardHTTPError.notFound
        }
    }

    private func beginUpload(
        _ request: WebHardHTTPRequestHead,
        path: String,
        initialBody: Data
    ) throws {
        guard let contentLength = request.contentLength, contentLength >= 0 else {
            throw WebHardHTTPError.lengthRequired
        }
        guard Int64(initialBody.count) <= contentLength else {
            throw WebHardHTTPError.badRequest("업로드 크기가 요청과 다릅니다.")
        }
        if let available = try store.rootURL.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage,
           contentLength > max(0, available - 50 * 1_024 * 1_024) {
            throw WebHardHTTPError.insufficientStorage
        }
        let prepared = try store.prepareUpload(path: path)
        do {
            let handle = try FileHandle(forWritingTo: prepared.temporaryURL)
            try consumeUpload(
                request: request,
                prepared: prepared,
                handle: handle,
                remaining: contentLength,
                data: initialBody
            )
        } catch {
            store.discardUpload(prepared)
            throw error
        }
    }

    private func consumeUpload(
        request: WebHardHTTPRequestHead,
        prepared: WebHardPreparedUpload,
        handle: FileHandle,
        remaining: Int64,
        data: Data
    ) throws {
        guard Int64(data.count) <= remaining else {
            try? handle.close()
            store.discardUpload(prepared)
            throw WebHardHTTPError.badRequest("업로드 크기가 요청과 다릅니다.")
        }
        if !data.isEmpty { try handle.write(contentsOf: data) }
        let newRemaining = remaining - Int64(data.count)
        let totalBytes = request.contentLength ?? 0
        let progressID = prepared.temporaryURL.lastPathComponent
        eventHandler(.uploadChanged(WebHardUploadProgress(
            id: progressID,
            filename: prepared.destinationURL.lastPathComponent,
            receivedBytes: max(totalBytes - newRemaining, 0),
            totalBytes: totalBytes
        )))
        guard newRemaining == 0 else {
            state = .upload(
                request: request,
                prepared: prepared,
                handle: handle,
                remaining: newRemaining
            )
            return
        }
        try handle.synchronize()
        try handle.close()
        do {
            try store.commitUpload(prepared)
            eventHandler(.uploadEnded(id: progressID))
            eventHandler(.contentsChanged)
            sendJSONMessage(status: 201, message: prepared.destinationURL.lastPathComponent)
        } catch {
            store.discardUpload(prepared)
            throw error
        }
    }

    private func isAuthorized(
        _ request: WebHardHTTPRequestHead,
        components: URLComponents
    ) -> Bool {
        guard !password.isEmpty else { return true }
        let headerPassword = request.headers["x-webhard-password"]
        let queryPassword = queryValue("password", in: components)
        return headerPassword == password || queryPassword == password
    }

    private func queryValue(_ name: String, in components: URLComponents) -> String? {
        components.queryItems?.first(where: { $0.name == name })?.value
    }

    private func sendJSONMessage(status: Int, message: String) {
        let body = (try? JSONSerialization.data(withJSONObject: ["message": message])) ?? Data()
        send(status: status, contentType: "application/json", body: body)
    }

    private func sendError(_ error: Error) {
        let response: (Int, String)
        switch error {
        case let error as WebHardHTTPError:
            response = (error.status, error.localizedDescription)
        case let error as WebHardFileStoreError:
            response = (error == .itemNotFound ? 404 : 400, error.localizedDescription)
        default:
            response = (500, error.localizedDescription)
        }
        sendJSONMessage(status: response.0, message: response.1)
    }

    private func send(status: Int, contentType: String, body: Data) {
        state = .responding
        var response = Data(Self.responseHead(
            status: status,
            contentType: contentType,
            contentLength: Int64(body.count)
        ).utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.finish()
        })
    }

    private func sendFile(
        _ url: URL,
        downloadName: String? = nil,
        deleteAfterSending: Bool,
        asAttachment: Bool = true
    ) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        let size = Int64(values.fileSize ?? 0)
        let filename = downloadName ?? url.lastPathComponent
        let contentType = values.contentType?.preferredMIMEType ?? "application/octet-stream"
        let encodedName = filename.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? "download"
        let extraHeaders = asAttachment
            ? ["Content-Disposition: attachment; filename*=UTF-8''\(encodedName)"]
            : []
        let header = Self.responseHead(
            status: 200,
            contentType: contentType,
            contentLength: size,
            extraHeaders: extraHeaders
        )
        let handle = try FileHandle(forReadingFrom: url)
        state = .responding
        connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                try? handle.close()
                if deleteAfterSending { try? FileManager.default.removeItem(at: url) }
                self.finish()
            } else {
                self.sendFileChunk(
                    handle: handle,
                    sourceURL: url,
                    deleteAfterSending: deleteAfterSending
                )
            }
        })
    }

    private func sendFileChunk(
        handle: FileHandle,
        sourceURL: URL,
        deleteAfterSending: Bool
    ) {
        do {
            let data = try handle.read(upToCount: 256 * 1_024) ?? Data()
            guard !data.isEmpty else {
                try? handle.close()
                if deleteAfterSending { try? FileManager.default.removeItem(at: sourceURL) }
                finish()
                return
            }
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    try? handle.close()
                    if deleteAfterSending { try? FileManager.default.removeItem(at: sourceURL) }
                    self.finish()
                } else {
                    self.sendFileChunk(
                        handle: handle,
                        sourceURL: sourceURL,
                        deleteAfterSending: deleteAfterSending
                    )
                }
            })
        } catch {
            try? handle.close()
            if deleteAfterSending { try? FileManager.default.removeItem(at: sourceURL) }
            finish()
        }
    }

    private func finish() {
        guard !completed else { return }
        completed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        completion(ObjectIdentifier(self))
    }

    private static func responseHead(
        status: Int,
        contentType: String,
        contentLength: Int64,
        extraHeaders: [String] = []
    ) -> String {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 201: reason = "Created"
        case 400: reason = "Bad Request"
        case 401: reason = "Unauthorized"
        case 404: reason = "Not Found"
        case 411: reason = "Length Required"
        case 507: reason = "Insufficient Storage"
        default: reason = "Internal Server Error"
        }
        return ([
            "HTTP/1.1 \(status) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(contentLength)",
            "Cache-Control: no-store",
            "X-Content-Type-Options: nosniff",
            "Connection: close",
        ] + extraHeaders + ["", ""]).joined(separator: "\r\n")
    }

    private static let page = #"""
    <!doctype html><html lang="ko"><head><meta charset="utf-8">
    <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
    <title>NasFinder PhoneHard</title><style>
    :root{color-scheme:light dark;font-family:-apple-system,BlinkMacSystemFont,sans-serif}
    body{max-width:980px;margin:auto;padding:22px 16px;background:#f4f5f9;color:#17171c}
    header{display:flex;align-items:center;gap:12px;margin-bottom:14px}h1{font-size:22px;margin:0}
    .badge{display:grid;place-items:center;width:42px;height:42px;border-radius:13px;background:#5856d6;color:white;font-weight:750}
    .bar{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:12px 0}.bar .spacer{flex:1}
    button,.button{border:0;border-radius:10px;padding:10px 13px;background:#5856d6;color:white;font:inherit;text-decoration:none;cursor:pointer}
    button.secondary,.button.secondary{background:#e4e4ed;color:#282832}button.selected{outline:2px solid #5856d6}button:disabled{opacity:.45;cursor:default}input[type=file]{display:none}
    #path{font-size:13px;color:#666;overflow-wrap:anywhere}#status{min-height:20px;font-size:13px;color:#555}#uploadHint{margin:-5px 0 10px;font-size:11px;color:#777}.danger{color:#c62828}
    #transfers{display:grid;gap:8px;margin:8px 0}.transfer{padding:10px 12px;background:white;border-radius:12px}.transfer-head{display:flex;gap:8px}.transfer-head span:first-child{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}.transfer progress{width:100%;height:5px}
    #dropHint{display:none;position:fixed;inset:14px;z-index:10;place-items:center;border:2px dashed #5856d6;border-radius:18px;background:#5856d622;color:#5856d6;font-size:18px;font-weight:700;pointer-events:none}body.dragging #dropHint{display:grid}
    .files{background:white;border-radius:16px;overflow:hidden}.row{position:relative;display:flex;align-items:center;gap:10px;padding:12px 14px;border-bottom:1px solid #ededf2;cursor:pointer}.row:last-child{border-bottom:0}.select{flex:0 0 auto;width:19px;height:19px;cursor:pointer}
    .preview{flex:0 0 48px;width:48px;height:48px;border-radius:10px;overflow:hidden;background:#e8e9ef;display:grid;place-items:center;font-size:24px}.preview img,.preview video{width:100%;height:100%;object-fit:cover}
    .name{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;background:transparent!important;color:inherit!important;text-align:left;padding:4px}.meta{font-size:12px;color:#777}.empty{padding:34px;text-align:center;color:#777}
    .files.small,.files.poster{display:grid;background:transparent;overflow:visible;gap:12px}.files.small{grid-template-columns:repeat(auto-fill,minmax(116px,1fr))}.files.poster{grid-template-columns:repeat(auto-fill,minmax(190px,1fr))}
    .files.small .row,.files.poster .row{display:block;padding:0;border:0;background:white;border-radius:14px;overflow:hidden}.files.small .select,.files.poster .select{position:absolute;z-index:2;top:8px;left:8px}.files.small .preview,.files.poster .preview{width:100%;height:auto;aspect-ratio:1;border-radius:0}.files.small .name,.files.poster .name{display:block;width:100%;padding:9px 10px 2px}.files.small .meta,.files.poster .meta{display:block;padding:0 10px 10px}
    @media(prefers-color-scheme:dark){body{background:#111115;color:#f5f5f7}.files,.row,.transfer,.files.small .row,.files.poster .row{background:#1c1c20}.row{border-color:#303036}.button.secondary,button.secondary{background:#303038;color:#eee}.meta,#path,#status,#uploadHint{color:#aaa}.preview{background:#29292f}}
    </style></head><body><header><div class="badge">H</div><div><h1>NasFinder PhoneHard</h1><div id="path">/</div></div></header>
    <div class="bar"><button id="up" class="secondary">위로</button><label class="button" title="파일을 선택하거나 파일과 폴더를 함께 끌어놓으세요">올리기<input id="files" type="file" multiple></label><button id="receive" disabled>받기</button><button id="mkdir" class="secondary">새 폴더</button><span class="spacer"></span><button data-view="list" class="secondary">자세히</button><button data-view="small" class="secondary">썸네일</button><button data-view="poster" class="secondary">포스터</button></div>
    <div id="status"></div><div id="uploadHint">파일과 폴더를 함께 끌어놓으면 한 번에 올립니다.</div><div id="transfers"></div><main id="list" class="files small"></main><div id="dropHint">파일과 폴더를 함께 놓아 올리기</div>
    <script>
    let password=sessionStorage.getItem('webHardPassword')||'',current='/',view=localStorage.getItem('phoneHardView')||'small';
    const list=document.querySelector('#list'),status=document.querySelector('#status'),pathLabel=document.querySelector('#path'),transfers=document.querySelector('#transfers'),receive=document.querySelector('#receive'),selected=new Map();
    const api=(route,path)=>`${route}?path=${encodeURIComponent(path)}${password?'&password='+encodeURIComponent(password):''}`;
    const join=(base,name)=>(base==='/'?'':base)+'/'+name,fmt=n=>n==null?'':new Intl.NumberFormat('ko',{notation:'compact',style:'unit',unit:'byte',unitDisplay:'narrow'}).format(n);
    const ext=n=>(n.split('.').pop()||'').toLowerCase(),images=new Set(['jpg','jpeg','png','gif','webp','heic','heif','bmp']),videos=new Set(['mp4','mov','m4v','webm']);
    function setView(next){view=next;localStorage.setItem('phoneHardView',view);list.className='files '+view;document.querySelectorAll('[data-view]').forEach(b=>b.classList.toggle('selected',b.dataset.view===view))}
    function updateSelection(){receive.disabled=selected.size===0;receive.textContent=selected.size?`받기 (${selected.size})`:'받기'}
    async function json(url,options,retry=true){const r=await fetch(url,options);const value=await r.json().catch(()=>({message:r.statusText}));if(r.status===401&&retry){const entered=prompt('폰하드 비밀번호');if(entered!==null){password=entered;sessionStorage.setItem('webHardPassword',password);return json(url.replace(/([?&])password=[^&]*/,'$1').replace(/[?&]$/,'')+(url.includes('?')?'&':'?')+'password='+encodeURIComponent(password),options,false)}}if(!r.ok)throw Error(value.message||r.statusText);return value}
    function preview(item){const box=document.createElement('div');box.className='preview';if(item.isDirectory){box.textContent='📁';return box}const kind=ext(item.name),src=api('/api/preview',item.path);if(images.has(kind)){const media=document.createElement('img');media.src=src;media.loading='lazy';box.append(media)}else if(videos.has(kind)){const media=document.createElement('video');media.src=src;media.preload='metadata';media.muted=true;media.playsInline=true;box.append(media)}else box.textContent='📄';return box}
    async function remove(item){if(!confirm(`${item.name}을(를) 삭제할까요?`))return;await json(api('/api/item',item.path),{method:'DELETE'});await load(current)}
    async function downloadFolder(path){const items=await json(api('/api/list',path));for(const item of items){if(item.isDirectory)await downloadFolder(item.path);else{const a=document.createElement('a');a.href=api('/api/file',item.path);a.download=item.name;document.body.append(a);a.click();a.remove();await new Promise(r=>setTimeout(r,180))}}}
    async function download(item){if(item.isDirectory)await downloadFolder(item.path);else{const a=document.createElement('a');a.href=api('/api/file',item.path);a.download=item.name;document.body.append(a);a.click();a.remove();await new Promise(r=>setTimeout(r,180))}}
    function actions(item,row){let timer;const choose=()=>{const receive=confirm(`${item.name}\n확인: 받기  ·  취소: 삭제`);if(receive){if(item.isDirectory)downloadFolder(item.path);else location.href=api('/api/file',item.path)}else remove(item)};row.oncontextmenu=e=>{e.preventDefault();choose()};row.ontouchstart=()=>timer=setTimeout(choose,650);row.ontouchend=row.ontouchmove=()=>clearTimeout(timer)}
    async function load(path){status.className='';status.textContent='불러오는 중…';try{const items=await json(api('/api/list',path));current=path;pathLabel.textContent=path;selected.clear();updateSelection();list.replaceChildren();if(!items.length){const e=document.createElement('div');e.className='empty';e.textContent='파일이 없습니다.';list.append(e)}for(const item of items){const row=document.createElement('div');row.className='row';const checkbox=document.createElement('input');checkbox.type='checkbox';checkbox.className='select';checkbox.setAttribute('aria-label',`${item.name} 선택`);checkbox.onclick=e=>e.stopPropagation();checkbox.onchange=()=>{if(checkbox.checked)selected.set(item.path,item);else selected.delete(item.path);updateSelection()};const name=document.createElement('button');name.className='name secondary';name.textContent=item.name;const open=()=>item.isDirectory?load(item.path):location.href=api('/api/file',item.path);name.onclick=e=>{e.stopPropagation();open()};row.onclick=open;const meta=document.createElement('span');meta.className='meta';meta.textContent=fmt(item.size);row.append(checkbox,preview(item),name,meta);actions(item,row);list.append(row)}status.textContent=''}catch(e){status.className='danger';status.textContent=e.message}}
    function sendFile(file,path){return new Promise((resolve,reject)=>{const row=document.createElement('div');row.className='transfer';row.innerHTML=`<div class="transfer-head"><span></span><span>0%</span></div><progress max="1" value="0"></progress>`;row.querySelector('span').textContent=file.webkitRelativePath||file.name;transfers.append(row);const xhr=new XMLHttpRequest();xhr.open('PUT',api('/api/file',path));xhr.setRequestHeader('Content-Type','application/octet-stream');if(password)xhr.setRequestHeader('X-WebHard-Password',password);xhr.upload.onprogress=e=>{if(!e.lengthComputable)return;const f=e.loaded/e.total;row.querySelector('progress').value=f;row.querySelectorAll('span')[1].textContent=Math.round(f*100)+'%'};xhr.onload=()=>{if(xhr.status>=200&&xhr.status<300){row.remove();resolve()}else reject(Error(xhr.statusText||'업로드 실패'))};xhr.onerror=()=>reject(Error('네트워크 오류'));xhr.send(file)})}
    const entryFile=entry=>new Promise((resolve,reject)=>entry.file(resolve,reject)),entryChildren=entry=>new Promise((resolve,reject)=>{const reader=entry.createReader(),all=[];const next=()=>reader.readEntries(values=>values.length?(all.push(...values),next()):resolve(all),reject);next()});
    async function collectEntry(entry,prefix=''){const path=prefix+entry.name;if(entry.isFile)return[{file:await entryFile(entry),path}];if(!entry.isDirectory)return[];const children=await entryChildren(entry),files=[];for(const child of children)files.push(...await collectEntry(child,path+'/'));return files}
    async function droppedFiles(dataTransfer){const files=[];for(const item of [...dataTransfer.items]){if(item.kind!=='file')continue;const entry=item.webkitGetAsEntry?.();if(entry)files.push(...await collectEntry(entry));else{const file=item.getAsFile();if(file)files.push({file,path:file.name})}}return files}
    async function upload(files,input){if(!files.length)return;status.className='';let done=0;for(const value of files){try{await sendFile(value.file,join(current,value.path));done++}catch(e){status.className='danger';status.textContent=`${value.path}: ${e.message}`;if(input)input.value='';return}}if(input)input.value='';await load(current);status.textContent=`${done}개 올림`}
    document.querySelectorAll('[data-view]').forEach(b=>b.onclick=()=>setView(b.dataset.view));setView(view);document.querySelector('#files').onchange=e=>upload([...e.target.files].map(file=>({file,path:file.webkitRelativePath||file.name})),e.target);let dragDepth=0;document.body.ondragenter=e=>{e.preventDefault();dragDepth++;document.body.classList.add('dragging')};document.body.ondragover=e=>{e.preventDefault();if(e.dataTransfer)e.dataTransfer.dropEffect='copy'};document.body.ondragleave=e=>{e.preventDefault();if(--dragDepth<=0){dragDepth=0;document.body.classList.remove('dragging')}};document.body.ondrop=async e=>{e.preventDefault();dragDepth=0;document.body.classList.remove('dragging');try{await upload(await droppedFiles(e.dataTransfer))}catch(error){status.className='danger';status.textContent=error.message}};receive.onclick=async()=>{const items=[...selected.values()];receive.disabled=true;status.className='';status.textContent=`${items.length}개 받는 중…`;try{for(const item of items)await download(item);status.textContent=`${items.length}개 받기 시작함`}catch(e){status.className='danger';status.textContent=e.message}finally{updateSelection()}};document.querySelector('#up').onclick=()=>{if(current==='/')return;load(current.split('/').slice(0,-1).join('/')||'/')};document.querySelector('#mkdir').onclick=async()=>{const name=prompt('새 폴더 이름');if(!name||name.includes('/'))return;try{await json(api('/api/folder',join(current,name)),{method:'POST'});await load(current)}catch(e){status.className='danger';status.textContent=e.message}};load('/');
    </script></body></html>
    """#
}

private enum WebHardHTTPError: LocalizedError {
    case badRequest(String)
    case unauthorized
    case notFound
    case lengthRequired
    case insufficientStorage

    var status: Int {
        switch self {
        case .badRequest: 400
        case .unauthorized: 401
        case .notFound: 404
        case .lengthRequired: 411
        case .insufficientStorage: 507
        }
    }

    var errorDescription: String? {
        switch self {
        case let .badRequest(message): message
        case .unauthorized: "비밀번호가 올바르지 않습니다."
        case .notFound: "요청한 기능을 찾을 수 없습니다."
        case .lengthRequired: "업로드 크기 정보가 필요합니다."
        case .insufficientStorage: "iPhone 저장공간이 부족합니다."
        }
    }
}
