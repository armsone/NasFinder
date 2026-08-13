import Foundation

enum ConnectionKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case synology
    case sftp
    case smb
    case webDAV
    case ftp
    case dropbox
    case oneDrive
    case googleDrive

    var id: Self { self }

    var title: String {
        switch self {
        case .synology: "Synology NAS"
        case .sftp: "SFTP 서버"
        case .smb: "SMB"
        case .webDAV: "WebDAV"
        case .ftp: "FTP"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google Drive"
        }
    }

    var subtitle: String {
        switch self {
        case .synology: "DSM File Station API를 사용합니다"
        case .sftp: "SSH를 통한 안전한 파일 전송"
        case .smb: "ipTIME·Windows·NAS의 SMB 2 파일 공유"
        case .webDAV: "ipTIME NAS와 일반 WebDAV 서버"
        case .ftp: "ipTIME 공유기·NAS·일반 FTP 서버"
        case .dropbox: "Dropbox 계정의 파일과 폴더"
        case .oneDrive: "Microsoft 계정의 OneDrive 파일"
        case .googleDrive: "Google 계정의 Drive 파일"
        }
    }

    var systemImage: String {
        switch self {
        case .synology: "externaldrive.connected.to.line.below"
        case .sftp: "network.badge.shield.half.filled"
        case .smb: "externaldrive.badge.wifi"
        case .webDAV: "globe.badge.chevron.backward"
        case .ftp: "arrow.up.arrow.down.square"
        case .dropbox: "shippingbox.fill"
        case .oneDrive: "cloud.fill"
        case .googleDrive: "triangle.fill"
        }
    }

    var defaultPort: Int {
        switch self {
        case .synology: 5001
        case .sftp: 22
        case .smb: 445
        case .webDAV: 9800
        case .ftp: 21
        case .dropbox, .oneDrive, .googleDrive: 443
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
        case .smb: "/"
        case .webDAV: "/"
        case .ftp: "/"
        case .dropbox, .oneDrive, .googleDrive: "/"
        }
    }

    /// The File Provider extension currently has concrete backends only for
    /// Synology and SFTP. Other connection kinds remain available inside the
    /// app, but must not be registered as broken locations in Files.
    var supportsFileProvider: Bool {
        switch self {
        case .synology, .sftp:
            true
        case .smb, .webDAV, .ftp, .dropbox, .oneDrive, .googleDrive:
            false
        }
    }

    var isOAuthCloud: Bool {
        switch self {
        case .dropbox, .oneDrive, .googleDrive: true
        default: false
        }
    }

    var oauthProvider: OAuthProvider? {
        switch self {
        case .dropbox: .dropbox
        case .oneDrive: .microsoft
        case .googleDrive: .google
        default: nil
        }
    }
}

enum WebDAVConnectionPreset: String, CaseIterable, Identifiable, Sendable {
    case generic
    case nextcloud
    case ownCloud
    case koofr

    var id: Self { self }

    var title: String {
        switch self {
        case .generic: "일반 WebDAV"
        case .nextcloud: "Nextcloud"
        case .ownCloud: "ownCloud"
        case .koofr: "Koofr"
        }
    }

    var defaultHost: String? {
        switch self {
        case .koofr: "app.koofr.net"
        case .generic, .nextcloud, .ownCloud: nil
        }
    }

    var defaultPort: Int { 443 }

    func rootPath(username: String) -> String {
        switch self {
        case .generic:
            return "/"
        case .nextcloud, .ownCloud:
            let trimmed = username.trimmingCharacters(in: .whitespacesAndNewlines)
            return "/remote.php/dav/files/\(trimmed)"
        case .koofr:
            return "/dav/Koofr"
        }
    }

    var credentialGuidance: String {
        switch self {
        case .generic:
            "외부 연결은 HTTPS와 서비스에서 발급한 앱 비밀번호를 권장합니다."
        case .nextcloud:
            "Nextcloud 사용자 이름과 개인 보안 설정에서 만든 앱 비밀번호를 사용하세요."
        case .ownCloud:
            "ownCloud 사용자 이름과 앱 비밀번호를 사용하세요. 서버 버전에 따라 관리자가 WebDAV 접근을 허용해야 합니다."
        case .koofr:
            "Koofr 계정 이메일과 Koofr에서 생성한 앱 전용 비밀번호를 사용하세요."
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
        self.usesTLS = (kind == .synology || kind == .webDAV || kind.isOAuthCloud) ? usesTLS : false
        self.trustedHostKey = kind == .sftp ? trustedHostKey : nil
        self.createdAt = createdAt
    }

    var normalizedRootPath: String {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .sftp {
            return trimmed.isEmpty ? "." : trimmed
        }
        guard !trimmed.isEmpty, trimmed != "/" else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)"
    }

    var endpointDescription: String {
        switch kind {
        case .synology:
            "\(usesTLS ? "https" : "http")://\(host):\(port)"
        case .sftp:
            "sftp://\(host):\(port)"
        case .smb:
            "smb://\(host):\(port)"
        case .webDAV:
            "\(usesTLS ? "https" : "http")://\(host):\(port)"
        case .ftp:
            "ftp://\(host):\(port)"
        case .dropbox, .oneDrive, .googleDrive:
            username.isEmpty ? kind.title : username
        }
    }
}

struct RemoteCredential: Equatable, Sendable {
    var password: String
    var cloudCredential: CloudCredential?

    init(password: String, cloudCredential: CloudCredential? = nil) {
        self.password = password
        self.cloudCredential = cloudCredential
    }
}
