import CryptoKit
import Foundation

/// QR 비밀(토큰)이 한 번이라도 v3 평문 핸드셰이크에 실렸는지 기록한다.
///
/// 평문으로 보내려 한 시점(성공 ACK 여부와 무관)에 발신이, 유효한 v3 시도에서 쓰인 시점에 수신이 표시한다.
/// 한 번 오염된 비밀은 재시도·앱 재시작·상대 변경 뒤에도 v4 원본 삭제 자격을 받지 못한다.
/// 비밀 자체는 저장하지 않고 SHA-256 지문만 남기며, 개수 상한도 만료도 없다(오래된 QR이 되살아나면 안 된다).
///
/// 보수적 처리(계약 개정 4): 기존 파일을 읽거나 해석하지 못하면 모든 비밀을 오염으로 보고 파일은 건드리지 않는다.
/// 새 지문을 쓰지 못한 경우에도 이 프로세스에서는 모든 비밀을 오염으로 본다. 두 경우 모두 삭제 자격만 사라지고
/// 일반 전송은 계속된다. 파일을 조용히 비우거나 새로 만들지 않는다.
final class PhotoTransferTokenTaintStore: @unchecked Sendable {
    static let shared = PhotoTransferTokenTaintStore()

    private struct Record: Codable { let fingerprint: String; var markedAt: Date }

    private let lock = NSLock()
    private let fileURL: URL
    private var records: [Record] = []
    /// 파일이 있는데 읽거나 해석하지 못했다. 이 경우 파일을 덮어쓰지 않는다.
    private var readFailed = false
    /// 이 프로세스에서 지문을 영속하지 못했다.
    private var writeFailed = false

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoTransferTaint", isDirectory: true)
        fileURL = base.appendingPathComponent("tainted.json")
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            writeFailed = true
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            records = try decoder.decode([Record].self, from: Data(contentsOf: fileURL))
        } catch {
            readFailed = true
        }
    }

    static func fingerprint(of token: String) -> String {
        SHA256.hash(data: Data("NF-taint\n\(token)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 알려진 오염이거나, 기록을 신뢰할 수 없으면(읽기·쓰기 실패) true.
    func isTainted(token: String) -> Bool {
        let fingerprint = Self.fingerprint(of: token)
        return withLock { readFailed || writeFailed || records.contains { $0.fingerprint == fingerprint } }
    }

    /// 평문 전송 직전에 호출한다. 저장이 끝난 뒤에 반환한다.
    /// - Returns: 지문이 디스크에 남았으면 true. false여도 이후 `isTainted`는 보수적으로 true이다.
    @discardableResult
    func markTainted(token: String) -> Bool {
        let fingerprint = Self.fingerprint(of: token)
        return withLock {
            if readFailed { return false }
            if !records.contains(where: { $0.fingerprint == fingerprint }) {
                records.append(Record(fingerprint: fingerprint, markedAt: Date()))
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            do {
                let data = try encoder.encode(records)
                try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                return true
            } catch {
                writeFailed = true
                return false
            }
        }
    }

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
