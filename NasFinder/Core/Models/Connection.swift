import Foundation

enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case synology
    case sftp

    var id: Self { self }

    var title: String {
        switch self {
        case .synology: "Synology NAS"
        case .sftp: "SFTP 서버"
        }
    }

    var subtitle: String {
        switch self {
        case .synology: "DSM File Station API를 사용합니다"
        case .sftp: "SSH를 통한 안전한 파일 전송"
        }
    }

    var systemImage: String {
        switch self {
        case .synology: "externaldrive.connected.to.line.below"
        case .sftp: "network.badge.shield.half.filled"
        }
    }

    var defaultPort: Int {
        switch self {
        case .synology: 5001
        case .sftp: 22
        }
    }

    static let synologyHTTPPort = 5000
    static let synologyHTTPSPort = 5001

    static func synologyPort(usesTLS: Bool) -> Int {
        usesTLS ? synologyHTTPSPort : synologyHTTPPort
    }

    static func synologyPortAfterTLSToggle(
        currentPort: Int,
        from oldValue: Bool,
        to newValue: Bool,
        hasExplicitPort: Bool
    ) -> Int {
        guard !hasExplicitPort,
              currentPort == synologyPort(usesTLS: oldValue) else {
            return currentPort
        }
        return synologyPort(usesTLS: newValue)
    }

    var defaultRootPath: String {
        switch self {
        case .synology: "/"
        case .sftp: "."
        }
    }
}

struct RemoteConnection: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var kind: ConnectionKind
    var host: String
    var port: Int
    var username: String
    var rootPath: String
    var usesTLS: Bool
    var trustedHostKey: String?
    var createdAt: Date

    init(
        id: UUID = UUID(),
        name: String,
        kind: ConnectionKind,
        host: String,
        port: Int? = nil,
        username: String,
        rootPath: String? = nil,
        usesTLS: Bool = true,
        trustedHostKey: String? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port ?? kind.defaultPort
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.rootPath = rootPath ?? kind.defaultRootPath
        self.usesTLS = kind == .synology ? usesTLS : false
        self.trustedHostKey = kind == .sftp ? trustedHostKey : nil
        self.createdAt = createdAt
    }

    var normalizedRootPath: String {
        guard kind == .synology else {
            let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "." : trimmed
        }

        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    var endpointDescription: String {
        switch kind {
        case .synology:
            "\(usesTLS ? "https" : "http")://\(host):\(port)"
        case .sftp:
            "sftp://\(host):\(port)"
        }
    }
}

struct RemoteCredential: Equatable, Sendable {
    var password: String
}
