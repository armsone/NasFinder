import Foundation

/// Builds the one IINA public-scheme URL (`iina://weblink?url=<original>`) used to hand a
/// credential-free http(s) original to the player, and validates what may be copied.
/// IINA's `parsePendingURL` accepts `open` or `weblink` hosts and reads only the `url` query
/// item; the original is always percent-encoded into that single item, never concatenated raw,
/// and no `mpv_*` option or outer query is ever added.
enum ExternalPlayerHandoff {
    static let unsafeAddressReason = "이 원본 주소에는 로그인 정보나 세션 값이 들어 있어 외부 앱으로 넘기거나 복사할 수 없습니다."

    /// Substrings of query names that carry credentials; any match rejects the address.
    private static let secretQueryNameFragments = [
        "sid", "session", "token", "signature", "sig", "auth", "password", "passwd", "pwd",
        "secret", "credential", "apikey", "api_key", "key", "jwt", "ticket", "cookie",
        "x-amz", "expires"
    ]

    /// Only http/https without user info or secret-looking query/fragment is transferable.
    static func safeOriginalURL(_ url: URL) -> URL? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.fragment == nil else { return nil }
        for item in components.queryItems ?? [] {
            let name = item.name.lowercased()
            if secretQueryNameFragments.contains(where: { name.contains($0) }) { return nil }
        }
        return components.url
    }

    /// `iina://weblink?url=<percent-encoded original>`; nil when the original is not safe.
    static func iinaURL(for original: URL) -> URL? {
        guard let safe = safeOriginalURL(original) else { return nil }
        return iinaWeblinkURL(absolute: safe.absoluteString)
    }

    private static func iinaWeblinkURL(absolute: String) -> URL? {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = absolute.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "iina"
        components.host = "weblink"
        components.percentEncodedQueryItems = [URLQueryItem(name: "url", value: encoded)]
        return components.url
    }

    /// The text a user copy action may put on the pasteboard (same validation as the handoff).
    static func copyableText(for original: URL) -> String? {
        safeOriginalURL(original)?.absoluteString
    }

    /// Validates that the URL points to the local loopback relay endpoint.
    static func isLoopbackURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return components.scheme?.lowercased() == "http" && components.host == "127.0.0.1"
    }

    /// Handoff for a temporary localhost loopback relay address to IINA.
    static func iinaLoopbackURL(for loopbackURL: URL) -> URL? {
        guard isLoopbackURL(loopbackURL) else { return nil }
        return iinaURL(for: loopbackURL)
    }

    /// Players the user can pick explicitly on the Mac error screen. Nothing is remembered.
    enum Player: String, CaseIterable, Identifiable {
        case iina
        case movistPro
        /// The OS file association; only ever offered for an existing local file.
        case systemDefault

        var id: String { rawValue }

        var title: String {
            switch self {
            case .iina: return "IINA"
            case .movistPro: return "무비스트 Pro"
            case .systemDefault: return "시스템 기본 앱"
            }
        }
    }

    /// Scheme-only address used to ask whether the player is installed (`canOpenURL`); it carries
    /// no media address. The schemes must be listed in the app's LSApplicationQueriesSchemes.
    static func installProbeURL(for player: Player) -> URL? {
        switch player {
        case .iina: return URL(string: "iina://")
        case .movistPro: return URL(string: "movistpro:")
        case .systemDefault: return nil
        }
    }

    /// JavaScript `encodeURIComponent` unreserved set.
    private static let componentAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return allowed
    }()

    /// Movist Pro's own Safari extension opens `'movistpro:' + encodeURIComponent(JSON.stringify(resource))`.
    /// The resource carries only the `url` string here (no title, options or credentials).
    /// Accepts an existing local file, a credential-free http(s) address or the loopback relay address.
    static func movistProURL(for source: URL) -> URL? {
        let payload: String
        if source.isFileURL {
            payload = source.absoluteString
        } else if isLoopbackURL(source) || safeOriginalURL(source) != nil {
            payload = source.absoluteString
        } else {
            return nil
        }
        return movistProURL(payload: payload)
    }

    private static func movistProURL(payload: String) -> URL? {
        guard let json = try? JSONSerialization.data(
                withJSONObject: ["url": payload],
                options: [.withoutEscapingSlashes]
              ),
              let text = String(data: json, encoding: .utf8),
              let encoded = text.addingPercentEncoding(withAllowedCharacters: componentAllowed) else {
            return nil
        }
        return URL(string: "movistpro:" + encoded)
    }

    /// `iina://open?url=<percent-encoded file URL>` for an existing local file; nothing else is added.
    static func iinaLocalFileURL(for fileURL: URL) -> URL? {
        guard fileURL.isFileURL else { return nil }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard let encoded = fileURL.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "iina"
        components.host = "open"
        components.percentEncodedQueryItems = [URLQueryItem(name: "url", value: encoded)]
        return components.url
    }

    // MARK: NAS login-session original (user-approved, transient)

    /// Handoff of the authenticated NAS original to the player the user just chose. This is the only
    /// path that may carry a session id; `safeOriginalURL` stays strict. The address is rebuilt from
    /// the typed parts and must match the item exactly, and the result is never logged, copied or stored.
    static func sessionHandoffURL(
        player: Player,
        session: NASSessionHandoff,
        item: RemoteFileItem,
        connection: RemoteConnection
    ) -> URL? {
        guard session.isValid(for: item, connection: connection) else { return nil }
        switch player {
        case .iina: return iinaWeblinkURL(absolute: session.url.absoluteString)
        case .movistPro: return movistProURL(payload: session.url.absoluteString)
        case .systemDefault: return nil
        }
    }

    /// The URL to open for the explicit choice, from the one already-selected source
    /// (local file, safe public address or loopback relay). Both players receive the same source.
    static func handoffURL(player: Player, source: URL) -> URL? {
        switch player {
        case .iina:
            return source.isFileURL ? iinaLocalFileURL(for: source) : iinaURL(for: source)
        case .movistPro:
            return movistProURL(for: source)
        case .systemDefault:
            return source.isFileURL ? source : nil
        }
    }
}

/// Synology File Station original-file address carrying the NAS login session (`_sid`, never the
/// password) for one item. It is created only by the Synology service for a player the user just
/// chose, validated by `isValid(for:connection:)` before use, and must not be logged, copied or persisted.
struct NASSessionHandoff: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: URL
    let connectionID: UUID
    let host: String
    let port: Int?
    let usesTLS: Bool
    let itemPath: String

    var description: String { "NASSessionHandoff(redacted)" }
    var debugDescription: String { description }

    private static let allowedQueryNames: Set<String> = ["api", "version", "method", "path", "mode", "_sid"]

    /// Host, port, protocol, endpoint, API, method and decoded path must all match the item; any extra
    /// query item or user info makes it invalid, so nothing else can ride along.
    func isValid(for item: RemoteFileItem, connection: RemoteConnection) -> Bool {
        guard connection.id == connectionID, connection.host == host,
              connection.port == port, connection.usesTLS == usesTLS,
              item.connectionID == connection.id, item.path == itemPath,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == (usesTLS ? "https" : "http"),
              components.host == host, components.port == port,
              components.user == nil, components.password == nil, components.fragment == nil,
              components.path == "/webapi/entry.cgi",
              let items = components.queryItems, items.count == Self.allowedQueryNames.count else { return false }
        var values: [String: String] = [:]
        for item in items {
            guard Self.allowedQueryNames.contains(item.name), values[item.name] == nil,
                  let value = item.value, !value.isEmpty else { return false }
            values[item.name] = value
        }
        return values["api"] == "SYNO.FileStation.Download"
            && values["method"] == "download"
            && values["path"] == itemPath
            && values["mode"] == "download"
    }
}
