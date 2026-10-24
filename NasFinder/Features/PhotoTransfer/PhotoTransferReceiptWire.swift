import CryptoKit
import Foundation

/// v4(`NASFINDER_PHOTO/4 hello … receipt-v1`)의 begin/인증된 영수증 프레임.
/// 계약: `shared-contract/transfer-wire-contract.md` 개정 2(Android 단일 writer). 문법·한도·키 집합·canonical MAC은 그 문서와 같아야 한다.
/// 파일 헤더 키 집합과 v3 핸드셰이크·`RESULT OK n` ACK는 건드리지 않는다.
enum PhotoTransferReceiptWire {
    static let capability = "receipt-v1"
    static let maximumFrameLength = 65_536
    static let maximumItemsPerFrame = 128
    static let itemCountRange = 1...10_000
    /// 이 앱 수신이 내보내는 사유 코드. 상대가 보내는 사유는 `isValidReason` 문법만 검사한다(자르거나 바꾸지 않는다).
    static let reasonCodes: Set<String> = ["checksum", "unsupported", "storage", "invalid", "conflict", "cancelled", "unknown",
                                          "outmissing", "outmodified", "outunverified"]

    static func isValidNonce(_ value: String) -> Bool { matches(value, length: 22...43) }
    static func isValidTransferID(_ value: String) -> Bool { matches(value, length: 22...64) }
    static func isValidReceiverID(_ value: String) -> Bool { matches(value, length: 22...64) }
    static func isValidItemID(_ value: String) -> Bool { matches(value, length: 1...64) }
    /// 계약 §2.2: `^[A-Za-z0-9_]{1,16}$`. `-`와 빈 문자열은 사유가 아니다(canonical의 `-`는 사유 없음 표시).
    static func isValidReason(_ value: String) -> Bool {
        matches(value, length: 1...16) && !value.utf8.contains(0x2D)
    }

    private static func matches(_ value: String, length: ClosedRange<Int>) -> Bool {
        guard length.contains(value.utf8.count) else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
                || (byte >= 0x61 && byte <= 0x7A) || byte == 0x2D || byte == 0x5F
        }
    }

    /// 새 전송 시도 묶음 ID. UUID 문자열(36자, 하이픈 포함)은 계약 허용 범위다.
    static func makeTransferID() -> String { UUID().uuidString }
    static func makeItemID() -> String { UUID().uuidString }
}

struct PhotoTransferBeginFrame: Equatable, Sendable {
    let transferId: String
    let itemCount: Int
}

struct PhotoTransferReceiptInput: Equatable, Hashable, Codable, Sendable {
    let index: Int
    let sha256: String
}

/// 수신 측 자산 식별자(PHAsset.localIdentifier 등)는 와이어에 없다(계약 개정 2). 수신 로컬 저널에만 둔다.
struct PhotoTransferReceiptItem: Equatable, Sendable {
    enum State: String, Sendable { case committed, failed }

    let itemId: String
    let state: State
    let inputs: [PhotoTransferReceiptInput]
    let reason: String?
}

struct PhotoTransferReceiptFrame: Equatable, Sendable {
    enum Stage: String, Sendable { case ready, final, error }
    enum Status: String, Sendable { case complete, partial, failed }

    let stage: Stage
    let transferId: String
    let receiverId: String
    let status: Status?
    let more: Bool
    /// 세션 안에서 수신이 보낸 영수증 프레임 순번(1부터 1씩).
    let seq: Int
    let items: [PhotoTransferReceiptItem]
    /// `hex(HMAC-SHA256(Ks, canonical))`. 소문자 hex 64자.
    let mac: String
}

/// 길이 접두(4바이트 big-endian) + UTF-8 JSON 제어 프레임의 인코더와 엄격한 디코더.
enum PhotoTransferControlCodec {
    enum CodecError: LocalizedError, Equatable {
        case frameTooLarge
        case invalidFrame

        var errorDescription: String? {
            switch self {
            case .frameTooLarge: "전송 제어 프레임이 허용 크기를 넘었습니다."
            case .invalidFrame: "전송 제어 프레임 형식이 올바르지 않습니다."
            }
        }
    }

    // MARK: 인코딩

    static func beginFrame(_ begin: PhotoTransferBeginFrame) throws -> Data {
        guard PhotoTransferReceiptWire.isValidTransferID(begin.transferId),
              PhotoTransferReceiptWire.itemCountRange.contains(begin.itemCount) else { throw CodecError.invalidFrame }
        return try frame(["begin": true, "transferId": begin.transferId, "itemCount": begin.itemCount])
    }

    /// 한 프레임에는 항목 128개까지만 싣는다. 더 많으면 나누며 프레임마다 `seq`가 1씩 늘고 MAC이 붙는다.
    /// - Returns: 전송할 프레임들과 다음 `seq`.
    static func receiptFrames(
        stage: PhotoTransferReceiptFrame.Stage,
        transferId: String,
        receiverId: String,
        status: PhotoTransferReceiptFrame.Status?,
        items: [PhotoTransferReceiptItem],
        sessionKey: SymmetricKey,
        startingSeq: Int
    ) throws -> (frames: [Data], nextSeq: Int) {
        guard PhotoTransferReceiptWire.isValidTransferID(transferId),
              PhotoTransferReceiptWire.isValidReceiverID(receiverId), startingSeq >= 1 else { throw CodecError.invalidFrame }
        let perFrame = PhotoTransferReceiptWire.maximumItemsPerFrame
        let chunks = stride(from: 0, to: max(items.count, 1), by: perFrame).map {
            Array(items[min($0, items.count)..<min($0 + perFrame, items.count)])
        }
        var seq = startingSeq
        var frames: [Data] = []
        for (offset, chunk) in chunks.enumerated() {
            let more = offset < chunks.count - 1
            let mac = receiptMAC(stage: stage, transferId: transferId, receiverId: receiverId, status: status,
                                 more: more, seq: seq, items: chunk, key: sessionKey)
            var object: [String: Any] = [
                "receipt": true, "stage": stage.rawValue, "transferId": transferId, "receiverId": receiverId,
                "more": more, "seq": seq, "items": chunk.map(itemObject), "mac": mac,
            ]
            if let status { object["status"] = status.rawValue }
            frames.append(try frame(object))
            seq += 1
        }
        return (frames, seq)
    }

    private static func itemObject(_ item: PhotoTransferReceiptItem) -> [String: Any] {
        var object: [String: Any] = ["itemId": item.itemId, "state": item.state.rawValue]
        if !item.inputs.isEmpty {
            object["inputs"] = item.inputs.map { ["index": $0.index, "sha256": $0.sha256] as [String: Any] }
        }
        if let reason = item.reason { object["reason"] = reason }
        return object
    }

    // MARK: MAC(계약 §2.2)

    /// canonical 문자열: 줄바꿈으로 나눈 `receipt, stage, transferId, receiverId, status|-, more, seq` 다음에
    /// 항목마다 `itemId|state|index:sha256,…(index 오름차순)|reason|-` 한 줄(itemId 오름차순). 끝에 추가 줄바꿈 없음.
    static func canonicalReceipt(
        stage: PhotoTransferReceiptFrame.Stage,
        transferId: String,
        receiverId: String,
        status: PhotoTransferReceiptFrame.Status?,
        more: Bool,
        seq: Int,
        items: [PhotoTransferReceiptItem]
    ) -> String {
        var lines = ["receipt", stage.rawValue, transferId, receiverId, status?.rawValue ?? "-", more ? "true" : "false", String(seq)]
        let sorted = items.sorted { Array($0.itemId.utf8).lexicographicallyPrecedes(Array($1.itemId.utf8)) }
        for item in sorted {
            let inputs = item.inputs.sorted { $0.index < $1.index }.map { "\($0.index):\($0.sha256)" }.joined(separator: ",")
            lines.append("\(item.itemId)|\(item.state.rawValue)|\(inputs)|\(item.reason ?? "-")")
        }
        return lines.joined(separator: "\n")
    }

    static func receiptMAC(
        stage: PhotoTransferReceiptFrame.Stage, transferId: String, receiverId: String,
        status: PhotoTransferReceiptFrame.Status?, more: Bool, seq: Int,
        items: [PhotoTransferReceiptItem], key: SymmetricKey
    ) -> String {
        let canonical = canonicalReceipt(stage: stage, transferId: transferId, receiverId: receiverId,
                                         status: status, more: more, seq: seq, items: items)
        return PhotoTransferV4Handshake.hex(Data(HMAC<SHA256>.authenticationCode(for: Data(canonical.utf8), using: key)))
    }

    /// 상수 시간 MAC 검증. 통과한 프레임만 신뢰한다.
    static func verifyMAC(of frame: PhotoTransferReceiptFrame, key: SymmetricKey) -> Bool {
        guard let expected = PhotoTransferV4Handshake.data(fromHex: frame.mac), expected.count == 32 else { return false }
        let canonical = canonicalReceipt(stage: frame.stage, transferId: frame.transferId, receiverId: frame.receiverId,
                                         status: frame.status, more: frame.more, seq: frame.seq, items: frame.items)
        return HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: Data(canonical.utf8), using: key)
    }

    private static func frame(_ object: [String: Any]) throws -> Data {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard !json.isEmpty, json.count <= PhotoTransferReceiptWire.maximumFrameLength else { throw CodecError.frameTooLarge }
        var length = UInt32(json.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(json)
        return result
    }

    // MARK: 디코딩(키 집합 엄격)

    static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    static func isBeginObject(_ object: [String: Any]) -> Bool { object["begin"] != nil }
    static func isReceiptObject(_ object: [String: Any]) -> Bool { object["receipt"] != nil }

    static func decodeBegin(_ object: [String: Any]) -> PhotoTransferBeginFrame? {
        guard Set(object.keys) == ["begin", "transferId", "itemCount"],
              boolValue(object["begin"]) == true,
              let transferId = object["transferId"] as? String,
              PhotoTransferReceiptWire.isValidTransferID(transferId),
              let count = intValue(object["itemCount"]),
              PhotoTransferReceiptWire.itemCountRange.contains(count) else { return nil }
        return PhotoTransferBeginFrame(transferId: transferId, itemCount: count)
    }

    static func decodeReceipt(_ object: [String: Any]) -> PhotoTransferReceiptFrame? {
        let required: Set<String> = ["receipt", "stage", "transferId", "receiverId", "more", "seq", "items", "mac"]
        let allowed = required.union(["status"])
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: allowed),
              boolValue(object["receipt"]) == true,
              let stageText = object["stage"] as? String, let stage = PhotoTransferReceiptFrame.Stage(rawValue: stageText),
              let transferId = object["transferId"] as? String, PhotoTransferReceiptWire.isValidTransferID(transferId),
              let receiverId = object["receiverId"] as? String, PhotoTransferReceiptWire.isValidReceiverID(receiverId),
              let more = boolValue(object["more"]),
              let seq = intValue(object["seq"]), seq >= 1,
              let mac = object["mac"] as? String, isLowercaseSHA256(mac),
              let rawItems = object["items"] as? [Any],
              rawItems.count <= PhotoTransferReceiptWire.maximumItemsPerFrame else { return nil }
        var status: PhotoTransferReceiptFrame.Status?
        if let rawStatus = object["status"] {
            guard let text = rawStatus as? String, let value = PhotoTransferReceiptFrame.Status(rawValue: text) else { return nil }
            status = value
        }
        // ready에서는 status를 생략할 수 있지만 final/error에는 반드시 있어야 한다(계약 개정 4).
        if stage != .ready, status == nil { return nil }
        var items: [PhotoTransferReceiptItem] = []
        var seen = Set<String>()
        for raw in rawItems {
            guard let dictionary = raw as? [String: Any], let item = decodeItem(dictionary),
                  seen.insert(item.itemId).inserted else { return nil }
            items.append(item)
        }
        return PhotoTransferReceiptFrame(stage: stage, transferId: transferId, receiverId: receiverId,
                                         status: status, more: more, seq: seq, items: items, mac: mac)
    }

    private static func decodeItem(_ object: [String: Any]) -> PhotoTransferReceiptItem? {
        let required: Set<String> = ["itemId", "state"]
        let keys = Set(object.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["inputs", "reason"])),
              let itemId = object["itemId"] as? String, PhotoTransferReceiptWire.isValidItemID(itemId),
              let stateText = object["state"] as? String, let state = PhotoTransferReceiptItem.State(rawValue: stateText)
        else { return nil }
        var inputs: [PhotoTransferReceiptInput] = []
        if let rawInputs = object["inputs"] {
            guard let list = rawInputs as? [Any], list.count <= 8 else { return nil }
            var indexes = Set<Int>()
            for raw in list {
                guard let input = raw as? [String: Any], Set(input.keys) == ["index", "sha256"],
                      let index = intValue(input["index"]), (0...7).contains(index), indexes.insert(index).inserted,
                      let sha = input["sha256"] as? String, isLowercaseSHA256(sha) else { return nil }
                inputs.append(PhotoTransferReceiptInput(index: index, sha256: sha))
            }
        }
        var reason: String?
        if let rawReason = object["reason"] {
            guard let text = rawReason as? String, PhotoTransferReceiptWire.isValidReason(text) else { return nil }
            reason = text
        }
        return PhotoTransferReceiptItem(itemId: itemId, state: state, inputs: inputs, reason: reason)
    }

    static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func intValue(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double, abs(double) < 1e15 else { return nil }
        return number.intValue
    }
}

/// 소켓에서 제어 프레임을 복원한다. 길이 접두가 한도를 넘거나 0이면 즉시 오류, 할당은 길이 검증 뒤에만 한다.
struct PhotoTransferControlFrameBuffer {
    private var buffer = Data()

    mutating func append(_ data: Data) { buffer.append(data) }

    /// 완성된 프레임의 JSON 본문을 하나 꺼낸다. 아직 모자라면 nil.
    mutating func nextJSON() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, Int(length) <= PhotoTransferReceiptWire.maximumFrameLength else {
            throw PhotoTransferControlCodec.CodecError.frameTooLarge
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let json = buffer.subdata(in: 4..<total)
        buffer.removeSubrange(0..<total)
        return json
    }
}
