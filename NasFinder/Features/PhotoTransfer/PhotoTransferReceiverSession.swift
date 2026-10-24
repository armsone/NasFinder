@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Network
import Photos
import CryptoKit
import UIKit

/// 받기(수신) 역할: 임시 포트 TCP 리스너를 열고 일회용 토큰으로 핸드셰이크를 검증한다.
/// 토큰은 한 번 수락되면 즉시 무효화되며, stop() 시 리스너·연결·수신 버퍼를 모두 정리한다.
@MainActor
final class PhotoTransferReceiverSession: ObservableObject {
    enum ReceivedMediaKind: String, Sendable {
        case photo
        case video
        case livePhoto
        case motionPhoto

        var title: String {
            switch self {
            case .photo: "사진"
            case .video: "영상"
            case .livePhoto: "Live Photo"
            case .motionPhoto: "Motion Photo"
            }
        }

        var systemImage: String {
            switch self {
            case .photo: "photo"
            case .video: "video"
            case .livePhoto, .motionPhoto: "livephoto"
            }
        }
    }

    struct ReceivedMediaResult: Identifiable {
        let id: String
        let kind: ReceivedMediaKind
        let thumbnail: UIImage?
    }

    enum Phase: Equatable {
        case idle
        case starting
        case waitingForSender(PhotoTransferPairingPayload)
        case senderConnected(PhotoTransferPairingPayload, PhotoTransferPeerPlatform)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var receivedFileCount = 0
    /// 사진 보관함에는 저장됐지만 저장본을 읽어 확인하지 못했거나 입력과 달라 보내는 기기의 원본 삭제 자격이 없는 항목 수.
    /// 이 값은 `receivedFileCount`의 일부이며 저장 실패가 아니다(읽기 권한이 없어도 사진은 저장된다).
    @Published private(set) var unverifiedSavedCount = 0
    @Published private(set) var currentFileName: String?
    @Published private(set) var transferProgress: Double?
    @Published private(set) var transferFinished = false
    @Published private(set) var receivedResults: [ReceivedMediaResult] = []

    private var listener: NWListener?
    private var activeToken: String?
    /// 현재 QR의 비밀이 v3 평문 줄로 이미 들어왔다. 새 QR(새 비밀)을 시작하면 초기화된다.
    private var activeTokenExposedToLegacy = false
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var acceptedConnection: NWConnection?
    private var connectedPeerPlatform: PhotoTransferPeerPlatform = .unknown
    private var supportsGroupedTransfer = false
    /// v4(receipt-v1)가 협상된 연결인지. 아니면 기존 v3 동작과 `RESULT OK n` ACK를 그대로 쓴다.
    private var supportsReceipts = false
    /// 토큰 소유 증명을 마친 v4 세션에서만 있는 영수증 MAC 키(`Ks`).
    private var receiptSessionKey: SymmetricKey?
    private var pendingV4: [ObjectIdentifier: PendingV4Handshake] = [:]
    private var v4 = ReceiptTransferState()
    private var wireDecoder = PhotoTransferStreamingWireDecoder()
    private var stagedComponents: [StagedComponent] = []
    private var sessionGeneration: UInt64 = 0
    private let queue = DispatchQueue(label: "com.armsone.nasfinder.photo-transfer.receiver")

    func start() {
        start(excludingToken: nil)
    }

    var canRegeneratePairingQRCode: Bool {
        Self.canRegeneratePairingQRCode(in: phase)
    }

    nonisolated static func canRegeneratePairingQRCode(in phase: Phase) -> Bool {
        if case .waitingForSender = phase { return true }
        return false
    }

    func regeneratePairingQRCode() {
        guard canRegeneratePairingQRCode else { return }
        start(excludingToken: activeToken)
    }

    private func start(excludingToken invalidatedToken: String?) {
        stop()
        phase = .starting
        let generation = sessionGeneration

        guard let hostAddress = PhotoTransferLocalIPv4.preferredAddress() else {
            phase = .failed("이 기기의 로컬 IPv4 주소를 찾지 못했습니다. 같은 Wi-Fi에 연결되어 있는지 확인해 주세요.")
            return
        }

        let listener: NWListener
        do {
            // 포트를 지정하지 않아 시스템이 임시 포트를 배정한다.
            listener = try NWListener(using: .tcp)
        } catch {
            phase = .failed(UserErrorText.message("수신 대기를 시작하지 못했습니다", error, recovery: UserErrorText.networkRecovery))
            return
        }

        var generatedToken = PhotoTransferPairingPayload.makeToken()
        while generatedToken == invalidatedToken {
            generatedToken = PhotoTransferPairingPayload.makeToken()
        }
        let token = generatedToken
        activeToken = token
        activeTokenExposedToLegacy = false
        self.listener = listener

        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleListenerState(
                    state,
                    for: listener,
                    hostAddress: hostAddress,
                    token: token,
                    generation: generation
                )
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                self?.accept(connection, from: listener, generation: generation)
            }
        }
        listener.start(queue: queue)
    }

    func stop() {
        sessionGeneration &+= 1
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        activeToken = nil
        for connection in pendingConnections.values {
            connection.cancel()
        }
        pendingConnections.removeAll()
        receiveBuffers.removeAll()
        acceptedConnection?.cancel()
        acceptedConnection = nil
        connectedPeerPlatform = .unknown
        supportsGroupedTransfer = false
        supportsReceipts = false
        receiptSessionKey = nil
        for pending in pendingV4.values { pending.timeoutTask?.cancel() }
        pendingV4.removeAll()
        v4 = ReceiptTransferState()
        wireDecoder.reset()
        wireDecoder = PhotoTransferStreamingWireDecoder()
        removeStagedComponents()
        receivedFileCount = 0
        unverifiedSavedCount = 0
        currentFileName = nil
        transferProgress = nil
        transferFinished = false
        receivedResults = []
        phase = .idle
    }

    private func handleListenerState(
        _ state: NWListener.State,
        for listener: NWListener,
        hostAddress: String,
        token: String,
        generation: UInt64
    ) {
        guard sessionGeneration == generation, self.listener === listener else { return }
        switch state {
        case .ready:
            guard case .starting = phase else { return }
            guard let rawPort = listener.port?.rawValue,
                  let payload = PhotoTransferPairingPayload(host: hostAddress, port: rawPort, token: token)
            else {
                fail("수신 포트를 준비하지 못했습니다.")
                return
            }
            phase = .waitingForSender(payload)
        case .failed(let error):
            fail(UserErrorText.message("수신 대기 중 오류가 발생했습니다", error, recovery: UserErrorText.networkRecovery))
        default:
            break
        }
    }

    private func fail(_ message: String) {
        stop()
        phase = .failed(message)
    }

    private func accept(
        _ connection: NWConnection,
        from listener: NWListener,
        generation: UInt64
    ) {
        guard sessionGeneration == generation, self.listener === listener else {
            connection.cancel()
            return
        }
        pendingConnections[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state, for: connection)
            }
        }
        connection.start(queue: queue)
        receiveNextChunk(on: connection)
    }

    private func handleConnectionState(_ state: NWConnection.State, for connection: NWConnection) {
        switch state {
        case .failed(let error):
            if acceptedConnection === connection {
                acceptedConnection = nil
                if !transferFinished {
                    fail(UserErrorText.message("보내는 기기와의 연결이 끊어졌습니다", error, recovery: UserErrorText.networkRecovery))
                }
            } else {
                discard(connection)
            }
        case .cancelled:
            if acceptedConnection === connection {
                acceptedConnection = nil
                if !transferFinished {
                    fail("보내는 기기와의 연결이 끊어졌습니다.")
                }
            } else {
                discard(connection)
            }
        default:
            break
        }
    }

    private func receiveNextChunk(on connection: NWConnection) {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: PhotoTransferHandshake.maximumLineLength
        ) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleReceivedChunk(data, isComplete: isComplete, error: error, on: connection)
            }
        }
    }

    private func handleReceivedChunk(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection
    ) {
        let key = ObjectIdentifier(connection)
        // stop()이나 페어링 완료 이후 도착한 뒤늦은 콜백은 무시한다.
        guard pendingConnections[key] != nil else { return }

        if let data, !data.isEmpty {
            receiveBuffers[key, default: Data()].append(data)
        }
        if error != nil {
            discard(connection)
            return
        }

        let buffer = receiveBuffers[key] ?? Data()
        if let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
            receiveBuffers[key] = nil
            let line = String(decoding: buffer[buffer.startIndex..<newlineIndex], as: UTF8.self)
            if let pending = pendingV4[key] {
                respondToProof(line, pending: pending, on: connection)
            } else if PhotoTransferV4Handshake.isHelloPrefix(line) {
                respondToHello(line, on: connection)
            } else {
                respond(toClientLine: line, on: connection)
            }
        } else if isComplete {
            discard(connection)
        } else if pendingV4[key] != nil, buffer.count > PhotoTransferV4Handshake.maximumProofLength {
            receiveBuffers[key] = nil
            send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
        } else if buffer.count >= PhotoTransferHandshake.maximumLineLength {
            receiveBuffers[key] = nil
            send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
        } else {
            receiveNextChunk(on: connection)
        }
    }

    private func respond(toClientLine line: String, on connection: NWConnection) {
        var decision: PhotoTransferHandshake.Decision
        if let token = activeToken {
            decision = PhotoTransferHandshake.decision(toClientLine: line, expectedToken: token)
        } else {
            decision = .init(
                response: PhotoTransferHandshake.rejectResponse,
                peerPlatform: .unknown,
                accepted: false,
                supportsGroupedTransfer: false
            )
        }
        if decision.accepted, let token = activeToken {
            // 유효한 v3 시도에서 평문으로 받은 비밀은 이후 v4 삭제 자격을 얻지 못한다.
            activeTokenExposedToLegacy = true
            if !PhotoTransferTokenTaintStore.shared.markTainted(token: token) {
                // 노출 기록을 디스크에 남기지 못하면 이 레거시 시도를 받아들이지 않는다(fail closed). 이 프로세스의 토큰은 계속 오염으로 취급된다.
                decision = .init(
                    response: PhotoTransferHandshake.rejectResponse,
                    peerPlatform: .unknown,
                    accepted: false,
                    supportsGroupedTransfer: false
                )
            }
        }
        if decision.accepted {
            // 동시에 들어온 다른 연결이 같은 토큰을 재사용하지 못하도록 응답 전에 확정한다.
            finishPairing(
                with: connection,
                peerPlatform: decision.peerPlatform,
                supportsGroupedTransfer: decision.supportsGroupedTransfer
            )
        }
        send(decision.response, accepted: decision.accepted, on: connection)
    }

    private func send(_ response: String, accepted: Bool, on connection: NWConnection) {
        connection.send(
            content: Data(response.utf8),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, self.isActive(connection) else {
                        connection.cancel()
                        return
                    }
                    if let error {
                        self.fail(UserErrorText.message("연결 응답을 보내지 못했습니다", error, recovery: UserErrorText.networkRecovery))
                    } else if accepted {
                        if self.connectedPeerPlatform == .unknown {
                            // v1 앱은 연결 확인 직후 소켓을 닫는다. 논리적 연결 성공은 유지한다.
                            self.transferFinished = true
                            connection.stateUpdateHandler = nil
                            connection.cancel()
                            self.acceptedConnection = nil
                        } else {
                            self.receiveTransferChunk(on: connection)
                        }
                    } else {
                        self.discard(connection)
                    }
                }
            }
        )
    }

    private func isActive(_ connection: NWConnection) -> Bool {
        acceptedConnection === connection
            || pendingConnections[ObjectIdentifier(connection)] === connection
    }

    private func finishPairing(
        with connection: NWConnection,
        peerPlatform: PhotoTransferPeerPlatform,
        supportsGroupedTransfer: Bool,
        supportsReceipts: Bool = false
    ) {
        activeToken = nil
        acceptedConnection = connection
        connectedPeerPlatform = peerPlatform
        self.supportsGroupedTransfer = supportsGroupedTransfer
        self.supportsReceipts = supportsReceipts
        wireDecoder.acceptsControlFrames = supportsReceipts
        pendingConnections[ObjectIdentifier(connection)] = nil
        for other in pendingConnections.values {
            other.cancel()
        }
        pendingConnections.removeAll()
        for pending in pendingV4.values { pending.timeoutTask?.cancel() }
        pendingV4.removeAll()
        receiveBuffers.removeAll()
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        if case .waitingForSender(let payload) = phase {
            phase = .senderConnected(payload, peerPlatform)
        }
    }

    private func receiveTransferChunk(on connection: NWConnection) {
        guard acceptedConnection === connection, !transferFinished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleTransferChunk(data, isComplete: isComplete, error: error, on: connection)
            }
        }
    }

    private func handleTransferChunk(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection
    ) {
        guard acceptedConnection === connection, !transferFinished else { return }
        if supportsReceipts {
            handleReceiptTransferChunk(data, isComplete: isComplete, error: error, on: connection)
            return
        }
        if let error {
            fail(UserErrorText.message("파일 수신 중 오류가 발생했습니다", error, recovery: UserErrorText.networkRecovery))
            return
        }

        do {
            if let data, !data.isEmpty {
                let events = try wireDecoder.append(data)
                updateTransferProgress()
                for (eventIndex, event) in events.enumerated() {
                    do {
                        switch event {
                        case .begin:
                            // v3 연결에서는 디코더가 begin을 이미 거부한다.
                            throw PhotoTransferWireCodec.CodecError.invalidHeader
                        case .file(let header, let fileURL):
                            try stageReceivedFile(header: header, fileURL: fileURL)
                            currentFileName = nil
                            transferProgress = nil
                        case .completed:
                            guard eventIndex == events.count - 1, !wireDecoder.hasUnconsumedData else {
                                throw PhotoTransferWireCodec.CodecError.invalidHeader
                            }
                            currentFileName = "사진 보관함에 저장 중…"
                            let generation = sessionGeneration
                            Task { [weak self] in
                                guard let self else { return }
                                do {
                                    let savedResults = try await self.commitStagedComponentsToPhotoLibrary()
                                    guard self.sessionGeneration == generation else { return }
                                    self.receivedResults = savedResults
                                    self.receivedFileCount = savedResults.count
                                    self.transferFinished = true
                                    self.currentFileName = nil
                                    self.transferProgress = 1
                                    self.removeStagedComponents()
                                    self.sendTransferResult("RESULT OK \(savedResults.count)\n", on: connection)
                                } catch {
                                    guard self.sessionGeneration == generation else { return }
                                    self.sendTransferResult("RESULT ERROR\n", on: connection) { [weak self] in
                                        self?.fail(UserErrorText.message("받은 항목을 사진 보관함에 저장하지 못했습니다", error, recovery: "사진 보관함 접근 권한과 저장 공간을 확인한 뒤 다시 시도해 주세요."))
                                    }
                                }
                            }
                            return
                        }
                    } catch {
                        for remaining in events.dropFirst(eventIndex) {
                            if case .file(_, let url) = remaining {
                                try? FileManager.default.removeItem(at: url)
                            }
                        }
                        throw error
                    }
                }
            }
        } catch {
            fail(UserErrorText.message("받은 파일을 저장하지 못했습니다", error, recovery: "저장 공간을 확인한 뒤 다시 시도해 주세요."))
            return
        }

        if isComplete {
            fail("파일 전송이 완료되기 전에 연결이 끊어졌습니다.")
        } else {
            receiveTransferChunk(on: connection)
        }
    }

    private func updateTransferProgress() {
        currentFileName = wireDecoder.pendingFileName
        if let expected = wireDecoder.pendingPayloadLength, expected > 0 {
            transferProgress = min(1, Double(wireDecoder.pendingPayloadByteCount) / Double(expected))
        } else {
            transferProgress = nil
        }
    }

    private struct StagedComponent {
        let header: PhotoTransferWireHeader
        let fileURL: URL
    }

    /// hello를 받고 CHALLENGE를 보낸 뒤 PROOF를 기다리는 연결. 이 시점에는 토큰이나 리스너를 소모하지 않는다.
    private struct PendingV4Handshake {
        let platformS: PhotoTransferPeerPlatform
        let nonceS: String
        let nonceR: String
        let key: SymmetricKey
        var timeoutTask: Task<Void, Never>?
    }

    /// v4 연결 하나의 진행 상태. 항목은 구성요소가 모두 모이는 즉시 하나씩 영구 저장한다.
    private struct ReceiptTransferState {
        var nextSeq = 1
        var transferId: String?
        var itemCount = 0
        var staged: [String: [StagedComponent]] = [:]
        var pendingEvents: [PhotoTransferStreamingWireDecoder.Event] = []
        var isPumping = false
        /// 이 연결에서 판정한 항목(저널에 아직 없는 실패 포함).
        var outcomes: [String: PhotoTransferReceiptItem] = [:]
        var savedResults: [ReceivedMediaResult] = []
        var knownItemIDs: Set<String> = []
        /// 이 연결에서 방금 저장하고 출력 증명까지 확인한 항목(final에서 다시 읽지 않는다).
        var freshlyVerified: Set<String> = []
    }

    /// 저널의 committed 항목이 지금도 유효한지 확인하는 함수. 기본은 실제 사진 보관함 자원 해시 대조이며 시험에서 바꿀 수 있다.
    var outputVerifier: (PhotoTransferReceiptJournal.Entry) async -> PhotoTransferOutputCheck = { await PhotoTransferOutputProofing.check($0) }

    private enum PhotoLibrarySaveError: LocalizedError {
        case accessDenied
        case unsupportedMotionContainer
        /// 저장 기록(저널)을 디스크에 남기지 못해 Photos 변경을 시작하지 않았다.
        case journalUnavailable

        var errorDescription: String? {
            switch self {
            case .journalUnavailable: "저장 기록을 남기지 못해 이 항목은 저장하지 않았습니다. 저장 공간을 확인한 뒤 다시 시도해 주세요."
            case .accessDenied: "사진 추가 권한이 필요합니다. 설정에서 사진 추가를 허용해 주세요."
            case .unsupportedMotionContainer: "이 기기에서는 Android Motion Photo 단일 파일을 Live Photo로 안전하게 저장할 수 없습니다."
            }
        }
    }

    private func stageReceivedFile(header: PhotoTransferWireHeader, fileURL: URL) throws {
        var keepFile = false
        defer {
            if !keepFile { try? FileManager.default.removeItem(at: fileURL) }
        }
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 0,
              header.byteLength == UInt64(fileSize) else {
            throw PhotoTransferWireCodec.CodecError.payloadLengthMismatch
        }
        let headerPlatform = header.sourcePlatform ?? .unknown
        if connectedPeerPlatform != .unknown,
           headerPlatform != connectedPeerPlatform {
            throw PhotoTransferWireCodec.CodecError.platformMismatch
        }
        if supportsGroupedTransfer {
            guard !header.isLegacyFlatFile else {
                throw PhotoTransferWireCodec.CodecError.invalidHeader
            }
        } else if !header.isLegacyFlatFile {
            throw PhotoTransferWireCodec.CodecError.invalidHeader
        }

        stagedComponents.append(.init(header: header, fileURL: fileURL))
        keepFile = true
    }

    /// 모든 그룹과 체크섬이 완전한 뒤 한 Photos 변경 트랜잭션으로 저장한다.
    /// 전송 또는 그룹 검증이 중간에 실패하면 사진 보관함에는 어떤 자산도 추가되지 않는다.
    private func commitStagedComponentsToPhotoLibrary() async throws -> [ReceivedMediaResult] {
        let validatedAssets = try validatedAssets(from: stagedComponents)
        let prepared = try await prepareCrossPlatformAssets(validatedAssets)
        defer { prepared.convertedPairs.forEach { $0.removeTemporaryFiles() } }
        let assets = prepared.assets
        let authorization = await requestPhotoLibraryAddAuthorization()
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibrarySaveError.accessDenied
        }

        let createdIdentifiers = PhotoTransferCreatedIdentifiersBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges { @Sendable in
                for asset in assets {
                    let request = PHAssetCreationRequest.forAsset()
                    for component in asset.components {
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = Self.safeFileName(component.originalFilename)
                        request.addResource(
                            with: component.resourceType,
                            fileURL: component.fileURL,
                            options: options
                        )
                    }
                    if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                        createdIdentifiers.values.append(identifier)
                    }
                }
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PhotoTransferWireCodec.CodecError.incompleteGroup) }
            }
        }
        guard createdIdentifiers.values.count == assets.count else {
            throw PhotoTransferWireCodec.CodecError.incompleteGroup
        }
        return await makeReceivedResults(
            identifiers: createdIdentifiers.values,
            savedAssets: assets
        )
    }

    private struct ValidatedComponent {
        let header: PhotoTransferWireHeader
        let fileURL: URL
        let resourceType: PHAssetResourceType
        let originalFilename: String
        /// 변환으로 새로 만든 파일이면 true. 출력 바이트가 입력 해시와 같다고 볼 수 없다.
        let isTransformed: Bool

        init(
            header: PhotoTransferWireHeader,
            fileURL: URL,
            resourceType: PHAssetResourceType,
            originalFilename: String? = nil,
            isTransformed: Bool = false
        ) {
            self.isTransformed = isTransformed
            self.header = header
            self.fileURL = fileURL
            self.resourceType = resourceType
            self.originalFilename = originalFilename ?? header.name ?? "received-file"
        }
    }

    private struct ValidatedAsset {
        let components: [ValidatedComponent]

        var receivedKind: ReceivedMediaKind {
            guard let header = components.first?.header else { return .photo }
            switch header.itemKind {
            case .video: return .video
            case .livePhoto: return .livePhoto
            case .motionPhoto: return .motionPhoto
            case .photo: return .photo
            case nil:
                return header.mediaKind == PhotoTransferMediaKind.video.rawValue ? .video : .photo
            }
        }
    }

    private struct PreparedPhotoAssets {
        let assets: [ValidatedAsset]
        let convertedPairs: [PhotoTransferLivePhotoConverter.ConvertedPair]
    }

    private func prepareCrossPlatformAssets(_ assets: [ValidatedAsset]) async throws -> PreparedPhotoAssets {
        var preparedAssets: [ValidatedAsset] = []
        var convertedPairs: [PhotoTransferLivePhotoConverter.ConvertedPair] = []
        do {
            for asset in assets {
                guard let first = asset.components.first?.header,
                      first.sourcePlatform == .android,
                      first.itemKind == .motionPhoto
                else {
                    preparedAssets.append(asset)
                    continue
                }
                guard let image = asset.components.first(where: { $0.resourceType == .photo }),
                      let video = asset.components.first(where: { $0.resourceType == .pairedVideo })
                else {
                    throw PhotoTransferWireCodec.CodecError.incompleteGroup
                }
                let converted = try await PhotoTransferLivePhotoConverter.convert(
                    imageURL: image.fileURL,
                    videoURL: video.fileURL,
                    stillImageTimeUs: first.stillImageTimeUs ?? -1
                )
                convertedPairs.append(converted)
                preparedAssets.append(.init(components: [
                    .init(
                        header: image.header,
                        fileURL: converted.imageURL,
                        resourceType: .photo,
                        originalFilename: converted.imageURL.lastPathComponent,
                        isTransformed: true
                    ),
                    .init(
                        header: video.header,
                        fileURL: converted.pairedVideoURL,
                        resourceType: .pairedVideo,
                        originalFilename: converted.pairedVideoURL.lastPathComponent,
                        isTransformed: true
                    ),
                ]))
            }
            return PreparedPhotoAssets(assets: preparedAssets, convertedPairs: convertedPairs)
        } catch {
            convertedPairs.forEach { $0.removeTemporaryFiles() }
            throw error
        }
    }

    private func validatedAssets(from components: [StagedComponent]) throws -> [ValidatedAsset] {
        guard !components.isEmpty else {
            throw PhotoTransferWireCodec.CodecError.incompleteGroup
        }
        let componentIDs = components.compactMap(\.header.id)
        guard componentIDs.count == components.count,
              Set(componentIDs).count == componentIDs.count else {
            throw PhotoTransferWireCodec.CodecError.incompleteGroup
        }
        var legacyAssets: [ValidatedAsset] = []
        var grouped: [String: [StagedComponent]] = [:]
        for component in components {
            let header = component.header
            if header.isLegacyFlatFile {
                let type: PHAssetResourceType
                switch header.mediaKind {
                case PhotoTransferMediaKind.photo.rawValue: type = .photo
                case PhotoTransferMediaKind.video.rawValue: type = .video
                default: throw PhotoTransferWireCodec.CodecError.invalidHeader
                }
                legacyAssets.append(.init(components: [.init(header: header, fileURL: component.fileURL, resourceType: type)]))
            } else if let groupId = header.groupId {
                grouped[groupId, default: []].append(component)
            } else {
                throw PhotoTransferWireCodec.CodecError.incompleteGroup
            }
        }

        var result = legacyAssets
        for group in grouped.values {
            guard let first = group.first?.header,
                  let expectedCount = first.componentCount,
                  group.count == expectedCount,
                  Set(group.compactMap(\.header.componentIndex)).count == expectedCount,
                  group.allSatisfy({ component in
                      let header = component.header
                      return header.itemId == first.itemId
                          && header.groupId == first.groupId
                          && header.itemKind == first.itemKind
                          && header.sourcePlatform == first.sourcePlatform
                          && header.componentCount == expectedCount
                          && header.stillImageTimeUs == first.stillImageTimeUs
                  })
            else {
                throw PhotoTransferWireCodec.CodecError.incompleteGroup
            }

            let sorted = group.sorted { ($0.header.componentIndex ?? -1) < ($1.header.componentIndex ?? -1) }
            switch first.itemKind {
            case .photo:
                guard sorted.count == 1, sorted[0].header.componentRole == .regularFile else {
                    throw PhotoTransferWireCodec.CodecError.incompleteGroup
                }
                result.append(.init(components: [.init(header: sorted[0].header, fileURL: sorted[0].fileURL, resourceType: .photo)]))
            case .video:
                guard sorted.count == 1, sorted[0].header.componentRole == .regularFile else {
                    throw PhotoTransferWireCodec.CodecError.incompleteGroup
                }
                result.append(.init(components: [.init(header: sorted[0].header, fileURL: sorted[0].fileURL, resourceType: .video)]))
            case .livePhoto, .motionPhoto:
                guard sorted.count == 2,
                      sorted[0].header.componentRole == .primaryImage,
                      sorted[1].header.componentRole == .motionVideo
                else {
                    if sorted.count == 1, sorted[0].header.componentRole == .motionContainer {
                        throw PhotoLibrarySaveError.unsupportedMotionContainer
                    }
                    throw PhotoTransferWireCodec.CodecError.incompleteGroup
                }
                result.append(.init(components: [
                    .init(header: sorted[0].header, fileURL: sorted[0].fileURL, resourceType: .photo),
                    .init(header: sorted[1].header, fileURL: sorted[1].fileURL, resourceType: .pairedVideo),
                ]))
            case nil:
                throw PhotoTransferWireCodec.CodecError.incompleteGroup
            }
        }
        return result
    }

    private func requestPhotoLibraryAddAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func makeReceivedResults(
        identifiers: [String],
        savedAssets: [ValidatedAsset]
    ) async -> [ReceivedMediaResult] {
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assetsByIdentifier: [String: PHAsset] = [:]
        fetched.enumerateObjects { asset, _, _ in
            assetsByIdentifier[asset.localIdentifier] = asset
        }

        var results: [ReceivedMediaResult] = []
        for (index, identifier) in identifiers.enumerated() {
            let savedAsset = savedAssets.indices.contains(index) ? savedAssets[index] : nil
            let plannedKind = savedAsset?.receivedKind ?? .photo
            let thumbnail: UIImage? = if let savedAsset {
                await requestFallbackThumbnail(for: savedAsset)
            } else {
                nil
            }
            guard let asset = assetsByIdentifier[identifier] else {
                results.append(.init(id: identifier, kind: plannedKind, thumbnail: thumbnail))
                continue
            }
            let kind = Self.actualReceivedKind(for: asset, plannedKind: plannedKind)
            results.append(.init(id: identifier, kind: kind, thumbnail: thumbnail))
        }
        return results
    }

    private func requestFallbackThumbnail(for asset: ValidatedAsset) async -> UIImage? {
        if let photo = asset.components.first(where: { $0.resourceType == .photo }),
           let source = CGImageSourceCreateWithURL(photo.fileURL as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 240,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return UIImage(cgImage: image)
            }
        }
        guard let video = asset.components.first(where: { $0.resourceType == .video }) else {
            return nil
        }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video.fileURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let frame = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: frame.image)
    }

    nonisolated static func actualReceivedKind(
        mediaType: PHAssetMediaType,
        mediaSubtypes: PHAssetMediaSubtype,
        plannedKind: ReceivedMediaKind
    ) -> ReceivedMediaKind {
        if mediaType == .video { return .video }
        if mediaType == .image, mediaSubtypes.contains(.photoLive) {
            return plannedKind == .motionPhoto ? .motionPhoto : .livePhoto
        }
        return .photo
    }

    private static func actualReceivedKind(
        for asset: PHAsset,
        plannedKind: ReceivedMediaKind
    ) -> ReceivedMediaKind {
        actualReceivedKind(
            mediaType: asset.mediaType,
            mediaSubtypes: asset.mediaSubtypes,
            plannedKind: plannedKind
        )
    }

    private func sendTransferResult(
        _ result: String,
        on connection: NWConnection,
        completion: (@MainActor @Sendable () -> Void)? = nil
    ) {
        let generation = sessionGeneration
        connection.send(content: Data(result.utf8), completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in
                connection.stateUpdateHandler = nil
                connection.cancel()
                guard let self, self.sessionGeneration == generation else { return }
                if self.acceptedConnection === connection { self.acceptedConnection = nil }
                completion?()
            }
        })
    }

    private func removeStagedComponents() {
        for component in stagedComponents {
            try? FileManager.default.removeItem(at: component.fileURL)
        }
        stagedComponents.removeAll()
    }

    nonisolated private static func safeFileName(_ proposedName: String) -> String {
        let leafName = URL(fileURLWithPath: proposedName).lastPathComponent
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " ._-"))
        let sanitized = leafName.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
        let result = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? "received-file" : String(result.prefix(180))
    }

    private func discard(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        pendingV4[key]?.timeoutTask?.cancel()
        pendingV4[key] = nil
        receiveBuffers[key] = nil
        pendingConnections[key] = nil
        connection.cancel()
    }
}

// MARK: - v4 항목별 영수증(receipt-v1)

extension PhotoTransferReceiverSession {
    // MARK: v4 핸드셰이크(토큰 미노출 challenge/proof)

    private func respondToHello(_ line: String, on connection: NWConnection) {
        if activeToken != nil, activeTokenExposedToLegacy {
            // 이 QR의 비밀은 이미 평문으로 노출됐다. 다운그레이드 없이 새 QR이 필요하다고 알리고 이 소켓만 닫는다.
            send(PhotoTransferHandshake.taintedResponse, accepted: false, on: connection)
            return
        }
        guard let token = activeToken,
              let hello = PhotoTransferV4Handshake.parseHello(line) else {
            // 형식 오류·claim 이후 접속: ERROR 후 이 소켓만 닫는다. 리스너와 토큰은 유지된다.
            send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
            return
        }
        let id = ObjectIdentifier(connection)
        let nonceR = PhotoTransferV4Handshake.makeNonce()
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(PhotoTransferV4Handshake.proofTimeoutSeconds))
            guard !Task.isCancelled, let self, self.pendingV4[id] != nil else { return }
            self.send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
        }
        pendingV4[id] = PendingV4Handshake(
            platformS: hello.platform, nonceS: hello.nonceS, nonceR: nonceR,
            key: PhotoTransferV4Handshake.handshakeKey(token: token), timeoutTask: timeout)
        connection.send(
            content: Data(PhotoTransferV4Handshake.challengeLine(nonceR: nonceR).utf8),
            completion: .contentProcessed { [weak self] error in
                Task { @MainActor in
                    guard let self, self.pendingConnections[id] === connection else { return }
                    if error != nil { self.discard(connection) } else { self.receiveNextChunk(on: connection) }
                }
            })
    }

    private func respondToProof(_ line: String, pending: PendingV4Handshake, on connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        pending.timeoutTask?.cancel()
        pendingV4[id] = nil
        guard activeToken != nil,
              let proof = PhotoTransferV4Handshake.parseProof(line),
              PhotoTransferV4Handshake.verifySenderProof(
                  proof, key: pending.key, platformS: pending.platformS, nonceS: pending.nonceS, nonceR: pending.nonceR)
        else {
            // 인증 실패는 "미지원"이 아니다. claim하지 않고 이 소켓만 닫는다.
            send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
            return
        }
        let proofR = PhotoTransferV4Handshake.receiverProof(
            key: pending.key, platformR: .ios, nonceS: pending.nonceS, nonceR: pending.nonceR)
        let sessionKey = PhotoTransferV4Handshake.sessionKey(key: pending.key, nonceS: pending.nonceS, nonceR: pending.nonceR)
        // 동시에 들어온 다른 연결이 같은 토큰을 재사용하지 못하도록 응답 전에 확정한다.
        finishPairing(with: connection, peerPlatform: pending.platformS, supportsGroupedTransfer: true, supportsReceipts: true)
        receiptSessionKey = sessionKey
        send(PhotoTransferV4Handshake.okLine(platform: .ios, proof: proofR), accepted: true, on: connection)
    }

    /// 계약 §2.2: 프레임마다 `seq`가 1씩 늘고 세션 키로 MAC을 붙인다.
    private func makeReceiptFrames(
        stage: PhotoTransferReceiptFrame.Stage,
        transferId: String,
        status: PhotoTransferReceiptFrame.Status?,
        items: [PhotoTransferReceiptItem]
    ) -> [Data] {
        guard let key = receiptSessionKey,
              let result = try? PhotoTransferControlCodec.receiptFrames(
                  stage: stage, transferId: transferId, receiverId: PhotoTransferReceiptJournal.shared.receiverId,
                  status: status, items: items, sessionKey: key, startingSeq: v4.nextSeq) else { return [] }
        v4.nextSeq = result.nextSeq
        return result.frames
    }

    nonisolated static func receiptReason(for error: Error) -> String {
        if let codec = error as? PhotoTransferWireCodec.CodecError {
            switch codec {
            case .checksumMismatch: return "checksum"
            case .payloadTooLarge, .payloadLengthMismatch: return "invalid"
            case .incompleteGroup, .invalidHeader, .invalidHeaderLength, .platformMismatch: return "invalid"
            }
        }
        if let save = error as? PhotoLibrarySaveError {
            switch save {
            case .accessDenied, .journalUnavailable: return "storage"
            case .unsupportedMotionContainer: return "unsupported"
            }
        }
        return "storage"
    }

    fileprivate func handleReceiptTransferChunk(
        _ data: Data?,
        isComplete: Bool,
        error: NWError?,
        on connection: NWConnection
    ) {
        if let error {
            finishInterrupted(message: UserErrorText.message("파일 수신 중 오류가 발생했습니다", error, recovery: UserErrorText.networkRecovery))
            return
        }
        do {
            if let data, !data.isEmpty {
                let events = try wireDecoder.append(data)
                updateTransferProgress()
                v4.pendingEvents.append(contentsOf: events)
            }
        } catch {
            let reason = Self.receiptReason(for: error)
            let generation = sessionGeneration
            Task { [weak self] in
                guard let self, self.sessionGeneration == generation else { return }
                await self.abortReceiptStream(reason: reason, detail: UserErrorText.koreanDetail(error) ?? "항목 검증에 실패했습니다", on: connection)
            }
            return
        }
        pumpReceiptEvents(on: connection, connectionEnded: isComplete)
    }

    /// 이벤트를 도착 순서대로 한 번에 하나씩 처리한다. 저장이 끝나기 전에는 다음 청크를 읽지 않는다.
    private func pumpReceiptEvents(on connection: NWConnection, connectionEnded: Bool) {
        guard !v4.isPumping else { return }
        v4.isPumping = true
        let generation = sessionGeneration
        Task { [weak self] in
            guard let self else { return }
            while !self.v4.pendingEvents.isEmpty {
                guard self.sessionGeneration == generation else { return }
                let event = self.v4.pendingEvents.removeFirst()
                let keepGoing = await self.processReceiptEvent(event, on: connection)
                if !keepGoing {
                    self.v4.isPumping = false
                    return
                }
            }
            self.v4.isPumping = false
            guard self.sessionGeneration == generation, !self.transferFinished else { return }
            if connectionEnded {
                self.finishInterrupted(message: "파일 전송이 완료되기 전에 연결이 끊어졌습니다.")
            } else {
                self.receiveTransferChunk(on: connection)
            }
        }
    }

    /// - Returns: 스트림을 계속 읽어도 되면 true.
    private func processReceiptEvent(_ event: PhotoTransferStreamingWireDecoder.Event, on connection: NWConnection) async -> Bool {
        switch event {
        case .begin(let begin):
            guard v4.transferId == nil else {
                await abortReceiptStream(reason: "invalid", detail: "begin 프레임이 두 번 도착했습니다.", on: connection)
                return false
            }
            v4.transferId = begin.transferId
            v4.itemCount = begin.itemCount
            await reconcileReceiptJournal()
            PhotoTransferReceiptJournal.shared.expireOldEntries()
            // ready에는 현재 출력이 검증된 committed만 싣는다. 사라졌거나 바뀌었거나 확인 못 한 항목은 싣지 않고,
            // 발신이 다시 보내도 바이트만 읽고 사본을 다시 만들지 않으며 final에서 사유와 함께 보고한다.
            let committed = await verifiedReceiptItems(forTransfer: begin.transferId, committedOnly: true)
            currentFileName = nil
            let frames = makeReceiptFrames(stage: .ready, transferId: begin.transferId, status: nil, items: committed)
            guard !frames.isEmpty, await sendControlFrames(frames, on: connection) else {
                finishInterrupted(message: "받은 항목 확인 응답을 보내지 못했습니다.")
                return false
            }
            return true
        case .file(let header, let fileURL):
            guard let transferId = v4.transferId else {
                try? FileManager.default.removeItem(at: fileURL)
                await abortReceiptStream(reason: "invalid", detail: "begin 없이 파일이 도착했습니다.", on: connection)
                return false
            }
            do {
                try validateReceiptComponent(header: header, fileURL: fileURL)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                await abortReceiptStream(reason: Self.receiptReason(for: error), detail: UserErrorText.koreanDetail(error) ?? "항목 검증에 실패했습니다", on: connection)
                return false
            }
            guard let itemId = header.itemId else { return false }
            if !v4.knownItemIDs.contains(itemId) {
                guard v4.knownItemIDs.count < v4.itemCount else {
                    try? FileManager.default.removeItem(at: fileURL)
                    await abortReceiptStream(reason: "invalid", detail: "begin에서 알린 항목 수를 넘었습니다.", on: connection)
                    return false
                }
                v4.knownItemIDs.insert(itemId)
            }
            v4.staged[itemId, default: []].append(StagedComponent(header: header, fileURL: fileURL))
            currentFileName = nil
            transferProgress = nil
            if let expected = header.componentCount, v4.staged[itemId]?.count == expected {
                await commitReceiptItem(itemId: itemId, transferId: transferId)
            }
            return true
        case .completed:
            await finishReceiptTransfer(on: connection)
            return false
        }
    }

    private func validateReceiptComponent(header: PhotoTransferWireHeader, fileURL: URL) throws {
        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 0, header.byteLength == UInt64(fileSize) else {
            throw PhotoTransferWireCodec.CodecError.payloadLengthMismatch
        }
        let headerPlatform = header.sourcePlatform ?? .unknown
        if connectedPeerPlatform != .unknown, headerPlatform != connectedPeerPlatform {
            throw PhotoTransferWireCodec.CodecError.platformMismatch
        }
        guard !header.isLegacyFlatFile, let itemId = header.itemId,
              PhotoTransferReceiptWire.isValidItemID(itemId), header.groupId == itemId else {
            throw PhotoTransferWireCodec.CodecError.invalidHeader
        }
    }

    /// 와이어에는 수신 로컬 자산 식별자나 출력 증명을 싣지 않는다(저널에만 둔다).
    /// `committed`는 저널 기록만으로 검증된 commit이 아니다. 현재 출력 확인(`check`)이 `verified`일 때만 committed로 보고하고,
    /// 아니면 `failed`와 사유(outmissing / outmodified / outunverified)로 보고한다. 저널의 자산은 그대로 보존된다.
    nonisolated static func receiptItem(from entry: PhotoTransferReceiptJournal.Entry, check: PhotoTransferOutputCheck) -> PhotoTransferReceiptItem {
        switch entry.state {
        case .committed:
            if check == .verified {
                return PhotoTransferReceiptItem(itemId: entry.itemId, state: .committed, inputs: entry.inputs, reason: nil)
            }
            return PhotoTransferReceiptItem(itemId: entry.itemId, state: .failed, inputs: entry.inputs,
                                            reason: check.receiptReason ?? "outunverified")
        case .failed:
            return PhotoTransferReceiptItem(itemId: entry.itemId, state: .failed, inputs: entry.inputs, reason: entry.reason ?? "unknown")
        case .reserved:
            return PhotoTransferReceiptItem(itemId: entry.itemId, state: .failed, inputs: entry.inputs, reason: "conflict")
        }
    }

    /// 이 전송의 저널 항목을 영수증 항목으로 바꾼다. `committed`는 매번 현재 출력을 확인한다
    /// (이 연결에서 방금 저장·증명한 항목은 다시 읽지 않는다). `reserved`는 제외한다.
    private func verifiedReceiptItems(forTransfer transferId: String, committedOnly: Bool = false) async -> [PhotoTransferReceiptItem] {
        var items: [PhotoTransferReceiptItem] = []
        let entries = PhotoTransferReceiptJournal.shared.entries(forTransfer: transferId)
        for entry in entries {
            switch entry.state {
            case .committed:
                let check: PhotoTransferOutputCheck = v4.freshlyVerified.contains(entry.itemId) ? .verified : await outputVerifier(entry)
                if committedOnly && check != .verified { continue }
                items.append(Self.receiptItem(from: entry, check: check))
            case .failed:
                if !committedOnly { items.append(Self.receiptItem(from: entry, check: .unverifiable)) }
            case .reserved:
                // 저장 여부를 확정하지 못한 예약도 final/error에는 싣는다(발신이 누락이 아니라 사유와 함께 본다). 이 연결에서 얻은 판정이 있으면 그것을 쓴다.
                if !committedOnly { items.append(v4.outcomes[entry.itemId] ?? Self.receiptItem(from: entry, check: .unverifiable)) }
            }
        }
        if !committedOnly {
            // 저널에 남기지 못한 이 연결의 판정(디스크 쓰기 실패 등)도 빠뜨리지 않는다.
            let journaled = Set(entries.map(\.itemId))
            for (itemId, outcome) in v4.outcomes where !journaled.contains(itemId) { items.append(outcome) }
        }
        return items
    }

    /// 앱이 멈춘 뒤 남은 `reserved` 예약을 정확한 계획·해시 증명으로만 판정한다. 읽기 권한이 없으면 판정하지 않는다.
    /// 공개된 자산이나 확인 불가 자산은 어떤 경우에도 지우지 않고, 판정할 수 없으면 `reserved`로 남긴다.
    private func reconcileReceiptJournal() async {
        let journal = PhotoTransferReceiptJournal.shared
        for entry in journal.reservedEntries() {
            let states = await PhotoTransferOutputProofing.currentStates(identifiers: entry.outputIdentifiers)
            let resolution = PhotoTransferOutputProofing.resolveReservation(
                outputIdentifiers: entry.outputIdentifiers, planned: entry.plannedOutputs, states: states)
            journal.applyResolution(transferId: entry.transferId, itemId: entry.itemId, resolution)
        }
    }

    /// 완성된 항목 하나를 검증·변환·영구 저장하고 저널을 갱신한다. 실패해도 다른 항목과 이미 저장된 자산은 건드리지 않는다.
    private func commitReceiptItem(itemId: String, transferId: String) async {
        guard let components = v4.staged.removeValue(forKey: itemId) else { return }
        defer { for component in components { try? FileManager.default.removeItem(at: component.fileURL) } }
        let journal = PhotoTransferReceiptJournal.shared
        let inputs = components.compactMap { component -> PhotoTransferReceiptInput? in
            guard let index = component.header.componentIndex, let sha = component.header.sha256 else { return nil }
            return PhotoTransferReceiptInput(index: index, sha256: sha)
        }.sorted { $0.index < $1.index }

        if let existing = journal.entry(transferId: transferId, itemId: itemId) {
            switch existing.state {
            case .committed:
                // 중복 전달: 바이트는 이미 읽어 해시를 검증했고 재저장하지 않는다(사용자가 지웠거나 바꾼 사본을 다시 만들지 않는다).
                // 입력 해시가 저널과 달라도 기존 항목은 건드리지 않고 저널의 실제 inputs를 그대로 보고하므로 발신이 불일치를 본다(계약 §2.3).
                // 현재 출력을 다시 확인해, 사라졌거나 바뀌었거나 확인 못 하면 검증된 committed로 보고하지 않는다.
                v4.outcomes[itemId] = Self.receiptItem(from: existing, check: await outputVerifier(existing))
                return
            case .reserved:
                await reconcileReceiptJournal()
                if let promoted = journal.entry(transferId: transferId, itemId: itemId), promoted.state == .committed {
                    v4.outcomes[itemId] = Self.receiptItem(from: promoted, check: await outputVerifier(promoted))
                    return
                }
                if journal.entry(transferId: transferId, itemId: itemId)?.state == .reserved {
                    // 저장 여부를 확인할 수 없는 상태. 중복 저장을 피하려고 다시 저장하지 않는다.
                    v4.outcomes[itemId] = PhotoTransferReceiptItem(itemId: itemId, state: .failed, inputs: inputs, reason: "conflict")
                    return
                }
            case .failed:
                break
            }
        }

        currentFileName = "사진 보관함에 저장 중…"
        do {
            let validated = try validatedAssets(from: components)
            let prepared = try await prepareCrossPlatformAssets(validated)
            defer { prepared.convertedPairs.forEach { $0.removeTemporaryFiles() } }
            let authorization = await requestPhotoLibraryAddAuthorization()
            guard authorization == .authorized || authorization == .limited else {
                throw PhotoLibrarySaveError.accessDenied
            }
            let planned = Self.plannedOutputs(for: prepared.assets)
            // Photos 변경을 시작하기 전에 예약(계획 포함, 식별자는 아직 없음)을 디스크에 먼저 남긴다. 못 남기면 저장하지 않는다.
            do {
                try journal.reserve(transferId: transferId, itemId: itemId, inputs: inputs, placeholderIdentifiers: [], plannedOutputs: planned)
            } catch {
                throw PhotoLibrarySaveError.journalUnavailable
            }
            let created = try await createPhotoAssets(prepared.assets) { placeholderIdentifiers in
                // commit 직전, 같은 변경 블록 안에서 placeholder 식별자를 예약에 영속한다. 실패해도 이 시점에는 변경을 되돌릴 수 없다.
                let plans = zip(placeholderIdentifiers, planned).map { identifier, plan in
                    PhotoTransferPlannedOutput(identifier: identifier, kind: plan.kind, parts: plan.parts)
                }
                return (try? journal.reserve(transferId: transferId, itemId: itemId, inputs: inputs,
                                             placeholderIdentifiers: placeholderIdentifiers, plannedOutputs: plans)) != nil
            }
            let identifiers = created.identifiers
            // 이 시점부터 자산은 사진 보관함에 공개됐다. 어떤 실패에도 롤백·삭제·재저장하지 않는다.
            // 저장 직후 실제 출력 증명(알려진 식별자만, 로컬 전용). 읽기 권한이 없거나 자원을 읽지 못하면 nil → 확인 불가(저장 자체는 성공).
            let proofs = await PhotoTransferOutputProofing.captureProofs(
                identifiers: identifiers,
                requiredResourceTypes: prepared.assets.map { Set($0.components.map { $0.resourceType.rawValue }) })
            // 변환 없이 저장된 부분은 보낸 입력 해시와 정확히 같아야 한다. 저장됐지만 다른 바이트면 증명을 남기지 않는다.
            var storedProofs = proofs
            var check: PhotoTransferOutputCheck = proofs == nil ? .unverifiable : .verified
            if let proofs, !PhotoTransferOutputProofing.unconvertedPartsMatchPlannedInputs(proofs: proofs, planned: planned) {
                storedProofs = nil
                check = .modified
            }
            var journaled = true
            do {
                try journal.markCommitted(transferId: transferId, itemId: itemId, outputIdentifiers: identifiers, outputProofs: storedProofs)
            } catch {
                // 기록 쓰기 실패: 예약은 남아 있어 다음 기회에 복구한다. 이번 영수증은 확인 불가로 보고해 삭제 자격과 자동 재저장을 막는다.
                journaled = false
                check = .unverifiable
            }
            if journaled, let entry = journal.entry(transferId: transferId, itemId: itemId) {
                if check == .verified { v4.freshlyVerified.insert(itemId) }
                v4.outcomes[itemId] = Self.receiptItem(from: entry, check: check)
            } else {
                v4.outcomes[itemId] = PhotoTransferReceiptItem(
                    itemId: itemId, state: .failed, inputs: inputs, reason: check.receiptReason ?? "outunverified")
            }
            if check != .verified { unverifiedSavedCount += 1 }
            let results = await makeReceivedResults(identifiers: identifiers, savedAssets: prepared.assets)
            v4.savedResults.append(contentsOf: results)
            receivedFileCount = v4.savedResults.count
        } catch {
            // commit 전에 실패했으면 예약을 지우고, commit 여부를 알 수 없으면 reconcile에 맡긴다.
            let reason = Self.receiptReason(for: error)
            // 여기에 오는 오류는 Photos 변경이 완료되지 않았음을 뜻한다(commit 뒤에는 던지지 않는다). 공개 자산을 지우지는 않는다.
            if journal.entry(transferId: transferId, itemId: itemId)?.state == .reserved {
                await reconcileReceiptJournal()
                if let entry = journal.entry(transferId: transferId, itemId: itemId), entry.state == .committed {
                    v4.outcomes[itemId] = Self.receiptItem(from: entry, check: await outputVerifier(entry))
                    return
                }
                journal.removeReservation(transferId: transferId, itemId: itemId)
            }
            journal.markFailed(transferId: transferId, itemId: itemId, inputs: inputs, reason: reason)
            v4.outcomes[itemId] = PhotoTransferReceiptItem(itemId: itemId, state: .failed, inputs: inputs, reason: reason)
        }
        currentFileName = nil
    }

    /// commit 전 계획. 변환 없이 저장되는 부분만 입력 해시를 싣는다(변환된 출력은 입력 해시와 같다고 가정하지 않는다).
    private static func plannedOutputs(for assets: [ValidatedAsset]) -> [PhotoTransferPlannedOutput] {
        assets.map { asset in
            let kind: String
            switch asset.receivedKind {
            case .video: kind = "video"
            case .livePhoto, .motionPhoto: kind = "livePhoto"
            case .photo: kind = "photo"
            }
            let parts = asset.components.map { component in
                PhotoTransferPlannedOutput.Part(
                    resourceType: component.resourceType.rawValue,
                    inputSha256: component.isTransformed ? nil : component.header.sha256)
            }
            return PhotoTransferPlannedOutput(identifier: "", kind: kind, parts: parts)
        }
    }

    /// 한 번의 Photos 변경으로 자산을 만든다. `onReserve`는 commit 전에 placeholder 식별자를 받는다.
    private func createPhotoAssets(
        _ assets: [ValidatedAsset],
        onReserve: @escaping @Sendable ([String]) -> Bool
    ) async throws -> (identifiers: [String], reservationPersisted: Bool) {
        let createdIdentifiers = PhotoTransferCreatedIdentifiersBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges { @Sendable in
                for asset in assets {
                    let request = PHAssetCreationRequest.forAsset()
                    for component in asset.components {
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = Self.safeFileName(component.originalFilename)
                        request.addResource(with: component.resourceType, fileURL: component.fileURL, options: options)
                    }
                    if let identifier = request.placeholderForCreatedAsset?.localIdentifier {
                        createdIdentifiers.values.append(identifier)
                    }
                }
                if createdIdentifiers.values.count == assets.count { createdIdentifiers.reservationPersisted = onReserve(createdIdentifiers.values) }
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: PhotoTransferWireCodec.CodecError.incompleteGroup) }
            }
        }
        guard createdIdentifiers.values.count == assets.count else {
            throw PhotoTransferWireCodec.CodecError.incompleteGroup
        }
        return (createdIdentifiers.values, createdIdentifiers.reservationPersisted)
    }

    /// `done` 처리: 불완전한 그룹은 실패로 기록하고, 저널의 이 전송 전체 상태를 final 영수증으로 보낸다.
    private func finishReceiptTransfer(on connection: NWConnection) async {
        guard let transferId = v4.transferId else {
            await abortReceiptStream(reason: "invalid", detail: "begin 없이 완료 프레임이 도착했습니다.", on: connection)
            return
        }
        let journal = PhotoTransferReceiptJournal.shared
        for (itemId, components) in v4.staged {
            let inputs = components.compactMap { component -> PhotoTransferReceiptInput? in
                guard let index = component.header.componentIndex, let sha = component.header.sha256 else { return nil }
                return PhotoTransferReceiptInput(index: index, sha256: sha)
            }.sorted { $0.index < $1.index }
            journal.markFailed(transferId: transferId, itemId: itemId, inputs: inputs, reason: "invalid")
            for component in components { try? FileManager.default.removeItem(at: component.fileURL) }
        }
        v4.staged.removeAll()
        let items = await verifiedReceiptItems(forTransfer: transferId)
        let committedCount = items.filter { $0.state == .committed }.count
        let status: PhotoTransferReceiptFrame.Status = committedCount >= v4.itemCount && committedCount == items.count
            ? .complete : (committedCount > 0 ? .partial : .failed)
        let frames = makeReceiptFrames(stage: .final, transferId: transferId, status: status, items: items)
        receivedResults = v4.savedResults
        receivedFileCount = v4.savedResults.count
        transferFinished = true
        currentFileName = nil
        transferProgress = 1
        // 응답 전송이 실패해도 이미 저장된 자산은 되돌리지 않는다.
        _ = await sendControlFrames(frames, on: connection)
        connection.stateUpdateHandler = nil
        connection.cancel()
        if acceptedConnection === connection { acceptedConnection = nil }
    }

    /// 스트림이 잘못되어 계속할 수 없을 때: 지금까지 저장된 항목을 보존하고 error 영수증을 보낸 뒤 닫는다.
    private func abortReceiptStream(reason: String, detail: String, on connection: NWConnection) async {
        for components in v4.staged.values { for component in components { try? FileManager.default.removeItem(at: component.fileURL) } }
        v4.staged.removeAll()
        v4.pendingEvents.removeAll()
        let transferId = v4.transferId ?? ""
        let items = PhotoTransferReceiptWire.isValidTransferID(transferId) ? await verifiedReceiptItems(forTransfer: transferId) : []
        let committedCount = items.filter { $0.state == .committed }.count
        if PhotoTransferReceiptWire.isValidTransferID(transferId) {
            let frames = makeReceiptFrames(stage: .error, transferId: transferId,
                                           status: committedCount > 0 ? .partial : .failed, items: items)
            if !frames.isEmpty { _ = await sendControlFrames(frames, on: connection) }
        }
        let kept = committedCount > 0 ? " 이미 저장된 \(committedCount)개는 그대로 유지됩니다." : ""
        finishInterrupted(message: "받은 파일을 처리하지 못했습니다: \(detail).\(kept)")
    }

    /// 연결이 끊기거나 스트림이 중단됐을 때. 저장된 자산과 저널은 그대로 두고 실패 화면만 보인다.
    private func finishInterrupted(message: String) {
        let saved = v4.savedResults.count
        let suffix = saved > 0 ? " 이미 저장된 \(saved)개는 유지되며, 보내는 기기에서 다시 시도하면 이어서 받습니다." : ""
        fail(message + suffix)
    }

    private func sendControlFrames(_ frames: [Data], on connection: NWConnection) async -> Bool {
        for frame in frames {
            let ok: Bool = await withCheckedContinuation { continuation in
                connection.send(content: frame, completion: .contentProcessed { error in
                    continuation.resume(returning: error == nil)
                })
            }
            if !ok { return false }
        }
        return true
    }
}

private final class PhotoTransferCreatedIdentifiersBox: @unchecked Sendable {
    var values: [String] = []
    var reservationPersisted = false
}
