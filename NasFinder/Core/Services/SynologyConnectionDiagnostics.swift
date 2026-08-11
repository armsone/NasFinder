import Foundation
import OSLog

enum SynologyDiagnosticStage: String, Equatable, Sendable {
    case addressResolution = "주소 확인"
    case transport = "네트워크 연결"
    case tls = "TLS 보안 연결"
    case webAPI = "DSM Web API 확인"
    case authentication = "DSM 로그인"
    case rootPath = "시작 폴더 확인"
    case cancelled = "연결 취소"
    case unknown = "Synology 연결"
}

struct SynologyConnectionDiagnostic: Equatable, Sendable {
    let stage: SynologyDiagnosticStage
    let message: String
    let reference: String

    var userMessage: String {
        "[\(stage.rawValue)] \(message)\n\n진단 코드: \(reference)"
    }
}

/// Marks the last verified part of a Synology connection test. The wrapped
/// error is retained only for local classification; diagnostics and logs never
/// include the host, account, password, session ID, or remote path.
struct SynologyConnectionTestFailure: LocalizedError, @unchecked Sendable {
    let stage: SynologyDiagnosticStage
    let underlying: Error

    var errorDescription: String? {
        "Synology 연결 테스트의 ‘\(stage.rawValue)’ 단계를 완료하지 못했습니다."
    }
}

enum SynologyConnectionProbeError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int)
    case invalidWebAPIResponse
    case authenticationAPIUnavailable
    case fileStationAPIUnavailable

    var errorDescription: String? {
        switch self {
        case .httpStatus(let status):
            "DSM Web API가 HTTP \(status) 응답을 보냈습니다."
        case .invalidWebAPIResponse:
            "서버 응답이 DSM Web API 형식이 아닙니다."
        case .authenticationAPIUnavailable:
            "DSM 로그인 API를 찾을 수 없습니다."
        case .fileStationAPIUnavailable:
            "File Station API를 찾을 수 없습니다. DSM에서 File Station이 설치·활성화되어 있는지 확인해 주세요."
        }
    }
}

enum SynologyConnectionDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder",
        category: "Synology"
    )

    static func diagnostic(
        for error: Error,
        connection: RemoteConnection
    ) -> SynologyConnectionDiagnostic {
        let failure = error as? SynologyConnectionTestFailure
        let underlying = failure?.underlying ?? error
        let reference = diagnosticReference(for: underlying)
        let nsError = underlying as NSError

        if RemoteRequestCancellation.isCancellation(underlying) {
            return .init(
                stage: .cancelled,
                message: "연결 시도가 취소됐습니다.",
                reference: reference
            )
        }

        if isAddressResolutionFailure(nsError) {
            return .init(
                stage: .addressResolution,
                message: "NAS 주소를 찾지 못했습니다. 주소의 오타와 iPhone의 Wi‑Fi·VPN 연결을 확인해 주세요.",
                reference: reference
            )
        }

        if isTLSFailure(nsError) {
            return .init(
                stage: .tls,
                message: tlsMessage(for: nsError, connection: connection),
                reference: reference
            )
        }

        if isTransportFailure(nsError) {
            return .init(
                stage: .transport,
                message: transportMessage(for: nsError, connection: connection),
                reference: reference
            )
        }

        switch failure?.stage {
        case .webAPI:
            let detail = safeUserDetail(for: underlying)
            return .init(
                stage: .webAPI,
                message: "서버에는 연결됐지만 DSM Web API를 확인하지 못했습니다. DSM 웹 포트와 리버스 프록시 설정을 확인해 주세요.\(detail)",
                reference: reference
            )
        case .authentication:
            let detail = safeUserDetail(for: underlying)
            return .init(
                stage: .authentication,
                message: "DSM Web API에는 연결됐지만 로그인을 완료하지 못했습니다.\(detail)",
                reference: reference
            )
        case .rootPath:
            let detail = safeUserDetail(for: underlying)
            return .init(
                stage: .rootPath,
                message: "DSM 로그인은 완료됐지만 시작 위치를 열지 못했습니다. 공유 폴더 경로와 File Station 권한을 확인해 주세요.\(detail)",
                reference: reference
            )
        case .addressResolution, .transport, .tls, .cancelled, .unknown, .none:
            return .init(
                stage: failure?.stage ?? .unknown,
                message: "Synology 연결을 완료하지 못했습니다. DSM 주소·포트·로그인 정보를 확인해 주세요.",
                reference: reference
            )
        }
    }

    static func record(_ diagnostic: SynologyConnectionDiagnostic) {
        logger.error(
            "Synology failure stage=\(diagnostic.stage.rawValue, privacy: .public) reference=\(diagnostic.reference, privacy: .public)"
        )
    }

    static func recordConnectionTestSucceeded() {
        logger.info("Synology connection test succeeded")
    }

    private static func transportMessage(
        for error: NSError,
        connection: RemoteConnection
    ) -> String {
        let scheme = connection.usesTLS ? "HTTPS" : "HTTP"
        let expectedPort = ConnectionKind.synologyPort(usesTLS: connection.usesTLS)
        let endpoint = "\(scheme) 포트 \(connection.port)"
        let portHint = connection.port == expectedPort
            ? "DSM의 기본 \(scheme) 포트는 \(expectedPort)입니다."
            : "DSM의 기본 \(scheme) 포트는 \(expectedPort)이지만 현재 \(connection.port)로 설정되었습니다."

        if error.domain == NSURLErrorDomain, error.code == NSURLErrorTimedOut {
            return "\(endpoint)에서 응답 시간이 초과됐습니다. \(portHint) SFTP는 같은 주소를 쓰더라도 별도 포트 22를 사용합니다. Safari에서 같은 주소와 DSM 포트를 열어 로그인 화면이 나오는지 확인하고, 방화벽·포트 포워딩·VPN과 iPhone의 로컬 네트워크 권한을 확인해 주세요."
        }

        return "\(endpoint)에 연결할 수 없습니다. \(portHint) 방화벽·포트 포워딩·VPN과 iPhone의 로컬 네트워크 권한을 확인해 주세요."
    }

    private static func tlsMessage(
        for error: NSError,
        connection: RemoteConnection
    ) -> String {
        if error.domain == NSURLErrorDomain,
           error.code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
            return "iOS가 보안되지 않은 HTTP 연결을 차단했습니다. HTTPS 5001을 사용하거나 같은 로컬 네트워크·VPN에서 연결해 주세요."
        }

        let portHint = connection.port == ConnectionKind.synologyHTTPSPort
            ? ""
            : " 현재 포트는 \(connection.port)이며 DSM HTTPS 기본 포트는 5001입니다."
        return "TLS 연결을 만들지 못했습니다. DSM의 HTTPS 설정과 iPhone에서 신뢰할 수 있는 인증서인지 확인해 주세요.\(portHint) HTTP 포트 5000에 HTTPS를 사용해도 TLS 연결이 실패합니다."
    }

    private static func diagnosticReference(for error: Error) -> String {
        let nsError = error as NSError
        return "\(String(reflecting: type(of: error)))|\(nsError.domain)#\(nsError.code)"
    }

    private static func safeUserDetail(for error: Error) -> String {
        let description: String?
        switch error {
        case let probe as SynologyConnectionProbeError:
            description = probe.errorDescription
        case let authentication as SynologyAuthenticationError:
            description = authentication.errorDescription
        case let finderError as NasFinderError:
            description = finderError.errorDescription
        default:
            description = nil
        }
        guard let description, !description.isEmpty else { return "" }
        return " \(description)"
    }

    private static func isAddressResolutionFailure(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && [
            NSURLErrorCannotFindHost,
            NSURLErrorDNSLookupFailed,
            NSURLErrorBadURL,
            NSURLErrorUnsupportedURL
        ].contains(error.code)
    }

    private static func isTLSFailure(_ error: NSError) -> Bool {
        error.domain == NSURLErrorDomain && [
            NSURLErrorSecureConnectionFailed,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected,
            NSURLErrorClientCertificateRequired,
            NSURLErrorAppTransportSecurityRequiresSecureConnection
        ].contains(error.code)
    }

    private static func isTransportFailure(_ error: NSError) -> Bool {
        if error.domain == NSURLErrorDomain {
            return [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDataNotAllowed,
                NSURLErrorInternationalRoamingOff
            ].contains(error.code)
        }
        if error.domain == NSPOSIXErrorDomain {
            return [
                Int(ECONNREFUSED), Int(ETIMEDOUT), Int(EHOSTUNREACH),
                Int(ENETUNREACH), Int(ENETDOWN), Int(ECONNRESET), Int(ENOTCONN)
            ].contains(error.code)
        }
        return false
    }
}
