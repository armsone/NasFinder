import Foundation

/// A validated server address entered in the connection form.
///
/// The connection model stores the host and port separately. This parser also
/// accepts commonly pasted forms such as `sftp://server.example.com:2222` and
/// prevents URL paths or credentials from being silently discarded.
struct ParsedServerAddress: Equatable, Sendable {
    let host: String
    let explicitPort: Int?
    let inferredTLS: Bool?

    func synchronizedSynologySettings(
        currentPort: Int,
        currentUsesTLS: Bool
    ) -> SynologyAddressSettings {
        let usesTLS = inferredTLS ?? currentUsesTLS
        let port: Int
        if let explicitPort {
            port = explicitPort
        } else if inferredTLS != nil {
            port = ConnectionKind.synologyPort(usesTLS: usesTLS)
        } else {
            port = currentPort
        }
        return SynologyAddressSettings(port: port, usesTLS: usesTLS)
    }
}

struct SynologyAddressSettings: Equatable, Sendable {
    let port: Int
    let usesTLS: Bool
}

enum ServerAddressParser {
    static func parse(_ input: String, kind: ConnectionKind) throws -> ParsedServerAddress {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ServerAddressError.empty }

        // An unbracketed IPv6 literal has multiple colons and no unambiguous
        // port separator. Keep the complete literal as the host; users can use
        // `[address]:port` when a non-default port is needed.
        if !trimmed.contains("://"),
           !trimmed.hasPrefix("["),
           trimmed.filter({ $0 == ":" }).count > 1 {
            guard isPlausibleUnbracketedIPv6(trimmed) else {
                throw ServerAddressError.invalid
            }
            return ParsedServerAddress(host: trimmed, explicitPort: nil, inferredTLS: nil)
        }

        let hasScheme = trimmed.contains("://")
        let candidate = hasScheme ? trimmed : "nasfinder://\(trimmed)"
        guard let components = URLComponents(string: candidate),
              var parsedHost = components.host,
              !parsedHost.isEmpty else {
            throw ServerAddressError.invalid
        }

        guard components.user == nil, components.password == nil else {
            throw ServerAddressError.credentialsNotAllowed
        }
        guard components.query == nil, components.fragment == nil else {
            throw ServerAddressError.invalid
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw ServerAddressError.pathNotAllowed
        }

        var inferredTLS: Bool?
        if hasScheme {
            let scheme = components.scheme?.lowercased() ?? ""
            switch (kind, scheme) {
            case (.sftp, "sftp"), (.sftp, "ssh"):
                break
            case (.synology, "https"):
                inferredTLS = true
            case (.synology, "http"):
                inferredTLS = false
            case (.webDAV, "https"):
                inferredTLS = true
            case (.webDAV, "http"), (.webDAV, "webdav"):
                inferredTLS = false
            case (.smb, "smb"):
                break
            case (.ftp, "ftp"):
                break
            default:
                throw ServerAddressError.unsupportedScheme(scheme)
            }
        }

        if parsedHost.hasPrefix("["), parsedHost.hasSuffix("]") {
            parsedHost.removeFirst()
            parsedHost.removeLast()
        }
        guard !parsedHost.isEmpty,
              !parsedHost.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw ServerAddressError.invalid
        }

        if let port = components.port, !(1...65_535).contains(port) {
            throw ServerAddressError.invalidPort
        }

        return ParsedServerAddress(
            host: parsedHost,
            explicitPort: components.port,
            inferredTLS: inferredTLS
        )
    }

    private static func isPlausibleUnbracketedIPv6(_ value: String) -> Bool {
        guard value.contains(":"), !value.contains("/") else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789abcdefABCDEF:.%")
        return value.unicodeScalars.allSatisfy(allowed.contains)
    }
}

enum ServerAddressError: LocalizedError, Equatable, Sendable {
    case empty
    case invalid
    case invalidPort
    case unsupportedScheme(String)
    case credentialsNotAllowed
    case pathNotAllowed

    var errorDescription: String? {
        switch self {
        case .empty:
            "서버 주소를 입력해 주세요."
        case .invalid:
            "서버 주소 형식을 확인해 주세요. 예: nas.example.com 또는 sftp://nas.example.com:22"
        case .invalidPort:
            "포트는 1~65535 사이여야 합니다."
        case .unsupportedScheme(let scheme):
            scheme.isEmpty
                ? "서버 주소 형식을 확인해 주세요."
                : "이 연결 방식에서는 \(scheme):// 주소를 사용할 수 없습니다."
        case .credentialsNotAllowed:
            "서버 주소에는 사용자 이름이나 비밀번호를 넣지 말고 로그인 항목에 입력해 주세요."
        case .pathNotAllowed:
            "폴더 경로는 서버 주소가 아니라 ‘시작 위치’에 입력해 주세요."
        }
    }
}
