import Foundation
import Security

/// 같은 Wi-Fi 페어링 QR에 담기는 버전 1 페이로드.
/// 형식: `nasfinder://photo-transfer/pair?version=1&host=<IPv4>&port=<1...65535>&token=<URL-safe-token>`
/// 네트워크 없이 인코딩·파싱을 검증할 수 있도록 순수 값 타입으로 유지한다.
struct PhotoTransferPairingPayload: Equatable, Sendable {
    static let scheme = "nasfinder"
    static let pairingHost = "photo-transfer"
    static let pairingPath = "/pair"
    static let supportedVersion = 1
    /// 토큰은 URL-safe Base64(패딩 제거) 문자 집합만 허용한다.
    static let tokenLengthRange = 22...128

    let version: Int
    let host: String
    let port: UInt16
    let token: String

    /// 검증을 통과한 값으로만 생성한다. 잘못된 값이면 nil.
    init?(host: String, port: UInt16, token: String) {
        guard Self.isValidIPv4Host(host), port > 0, Self.isValidToken(token) else {
            return nil
        }
        self.version = Self.supportedVersion
        self.host = host
        self.port = port
        self.token = token
    }

    /// QR 문자열을 엄격하게 파싱한다. 스킴·호스트·경로·쿼리 4개 키가
    /// 정확히 일치해야 하며, 중복 키나 알 수 없는 키가 있으면 거부한다.
    init?(pairingURLString: String) {
        guard let components = URLComponents(string: pairingURLString),
              components.scheme?.lowercased() == Self.scheme,
              components.host == Self.pairingHost,
              components.path == Self.pairingPath,
              components.user == nil,
              components.password == nil,
              components.port == nil,
              components.fragment == nil,
              let queryItems = components.queryItems
        else {
            return nil
        }

        var values: [String: String] = [:]
        for item in queryItems {
            guard let value = item.value,
                  values.updateValue(value, forKey: item.name) == nil
            else {
                return nil
            }
        }

        guard values.count == 4,
              values["version"] == String(Self.supportedVersion),
              let hostValue = values["host"],
              let portValue = values["port"],
              let tokenValue = values["token"],
              let port = Self.parsePort(portValue)
        else {
            return nil
        }

        self.init(host: hostValue, port: port, token: tokenValue)
    }

    /// QR에 인코딩할 정규 형태 문자열. 모든 값이 URL-safe라 추가 인코딩이 필요 없다.
    var pairingURLString: String {
        "\(Self.scheme)://\(Self.pairingHost)\(Self.pairingPath)?version=\(version)&host=\(host)&port=\(port)&token=\(token)"
    }

    /// 일회용 토큰을 암호학적 난수로 생성해 URL-safe Base64로 반환한다.
    static func makeToken(byteCount: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator 역시 Apple 플랫폼에서 암호학적으로 안전하다.
            var generator = SystemRandomNumberGenerator()
            bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// 점으로 구분된 4옥텟 IPv4만 허용한다. 선행 0, 미지정(0.0.0.0), 브로드캐스트는 거부.
    static func isValidIPv4Host(_ string: String) -> Bool {
        guard string != "0.0.0.0", string != "255.255.255.255" else { return false }
        let octets = string.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        for octet in octets {
            guard (1...3).contains(octet.count),
                  octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  !(octet.count > 1 && octet.first == "0"),
                  let value = Int(octet), value <= 255
            else {
                return false
            }
        }
        return true
    }

    /// 1...65535 범위의 십진수만 허용한다. 선행 0은 거부.
    static func parsePort(_ string: String) -> UInt16? {
        guard (1...5).contains(string.count),
              string.allSatisfy({ $0.isASCII && $0.isNumber }),
              string.first != "0",
              let value = UInt32(string),
              (1...65535).contains(value)
        else {
            return nil
        }
        return UInt16(value)
    }

    static func isValidToken(_ string: String) -> Bool {
        tokenLengthRange.contains(string.count) && string.allSatisfy { character in
            character.isASCII
                && (character.isLetter || character.isNumber || character == "-" || character == "_")
        }
    }
}

/// TCP 핸드셰이크 한 줄 프로토콜.
/// v3: `NASFINDER_PHOTO/3 <token> ios|android grouped-v1\n`
///   → `OK ios|android grouped-v1\n`.
/// 기존 v1/v2 요청도 flat-file 연결로 계속 수락한다.
enum PhotoTransferHandshake {
    static let legacyProtocolIdentifier = "NASFINDER_PHOTO/1"
    static let legacyPlatformProtocolIdentifier = "NASFINDER_PHOTO/2"
    static let protocolIdentifier = "NASFINDER_PHOTO/3"
    static let groupedCapability = "grouped-v1"
    static let acceptResponse = "OK\n"
    static let rejectResponse = "ERROR\n"
    /// 개행 없이 이 길이를 넘는 요청은 즉시 거부한다.
    static let maximumLineLength = 512

    static func clientLine(token: String, sourcePlatform: PhotoTransferPeerPlatform = .ios) -> String {
        "\(protocolIdentifier) \(token) \(sourcePlatform.rawValue) \(groupedCapability)\n"
    }

    struct Decision: Equatable {
        let response: String
        let peerPlatform: PhotoTransferPeerPlatform
        let accepted: Bool
        let supportsGroupedTransfer: Bool
    }

    static func decision(
        toClientLine line: String,
        expectedToken: String,
        receiverPlatform: PhotoTransferPeerPlatform = .ios
    ) -> Decision {
        guard !expectedToken.isEmpty, !line.contains("\n"), !line.contains("\r") else {
            return Decision(response: rejectResponse, peerPlatform: .unknown, accepted: false, supportsGroupedTransfer: false)
        }
        let components = line.split(separator: " ", omittingEmptySubsequences: false)
        if components.count == 2,
           components[0] == legacyProtocolIdentifier,
           constantTimeEquals(String(components[1]), expectedToken) {
            return Decision(response: acceptResponse, peerPlatform: .unknown, accepted: true, supportsGroupedTransfer: false)
        }
        if components.count == 3,
           components[0] == legacyPlatformProtocolIdentifier,
           constantTimeEquals(String(components[1]), expectedToken),
           let peerPlatform = PhotoTransferPeerPlatform(rawValue: String(components[2])),
           peerPlatform != .unknown {
            return Decision(
                response: "OK \(receiverPlatform.rawValue)\n",
                peerPlatform: peerPlatform,
                accepted: true,
                supportsGroupedTransfer: false
            )
        }
        if components.count == 4,
           components[0] == protocolIdentifier,
           constantTimeEquals(String(components[1]), expectedToken),
           let peerPlatform = PhotoTransferPeerPlatform(rawValue: String(components[2])),
           peerPlatform != .unknown,
           components[3] == Substring(groupedCapability) {
            return Decision(
                response: "OK \(receiverPlatform.rawValue) \(groupedCapability)\n",
                peerPlatform: peerPlatform,
                accepted: true,
                supportsGroupedTransfer: true
            )
        }
        return Decision(response: rejectResponse, peerPlatform: .unknown, accepted: false, supportsGroupedTransfer: false)
    }

    /// 개행이 제거된 요청 한 줄에 대한 응답을 결정한다. 네트워크 없이 테스트 가능.
    static func response(toClientLine line: String, expectedToken: String) -> String {
        decision(toClientLine: line, expectedToken: expectedToken).response
    }

    static func acceptedPeerPlatform(fromResponse response: String) -> PhotoTransferPeerPlatform? {
        acceptedPeer(fromResponse: response)?.platform
    }

    static func acceptedPeer(fromResponse response: String) -> (platform: PhotoTransferPeerPlatform, supportsGroupedTransfer: Bool)? {
        if response == acceptResponse { return (.unknown, false) }
        guard response.hasSuffix("\n") else { return nil }
        let values = response.dropLast().split(separator: " ", omittingEmptySubsequences: false)
        guard (values.count == 2 || values.count == 3), values[0] == "OK",
              let platform = PhotoTransferPeerPlatform(rawValue: String(values[1])),
              platform != .unknown
        else {
            return nil
        }
        if values.count == 3, values[2] != Substring(groupedCapability) { return nil }
        return (platform, values.count == 3)
    }

    /// 토큰 비교는 타이밍 차이를 남기지 않도록 상수 시간으로 수행한다.
    private static func constantTimeEquals(_ lhs: String, _ rhs: String) -> Bool {
        let lhsBytes = Array(lhs.utf8)
        let rhsBytes = Array(rhs.utf8)
        guard lhsBytes.count == rhsBytes.count else { return false }
        var difference: UInt8 = 0
        for index in lhsBytes.indices {
            difference |= lhsBytes[index] ^ rhsBytes[index]
        }
        return difference == 0
    }
}

enum PhotoTransferPeerPlatform: String, Codable, Equatable, Sendable {
    case ios
    case android
    case unknown

    var title: String {
        switch self {
        case .ios: "iPhone/iPad"
        case .android: "Android"
        case .unknown: "기존 버전"
        }
    }
}

/// 연결된 플랫폼 조합에 따른 미디어 처리 경로를 결정한다.
enum PhotoTransferMediaPipelineRoute: Equatable {
    case preserveOriginal
    case crossPlatformConversion(source: PhotoTransferPeerPlatform, destination: PhotoTransferPeerPlatform)
    case compatibility

    static func route(
        source: PhotoTransferPeerPlatform,
        destination: PhotoTransferPeerPlatform
    ) -> Self {
        guard source != .unknown, destination != .unknown else { return .compatibility }
        return source == destination
            ? .preserveOriginal
            : .crossPlatformConversion(source: source, destination: destination)
    }
}
