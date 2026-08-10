import Citadel
import Foundation
import OSLog

enum SFTPDiagnosticStage: String, Equatable, Sendable {
    case addressResolution = "주소 확인"
    case transport = "네트워크 연결"
    case hostKey = "호스트 키 확인"
    case negotiation = "SSH 협상"
    case authentication = "SSH 인증"
    case subsystem = "SFTP 시작"
    case remotePath = "폴더 확인"
    case cancelled = "연결 취소"
    case unknown = "SFTP 연결"
}

struct SFTPConnectionDiagnostic: Equatable, Sendable {
    let stage: SFTPDiagnosticStage
    let message: String
    let reference: String

    var userMessage: String {
        "[\(stage.rawValue)] \(message)\n\n진단 코드: \(reference)"
    }
}

/// Converts low-level Citadel/SwiftNIO failures into actionable Korean text.
///
/// Diagnostic references contain only the error type/domain/code. Host names,
/// account names, paths, and passwords are deliberately never logged.
enum SFTPConnectionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder",
        category: "SFTP"
    )

    static func diagnostic(
        for error: Error,
        rootPath: String
    ) -> SFTPConnectionDiagnostic {
        let reference = diagnosticReference(for: error)

        if error is CancellationError {
            return .init(
                stage: .cancelled,
                message: "연결 시도가 취소됐습니다.",
                reference: reference
            )
        }

        if let trust = error as? SFTPHostKeyTrustRequired {
            return .init(
                stage: .hostKey,
                message: trust.errorDescription ?? "SSH 호스트 키를 확인해 주세요.",
                reference: reference
            )
        }

        if error is AuthenticationFailed {
            return authenticationDiagnostic(reference: reference)
        }

        if let clientError = error as? SSHClientError {
            switch clientError {
            case .allAuthenticationOptionsFailed:
                return authenticationDiagnostic(reference: reference)
            case .unsupportedPasswordAuthentication:
                return .init(
                    stage: .authentication,
                    message: "서버가 비밀번호 SSH 로그인을 허용하지 않습니다. 서버의 PasswordAuthentication 설정을 확인해 주세요.",
                    reference: reference
                )
            case .unsupportedPrivateKeyAuthentication, .unsupportedHostBasedAuthentication:
                return authenticationDiagnostic(reference: reference)
            case .channelCreationFailed:
                return subsystemDiagnostic(reference: reference)
            @unknown default:
                break
            }
        }

        if let sftpError = error as? SFTPError {
            switch sftpError {
            case .errorStatus(let status):
                switch status.errorCode {
                case .noSuchFile:
                    return .init(
                        stage: .remotePath,
                        message: "SSH 로그인은 완료됐지만 시작 위치가 없습니다. 서버에서 해당 경로가 존재하는지 확인해 주세요.",
                        reference: reference
                    )
                case .permissionDenied:
                    return .init(
                        stage: .remotePath,
                        message: "SSH 로그인은 완료됐지만 시작 위치를 읽을 권한이 없습니다. NAS의 공유 폴더 권한을 확인해 주세요.",
                        reference: reference
                    )
                case .noConnection, .connectionLost:
                    return transportDiagnostic(reference: reference)
                default:
                    return .init(
                        stage: .remotePath,
                        message: "SSH 로그인은 완료됐지만 시작 위치를 열지 못했습니다. 경로와 폴더 권한을 확인해 주세요.",
                        reference: reference
                    )
                }
            case .missingResponse, .unsupportedVersion, .invalidResponse,
                 .invalidPayload, .unknownMessage, .noResponseTarget:
                return subsystemDiagnostic(reference: reference)
            case .connectionClosed:
                return transportDiagnostic(reference: reference)
            case .fileHandleInvalid:
                return .init(
                    stage: .remotePath,
                    message: "서버가 폴더 요청을 완료하지 못했습니다. 시작 위치와 권한을 확인해 주세요.",
                    reference: reference
                )
            @unknown default:
                return subsystemDiagnostic(reference: reference)
            }
        }

        let errorText = String(describing: error).lowercased()
        let reflectedText = String(reflecting: error).lowercased()
        let combinedText = "\(errorText) \(reflectedText)"
        let nsError = error as NSError

        if isNegotiationFailure(text: combinedText) {
            return .init(
                stage: .negotiation,
                message: "서버와 공통으로 사용할 SSH 암호·키 교환 알고리즘을 찾지 못했습니다. NAS의 SSH/SFTP 보안 수준과 Cipher·KEX 설정을 확인해 주세요.",
                reference: reference
            )
        }

        if isAddressResolutionFailure(nsError: nsError, text: combinedText) {
            return .init(
                stage: .addressResolution,
                message: "서버 주소를 찾지 못했습니다. 호스트 이름의 오타와 Wi‑Fi·VPN 연결을 확인해 주세요.",
                reference: reference
            )
        }

        if isTransportFailure(nsError: nsError, text: combinedText) {
            return transportDiagnostic(reference: reference)
        }

        // The root path is intentionally not placed in the log/reference. It
        // can contain a person's or shared folder's name. Mention its presence
        // only generically in the user-facing guidance.
        let hasCustomRoot = !rootPath.isEmpty && rootPath != "." && rootPath != "/"
        return .init(
            stage: .unknown,
            message: hasCustomRoot
                ? "SFTP 연결을 완료하지 못했습니다. 주소·포트·로그인 정보와 시작 위치를 확인해 주세요."
                : "SFTP 연결을 완료하지 못했습니다. 주소·포트·로그인 정보를 확인해 주세요.",
            reference: reference
        )
    }

    static func record(_ diagnostic: SFTPConnectionDiagnostic) {
        logger.error(
            "SFTP failure stage=\(diagnostic.stage.rawValue, privacy: .public) reference=\(diagnostic.reference, privacy: .public)"
        )
    }

    static func recordConnectionTestSucceeded() {
        logger.info("SFTP connection test succeeded")
    }

    private static func authenticationDiagnostic(reference: String) -> SFTPConnectionDiagnostic {
        .init(
            stage: .authentication,
            message: "SSH 서버에는 연결됐지만 로그인이 거부됐습니다. 사용자 이름·비밀번호와 해당 계정의 SSH 접속 권한을 확인해 주세요.",
            reference: reference
        )
    }

    private static func subsystemDiagnostic(reference: String) -> SFTPConnectionDiagnostic {
        .init(
            stage: .subsystem,
            message: "SSH 로그인은 완료됐지만 SFTP 기능을 열지 못했습니다. NAS에서 SFTP 서비스가 활성화되어 있는지 확인해 주세요.",
            reference: reference
        )
    }

    private static func transportDiagnostic(reference: String) -> SFTPConnectionDiagnostic {
        .init(
            stage: .transport,
            message: "서버의 SSH 포트에 연결할 수 없습니다. 포트·방화벽·포트 포워딩·VPN과 iPhone 설정 > 개인정보 보호 및 보안 > 로컬 네트워크 > NasFinder 권한을 확인해 주세요.",
            reference: reference
        )
    }

    private static func diagnosticReference(for error: Error) -> String {
        let nsError = error as NSError
        let typeName = String(reflecting: type(of: error))
        return "\(typeName)|\(nsError.domain)#\(nsError.code)"
    }

    private static func isAddressResolutionFailure(nsError: NSError, text: String) -> Bool {
        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorCannotFindHost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorBadURL,
                NSURLErrorUnsupportedURL
            ].contains(nsError.code)
        }
        return [
            "dns error", "dns lookup", "cannot find host", "cannotfindhost",
            "host not found", "getaddrinfo", "eai_noname",
            "name or service not known", "nodename nor servname"
        ].contains(where: text.contains)
    }

    private static func isNegotiationFailure(text: String) -> Bool {
        [
            "no common algorithm", "key exchange", "keyexchange", " kex",
            "could not agree", "algorithm negotiation", "unable to negotiate"
        ].contains(where: text.contains)
    }

    private static func isTransportFailure(nsError: NSError, text: String) -> Bool {
        if nsError.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDataNotAllowed,
                NSURLErrorInternationalRoamingOff
            ].contains(nsError.code)
        }
        if nsError.domain == NSPOSIXErrorDomain {
            return [
                Int(ECONNREFUSED), Int(ETIMEDOUT), Int(EHOSTUNREACH),
                Int(ENETUNREACH), Int(ENETDOWN), Int(ECONNRESET), Int(ENOTCONN)
            ].contains(nsError.code)
        }
        return [
            "connection refused", "connect timeout", "connecttimeout", "connection timed out",
            "network is unreachable", "host is unreachable", "connection reset",
            "connection errors:"
        ].contains(where: text.contains)
    }
}
