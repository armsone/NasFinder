import CryptoKit
import Foundation
import Photos

/// 발신 로컬에서만 쓰는 원본 신원 스냅샷. 와이어에는 절대 싣지 않는다(PHAsset 식별자는 이 기기 밖으로 나가지 않는다).
struct PhotoTransferSourceSnapshot: Codable, Equatable, Sendable {
    struct ResourceDescriptor: Codable, Equatable, Sendable {
        let typeRawValue: Int
        let originalFilename: String
        let uniformTypeIdentifier: String
    }

    /// 사용자가 PhotosPicker로 고른 정확한 PHAsset의 `localIdentifier`.
    let assetLocalIdentifier: String
    let creationDate: Date?
    let modificationDate: Date?
    /// 전송한 구성요소와 같은 순서(index 0, 1)의 PHAssetResource 서술자.
    let resources: [ResourceDescriptor]
    /// 전송 시점에 이 PHAsset이 가진 모든 자원의 타입(`PHAssetResourceType.rawValue`). 없으면(이전 버전 기록) 삭제 대상에서 제외한다.
    /// 전송한 자원이 자산 전체 자원과 정확히 같은 단순 원본 구성일 때만 삭제 자격이 있다.
    var allResourceTypeRawValues: [Int]? = nil
}

/// 한 번의 전송 시도 묶음 계획. `transferId`와 항목별 `itemId`는 재시도·재연결 동안 바뀌지 않는다.
struct PhotoTransferSenderPlan: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        enum Status: String, Codable, Sendable {
            /// 아직 보내지 않았거나 영수증을 받지 못했다.
            case pending
            /// 수신이 committed로 보고했고 입력 해시가 기대값과 정확히 일치한다.
            case verified
            /// 수신이 실패를 보고했다.
            case failed
            /// 영수증이 없거나 해시가 맞지 않아 저장 여부를 확신할 수 없다.
            case unknown
            /// 영수증을 지원하지 않는 상대(count-only ACK)가 개수만 확인했다. 삭제 자격이 없다.
            case legacyAcknowledged
        }

        let itemId: String
        let position: Int
        /// PhotosPicker가 준 식별자. 와이어에는 싣지 않는다.
        let pickerIdentifier: String?
        var kindRawValue: String
        var expectedInputs: [PhotoTransferReceiptInput]
        var snapshot: PhotoTransferSourceSnapshot?
        var status: Status
        var reason: String?
        /// 인증된 영수증이 `failed`로 보고한 출력 무결성 사유 코드(outmissing/outmodified/outunverified).
        /// 있으면 같은 transferId의 자동 재연결·일반 재시도는 이 항목을 다시 보내지 않는다(사용자 사본을 되살리지 않는다).
        var blockedReasonCode: String?

        var isOutputBlocked: Bool {
            guard let blockedReasonCode else { return false }
            return PhotoTransferSenderPlan.outputBlockReasonCodes.contains(blockedReasonCode)
        }
    }

    /// `conflict`는 수신이 이전 저장 여부를 확정하지 못한 예약(크래시 뒤 미해소)으로, 같은 transferId로 자동 재전송하지 않는다.
    static let outputBlockReasonCodes: Set<String> = ["outmissing", "outmodified", "outunverified", "conflict"]

    let transferId: String
    /// 고른 항목 식별자를 모두 알 때만 있다. 같은 선택으로 재시도할 때 계획을 이어 쓰는 열쇠.
    let selectionKey: String?
    var receiverId: String?
    var items: [Item]
    var updatedAt: Date
    /// 사용자가 명시적으로 '새로 보내기'를 골라 이 계획 대신 새 transferId가 생겼을 때 그 ID. 이 계획은 더 이어 쓰지 않는다.
    var supersededBy: String?

    static func selectionKey(for identifiers: [String?]) -> String? {
        guard !identifiers.isEmpty, identifiers.allSatisfy({ $0 != nil }) else { return nil }
        var hasher = SHA256()
        for identifier in identifiers.compactMap({ $0 }) { hasher.update(data: Data((identifier + "\n").utf8)) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func make(identifiers: [String?], kinds: [PhotoTransferMediaKind]) -> PhotoTransferSenderPlan {
        PhotoTransferSenderPlan(
            transferId: PhotoTransferReceiptWire.makeTransferID(),
            selectionKey: selectionKey(for: identifiers),
            receiverId: nil,
            items: identifiers.enumerated().map { offset, identifier in
                Item(itemId: PhotoTransferReceiptWire.makeItemID(), position: offset, pickerIdentifier: identifier,
                     kindRawValue: (kinds.indices.contains(offset) ? kinds[offset] : .unknown).rawValue,
                     expectedInputs: [], snapshot: nil, status: .pending, reason: nil)
            },
            updatedAt: Date())
    }

    var isFullyVerified: Bool { !items.isEmpty && items.allSatisfy { $0.status == .verified } }

    /// 일반 재시도에서 제외되는 출력 무결성 실패 항목.
    var outputBlockedItems: [Item] { items.filter { $0.status != .verified && $0.isOutputBlocked } }
}

/// 발신 계획을 앱 재시작 뒤에도 이어 쓰도록 남기는 작은 저널(원자적 교체 쓰기).
/// 안정 ID가 있어야 수신이 같은 항목의 재전송을 멱등하게 처리할 수 있다.
final class PhotoTransferSenderJournal: @unchecked Sendable {
    static let shared = PhotoTransferSenderJournal()
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    private let lock = NSLock()
    private let fileURL: URL
    private var plans: [PhotoTransferSenderPlan]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTransferSender", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("plans.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = Self.decode(data) {
            plans = decoded
        } else {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = base.appendingPathComponent("plans.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            plans = []
        }
    }

    /// 같은 선택으로 아직 모두 검증되지 않은 계획이 있으면 그것을, 아니면 새 계획을 만들어 저장한다.
    func planForSending(identifiers: [String?], kinds: [PhotoTransferMediaKind]) -> PhotoTransferSenderPlan {
        withLock {
            let key = PhotoTransferSenderPlan.selectionKey(for: identifiers)
            if let key, let existing = plans.first(where: { $0.selectionKey == key && $0.supersededBy == nil && !$0.isFullyVerified && $0.items.count == identifiers.count }) {
                return existing
            }
            let plan = PhotoTransferSenderPlan.make(identifiers: identifiers, kinds: kinds)
            plans.append(plan)
            persistLocked()
            return plan
        }
    }

    /// 사용자가 명시적으로 '새로 보내기'를 골랐을 때만 호출한다. 새 transferId·itemId의 계획을 만들고 이전 계획은
    /// 지우지 않은 채 대체됨으로만 표시한다(이전 영수증·검증 상태·원본은 건드리지 않고, 새 계획은 어떤 검증도 물려받지 않는다).
    func planForNewTransfer(superseding oldTransferId: String, identifiers: [String?], kinds: [PhotoTransferMediaKind]) -> PhotoTransferSenderPlan {
        withLock {
            var fresh = PhotoTransferSenderPlan.make(identifiers: identifiers, kinds: kinds)
            while fresh.transferId == oldTransferId { fresh = PhotoTransferSenderPlan.make(identifiers: identifiers, kinds: kinds) }
            if let index = plans.firstIndex(where: { $0.transferId == oldTransferId }) {
                plans[index].supersededBy = fresh.transferId
            }
            if fresh.selectionKey != nil { plans.append(fresh) }
            persistLocked()
            return fresh
        }
    }

    func plan(transferId: String) -> PhotoTransferSenderPlan? {
        withLock { plans.first { $0.transferId == transferId } }
    }

    func update(_ plan: PhotoTransferSenderPlan) {
        withLock {
            var updated = plan
            updated.updatedAt = Date()
            if let index = plans.firstIndex(where: { $0.transferId == plan.transferId }) { plans[index] = updated }
            else { plans.append(updated) }
            persistLocked()
        }
    }

    /// 사용자가 전송 기록을 정리했거나 삭제 단계를 마쳤을 때.
    func remove(transferId: String) {
        withLock {
            plans.removeAll { $0.transferId == transferId }
            persistLocked()
        }
    }

    func expireOldPlans(now: Date = Date()) {
        withLock {
            let before = plans.count
            plans.removeAll { now.timeIntervalSince($0.updatedAt) > Self.retention }
            if plans.count != before { persistLocked() }
        }
    }

    private func persistLocked() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(plans) else { return }
        try? data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private static func decode(_ data: Data) -> [PhotoTransferSenderPlan]? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([PhotoTransferSenderPlan].self, from: data)
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
