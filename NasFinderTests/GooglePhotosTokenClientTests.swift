import Foundation
import XCTest
@testable import NasFinder

final class GooglePhotosTokenClientTests: XCTestCase {
    private let clientID = "1234-example.apps.googleusercontent.com"

    private func makeConfiguration() throws -> GooglePhotosOAuthConfiguration {
        try GooglePhotosOAuthConfiguration.make(clientID: clientID)
    }

    private func makeClient(
        mock: GooglePhotosHTTPClientMock,
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) throws -> GooglePhotosTokenClient {
        GooglePhotosTokenClient(configuration: try makeConfiguration(), httpClient: mock, now: { now })
    }

    // MARK: - 설정

    func testConfigurationDerivesReversedCallbackSchemeAndPickerScopeOnly() throws {
        let configuration = try makeConfiguration()
        XCTAssertEqual(configuration.callbackScheme, "com.googleusercontent.apps.1234-example")
        XCTAssertEqual(configuration.redirectURI, "com.googleusercontent.apps.1234-example:/oauthredirect")
        XCTAssertEqual(
            configuration.scopes,
            ["https://www.googleapis.com/auth/photospicker.mediaitems.readonly"]
        )
        XCTAssertEqual(configuration.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(configuration.revocationEndpoint.absoluteString, "https://oauth2.googleapis.com/revoke")
    }

    func testConfigurationRejectsMissingEmptyAndPlaceholderClientID() {
        for invalid in [nil, "", "   ", "REPLACE_WITH_CLIENT_ID"] {
            XCTAssertThrowsError(try GooglePhotosOAuthConfiguration.make(clientID: invalid)) { error in
                XCTAssertEqual(error as? GooglePhotosOAuthError, .configurationMissing)
            }
        }
    }

    // MARK: - 코드 교환

    func testExchangeAuthorizationCodeSendsPKCEFormBodyAndParsesCredential() async throws {
        let responseBody = Data("""
        {
          "access_token": "at-1",
          "refresh_token": "rt-1",
          "expires_in": 3600,
          "scope": "https://www.googleapis.com/auth/photospicker.mediaitems.readonly"
        }
        """.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: responseBody)])
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credential = try await makeClient(mock: mock, now: now)
            .exchangeAuthorizationCode("auth-code", codeVerifier: "verifier-1")

        XCTAssertEqual(credential.accessToken, "at-1")
        XCTAssertEqual(credential.refreshToken, "rt-1")
        XCTAssertEqual(credential.expirationDate, now.addingTimeInterval(3600))
        XCTAssertEqual(
            credential.grantedScopes,
            ["https://www.googleapis.com/auth/photospicker.mediaitems.readonly"]
        )

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(request.httpMethod, "POST")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code=auth-code"))
        XCTAssertTrue(body.contains("code_verifier=verifier-1"))
        XCTAssertFalse(body.contains("client_secret"))
    }

    // MARK: - 갱신

    func testRefreshPreservesExistingRefreshTokenWhenResponseOmitsIt() async throws {
        let responseBody = Data(#"{"access_token": "at-2", "expires_in": 1800}"#.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: responseBody)])
        let original = GooglePhotosCredential(
            accessToken: "at-old",
            refreshToken: "rt-keep",
            expirationDate: nil,
            grantedScopes: []
        )

        let refreshed = try await makeClient(mock: mock).refresh(original)
        XCTAssertEqual(refreshed.accessToken, "at-2")
        XCTAssertEqual(refreshed.refreshToken, "rt-keep")

        let body = String(data: try XCTUnwrap(mock.requests.first?.httpBody), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("grant_type=refresh_token"))
        XCTAssertTrue(body.contains("refresh_token=rt-keep"))
    }

    func testRefreshMapsInvalidGrantToReauthorizationRequiredWithoutBodyDetails() async throws {
        let responseBody = Data(#"{"error": "invalid_grant", "error_description": "Token revoked secret-detail"}"#.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(statusCode: 400, body: responseBody)])
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: "rt",
            expirationDate: nil,
            grantedScopes: []
        )

        do {
            _ = try await makeClient(mock: mock).refresh(credential)
            XCTFail("invalid_grant은 재인증 필요 오류로 매핑되어야 합니다.")
        } catch let error as GooglePhotosOAuthError {
            XCTAssertEqual(error, .reauthorizationRequired)
            XCTAssertFalse(error.localizedDescription.contains("secret-detail"))
        }
    }

    func testRefreshMapsOtherFailuresToTokenExchangeFailedWithStatusOnly() async throws {
        let responseBody = Data(#"{"error": "server_error", "error_description": "internal secret"}"#.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(statusCode: 500, body: responseBody)])
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: "rt",
            expirationDate: nil,
            grantedScopes: []
        )

        do {
            _ = try await makeClient(mock: mock).refresh(credential)
            XCTFail("HTTP 오류가 매핑되어야 합니다.")
        } catch let error as GooglePhotosOAuthError {
            XCTAssertEqual(error, .tokenExchangeFailed(statusCode: 500))
            XCTAssertFalse(error.localizedDescription.contains("internal secret"))
        }
    }

    func testRefreshWithoutRefreshTokenRequiresReauthorization() async throws {
        let mock = GooglePhotosHTTPClientMock()
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: nil,
            expirationDate: nil,
            grantedScopes: []
        )

        do {
            _ = try await makeClient(mock: mock).refresh(credential)
            XCTFail("refresh token이 없으면 재인증 필요 오류가 발생해야 합니다.")
        } catch let error as GooglePhotosOAuthError {
            XCTAssertEqual(error, .reauthorizationRequired)
        }
        XCTAssertTrue(mock.requests.isEmpty)
    }

    // MARK: - 해제

    func testRevokeSendsRefreshTokenToRevocationEndpoint() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: Data())])
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: "rt",
            expirationDate: nil,
            grantedScopes: []
        )
        try await makeClient(mock: mock).revoke(credential)

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://oauth2.googleapis.com/revoke")
        let body = String(data: try XCTUnwrap(request.httpBody), encoding: .utf8) ?? ""
        XCTAssertEqual(body, "token=rt")
    }

    func testRevokeFailureExposesOnlyStatusCode() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(statusCode: 400, body: Data("secret".utf8))])
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: nil,
            expirationDate: nil,
            grantedScopes: []
        )

        do {
            try await makeClient(mock: mock).revoke(credential)
            XCTFail("revoke 실패가 오류로 매핑되어야 합니다.")
        } catch let error as GooglePhotosOAuthError {
            XCTAssertEqual(error, .revocationFailed(statusCode: 400))
            XCTAssertFalse(error.localizedDescription.contains("secret"))
        }
    }

    // MARK: - 자격 증명

    func testCredentialExpiryUsesLeeway() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let credential = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: nil,
            expirationDate: now.addingTimeInterval(30),
            grantedScopes: []
        )
        XCTAssertTrue(credential.isExpired(now: now, leeway: 60))
        XCTAssertFalse(credential.isExpired(now: now, leeway: 10))

        let noExpiry = GooglePhotosCredential(
            accessToken: "at",
            refreshToken: nil,
            expirationDate: nil,
            grantedScopes: []
        )
        XCTAssertFalse(noExpiry.isExpired(now: now))
    }
}
