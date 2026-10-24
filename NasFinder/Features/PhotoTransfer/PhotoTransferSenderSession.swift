import Foundation
import CryptoKit
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

/// 송신 완료 화면에 보이는 항목별 결과. 삭제 가능 여부(`eligibility`)와 사유를 함께 담는다.
struct PhotoTransferItemOutcome: Identifiable, Equatable, Sendable {
    let id: String
    let position: Int
    let kind: PhotoTransferMediaKind
    let status: PhotoTransferSenderPlan.Item.Status
    let statusText: String
    /// 받는 기기 출력 무결성 실패(outmissing/outmodified/outunverified)로 일반 재시도에서 제외된 항목의 사유 코드.
    let outputBlockedCode: String?
    var eligibility: PhotoTransferSourceVerifier.Eligibility
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
    /// 항목별 결과(영수증 협상 여부와 무관하게 전송이 끝났을 때 채워진다).
    @Published private(set) var itemOutcomes: [PhotoTransferItemOutcome] = []
    /// 상대 앱이 항목별 저장 확인(receipt-v1)을 협상했는지. false면 원본 삭제를 쓸 수 없다.
    @Published private(set) var receiptsNegotiated = false
    /// 이 QR 비밀이 예전에 평문(v3)으로 보내졌거나 보내려 한 적이 있으면 true. 영수증은 받아도 원본 삭제 자격은 없다.
    @Published private(set) var tokenExposedToLegacy = false
    /// 원본 삭제를 쓸 수 있는 세션: 인증된 v4 영수증이 있고 비밀이 평문에 노출된 적이 없다.
    var deletionEligibleSession: Bool { receiptsNegotiated && !tokenExposedToLegacy }
    /// 사용자가 '새로 보내기'를 골랐을 때, 새 transferId로 다시 보낼 원래 선택 위치(원래 순서). nil이면 선택 전체.
    @Published private(set) var newCopyPositions: [Int]?
    /// 연결·전송·결과 세션이 바뀔 때마다 늘어난다. 화면은 이 값이 바뀌면 삭제 선택을 비운다(이전에 체크한 항목을 이어받지 않는다).
    @Published private(set) var resultEpoch: UInt64 = 0
    private var plan: PhotoTransferSenderPlan?
    private var lastPlanItems: [PhotoTransferSendSource] = []
    private var controlBuffer = PhotoTransferControlFrameBuffer()
    /// v4 핸드셰이크를 먼저 시도하고 거절되면 같은 host:port로 v3 줄을 다시 보낸다(한 번만).
    private var attemptingV4 = false
    private var didFallBackToLegacy = false

    private enum HandshakeStep { case legacyOK, challenge, proofOK }
    private var handshakeStep: HandshakeStep = .legacyOK
    private var handshakeNonceS = ""
    private var handshakeNonceR = ""
    private var handshakeKey: SymmetricKey?
    /// 인증을 통과한 v4 세션에서만 있는 영수증 MAC 키(`Ks`)와 기대 순번.
    private var receiptSessionKey: SymmetricKey?
    private var expectedReceiptSeq = 1

    private enum ReceiptAuthenticationError: LocalizedError {
        case macMismatch
        case unexpectedSequence

        var errorDescription: String? {
            switch self {
            case .macMismatch: "받는 기기의 저장 확인 응답을 인증하지 못했습니다."
            case .unexpectedSequence: "받는 기기의 저장 확인 응답 순서가 올바르지 않습니다."
            }
        }
    }

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
        attemptingV4 = true
        didFallBackToLegacy = false
        openConnection(using: payload)
    }

    /// v4가 거절됐을 때 같은 host:port로 새 연결을 열어 v3 줄로 다시 협상한다. 타임아웃은 이 사유가 아니다.
    private func retryHandshakeWithLegacy(payload: PhotoTransferPairingPayload) {
        // CHALLENGE 이후의 실패는 "미지원"이 아니라 인증 실패이므로 v3로 내리지 않는다.
        guard attemptingV4, handshakeStep == .challenge, !didFallBackToLegacy else {
            fail("받는 기기가 연결 요청을 거절했습니다. QR 코드를 다시 스캔해 주세요.")
            return
        }
        didFallBackToLegacy = true
        attemptingV4 = false
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        responseBuffer.removeAll()
        handshakeStep = .legacyOK
        handshakeKey = nil
        openConnection(using: payload)
    }

    private func openConnection(using payload: PhotoTransferPairingPayload) {
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
        resultEpoch &+= 1
        sendTask?.cancel()
        sendTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel()
        connection = nil
        responseBuffer.removeAll()
        controlBuffer = PhotoTransferControlFrameBuffer()
        sentItemCount = 0
        totalItemCount = 0
        transferProgress = nil
        isSending = false
        transferFinished = false
        itemOutcomes = []
        receiptsNegotiated = false
        tokenExposedToLegacy = false
        attemptingV4 = false
        handshakeStep = .legacyOK
        handshakeKey = nil
        receiptSessionKey = nil
        expectedReceiptSeq = 1
        supportsGroupedTransfer = false
        connectionStage = nil
        lastConnectionErrorDescription = nil
        phase = .idle
    }

    func send(items: [PhotoTransferSendSource]) {
        let kinds = items.map(\.kind)
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
        itemOutcomes = []
        let generation = sessionGeneration
        resultEpoch &+= 1
        plan = Self.requalifiedForNewConnection(makePlan(for: items, kinds: kinds))
        if let restored = plan { PhotoTransferSenderJournal.shared.update(restored) }
        lastPlanItems = items
        let negotiated = receiptsNegotiated

        sendTask = Task { [weak self] in
            guard let self else { return }
            do {
                var skipped = Set<String>()
                if negotiated {
                    skipped = try await self.beginReceiptTransfer(generation: generation)
                }
                // 출력 무결성 실패로 확정된 항목은 같은 transferId에서 다시 스트리밍하지 않는다.
                skipped.formUnion(self.plan?.outputBlockedItems.map(\.itemId) ?? [])
                for (offset, item) in items.enumerated() {
                    try Task.checkCancellation()
                    guard let itemId = self.plan?.items[offset].itemId else { throw CancellationError() }
                    if skipped.contains(itemId) {
                        self.sentItemCount = offset + 1
                        self.transferProgress = Double(offset + 1) / Double(items.count)
                        continue
                    }
                    let prepared = try await item.load(offset + 1, itemId)
                    defer { prepared.removeTemporaryFiles() }
                    guard self.sessionGeneration == generation else { throw CancellationError() }
                    // 삭제 판정에 쓸 기대 해시·원본 스냅샷은 보내기 전에 남긴다(중간에 끊겨도 재시도가 같은 값을 쓴다).
                    self.updatePlan {
                        $0.items[offset].expectedInputs = prepared.inputs
                        $0.items[offset].snapshot = prepared.snapshot
                        $0.items[offset].kindRawValue = prepared.wireKind.rawValue
                    }
                    try await self.sendPreparedItem(prepared)
                    self.sentItemCount = offset + 1
                    self.transferProgress = Double(offset + 1) / Double(items.count)
                }
                guard self.sessionGeneration == generation else { throw CancellationError() }
                try await self.sendData(PhotoTransferWireCodec.completionFrame())
                guard self.sessionGeneration == generation else { throw CancellationError() }
                if negotiated {
                    try await self.finishReceiptTransfer(generation: generation)
                } else if self.supportsGroupedTransfer {
                    let savedCount = try await self.receiveTransferResult()
                    guard self.sessionGeneration == generation else { throw CancellationError() }
                    guard savedCount == items.count else {
                        throw URLError(.cannotParseResponse)
                    }
                    // 개수만 확인하는 기존 ACK는 항목 식별·해시 증명이 없어 삭제 자격이 없다.
                    self.updatePlan { plan in
                        for index in plan.items.indices { plan.items[index].status = .legacyAcknowledged }
                    }
                    if let plan = self.plan { self.itemOutcomes = self.makeOutcomes(from: plan) }
                }
                guard self.sessionGeneration == generation else { throw CancellationError() }
                self.isSending = false
                self.transferFinished = true
                self.sendTask = nil
            } catch is CancellationError {
                // cancel() 이후 도착한 작업 종료는 상태를 다시 바꾸지 않는다.
            } catch {
                guard self.sessionGeneration == generation else { return }
                // 실패해도 지금까지의 항목별 상태는 저널에 남아 다음 시도가 같은 안정 ID로 이어 간다.
                if let plan = self.plan { PhotoTransferSenderJournal.shared.update(plan) }
                self.fail(UserErrorText.message("파일을 보내지 못했습니다", error, recovery: UserErrorText.networkRecovery))
            }
        }
    }

    /// 일반 재시도로 다시 보낼 수 있는(검증되지 않았고 출력 실패로 막히지 않은) 항목 수.
    var retryableItemCount: Int {
        guard let plan else { return 0 }
        return plan.items.filter { $0.status != .verified && !$0.isOutputBlocked }.count
    }

    /// 사용자가 결과 화면에서 명시적으로 '새로 보내기'를 눌렀을 때만 호출한다. 출력 실패로 막힌 항목만 새 transferId로
    /// 다시 보내도록 준비하고(원래 선택 순서 유지), 연결은 처음부터 다시 맺는다. 이전 계획의 검증·삭제 자격은 물려받지 않는다.
    @discardableResult
    func startNewTransferForBlockedItems(items: [PhotoTransferSendSource]) -> Bool {
        guard !isSending, let old = plan, items.count == old.items.count else { return false }
        let positions = old.outputBlockedItems.map(\.position).filter { items.indices.contains($0) }.sorted()
        guard !positions.isEmpty else { return false }
        let subset = positions.map { items[$0] }
        let subsetKinds = subset.map(\.kind)
        let identifiers = subset.map { Optional($0.id) }
        let fresh = PhotoTransferSenderJournal.shared.planForNewTransfer(
            superseding: old.transferId, identifiers: identifiers, kinds: subsetKinds)
        cancel()
        plan = fresh
        lastPlanItems = subset
        newCopyPositions = positions
        return true
    }

    /// 새로 보내기 범위를 해제한다(결과 화면을 닫을 때).
    func clearNewCopyScope() {
        newCopyPositions = nil
    }

    /// 같은 선택이면 이전 계획(안정 transferId·itemId)을 이어 쓴다. 식별자를 모르는 선택은 이 세션 안에서만 이어 쓴다.
    private func makePlan(for items: [PhotoTransferSendSource], kinds: [PhotoTransferMediaKind]) -> PhotoTransferSenderPlan {
        let identifiers = items.map { Optional($0.id) }
        if identifiers.allSatisfy({ $0 != nil }) {
            return PhotoTransferSenderJournal.shared.planForSending(identifiers: identifiers, kinds: kinds)
        }
        if let existing = plan, lastPlanItems.map(\.id) == items.map(\.id), !existing.isFullyVerified { return existing }
        return PhotoTransferSenderPlan.make(identifiers: identifiers, kinds: kinds)
    }

    // MARK: v4 영수증

    private func updatePlan(_ body: (inout PhotoTransferSenderPlan) -> Void) {
        guard var current = plan else { return }
        body(&current)
        plan = current
        PhotoTransferSenderJournal.shared.update(current)
    }

    /// begin을 보내고 ready 영수증을 받아, 이미 저장이 확인된 항목(건너뛸 itemId 집합)을 돌려준다.
    private func beginReceiptTransfer(generation: UInt64) async throws -> Set<String> {
        guard let current = plan else { throw CancellationError() }
        try await sendData(PhotoTransferControlCodec.beginFrame(
            PhotoTransferBeginFrame(transferId: current.transferId, itemCount: current.items.count)))
        let ready = try await receiveReceiptFrame(expecting: current.transferId)
        guard ready.stage == .ready else {
            throw PhotoTransferControlCodec.CodecError.invalidFrame
        }
        try acceptReceiverID(ready.receiverId)
        var frames = [ready]
        while frames.last?.more == true {
            let next = try await receiveReceiptFrame(expecting: current.transferId)
            guard next.stage == .ready, next.receiverId == ready.receiverId else {
                throw PhotoTransferControlCodec.CodecError.invalidFrame
            }
            frames.append(next)
        }
        guard sessionGeneration == generation else { throw CancellationError() }
        var skipped = Set<String>()
        let committed = frames.flatMap(\.items).filter { $0.state == .committed }
        updatePlan { plan in
            for item in committed {
                guard let index = plan.items.firstIndex(where: { $0.itemId == item.itemId }) else { continue }
                // 이미 저장이 확인된 항목은 기대 해시와 정확히 일치할 때만 다시 보내지 않는다.
                if !plan.items[index].expectedInputs.isEmpty,
                   Self.inputsMatch(item.inputs, plan.items[index].expectedInputs) {
                    plan.items[index].status = .verified
                    plan.items[index].reason = nil
                    skipped.insert(item.itemId)
                }
            }
        }
        return skipped
    }

    /// `done` 뒤에 final(또는 error) 영수증을 모두 받아 항목별로 판정한다.
    private func finishReceiptTransfer(generation: UInt64) async throws {
        guard let current = plan else { throw CancellationError() }
        var frames: [PhotoTransferReceiptFrame] = []
        repeat {
            let frame = try await receiveReceiptFrame(expecting: current.transferId)
            guard frame.stage != .ready else { throw PhotoTransferControlCodec.CodecError.invalidFrame }
            try acceptReceiverID(frame.receiverId)
            frames.append(frame)
        } while frames.last?.more == true
        guard sessionGeneration == generation else { throw CancellationError() }
        let received = frames.flatMap(\.items)
        updatePlan { Self.applyFinalReceipt(received, to: &$0) }
        resultEpoch &+= 1
        if let updated = plan { itemOutcomes = makeOutcomes(from: updated) }
    }

    /// 새 연결(또는 저널에서 복원한 계획)은 이전 `.verified`를 삭제 권위로 쓰지 않는다. 모두 `.pending`으로 되돌리고,
    /// 이번 연결의 인증된 ready/final 영수증으로만 다시 자격을 얻는다. 출력 무결성으로 막힌 항목의 실패 판정은 유지한다.
    nonisolated static func requalifiedForNewConnection(_ plan: PhotoTransferSenderPlan) -> PhotoTransferSenderPlan {
        var result = plan
        for index in result.items.indices where result.items[index].status == .verified || result.items[index].status == .legacyAcknowledged {
            result.items[index].status = .pending
            result.items[index].reason = nil
        }
        return result
    }

    /// 최신 인증된 final/error 영수증을 모든 항목의 유일한 권위로 쓴다. 이전 `.verified`도 예외가 아니다.
    /// 영수증에 없거나(누락) 같은 항목이 모순되게 중복되면 fail-closed로 `.unknown`이다. 이번에 보내지 않은 출력 실패 항목은 실패를 유지한다.
    nonisolated static func applyFinalReceipt(_ received: [PhotoTransferReceiptItem], to plan: inout PhotoTransferSenderPlan) {
        for index in plan.items.indices {
            let matches = received.filter { $0.itemId == plan.items[index].itemId }
            if matches.isEmpty {
                if plan.items[index].isOutputBlocked {
                    plan.items[index].status = .failed
                    plan.items[index].reason = plan.items[index].reason ?? reasonText(plan.items[index].blockedReasonCode)
                } else {
                    plan.items[index].status = .unknown
                    plan.items[index].reason = "받는 기기가 이 항목의 결과를 알려 주지 않았습니다."
                }
                continue
            }
            // 실패 보고가 하나라도 있으면 실패가 우선한다. 성공 보고가 둘 이상이면 모두 같은 입력이어야 한다.
            if let failed = matches.first(where: { $0.state == .failed }) {
                plan.items[index].status = .failed
                plan.items[index].reason = reasonText(failed.reason)
                plan.items[index].blockedReasonCode = failed.reason.flatMap { PhotoTransferSenderPlan.outputBlockReasonCodes.contains($0) ? $0 : nil }
                continue
            }
            plan.items[index].blockedReasonCode = nil
            if matches.allSatisfy({ inputsMatch($0.inputs, plan.items[index].expectedInputs) }) {
                plan.items[index].status = .verified
                plan.items[index].reason = nil
            } else {
                plan.items[index].status = .unknown
                plan.items[index].reason = "받는 기기가 확인한 파일 정보가 보낸 파일과 일치하지 않습니다."
            }
        }
    }

    private func acceptReceiverID(_ receiverId: String) throws {
        if let known = plan?.receiverId, known != receiverId {
            // 같은 transferId를 다른 수신 앱 설치에 이어 보내지 않는다.
            throw PhotoTransferControlCodec.CodecError.invalidFrame
        }
        updatePlan { $0.receiverId = receiverId }
    }

    nonisolated static func inputsMatch(_ received: [PhotoTransferReceiptInput], _ expected: [PhotoTransferReceiptInput]) -> Bool {
        !expected.isEmpty && received.count == expected.count && Set(received) == Set(expected)
    }

    nonisolated static func reasonText(_ code: String?) -> String {
        switch code {
        case "checksum": "받는 기기에서 파일 무결성 검증에 실패했습니다."
        case "unsupported": "받는 기기가 지원하지 않는 형식입니다."
        case "storage": "받는 기기에 저장하지 못했습니다."
        case "invalid": "전송된 파일 구성이 올바르지 않았습니다."
        case "conflict": "받는 기기가 이전에 저장이 시작된 이 항목의 결과를 확인하지 못했습니다. 이미 저장돼 있을 수 있어 자동으로 다시 저장하지 않습니다. 필요하면 '새로 보내기'로 새 전송을 시작할 수 있으며, 그러면 받는 기기에 같은 사진이 중복될 수 있습니다."
        case "cancelled": "전송이 취소되었습니다."
        case "outmissing": "받는 기기에 저장됐던 사본이 지금은 없습니다. 사용자가 지웠을 수 있어 자동으로 다시 저장하지 않으며, 원본 삭제 대상이 아닙니다."
        case "outmodified": "받는 기기의 저장된 사본이 바뀌었습니다. 자동으로 덮어쓰거나 다시 저장하지 않으며, 원본 삭제 대상이 아닙니다."
        case "outunverified": "받는 기기에서 저장은 됐을 수 있지만 사진 보관함 읽기 권한이 없는 등으로 사본을 확인하지 못했습니다. 자동으로 다시 저장하지 않으며, 원본 삭제 대상이 아닙니다."
        default: "받는 기기에서 알 수 없는 오류가 발생했습니다."
        }
    }

    /// 계획을 완료 화면용 항목 결과로 바꾼다. 삭제 후보 여부는 영수증 협상 여부까지 반영한 1차 판정이다.
    private func makeOutcomes(from plan: PhotoTransferSenderPlan) -> [PhotoTransferItemOutcome] {
        plan.items.map { item in
            let statusText: String = switch item.status {
            case .verified: "받는 기기 저장 확인됨"
            case .failed: item.reason ?? "저장 실패"
            case .unknown: item.reason ?? "저장 여부를 확인하지 못함"
            case .legacyAcknowledged: "개수만 확인됨(항목별 확인 불가)"
            case .pending: "보내지 못함"
            }
            return PhotoTransferItemOutcome(
                id: item.itemId, position: item.position,
                kind: PhotoTransferMediaKind(rawValue: item.kindRawValue) ?? .unknown,
                status: item.status, statusText: statusText,
                outputBlockedCode: item.isOutputBlocked ? item.blockedReasonCode : nil,
                eligibility: PhotoTransferSourceVerifier.preliminaryEligibility(of: item, receiptsNegotiated: deletionEligibleSession, tokenExposed: tokenExposedToLegacy))
        }
    }

    // MARK: 완료 뒤 원본 삭제(선택)

    /// 삭제 직전에 원본을 다시 읽어 검증하고, 통과한 항목만 시스템 삭제 확인을 거쳐 지운다.
    /// - Returns: 삭제한 itemId, 제외된 itemId와 사유.
    func deleteSourceOriginals(itemIDs: [String]) async -> (deleted: [String], excluded: [String: String], failure: String?) {
        // 이번 연결의 final 영수증으로 판정을 마친 세션에서만 삭제를 시도한다(저널에서 복원한 이전 상태는 권위가 아니다).
        guard deletionEligibleSession, transferFinished, !isSending, let plan else {
            let reason = tokenExposedToLegacy ? PhotoTransferSourceVerifier.tokenExposedReason : "항목별 저장 확인이 없어 삭제할 수 없습니다."
            return ([], Dictionary(uniqueKeysWithValues: itemIDs.map { ($0, reason) }), nil)
        }
        var excluded: [String: String] = [:]
        var candidates: [(String, PHAsset)] = []
        for id in itemIDs {
            guard let item = plan.items.first(where: { $0.itemId == id }) else { continue }
            let preliminary = PhotoTransferSourceVerifier.preliminaryEligibility(of: item, receiptsNegotiated: true, tokenExposed: false)
            if case let .excluded(reason) = preliminary { excluded[id] = reason; continue }
            let result = await PhotoTransferSourceVerifier.revalidate(item)
            if case let .excluded(reason) = result.eligibility { excluded[id] = reason }
            else if let asset = result.asset { candidates.append((id, asset)) }
        }
        // OS 삭제 동의를 요청하기 직전에 자산 전체 자원 구성을 한 번 더 점검한다(해시 계산 동안 바뀔 수 있다).
        var finalCandidates: [(String, PHAsset)] = []
        for (id, asset) in candidates {
            guard let item = plan.items.first(where: { $0.itemId == id }) else { continue }
            if case let .excluded(reason) = PhotoTransferSourceVerifier.recheckBeforeDelete(item, asset: asset) {
                excluded[id] = reason
            } else {
                finalCandidates.append((id, asset))
            }
        }
        guard !finalCandidates.isEmpty else { return ([], excluded, nil) }
        do {
            try await PhotoTransferSourceVerifier.delete(finalCandidates.map(\.1))
            return (finalCandidates.map(\.0), excluded, nil)
        } catch {
            let message = PhotoTransferSourceVerifier.isUserDeclined(error)
                ? "삭제를 허용하지 않아 원본을 그대로 두었습니다."
                : UserErrorText.message("원본을 삭제하지 못했습니다", error, recovery: "원본은 그대로 남아 있습니다.")
            return ([], excluded, message)
        }
    }

    /// 삭제가 끝났거나 모두 확인된 전송 기록을 정리한다. 일부만 확인된 기록은 재시도를 위해 남긴다.
    func discardFullyVerifiedPlan() {
        guard let plan, plan.isFullyVerified else { return }
        PhotoTransferSenderJournal.shared.remove(transferId: plan.transferId)
        self.plan = nil
    }

    /// 삭제한 항목은 이후 목록에서 제외 사유를 바꿔 보인다.
    func markDeleted(itemIDs: [String]) {
        itemOutcomes = itemOutcomes.map { outcome in
            var updated = outcome
            if itemIDs.contains(outcome.id) { updated.eligibility = .excluded("원본을 삭제했습니다.") }
            return updated
        }
    }

    private func receiveReceiptFrame(expecting transferId: String) async throws -> PhotoTransferReceiptFrame {
        guard let connection else { throw URLError(.networkConnectionLost) }
        let generation = sessionGeneration
        let frame: PhotoTransferReceiptFrame = try await performBoundedOperation(
            timeoutError: .resultAcknowledgement
        ) { finish in
            pumpReceiptFrame(on: connection, generation: generation, finish: finish)
        }
        guard Self.isCurrentAttempt(
            callbackGeneration: generation,
            currentGeneration: sessionGeneration,
            connectionMatches: self.connection === connection
        ) else { throw CancellationError() }
        guard frame.transferId == transferId else { throw PhotoTransferControlCodec.CodecError.invalidFrame }
        // 신뢰하기 전에 MAC(상수 시간)과 순번을 확인한다. 하나라도 어긋나면 연결을 중단하고 내용을 쓰지 않는다.
        guard let key = receiptSessionKey, PhotoTransferControlCodec.verifyMAC(of: frame, key: key) else {
            throw ReceiptAuthenticationError.macMismatch
        }
        guard frame.seq == expectedReceiptSeq else { throw ReceiptAuthenticationError.unexpectedSequence }
        expectedReceiptSeq += 1
        return frame
    }

    private func pumpReceiptFrame(
        on connection: NWConnection,
        generation: UInt64,
        finish: @escaping @Sendable (Result<PhotoTransferReceiptFrame, Error>) -> Void
    ) {
        do {
            if let json = try controlBuffer.nextJSON() {
                guard let object = PhotoTransferControlCodec.jsonObject(json),
                      let frame = PhotoTransferControlCodec.decodeReceipt(object) else {
                    finish(.failure(PhotoTransferControlCodec.CodecError.invalidFrame))
                    return
                }
                finish(.success(frame))
                return
            }
        } catch {
            finish(.failure(error))
            return
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
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
                let received = data ?? Data()
                self.controlBuffer.append(received)
                if received.isEmpty, isComplete {
                    finish(.failure(URLError(.networkConnectionLost)))
                } else {
                    self.pumpReceiptFrame(on: connection, generation: generation, finish: finish)
                }
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
            lastConnectionErrorDescription = UserErrorText.koreanDetail(error)
        case .failed(let error):
            if transferFinished {
                self.connection = nil
            } else if case .connecting(let handshakePayload) = phase, attemptingV4, handshakeStep == .challenge,
                      connectionStage == .handshakeResponse, responseBuffer.isEmpty {
                retryHandshakeWithLegacy(payload: handshakePayload)
            } else if case .connected = phase {
                fail(UserErrorText.message("받는 기기와의 연결이 끊어졌습니다", error, recovery: UserErrorText.networkRecovery))
            } else {
                fail(UserErrorText.message("연결하지 못했습니다", error, recovery: UserErrorText.networkRecovery))
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
        let line: String
        if attemptingV4 {
            handshakeStep = .challenge
            handshakeNonceS = PhotoTransferV4Handshake.makeNonce()
            handshakeKey = PhotoTransferV4Handshake.handshakeKey(token: payload.token)
            line = PhotoTransferV4Handshake.helloLine(platform: .ios, nonceS: handshakeNonceS)
        } else {
            handshakeStep = .legacyOK
            // 평문 바이트를 보내려는 시점에 먼저 표시한다(ACK 성공 여부와 무관, 재시도·재시작 뒤에도 유지).
            // 지문이 디스크에 남지 않으면 재시작 뒤 이 QR이 v4 삭제 자격을 되찾을 수 있으므로 평문을 보내지 않는다(fail closed).
            guard PhotoTransferTokenTaintStore.shared.markTainted(token: payload.token) else {
                fail("이 기기에서 연결 기록을 안전하게 저장하지 못해 예전 방식 연결을 시작하지 않았습니다. 받는 기기에서 새 QR 코드를 만들어 다시 시도해 주세요.")
                return
            }
            tokenExposedToLegacy = true
            line = PhotoTransferHandshake.clientLine(token: payload.token, sourcePlatform: .ios)
        }
        sendHandshakeLine(line, on: connection, payload: payload, generation: generation)
    }

    private func sendHandshakeLine(
        _ line: String,
        on connection: NWConnection,
        payload: PhotoTransferPairingPayload,
        generation: UInt64
    ) {
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
                        self.fail(UserErrorText.message("연결 요청을 보내지 못했습니다", error, recovery: UserErrorText.networkRecovery))
                    } else {
                        self.receiveResponseChunk(on: connection, payload: payload)
                    }
                }
            }
        )
    }

    private func receiveResponseChunk(on connection: NWConnection, payload: PhotoTransferPairingPayload) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: PhotoTransferV4Handshake.maximumOKLength) { [weak self] data, _, isComplete, error in
            Task { @MainActor in
                self?.handleResponseChunk(data, isComplete: isComplete, error: error, on: connection, payload: payload)
            }
        }
    }

    private var handshakeLineLimit: Int {
        switch handshakeStep {
        case .legacyOK: 64
        case .challenge: PhotoTransferV4Handshake.maximumChallengeLength
        case .proofOK: PhotoTransferV4Handshake.maximumOKLength
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
        let generation = sessionGeneration

        if let data, !data.isEmpty {
            responseBuffer.append(data)
        }
        if let error {
            // 응답이 전혀 없던 연결 reset은 v4를 모르는 상대일 수 있다. 한 번만 v3로 다시 협상한다.
            if attemptingV4, handshakeStep == .challenge, responseBuffer.isEmpty { retryHandshakeWithLegacy(payload: payload) }
            else { fail(UserErrorText.message("응답을 받지 못했습니다", error, recovery: UserErrorText.networkRecovery)) }
            return
        }

        if let newline = responseBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = String(decoding: responseBuffer[responseBuffer.startIndex..<newline], as: UTF8.self)
            let trailing = responseBuffer[responseBuffer.index(after: newline)...]
            responseBuffer.removeAll()
            guard trailing.isEmpty else {
                fail("받는 기기의 응답 형식이 올바르지 않습니다.")
                return
            }
            switch handshakeStep {
            case .legacyOK:
                if let peer = PhotoTransferHandshake.acceptedPeer(fromResponse: line + "\n") {
                    timeoutTask?.cancel()
                    timeoutTask = nil
                    supportsGroupedTransfer = peer.supportsGroupedTransfer
                    receiptsNegotiated = false
                    attemptingV4 = false
                    connectionStage = nil
                    phase = .connected(payload, peer.platform)
                } else {
                    fail("받는 기기가 연결 요청을 거절했습니다. QR 코드를 다시 스캔해 주세요.")
                }
            case .challenge:
                if line == "ERROR tainted" {
                    // 상대가 이 QR의 비밀을 이미 노출된 것으로 본다. v3로 내려가지 않는다.
                    fail("이 QR 코드는 이미 사용되어 더 이상 안전하지 않습니다. 받는 기기에서 새 QR 코드를 만들어 다시 스캔해 주세요.")
                } else if line == "ERROR" {
                    // v4를 모르는 상대(또는 hello 거부): 같은 host:port로 v3 줄을 다시 보낸다.
                    retryHandshakeWithLegacy(payload: payload)
                } else if let nonceR = PhotoTransferV4Handshake.parseChallenge(line), let key = handshakeKey {
                    handshakeNonceR = nonceR
                    handshakeStep = .proofOK
                    let proof = PhotoTransferV4Handshake.senderProof(
                        key: key, platformS: .ios, nonceS: handshakeNonceS, nonceR: nonceR)
                    // PROOF 응답도 같은 단계 타임아웃 안에서 기다린다.
                    startTimeout(.handshakeResponse, duration: Self.timeoutDuration(for: .handshakeResponse),
                                 connection: connection, generation: generation)
                    sendHandshakeLine(PhotoTransferV4Handshake.proofLine(proof), on: connection, payload: payload, generation: generation)
                } else {
                    fail("받는 기기의 응답 형식이 올바르지 않습니다.")
                }
            case .proofOK:
                guard let ok = PhotoTransferV4Handshake.parseOK(line), let key = handshakeKey,
                      PhotoTransferV4Handshake.verifyReceiverProof(
                          ok.proof, key: key, platformR: ok.platform, nonceS: handshakeNonceS, nonceR: handshakeNonceR)
                else {
                    // 인증 실패는 "미지원"이 아니다. 조용히 v3로 내려가지 않고 실패로 알린다.
                    fail("상대 기기를 확인하지 못했습니다. QR 코드를 다시 스캔해 주세요.")
                    return
                }
                timeoutTask?.cancel()
                timeoutTask = nil
                receiptSessionKey = PhotoTransferV4Handshake.sessionKey(
                    key: key, nonceS: handshakeNonceS, nonceR: handshakeNonceR)
                expectedReceiptSeq = 1
                supportsGroupedTransfer = true
                receiptsNegotiated = true
                // 같은 비밀이 예전에 평문으로 나간 적이 있으면 이 v4 세션도 삭제 자격이 없다(재키·승격 없음).
                tokenExposedToLegacy = PhotoTransferTokenTaintStore.shared.isTainted(token: payload.token)
                attemptingV4 = false
                handshakeKey = nil
                connectionStage = nil
                phase = .connected(payload, ok.platform)
            }
        } else if isComplete, attemptingV4, handshakeStep == .challenge, responseBuffer.isEmpty {
            // hello에 아무 응답 없이 닫힘: v4를 모르는 상대.
            retryHandshakeWithLegacy(payload: payload)
        } else if isComplete || responseBuffer.count >= handshakeLineLimit {
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
                ) + " " + UserErrorText.networkRecovery
            )
        }
    }
}
