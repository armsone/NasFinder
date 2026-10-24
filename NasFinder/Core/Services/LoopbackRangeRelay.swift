import Foundation
import Network
import os
import UIKit

enum LoopbackRelayError: LocalizedError {
    case unsupportedPlatform
    case ineligible
    case tokenUnavailable
    case listenerFailed
    case relayLimitReached

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            "이 주소 중계는 Mac에서만 사용할 수 있습니다."
        case .ineligible:
            "이 파일은 전체를 내려받지 않고 외부 플레이어에 넘길 수 없습니다. (범위 읽기를 지원하지 않거나 파일 크기를 알 수 없습니다.) 앱 안의 플레이어로 재생해 주세요."
        case .tokenUnavailable, .listenerFailed:
            "이 Mac 안의 임시 재생 주소를 만들지 못했습니다."
        case .relayLimitReached:
            "동시에 열 수 있는 외부 재생 주소(최대 4개)가 모두 사용 중입니다. 기존 재생을 마치거나 플레이어를 닫은 뒤 다시 시도해 주세요."
        }
    }
}

/// One loopback-only HTTP Range endpoint for exactly one registered remote file. It binds
/// `127.0.0.1` with an OS-chosen port, serves `GET`/`HEAD /v/<token>` and reads the NAS only
/// through `service.readRange` in bounded chunks. It never sees a path or URL from a client, never
/// caches to disk, and forwards no upstream header or error text. All mutable state lives on `queue`.
final class LoopbackRangeRelay: @unchecked Sendable {
    static let maximumClients = 8
    /// Idle lease: with no connection open, the listener is closed this long after the last
    /// disconnect (or start). An open connection (even a paused player) keeps it alive.
    static let idleLease: TimeInterval = 15 * 60
    static let headerTimeout: TimeInterval = 10

    let itemID: String
    private let item: RemoteFileItem
    private let service: any RemoteFileService
    private let size: Int64
    private let contentType: String
    private let token: String
    private let queue = DispatchQueue(label: "com.nasfinder.loopback-relay")
    private var listener: NWListener?
    private var port: UInt16 = 0
    private var clients: [ObjectIdentifier: Client] = [:]
    private var idleTimer: DispatchWorkItem?
    private var isStopped = false
    private var onStop: (@Sendable (LoopbackRangeRelay) -> Void)?

    private final class Client: @unchecked Sendable {
        let connection: NWConnection
        var buffer = Data()
        var task: Task<Void, Never>?
        var headerTimer: DispatchWorkItem?
        var isClosed = false
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(
        item: RemoteFileItem,
        service: any RemoteFileService,
        size: Int64,
        token: String,
        onStop: @escaping @Sendable (LoopbackRangeRelay) -> Void
    ) {
        itemID = item.id
        self.item = item
        self.service = service
        self.size = size
        self.token = token
        contentType = LoopbackHTTP.contentType(forFileName: item.name)
        self.onStop = onStop
    }

    // MARK: Lifecycle

    /// Starts listening and returns `http://127.0.0.1:<port>/v/<token>`.
    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            queue.async {
                let parameters = NWParameters.tcp
                // Specific loopback IPv4 + system-assigned port; never 0.0.0.0, :: or a LAN address.
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
                guard let listener = try? NWListener(using: parameters) else {
                    continuation.resume(throwing: LoopbackRelayError.listenerFailed)
                    return
                }
                self.listener = listener
                let didReply = OSAllocatedUnfairLock(initialState: false)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self, weak listener] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard didReply.withLock({ replied in
                            guard !replied else { return false }
                            replied = true
                            return true
                        }) else { return }
                        guard let rawPort = listener?.port?.rawValue,
                              let url = URL(string: "http://127.0.0.1:\(rawPort)\(LoopbackHTTP.routePrefix)\(self.token)") else {
                            continuation.resume(throwing: LoopbackRelayError.listenerFailed)
                            self.stopOnQueue()
                            return
                        }
                        self.port = rawPort
                        self.armIdleTimer()
                        continuation.resume(returning: url)
                    case .failed, .cancelled:
                        if didReply.withLock({ replied in
                            guard !replied else { return false }
                            replied = true
                            return true
                        }) {
                            continuation.resume(throwing: LoopbackRelayError.listenerFailed)
                        }
                        self.stopOnQueue()
                    default:
                        break
                    }
                }
                listener.start(queue: self.queue)
            }
        }
    }

    func stop() {
        queue.async { self.stopOnQueue() }
    }

    private func stopOnQueue() {
        guard !isStopped else { return }
        isStopped = true
        idleTimer?.cancel()
        idleTimer = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        for client in Array(clients.values) { close(client) }
        let callback = onStop
        onStop = nil
        callback?(self)
    }

    private func armIdleTimer() {
        idleTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            if self.clients.isEmpty { self.stopOnQueue() } else { self.armIdleTimer() }
        }
        idleTimer = work
        queue.asyncAfter(deadline: .now() + Self.idleLease, execute: work)
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        guard !isStopped, clients.count < Self.maximumClients else {
            connection.cancel()
            return
        }
        let client = Client(connection)
        clients[ObjectIdentifier(client)] = client
        connection.stateUpdateHandler = { [weak self, weak client] state in
            guard let self, let client else { return }
            switch state {
            case .failed, .cancelled: self.close(client)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.close(client)
        }
        client.headerTimer = timeout
        queue.asyncAfter(deadline: .now() + Self.headerTimeout, execute: timeout)
        connection.start(queue: queue)
        receive(client)
    }

    private func close(_ client: Client) {
        guard !client.isClosed else { return }
        client.isClosed = true
        client.headerTimer?.cancel()
        client.task?.cancel()
        client.connection.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client))
        if clients.isEmpty, !isStopped { armIdleTimer() }
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) {
            [weak self, weak client] data, _, isComplete, error in
            guard let self, let client, !client.isClosed else { return }
            if let data { client.buffer.append(data) }
            if error != nil { self.close(client); return }
            switch LoopbackHTTP.parse(client.buffer) {
            case .incomplete:
                if isComplete { self.close(client) } else { self.receive(client) }
            case let .rejected(status):
                client.headerTimer?.cancel()
                self.sendFinal(client, LoopbackHTTP.errorHead(status: status))
            case let .request(request):
                client.headerTimer?.cancel()
                self.handle(request, from: client)
            }
        }
    }

    // MARK: Request handling

    private func handle(_ request: LoopbackHTTPRequest, from client: Client) {
        // Host, Origin, route and method are all decided before any backend read.
        if let status = LoopbackHTTP.rejection(for: request, token: token, boundPort: port) {
            sendFinal(client, LoopbackHTTP.errorHead(status: status))
            return
        }
        let resolution = LoopbackHTTP.resolveRange(request.headers["range"], size: size)
        guard let success = LoopbackHTTP.successHead(
            resolution: resolution,
            size: size,
            contentType: contentType
        ) else {
            sendFinal(client, LoopbackHTTP.errorHead(status: 416, size: size))
            return
        }
        if request.method == .head {
            sendFinal(client, success.head)
            return
        }

        let service = service
        let item = item
        client.task = Task { [weak self, weak client] in
            guard let self, let client else { return }
            var didSendHead = false
            do {
                try await LoopbackRangeStreamer.stream(
                    span: success.span,
                    read: { offset, length in
                        try await service.readRange(of: item, offset: offset, length: length)
                    },
                    send: { chunk in
                        if !didSendHead {
                            didSendHead = true
                            try await self.send(client, success.head)
                        }
                        try await self.send(client, chunk)
                    }
                )
                self.queue.async { self.sendFinal(client, nil) }
            } catch {
                // Upstream failure (remote changed, auth lapsed, short read): never forward details.
                self.queue.async {
                    if !didSendHead, !client.isClosed, !RemoteRequestCancellation.isCancellation(error) {
                        self.sendFinal(client, LoopbackHTTP.errorHead(status: 502))
                    } else {
                        self.close(client)
                    }
                }
            }
        }
    }

    /// Completes only after the connection reports the bytes processed (serial back-pressure).
    private func send(_ client: Client, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !client.isClosed else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                client.connection.send(
                    content: data,
                    contentContext: .defaultStream,
                    isComplete: false,
                    completion: .contentProcessed { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                )
            }
        }
    }

    /// Last write on a connection (`Connection: close`): write-close, then cancel once processed.
    private func sendFinal(_ client: Client, _ data: Data?) {
        guard !client.isClosed else { return }
        client.connection.send(
            content: data,
            contentContext: .finalMessage,
            isComplete: true,
            completion: .contentProcessed { [weak self, weak client] _ in
                guard let self, let client else { return }
                self.queue.async { self.close(client) }
            }
        )
    }
}

/// Owns the loopback relays independently of any preview view, because the external player keeps
/// reading after the preview closes. There is no completion callback from IINA, so the lifetime
/// is: idle lease (15 min with no open connection), explicit stop, or app termination.
@MainActor
final class LoopbackPlaybackRelayManager {
    static let shared = LoopbackPlaybackRelayManager()
    static let maximumRelays = 4

    private struct Entry {
        let relay: LoopbackRangeRelay
        let url: URL
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var pendingStarts: [String: Task<URL, Error>] = [:]
    private var terminationObserver: NSObjectProtocol?

    init(observeTermination: Bool = true) {
        if observeTermination {
            terminationObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.willTerminateNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.stopAll() }
            }
        }
    }

    nonisolated static var isSupportedPlatform: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// Known positive size + range-capable service for this exact connection; otherwise nil
    /// (the caller reports it honestly and never falls back to a full download).
    nonisolated static func eligibleSize(for item: RemoteFileItem, service: any RemoteFileService) -> Int64? {
        guard isSupportedPlatform,
              !item.isDirectory,
              item.isPlayerMedia,
              item.connectionID == service.connection.id,
              service.supportsRangeStreaming,
              let size = item.size, size > 0 else { return nil }
        return size
    }

    func hasCapacity(for id: String) -> Bool {
        if entries[id] != nil || pendingStarts[id] != nil {
            return true
        }
        let activeCount = Set(entries.keys).union(pendingStarts.keys).count
        return activeCount < Self.maximumRelays
    }

    func relayURL(for item: RemoteFileItem, service: any RemoteFileService) async throws -> URL {
        guard Self.isSupportedPlatform else { throw LoopbackRelayError.unsupportedPlatform }
        guard let size = Self.eligibleSize(for: item, service: service) else {
            throw LoopbackRelayError.ineligible
        }
        let id = item.id
        if let entry = entries[id] { return entry.url }
        if let pending = pendingStarts[id] { return try await pending.value }

        guard hasCapacity(for: id) else {
            throw LoopbackRelayError.relayLimitReached
        }

        guard let token = LoopbackHTTP.makeToken() else { throw LoopbackRelayError.tokenUnavailable }
        let relay = LoopbackRangeRelay(item: item, service: service, size: size, token: token) { [weak self] relay in
            Task { @MainActor in self?.relayStopped(relay) }
        }
        let start = Task { try await relay.start() }
        pendingStarts[id] = start
        defer { pendingStarts[id] = nil }
        let url: URL
        do {
            url = try await start.value
        } catch {
            relay.stop()
            throw error
        }
        pendingStarts[id] = nil
        entries[id] = Entry(relay: relay, url: url)
        order.removeAll { $0 == id }
        order.append(id)
        return url
    }

    #if DEBUG
    func registerPendingStartForTesting(id: String, task: Task<URL, Error>) {
        pendingStarts[id] = task
    }
    #endif

    func stop(itemID: String) {
        entries[itemID]?.relay.stop()
    }

    func stopAll() {
        for entry in entries.values { entry.relay.stop() }
    }

    private func relayStopped(_ relay: LoopbackRangeRelay) {
        guard entries[relay.itemID]?.relay === relay else { return }
        entries.removeValue(forKey: relay.itemID)
        order.removeAll { $0 == relay.itemID }
    }
}
