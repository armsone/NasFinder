import CryptoKit
import Foundation
import Security

/// v4 핸드셰이크(계약 개정 2): 토큰을 와이어에 싣지 않는 challenge/proof.
///
///     S→R  NASFINDER_PHOTO/4 hello <ios|android> grouped-v1 receipt-v1 <nS>\n
///     R→S  CHALLENGE <nR>\n
///     S→R  PROOF <hex64>\n
///     R→S  OK <ios|android> grouped-v1 receipt-v1 <hex64>\n   |   ERROR\n
///
/// 토큰은 HMAC 키 재료로만 쓰인다. 표준 CryptoKit HMAC-SHA256 하나만 쓰며 자체 암호 알고리즘은 없다.
/// 인증(토큰 소유 증명, 영수증 무결성·신선도)만 추가하고 기밀성은 추가하지 않는다.
enum PhotoTransferV4Handshake {
    static let helloPrefix = "NASFINDER_PHOTO/4"
    static let maximumHelloLength = 512
    static let maximumChallengeLength = 128
    static let maximumProofLength = 128
    static let maximumOKLength = 192
    /// 수신이 hello 뒤 PROOF를 기다리는 시간(초).
    static let proofTimeoutSeconds = 5

    // MARK: 줄 문법

    static func helloLine(platform: PhotoTransferPeerPlatform, nonceS: String) -> String {
        "\(helloPrefix) hello \(platform.rawValue) grouped-v1 \(PhotoTransferReceiptWire.capability) \(nonceS)\n"
    }

    /// 줄 끝 `\n`/`\r`을 뗀 한 줄을 받는다. 정확히 6토큰이어야 한다.
    static func parseHello(_ line: String) -> (platform: PhotoTransferPeerPlatform, nonceS: String)? {
        let parts = tokens(line)
        guard parts.count == 6, parts[0] == helloPrefix, parts[1] == "hello",
              let platform = PhotoTransferPeerPlatform(rawValue: parts[2]), platform != .unknown,
              parts[3] == "grouped-v1", parts[4] == PhotoTransferReceiptWire.capability,
              PhotoTransferReceiptWire.isValidNonce(parts[5]) else { return nil }
        return (platform, parts[5])
    }

    static func isHelloPrefix(_ line: String) -> Bool {
        line.hasPrefix(helloPrefix + " hello ")
    }

    static func challengeLine(nonceR: String) -> String { "CHALLENGE \(nonceR)\n" }

    static func parseChallenge(_ line: String) -> String? {
        let parts = tokens(line)
        guard parts.count == 2, parts[0] == "CHALLENGE", PhotoTransferReceiptWire.isValidNonce(parts[1]) else { return nil }
        return parts[1]
    }

    static func proofLine(_ proof: String) -> String { "PROOF \(proof)\n" }

    static func parseProof(_ line: String) -> String? {
        let parts = tokens(line)
        guard parts.count == 2, parts[0] == "PROOF", PhotoTransferCrypto.isLowercaseHex64(parts[1]) else { return nil }
        return parts[1]
    }

    static func okLine(platform: PhotoTransferPeerPlatform, proof: String) -> String {
        "OK \(platform.rawValue) grouped-v1 \(PhotoTransferReceiptWire.capability) \(proof)\n"
    }

    static func parseOK(_ line: String) -> (platform: PhotoTransferPeerPlatform, proof: String)? {
        let parts = tokens(line)
        guard parts.count == 5, parts[0] == "OK",
              let platform = PhotoTransferPeerPlatform(rawValue: parts[1]), platform != .unknown,
              parts[2] == "grouped-v1", parts[3] == PhotoTransferReceiptWire.capability,
              PhotoTransferCrypto.isLowercaseHex64(parts[4]) else { return nil }
        return (platform, parts[4])
    }

    /// 선택적 `\r`을 뗀 뒤 공백으로 나눈다(연속 공백은 허용하지 않아 빈 토큰이 생기면 형식 오류).
    private static func tokens(_ line: String) -> [String] {
        var text = line
        if text.hasSuffix("\r") { text.removeLast() }
        guard !text.contains("\n"), !text.contains("\r") else { return [] }
        let parts = text.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        return parts.contains(where: \.isEmpty) ? [] : parts
    }

    // MARK: 암호(표준 HMAC-SHA256)

    static func makeNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// `K = HMAC-SHA256(key = UTF-8(token), msg = "NASFINDER_PHOTO/4 key")`
    static func handshakeKey(token: String) -> SymmetricKey {
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data("NASFINDER_PHOTO/4 key".utf8), using: SymmetricKey(data: Data(token.utf8)))
        return SymmetricKey(data: Data(mac))
    }

    /// `proofS = hex(HMAC(K, "NF4-S\n" + platformS + "\n" + nS + "\n" + nR))`
    static func senderProof(key: SymmetricKey, platformS: PhotoTransferPeerPlatform, nonceS: String, nonceR: String) -> String {
        hex(authentication("NF4-S\n\(platformS.rawValue)\n\(nonceS)\n\(nonceR)", key: key))
    }

    /// `proofR = hex(HMAC(K, "NF4-R\n" + platformR + "\n" + nS + "\n" + nR))`
    static func receiverProof(key: SymmetricKey, platformR: PhotoTransferPeerPlatform, nonceS: String, nonceR: String) -> String {
        hex(authentication("NF4-R\n\(platformR.rawValue)\n\(nonceS)\n\(nonceR)", key: key))
    }

    /// `Ks = HMAC(K, "NF4-session\n" + nS + "\n" + nR)`. 영수증 MAC에만 쓴다.
    static func sessionKey(key: SymmetricKey, nonceS: String, nonceR: String) -> SymmetricKey {
        SymmetricKey(data: authentication("NF4-session\n\(nonceS)\n\(nonceR)", key: key))
    }

    /// 상수 시간 검증(CryptoKit `isValidAuthenticationCode`).
    static func verifySenderProof(_ proof: String, key: SymmetricKey, platformS: PhotoTransferPeerPlatform,
                                  nonceS: String, nonceR: String) -> Bool {
        verify(proof, "NF4-S\n\(platformS.rawValue)\n\(nonceS)\n\(nonceR)", key: key)
    }

    static func verifyReceiverProof(_ proof: String, key: SymmetricKey, platformR: PhotoTransferPeerPlatform,
                                    nonceS: String, nonceR: String) -> Bool {
        verify(proof, "NF4-R\n\(platformR.rawValue)\n\(nonceS)\n\(nonceR)", key: key)
    }

    private static func verify(_ proof: String, _ message: String, key: SymmetricKey) -> Bool {
        guard let expected = data(fromHex: proof), expected.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(expected, authenticating: Data(message.utf8), using: key)
    }

    private static func authentication(_ message: String, key: SymmetricKey) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key))
    }

    static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    static func data(fromHex text: String) -> Data? {
        guard PhotoTransferCrypto.isLowercaseHex64(text) else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

enum PhotoTransferCrypto {
    static func isLowercaseHex64(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }
    }
}
