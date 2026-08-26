@preconcurrency import AVFoundation
import Foundation
import ImageIO
import Network
import Photos
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
    @Published private(set) var currentFileName: String?
    @Published private(set) var transferProgress: Double?
    @Published private(set) var transferFinished = false
    @Published private(set) var receivedResults: [ReceivedMediaResult] = []

    private var listener: NWListener?
    private var activeToken: String?
    private var pendingConnections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private var acceptedConnection: NWConnection?
    private var connectedPeerPlatform: PhotoTransferPeerPlatform = .unknown
    private var supportsGroupedTransfer = false
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
            phase = .failed("수신 대기를 시작하지 못했습니다: \(error.localizedDescription)")
            return
        }

        var generatedToken = PhotoTransferPairingPayload.makeToken()
        while generatedToken == invalidatedToken {
            generatedToken = PhotoTransferPairingPayload.makeToken()
        }
        let token = generatedToken
        activeToken = token
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
        wireDecoder.reset()
        wireDecoder = PhotoTransferStreamingWireDecoder()
        removeStagedComponents()
        receivedFileCount = 0
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
            fail("수신 대기 중 오류가 발생했습니다: \(error.localizedDescription)")
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
                    fail("보내는 기기와의 연결이 끊어졌습니다: \(error.localizedDescription)")
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
            respond(toClientLine: line, on: connection)
        } else if isComplete {
            discard(connection)
        } else if buffer.count >= PhotoTransferHandshake.maximumLineLength {
            receiveBuffers[key] = nil
            send(PhotoTransferHandshake.rejectResponse, accepted: false, on: connection)
        } else {
            receiveNextChunk(on: connection)
        }
    }

    private func respond(toClientLine line: String, on connection: NWConnection) {
        let decision: PhotoTransferHandshake.Decision
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
                        self.fail("연결 응답을 보내지 못했습니다: \(error.localizedDescription)")
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
        supportsGroupedTransfer: Bool
    ) {
        activeToken = nil
        acceptedConnection = connection
        connectedPeerPlatform = peerPlatform
        self.supportsGroupedTransfer = supportsGroupedTransfer
        pendingConnections[ObjectIdentifier(connection)] = nil
        for other in pendingConnections.values {
            other.cancel()
        }
        pendingConnections.removeAll()
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
        if let error {
            fail("파일 수신 중 오류가 발생했습니다: \(error.localizedDescription)")
            return
        }

        do {
            if let data, !data.isEmpty {
                let events = try wireDecoder.append(data)
                updateTransferProgress()
                for (eventIndex, event) in events.enumerated() {
                    do {
                        switch event {
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
                                        self?.fail("받은 항목을 사진 보관함에 저장하지 못했습니다: \(error.localizedDescription)")
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
            fail("받은 파일을 저장하지 못했습니다: \(error.localizedDescription)")
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

    private enum PhotoLibrarySaveError: LocalizedError {
        case accessDenied
        case unsupportedMotionContainer

        var errorDescription: String? {
            switch self {
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
            PHPhotoLibrary.shared().performChanges {
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

        init(
            header: PhotoTransferWireHeader,
            fileURL: URL,
            resourceType: PHAssetResourceType,
            originalFilename: String? = nil
        ) {
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
                        originalFilename: converted.imageURL.lastPathComponent
                    ),
                    .init(
                        header: video.header,
                        fileURL: converted.pairedVideoURL,
                        resourceType: .pairedVideo,
                        originalFilename: converted.pairedVideoURL.lastPathComponent
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
        receiveBuffers[key] = nil
        pendingConnections[key] = nil
        connection.cancel()
    }
}

private final class PhotoTransferCreatedIdentifiersBox: @unchecked Sendable {
    var values: [String] = []
}
