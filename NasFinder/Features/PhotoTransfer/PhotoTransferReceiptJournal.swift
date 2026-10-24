import Foundation

/// 수신 측 영수증 저널. 사진 보관함에 영구 저장(commit)한 항목의 `(transferId, itemId)` → 입력 해시·출력 자산 ID를 남긴다.
/// - 응답(ACK) 전송이 실패해도 이미 저장된 자산은 되돌리거나 지우지 않는다. 재연결 때 이 저널로 멱등하게 답한다.
/// - commit 직전에 `reserved`(Photos placeholder 식별자·계획 포함)를 쓰고, commit 성공 후 `committed`(출력 증명 포함)로 올린다.
///   commit 후 저널 갱신 전에 앱이 멈추면 다음 실행에서 `applyResolution`이 정확한 계획·해시가 맞을 때만 승격하고,
///   출력이 없음이 확인되면 되돌린다. 확인할 수 없으면 `reserved`로 남긴다. 블라인드 재저장은 하지 않는다.
/// - `committed`는 "저장한 적이 있다"는 기록일 뿐 지금 사본이 유효하다는 증거가 아니다. 영수증에서 검증된 commit으로 보고하려면
///   `outputProofs`와 현재 사진 보관함 자원을 `PhotoTransferOutputProofing`으로 대조해야 한다.
/// - `reserved`는 정확한 계획·해시 증명이 있을 때만 승격하고, 아니면 그대로 둔다. 이 저널은 자산을 지우지 않는다.
/// - 만료(90일)는 저널 항목만 지우며 저장된 자산은 건드리지 않는다.
/// - 디스크 쓰기에 실패하면 던지거나(`reserve`, `markCommitted`) false를 돌려주고, 메모리 상태를 쓰기 전으로 되돌린다.
///   메모리에서만 `committed`가 되어 재시작 뒤 사라지는 일이 없다. 기존 `reserved`/`committed` 항목의 신원·출력 ID·계획은
///   `markFailed`가 덮어쓰지 않는다.
final class PhotoTransferReceiptJournal: @unchecked Sendable {
    enum State: String, Codable, Sendable { case reserved, committed, failed }

    struct Entry: Codable, Equatable, Sendable {
        var transferId: String
        var itemId: String
        var state: State
        var inputs: [PhotoTransferReceiptInput]
        /// Photos `localIdentifier`. `reserved`일 때는 placeholder 식별자(commit 후 같은 값이 자산 ID가 된다).
        var outputIdentifiers: [String]
        var reason: String?
        var updatedAt: Date
        /// 저장 직후 실제 출력 증명(로컬 전용, 와이어에 싣지 않음). 없으면 현재 출력을 검증할 수 없는 기록이다(유효하다고 가정하지 않는다).
        var outputProofs: [PhotoTransferOutputProof]? = nil
        /// `reserved` 크래시 복구 판정용 계획(commit 전에 영속).
        var plannedOutputs: [PhotoTransferPlannedOutput]? = nil
    }

    private struct FileContents: Codable {
        var version = 1
        var receiverId: String
        var entries: [Entry]
    }

    static let shared = PhotoTransferReceiptJournal()
    static let retention: TimeInterval = 90 * 24 * 60 * 60

    typealias Writer = (Data, URL) throws -> Void

    private let lock = NSLock()
    private let fileURL: URL
    private let writer: Writer
    private var contents: FileContents

    /// - Parameter writer: 시험에서 쓰기 실패를 주입하기 위한 대체 쓰기. 기본은 원자적 교체 쓰기다.
    init(directory: URL? = nil, writer: Writer? = nil) {
        self.writer = writer ?? { data, url in
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTransferReceipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        fileURL = base.appendingPathComponent("journal.json")
        if let data = try? Data(contentsOf: fileURL), let decoded = Self.decode(data) {
            contents = decoded
        } else {
            // 읽지 못한 파일은 덮어쓰기 전에 따로 보관한다.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let backup = base.appendingPathComponent("journal.unreadable-\(Int(Date().timeIntervalSince1970)).json")
                try? FileManager.default.copyItem(at: fileURL, to: backup)
            }
            contents = FileContents(receiverId: Self.makeReceiverID(), entries: [])
            try? persistLocked()
        }
    }

    /// 앱 설치별 랜덤 수신자 ID(`[A-Za-z0-9_-]{22,64}`).
    var receiverId: String { withLock { contents.receiverId } }

    func entries(forTransfer transferId: String) -> [Entry] {
        withLock { contents.entries.filter { $0.transferId == transferId } }
    }

    func entry(transferId: String, itemId: String) -> Entry? {
        withLock { contents.entries.first { $0.transferId == transferId && $0.itemId == itemId } }
    }

    /// commit 직전 예약. 같은 항목이 이미 `committed`이면 덮어쓰지 않고 false.
    /// 디스크에 남기지 못하면 던진다(메모리도 되돌린다). 호출자는 예약이 영속되기 전에 Photos 변경을 시작하지 않는다.
    @discardableResult
    func reserve(transferId: String, itemId: String, inputs: [PhotoTransferReceiptInput], placeholderIdentifiers: [String],
                 plannedOutputs: [PhotoTransferPlannedOutput]? = nil) throws -> Bool {
        try withLock {
            if let existing = contents.entries.first(where: { $0.transferId == transferId && $0.itemId == itemId }),
               existing.state == .committed { return false }
            try commitLocked {
                upsertLocked(Entry(transferId: transferId, itemId: itemId, state: .reserved, inputs: inputs,
                                   outputIdentifiers: placeholderIdentifiers, reason: nil, updatedAt: Date(),
                                   outputProofs: nil, plannedOutputs: plannedOutputs))
            }
            return true
        }
    }

    /// 항목을 `committed`로 올린다. 예약이 없으면 false. 디스크 쓰기에 실패하면 던지고 항목은 이전 상태(`reserved`)로 남는다.
    @discardableResult
    func markCommitted(transferId: String, itemId: String, outputIdentifiers: [String], outputProofs: [PhotoTransferOutputProof]? = nil) throws -> Bool {
        try withLock {
            guard var entry = contents.entries.first(where: { $0.transferId == transferId && $0.itemId == itemId }) else { return false }
            entry.state = .committed
            entry.outputIdentifiers = outputIdentifiers
            entry.outputProofs = outputProofs
            entry.reason = nil
            entry.updatedAt = Date()
            try commitLocked { upsertLocked(entry) }
            return true
        }
    }

    /// 실패를 기록한다. 이미 `reserved`나 `committed`인 항목(신원·출력 ID·계획)은 덮어쓰지 않는다.
    /// - Returns: 실제로 `failed`로 기록했으면 true. 보호된 기존 항목이 있거나 디스크 쓰기에 실패하면 false.
    @discardableResult
    func markFailed(transferId: String, itemId: String, inputs: [PhotoTransferReceiptInput], reason: String) -> Bool {
        withLock {
            if let existing = contents.entries.first(where: { $0.transferId == transferId && $0.itemId == itemId }),
               existing.state != .failed { return false }
            do {
                try commitLocked {
                    upsertLocked(Entry(transferId: transferId, itemId: itemId, state: .failed, inputs: inputs,
                                       outputIdentifiers: [], reason: reason, updatedAt: Date()))
                }
                return true
            } catch {
                return false
            }
        }
    }

    /// 예약만 하고 commit이 일어나지 않았음이 확인된 항목을 지운다(미커밋으로 되돌림). 디스크에 반영하지 못하면 false이고 예약은 남는다.
    @discardableResult
    func removeReservation(transferId: String, itemId: String) -> Bool {
        withLock {
            guard contents.entries.contains(where: { $0.transferId == transferId && $0.itemId == itemId && $0.state == .reserved }) else { return true }
            do {
                try commitLocked {
                    contents.entries.removeAll { $0.transferId == transferId && $0.itemId == itemId && $0.state == .reserved }
                }
                return true
            } catch {
                return false
            }
        }
    }

    func reservedEntries() -> [Entry] {
        withLock { contents.entries.filter { $0.state == .reserved } }
    }

    /// 앱 시작·begin 때 `reserved` 항목에 대한 판정을 적용한다(판정은 `PhotoTransferOutputProofing.resolveReservation`).
    /// - `promote`: 정확한 증명이 있을 때만 `committed`(증명 포함). `revert`: 출력 자산이 없음이 확인됐을 때만 항목 제거.
    /// - `unresolved`: 아무것도 바꾸지 않는다(자산을 지우거나 다시 저장하지 않는다).
    @discardableResult
    func applyResolution(transferId: String, itemId: String, _ resolution: PhotoTransferReservationResolution) -> Bool {
        withLock {
            guard var entry = contents.entries.first(where: { $0.transferId == transferId && $0.itemId == itemId && $0.state == .reserved }) else { return false }
            // 쓰기에 실패하면 메모리를 되돌리고 false: 항목은 `reserved`로 남아 다음 기회에 다시 판정한다.
            do {
                switch resolution {
                case .promote(let proofs):
                    entry.state = .committed
                    entry.outputProofs = proofs
                    entry.updatedAt = Date()
                    try commitLocked { upsertLocked(entry) }
                    return true
                case .revert:
                    try commitLocked {
                        contents.entries.removeAll { $0.transferId == transferId && $0.itemId == itemId && $0.state == .reserved }
                    }
                    return true
                case .unresolved:
                    return false
                }
            } catch {
                return false
            }
        }
    }

    /// 마지막 갱신 후 90일이 지난 저널 항목만 지운다. 저장된 자산은 건드리지 않는다.
    func expireOldEntries(now: Date = Date()) {
        withLock {
            let expired = contents.entries.contains { $0.state != .reserved && now.timeIntervalSince($0.updatedAt) > Self.retention }
            guard expired else { return }
            try? commitLocked {
                contents.entries.removeAll { $0.state != .reserved && now.timeIntervalSince($0.updatedAt) > Self.retention }
            }
        }
    }

    // MARK: 내부

    /// 메모리 변경을 적용하고 디스크에 쓴다. 쓰기에 실패하면 메모리를 적용 전으로 되돌리고 오류를 다시 던진다.
    private func commitLocked(_ change: () -> Void) throws {
        let snapshot = contents.entries
        change()
        do {
            try persistLocked()
        } catch {
            contents.entries = snapshot
            throw error
        }
    }

    private func upsertLocked(_ entry: Entry) {
        if let index = contents.entries.firstIndex(where: { $0.transferId == entry.transferId && $0.itemId == entry.itemId }) {
            contents.entries[index] = entry
        } else {
            contents.entries.append(entry)
        }
    }

    private func persistLocked() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        // 임시 파일에 쓴 뒤 교체하는 원자적 쓰기. 쓰는 도중 중단돼도 이전 저널이 남는다.
        try writer(try encoder.encode(contents), fileURL)
    }

    private static func decode(_ data: Data) -> FileContents? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let value = try? decoder.decode(FileContents.self, from: data),
              PhotoTransferReceiptWire.isValidReceiverID(value.receiverId) else { return nil }
        return value
    }

    private static func makeReceiverID() -> String {
        // 128비트 무작위 → URL-safe Base64(패딩 제거) 22자.
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
