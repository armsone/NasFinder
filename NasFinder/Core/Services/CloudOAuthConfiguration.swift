import Foundation

struct CloudOAuthConfiguration: Sendable {
    let provider: OAuthProvider
    let clientID: String
    let authorizationEndpoint: URL
    let tokenEndpoint: URL
    let redirectURI: String
    let callbackScheme: String
    let scopes: [String]

    static func configuration(for provider: OAuthProvider) throws -> Self {
        switch provider {
        case .dropbox:
            return Self(
                provider: provider,
                clientID: "yrvp63r1yokddm1",
                authorizationEndpoint: URL(string: "https://www.dropbox.com/oauth2/authorize")!,
                tokenEndpoint: URL(string: "https://api.dropboxapi.com/oauth2/token")!,
                redirectURI: "db-yrvp63r1yokddm1://2/token",
                callbackScheme: "db-yrvp63r1yokddm1",
                scopes: [
                    "account_info.read", "files.metadata.read", "files.metadata.write",
                    "files.content.read", "files.content.write"
                ]
            )
        case .microsoft:
            return Self(
                provider: provider,
                clientID: "d16cf65e-ea78-4f75-a55f-f8888c5f10a0",
                authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
                tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
                redirectURI: "msauth.com.armsone.nasfinder://auth",
                callbackScheme: "msauth.com.armsone.nasfinder",
                scopes: ["openid", "profile", "offline_access", "User.Read", "Files.ReadWrite"]
            )
        case .google:
            guard let clientID = Bundle.main.object(forInfoDictionaryKey: "NasFinderGoogleClientID") as? String,
                  !clientID.isEmpty,
                  !clientID.hasPrefix("REPLACE_") else {
                throw CloudOAuthError.configurationMissing("Google OAuth 클라이언트 ID가 아직 설정되지 않았습니다.")
            }
            let reversed = clientID.split(separator: ".").reversed().joined(separator: ".")
            return Self(
                provider: provider,
                clientID: clientID,
                authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                redirectURI: "\(reversed):/oauthredirect",
                callbackScheme: reversed,
                scopes: ["openid", "email", "profile", "https://www.googleapis.com/auth/drive"]
            )
        case .box, .pCloud, .yandex:
            throw CloudOAuthError.configurationMissing("이 서비스의 OAuth 설정은 아직 준비되지 않았습니다.")
        }
    }
}

enum CloudOAuthError: LocalizedError, Sendable {
    case configurationMissing(String)
    case invalidCallback
    case authorizationFailed(String)
    case tokenExchangeFailed(String)

    var errorDescription: String? {
        switch self {
        case let .configurationMissing(message), let .authorizationFailed(message),
             let .tokenExchangeFailed(message): message
        case .invalidCallback: "로그인 결과를 확인하지 못했습니다. 다시 시도해 주세요."
        }
    }
}
