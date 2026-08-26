import Foundation

/// Google Photos Picker용 토큰 교환/갱신/해제 클라이언트.
/// 오류에 응답 본문이나 토큰 값을 절대 포함하지 않는다.
struct GooglePhotosTokenClient: Sendable {
    let configuration: GooglePhotosOAuthConfiguration
    let httpClient: any GooglePhotosHTTPClient
    let now: @Sendable () -> Date

    init(
        configuration: GooglePhotosOAuthConfiguration,
        httpClient: any GooglePhotosHTTPClient = URLSession.shared,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.configuration = configuration
        self.httpClient = httpClient
        self.now = now
    }

    func exchangeAuthorizationCode(_ code: String, codeVerifier: String) async throws -> GooglePhotosCredential {
        try await requestToken(parameters: [
            "client_id": configuration.clientID,
            "code": code,
            "code_verifier": codeVerifier,
            "grant_type": "authorization_code",
            "redirect_uri": configuration.redirectURI
        ], previousRefreshToken: nil)
    }

    func refresh(_ credential: GooglePhotosCredential) async throws -> GooglePhotosCredential {
        guard let refreshToken = credential.refreshToken, !refreshToken.isEmpty else {
            throw GooglePhotosOAuthError.reauthorizationRequired
        }
        return try await requestToken(parameters: [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ], previousRefreshToken: refreshToken)
    }

    /// 원격 revoke 요청. 실패해도 호출 측에서 로컬 자격 증명 삭제를 계속 진행할 수 있도록
    /// 오류를 던지기만 하고 다른 부수 효과는 없다.
    func revoke(_ credential: GooglePhotosCredential) async throws {
        var request = URLRequest(url: configuration.revocationEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode([
            "token": credential.refreshToken ?? credential.accessToken
        ])
        let (_, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GooglePhotosOAuthError.revocationFailed(statusCode: nil)
        }
        guard 200..<300 ~= http.statusCode else {
            throw GooglePhotosOAuthError.revocationFailed(statusCode: http.statusCode)
        }
    }

    private func requestToken(
        parameters: [String: String],
        previousRefreshToken: String?
    ) async throws -> GooglePhotosCredential {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(parameters)

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GooglePhotosOAuthError.tokenExchangeFailed(statusCode: nil)
        }
        guard 200..<300 ~= http.statusCode else {
            let errorCode = (try? JSONDecoder().decode(TokenErrorResponse.self, from: data))?.error
            if errorCode == "invalid_grant" {
                throw GooglePhotosOAuthError.reauthorizationRequired
            }
            throw GooglePhotosOAuthError.tokenExchangeFailed(statusCode: http.statusCode)
        }
        guard let payload = try? JSONDecoder().decode(TokenResponse.self, from: data),
              !payload.accessToken.isEmpty else {
            throw GooglePhotosOAuthError.tokenExchangeFailed(statusCode: http.statusCode)
        }
        return GooglePhotosCredential(
            accessToken: payload.accessToken,
            refreshToken: payload.refreshToken ?? previousRefreshToken,
            expirationDate: payload.expiresIn.map { now().addingTimeInterval($0) },
            grantedScopes: payload.scope?.split(separator: " ").map(String.init) ?? configuration.scopes
        )
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private struct TokenErrorResponse: Decodable {
        let error: String?
    }
}
