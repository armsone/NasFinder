import Foundation
import Network
import PhotosUI
import SwiftUI

private final class PhotoTransferAsyncGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var pendingResult: Result<Value, Error>?
    private var isCompleted = false
    private var timeoutTask: Task<Void, Never>?

    func install(_ continuation: CheckedContinuation<Value, Error>) {
        lock.lock()
        if let pendingResult {
            lock.unlock()
            continuation.resume(with: pendingResult)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installTimeoutTask(_ task: Task<Void, Never>) {
        lock.lock()
        if isCompleted {
            lock.unlock()
            task.cancel()
        } else {
            timeoutTask = task
            lock.unlock()
        }
    }

    func finish(with result: Result<Value, Error>) {
        lock.lock()
        guard !isCompleted else {
            lock.unlock()
            return
        }
        isCompleted = true
        let continuation = self.continuation
        self.continuation = nil
        if continuation == nil { pendingResult = result }
        let timeoutTask = self.timeoutTask
        self.timeoutTask = nil
        lock.unlock()

        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

/// 보내기(발신) 역할: 스캔한 페이로드의 host/port로 접속해 한 줄 핸드셰이크를 수행한다.
@MainActor
final class PhotoTransferSenderSession: ObservableObject {
    enum ConnectionTimeoutStage: Equatable {
        case tcpConnection
        case handshakeResponse
    }

    enum OperationTimeoutError: LocalizedError {
        case frameSend
        case resultAcknowledgement

        var errorDescription: String? {
            switch self {
            case .frameSend: "파일 데이터 전송 시간이 초과되었습니다."
            case .resultAcknowledgement: "받는 기기의 저장 확인 응답 시간이 초과되었습니다."
            }
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting(PhotoTransferPairingPayload)
        case connected(PhotoTransferPairingPayload, PhotoTransferPeerPlatform)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var sentItemCount = 0
    @Published private(set) var totalItemCount = 0
    @Published private(set) var transferProgress: Double?
    @Published private(set) var isSending = false
    @Published private(set) var transferFinished = false

    private var connection: NWConnection?
    private var responseBuffer = Data()
    private var timeoutTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var supportsGroupedTransfer = false
    private var connectionStage: ConnectionTimeoutStage?
    private var lastConnectionErrorDescription: String?
    private var sessionGeneration: UInt64 = 0
    private let queue = DispatchQueue(label: "com.armsone.nasfinder.photo-transfer.sender")

    nonisolated static var operationTimeoutDuration: Duration { .seconds(120) }

    func connect(using payload: PhotoTransferPairingPayload) {
        cancel()
        phase = .connecting(payload)
        connectionStage = .tcpConnection
        let generation = sessionGeneration

        guard let port = NWEndpoint.Port(rawValue: payload.port) else {
            phase = .failed("포트 번호가 올바르지 않습니다.")
            return
        }

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let connection = NWConnection(host: NWEndpoint.Host(payload.host), port: port, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(
                    state,
                    for: connection,
                    payload: payload,
                    generation: generation
                )
            }
        }
        connection.start(queue: queue)
        startTimeout(
            .tcpConnection,
            duration: Self.timeoutDuration(for: .tcpConnection),
            connection: connection,
            generation: generation
        )
    }

    func cancel() {
        sessionGeneration &+= 1
        sendTask?.cancel()
        sendTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        responseBuffer.removeAll()
        sentItemCount = 0
        totalItemCount = 0
        transferProgress = nil
        isSending = false
        transferFinished = false
        supportsGroupedTransfer = false
        connectionStage = nil
        lastConnectionErrorDescription = nil
        phase = .idle
    }

    func send(items: [PhotosPickerItem], kinds: [PhotoTransferMediaKind]) {
        guard case .connected = phase,
              connection != nil,
              !items.isEmpty,
              !isSending,
              !transferFinished
        else { return }
        if kinds.contains(.livePhoto), !supportsGroupedTransfer {
            fail("상대 기기 버전이 Live Photo 원본 전송을 지원하지 않습니다.")
            return
        }
        isSending = true
        sentItemCount = 0
        totalItemCount = items.count
        transferProgress = 0
        let generation = sessionGeneration

        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                for (offset, item) in items.enumerated() {
                    try Task.checkCancellation()
                    let kind = kinds.indices.contains(offset) ? kinds[offset] : .unknown
                    let prepared = try await PhotoTransferSelectionLoader.load(
                        item: item,
                        index: offset + 1,
                        kind: kind
                    )
                    defer { prepared.removeTemporaryFiles() }
                    guard self.sessionGeneration == generation else { throw CancellationError() }
                    try await self.sendPreparedItem(prepared)
                    self.sentItemCount = offset + 1
                    self.transferProgress = Double(offset + 1) / Double(items.count)
                }
                guard self.sessionGeneration == generation else { throw CancellationError() }
                try await self.sendData(PhotoTransferWireCodec.completionFrame())
                guard self.sessionGeneration == generation else { throw CancellationError() }
                if self.supportsGroupedTransfer {
                    let savedCount = try await self.receiveTransferResult()
                    guard self.sessionGeneration == generation else { throw CancellationError() }
                    guard savedCount == items.count else {
                        throw URLError(.cannotParseResponse)
                    }
                }
                guard self.sessionGeneration == generation else { throw CancellationError() }
                self.isSending = false
                self.transferFinished = true
                self.sendTask = nil
            } catch is CancellationError {
                // cancel() 이후 도착한 작업 종료는 상태를 다시 바꾸지 않는다.
            } catch {
                guard self.sessionGeneration == generation else { return }
                self.fail("파일을 보내지 못했습니다: \(error.localizedDescription)")
            }
        }
    }

    private func handleConnectionState(
        _ state: NWConnection.State,
        for connection: NWConnection,
        payload: PhotoTransferPairingPayload,
        generation: UInt64
    ) {
        guard Self.isCurrentAttempt(
            callbackGeneration: generation,
            currentGeneration: sessionGeneration,
            connectionMatches: self.connection === connection
        ) else { return }
        switch state {
        case .ready:
            guard connectionStage == .tcpConnection else { return }
            connectionStage = .handshakeResponse
            startTimeout(
                .handshakeResponse,
                duration: Self.timeoutDuration(for: .handshakeResponse),
                connection: connection,
                generation: generation
            )
            sendHandshake(on: connection, payload: payload, generation: generation)
        case .waiting(let error):
            lastConnectionErrorDescription = error.localizedDescription
        case .failed(let error):
            if transferFinished {
                self.connection = nil
            } else if case .connected = phase {
                fail("받는 기기와의 연결이 끊어졌습니다: \(error.localizedDescription)")
            } else {
                fail("연결하지 못했습니다: \(error.localizedDescription)")
            }
        case .cancelled:
            if transferFinished {
                self.connection = nil
            } else if case .connected = phase, connection === self.connection {
                fail("받는 기기와의 연결이 끊어졌습니다.")
            }
        default:
            break
        }
    }

    private func sendHandshake(
        on connection: NWConnection,
        payload: PhotoTransferPairingPayload,
        generation: UInt64
    ) {
        let line = PhotoTransferHandshake.clientLine(token: payload.token, sourcePlatform: .ios)
        connection.send(
            content: Data(line.utf8),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self,
                          Self.isCurrentAttempt(
                              callbackGeneration: generation,
                              currentGeneration: self.sessionGeneration,
                              connectionMatches: self.connection === connection
                          )
                    else { return }
                    if let error {
                        self.fail("연결 요청을 보내지 못했습니다: \(error.localizedDescription)")
                    } else {
                        self.receiveResponseChunk(on: connection, payload: payload)
                    }
                }
            }
        )
    }

    private func receiveResponseChunk(on connection: NWConnection, payload: PhotoTransferPairingPayload) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleResponseChunk(data, isComplete: isComplete, error: error, on: connection, payload: payload)
            }
        }
    }

    private func handleResponseChunk(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection,
        payload: PhotoTransferPairingPayload
    ) {
        guard self.connection === connection, case .connecting = phase else { return }

        if let data, !data.isEmpty {
            responseBuffer.append(data)
        }
        if let error {
            fail("응답을 받지 못했습니다: \(error.localizedDescription)")
            return
        }

        if responseBuffer.contains(UInt8(ascii: "\n")) {
            let response = String(decoding: responseBuffer, as: UTF8.self)
            responseBuffer.removeAll()
            if let peer = PhotoTransferHandshake.acceptedPeer(fromResponse: response) {
                timeoutTask?.cancel()
                timeoutTask = nil
                supportsGroupedTransfer = peer.supportsGroupedTransfer
                connectionStage = nil
                phase = .connected(payload, peer.platform)
            } else {
                fail("받는 기기가 연결 요청을 거절했습니다. QR 코드를 다시 스캔해 주세요.")
            }
        } else if isComplete || responseBuffer.count >= 64 {
            fail("받는 기기의 응답 형식이 올바르지 않습니다.")
        } else {
            receiveResponseChunk(on: connection, payload: payload)
        }
    }

    private func fail(_ message: String) {
        cancel()
        phase = .failed(message)
    }

    private func sendPreparedItem(_ item: PhotoTransferPreparedItem) async throws {
        for component in item.components {
            let header: PhotoTransferWireHeader
            if supportsGroupedTransfer {
                header = component.header
            } else if let legacy = component.header.legacyFlatCopy {
                header = legacy
            } else {
                throw PhotoTransferWireCodec.CodecError.invalidHeader
            }
            try await sendData(PhotoTransferWireCodec.headerFrame(header))
            try await sendFile(at: component.fileURL)
        }
    }

    /// FileRepresentation으로 받은 원본을 작은 청크로 보내 대용량 영상을 한 Data로 적재하지 않는다.
    private func sendFile(at url: URL) async throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            try await sendData(chunk)
        }
    }

    private func sendData(_ data: Data) async throws {
        guard let connection else {
            throw URLError(.networkConnectionLost)
        }
        let generation = sessionGeneration
        let _: Void = try await performBoundedOperation(timeoutError: .frameSend) { finish in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    finish(.failure(error))
                } else {
                    finish(.success(()))
                }
            })
        }
        guard Self.isCurrentAttempt(
            callbackGeneration: generation,
            currentGeneration: sessionGeneration,
            connectionMatches: self.connection === connection
        ) else { throw CancellationError() }
    }

    /// v3는 수신 기기가 실제 사진 보관함 저장을 끝낸 뒤에만 완료로 인정한다.
    private func receiveTransferResult() async throws -> Int {
        guard let connection else { throw URLError(.networkConnectionLost) }
        let generation = sessionGeneration
        let result: Int = try await performBoundedOperation(
            timeoutError: .resultAcknowledgement
        ) { finish in
            receiveTransferResultChunk(
                on: connection,
                buffer: Data(),
                generation: generation,
                finish: finish
            )
        }
        guard Self.isCurrentAttempt(
            callbackGeneration: generation,
            currentGeneration: sessionGeneration,
            connectionMatches: self.connection === connection
        ) else { throw CancellationError() }
        return result
    }

    private func receiveTransferResultChunk(
        on connection: NWConnection,
        buffer: Data,
        generation: UInt64,
        finish: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard Self.isCurrentAttempt(
            callbackGeneration: generation,
            currentGeneration: sessionGeneration,
            connectionMatches: self.connection === connection
        ) else {
            finish(.failure(CancellationError()))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 128) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self,
                      Self.isCurrentAttempt(
                          callbackGeneration: generation,
                          currentGeneration: self.sessionGeneration,
                          connectionMatches: self.connection === connection
                      )
                else {
                    finish(.failure(CancellationError()))
                    return
                }
                if let error {
                    finish(.failure(error))
                    return
                }
                var nextBuffer = buffer
                nextBuffer.append(data ?? Data())
                if let newline = nextBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = String(decoding: nextBuffer[nextBuffer.startIndex..<newline], as: UTF8.self)
                    let values = line.split(separator: " ", omittingEmptySubsequences: false)
                    guard values.count == 3,
                          values[0] == "RESULT",
                          values[1] == "OK",
                          let count = Int(values[2]), count >= 0
                    else {
                        finish(.failure(URLError(.cannotParseResponse)))
                        return
                    }
                    finish(.success(count))
                } else if isComplete {
                    finish(.failure(URLError(.networkConnectionLost)))
                } else if nextBuffer.count >= 128 {
                    finish(.failure(URLError(.cannotParseResponse)))
                } else {
                    self.receiveTransferResultChunk(
                        on: connection,
                        buffer: nextBuffer,
                        generation: generation,
                        finish: finish
                    )
                }
            }
        }
    }

    private func performBoundedOperation<Value: Sendable>(
        timeoutError: OperationTimeoutError,
        start: (@escaping @Sendable (Result<Value, Error>) -> Void) -> Void
    ) async throws -> Value {
        let gate = PhotoTransferAsyncGate<Value>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                gate.install(continuation)
                guard !Task.isCancelled else {
                    gate.finish(with: .failure(CancellationError()))
                    return
                }
                let timeoutTask = Task {
                    try? await Task.sleep(for: Self.operationTimeoutDuration)
                    guard !Task.isCancelled else { return }
                    gate.finish(with: .failure(timeoutError))
                }
                gate.installTimeoutTask(timeoutTask)
                start { result in gate.finish(with: result) }
            }
        } onCancel: {
            gate.finish(with: .failure(CancellationError()))
        }
    }

    nonisolated static func isCurrentAttempt(
        callbackGeneration: UInt64,
        currentGeneration: UInt64,
        connectionMatches: Bool
    ) -> Bool {
        callbackGeneration == currentGeneration && connectionMatches
    }

    nonisolated static func timeoutMessage(
        for stage: ConnectionTimeoutStage,
        lastErrorDescription: String?
    ) -> String {
        let baseMessage = switch stage {
        case .tcpConnection: "받는 기기에 연결하는 시간이 초과되었습니다."
        case .handshakeResponse: "받는 기기의 연결 응답 시간이 초과되었습니다."
        }
        guard let lastErrorDescription, !lastErrorDescription.isEmpty else {
            return baseMessage
        }
        return "\(baseMessage) 마지막 네트워크 오류: \(lastErrorDescription)"
    }

    nonisolated static func timeoutDuration(for stage: ConnectionTimeoutStage) -> Duration {
        switch stage {
        case .tcpConnection, .handshakeResponse:
            return .seconds(10)
        }
    }

    private func startTimeout(
        _ stage: ConnectionTimeoutStage,
        duration: Duration,
        connection: NWConnection,
        generation: UInt64
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled, let self else { return }
            guard Self.isCurrentAttempt(
                callbackGeneration: generation,
                currentGeneration: self.sessionGeneration,
                connectionMatches: self.connection === connection
            ), self.connectionStage == stage,
               case .connecting = self.phase
            else { return }
            self.fail(
                Self.timeoutMessage(
                    for: stage,
                    lastErrorDescription: self.lastConnectionErrorDescription
                )
            )
        }
    }
}
