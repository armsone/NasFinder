import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// Google Photos Picker 전용 Authorization Code + PKCE(S256) 인가 흐름.
/// 기존 `CloudOAuthAuthorizer`(Drive 등)와 완전히 분리되어 있다.
@MainActor
final class GooglePhotosOAuthAuthorizer: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private let tokenClientFactory: @Sendable (GooglePhotosOAuthConfiguration) -> GooglePhotosTokenClient

    init(
        tokenClientFactory: @escaping @Sendable (GooglePhotosOAuthConfiguration) -> GooglePhotosTokenClient = {
            GooglePhotosTokenClient(configuration: $0)
        }
    ) {
        self.tokenClientFactory = tokenClientFactory
    }

    func authorize(configuration: GooglePhotosOAuthConfiguration? = nil) async throws -> GooglePhotosCredential {
        let configuration = try configuration ?? GooglePhotosOAuthConfiguration.loadFromMainBundle()
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomURLSafeString(byteCount: 24)

        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent")
        ]

        #if DEBUG
        if let languageIndex = ProcessInfo.processInfo.arguments.firstIndex(
            of: "-googlePhotosOAuthDemoLanguage"
        ), ProcessInfo.processInfo.arguments.indices.contains(languageIndex + 1) {
            components.queryItems?.append(
                URLQueryItem(
                    name: "hl",
                    value: ProcessInfo.processInfo.arguments[languageIndex + 1]
                )
            )
        }
        #endif

        let callbackURL: URL = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: components.url!,
                callbackURLScheme: configuration.callbackScheme
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: GooglePhotosOAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: GooglePhotosOAuthError.authorizationFailed)
                return
            }
        }
        session = nil

        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callback.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw GooglePhotosOAuthError.invalidCallback
        }
        if callback.queryItems?.contains(where: { $0.name == "error" }) == true {
            throw GooglePhotosOAuthError.authorizationFailed
        }
        guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw GooglePhotosOAuthError.invalidCallback
        }
        return try await tokenClientFactory(configuration)
            .exchangeAuthorizationCode(code, codeVerifier: verifier)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private static func randomURLSafeString(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
