import Foundation

/// Google Photos Picker 전용 OAuth 설정. 기존 Google Drive OAuth 설정과 완전히 분리되어 있다.
struct GooglePhotosOAuthConfiguration: Sendable {
    let clientID: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let revocationEndpoint: URL
    let redirectURI: String
    let callbackScheme: String
    let scopes: [String]

    static let pickerScope = "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
    static let infoPlistClientIDKey = "NasFinderGooglePhotosClientID"

    static func make(clientID rawClientID: String?) throws -> Self {
        guard let clientID = rawClientID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientID.isEmpty,
              !clientID.hasPrefix("REPLACE_") else {
            throw GooglePhotosOAuthError.configurationMissing
        }
        let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
        return Self(
            clientID: clientID,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            redirectURI: "\(reversed):/oauthredirect",
            callbackScheme: reversed,
            scopes: [pickerScope]
        )
    }

    static func loadFromMainBundle() throws -> Self {
        try make(clientID: Bundle.main.object(forInfoDictionaryKey: infoPlistClientIDKey) as? String)
    }
}

/// 토큰·인가 코드·응답 본문 등 민감한 값을 절대 포함하지 않는 OAuth 오류.
enum GooglePhotosOAuthError: LocalizedError, Equatable, Sendable {
    case configurationMissing
    case invalidCallback
    case authorizationFailed
    case tokenExchangeFailed(statusCode: Int?)
    case reauthorizationRequired
    case revocationFailed(statusCode: Int?)

    var errorDescription: String? {
        switch self {
        case .configurationMissing:
            "Google Photos OAuth 클라이언트 ID가 아직 설정되지 않았습니다."
        case .invalidCallback:
            "Google Photos 로그인 결과를 확인하지 못했습니다. 다시 시도해 주세요."
        case .authorizationFailed:
            "Google Photos 로그인 화면을 열지 못했습니다."
        case let .tokenExchangeFailed(statusCode):
            if let statusCode {
                "Google Photos 인증 토큰을 발급받지 못했습니다. (HTTP \(statusCode))"
            } else {
                "Google Photos 인증 토큰을 발급받지 못했습니다."
            }
        case .reauthorizationRequired:
            "Google Photos 인증이 만료되었습니다. 다시 로그인해 주세요."
        case let .revocationFailed(statusCode):
            if let statusCode {
                "Google Photos 인증 해제 요청이 실패했습니다. (HTTP \(statusCode))"
            } else {
                "Google Photos 인증 해제 요청이 실패했습니다."
            }
        }
    }
}
