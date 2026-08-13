import AuthenticationServices
import Combine
import CryptoKit
import Foundation
import Security
import UIKit

@MainActor
final class CloudOAuthAuthorizer: NSObject, ObservableObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func authorize(provider: OAuthProvider) async throws -> OAuthCredential {
        let configuration = try CloudOAuthConfiguration.configuration(for: provider)
        let verifier = Self.randomURLSafeString(byteCount: 32)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
        let state = Self.randomURLSafeString(byteCount: 24)

        var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false)!
        var queryItems = [
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        if provider == .dropbox {
            queryItems.append(URLQueryItem(name: "token_access_type", value: "offline"))
        } else if provider == .google {
            queryItems.append(URLQueryItem(name: "access_type", value: "offline"))
            queryItems.append(URLQueryItem(name: "prompt", value: "consent"))
        }
        components.queryItems = queryItems

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
                    continuation.resume(throwing: CloudOAuthError.invalidCallback)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            guard session.start() else {
                self.session = nil
                continuation.resume(throwing: CloudOAuthError.authorizationFailed("로그인 화면을 열지 못했습니다."))
                return
            }
        }
        session = nil

        guard let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false),
              callback.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw CloudOAuthError.invalidCallback
        }
        if let message = callback.queryItems?.first(where: { $0.name == "error_description" })?.value {
            throw CloudOAuthError.authorizationFailed(message)
        }
        guard let code = callback.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw CloudOAuthError.invalidCallback
        }
        return try await exchange(code: code, verifier: verifier, configuration: configuration)
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }

    private func exchange(
        code: String,
        verifier: String,
        configuration: CloudOAuthConfiguration
    ) async throws -> OAuthCredential {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": verifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            let detail = String(data: data, encoding: .utf8) ?? "HTTP 응답 오류"
            throw CloudOAuthError.tokenExchangeFailed(detail)
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        let scopeText = object["scope"] as? String
        return OAuthCredential(
            provider: configuration.provider,
            accessToken: accessToken,
            refreshToken: object["refresh_token"] as? String,
            expirationDate: expiresIn.map { Date().addingTimeInterval($0) },
            accountIdentifier: nil,
            grantedScopes: scopeText?.split(separator: " ").map(String.init) ?? configuration.scopes
        )
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
