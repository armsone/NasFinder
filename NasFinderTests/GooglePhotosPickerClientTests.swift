import Foundation
import XCTest
@testable import NasFinder

final class GooglePhotosPickerClientTests: XCTestCase {
    private func makeClient(
        mock: GooglePhotosHTTPClientMock,
        token: String = "test-access-token"
    ) -> GooglePhotosPickerClient {
        GooglePhotosPickerClient(httpClient: mock) { token }
    }

    private func sessionJSON(id: String = "session-1") -> Data {
        Data("""
        {"id": "\(id)", "pickerUri": "https://photos.google.com/picker/\(id)"}
        """.utf8)
    }

    func testCreateSessionSendsPostWithDefaultMaxItemCountBody() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: sessionJSON())])
        let session = try await makeClient(mock: mock).createSession()

        XCTAssertEqual(session.id, "session-1")
        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://photospicker.googleapis.com/v1/sessions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let pickingConfig = try XCTUnwrap(object["pickingConfig"] as? [String: Any])
        XCTAssertEqual(pickingConfig["maxItemCount"] as? String, "50")
        XCTAssertEqual(object.count, 1)
        XCTAssertEqual(pickingConfig.count, 1)
    }

    func testCreateSessionSendsCustomMaxItemCountAsString() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: sessionJSON())])
        _ = try await makeClient(mock: mock).createSession(maxItemCount: 7)

        let body = try XCTUnwrap(mock.requests.first?.httpBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: [String: String]])
        XCTAssertEqual(object["pickingConfig"]?["maxItemCount"], "7")
    }

    func testFetchSessionUsesGetWithEscapedIdentifier() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: sessionJSON(id: "abc def"))])
        _ = try await makeClient(mock: mock).fetchSession(id: "abc def")

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://photospicker.googleapis.com/v1/sessions/abc%20def"
        )
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }

    func testDeleteSessionUsesDeleteMethod() async throws {
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(body: Data())])
        try await makeClient(mock: mock).deleteSession(id: "session-9")

        let request = try XCTUnwrap(mock.requests.first)
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://photospicker.googleapis.com/v1/sessions/session-9"
        )
    }

    func testAllMediaItemsFollowsPaginationAndBuildsQueries() async throws {
        let firstPage = Data("""
        {"mediaItems": [{"id": "a", "type": "PHOTO"}], "nextPageToken": "token-2"}
        """.utf8)
        let secondPage = Data("""
        {"mediaItems": [{"id": "b", "type": "VIDEO"}]}
        """.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [
            .init(body: firstPage),
            .init(body: secondPage)
        ])

        let items = try await makeClient(mock: mock).allMediaItems(sessionID: "session-1", pageSize: 25)
        XCTAssertEqual(items.map(\.id), ["a", "b"])
        XCTAssertEqual(mock.requests.count, 2)

        let firstComponents = try XCTUnwrap(
            mock.requests[0].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        XCTAssertEqual(firstComponents.path, "/v1/mediaItems")
        XCTAssertEqual(
            firstComponents.queryItems,
            [
                URLQueryItem(name: "sessionId", value: "session-1"),
                URLQueryItem(name: "pageSize", value: "25")
            ]
        )

        let secondComponents = try XCTUnwrap(
            mock.requests[1].url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        )
        XCTAssertEqual(
            secondComponents.queryItems,
            [
                URLQueryItem(name: "sessionId", value: "session-1"),
                URLQueryItem(name: "pageSize", value: "25"),
                URLQueryItem(name: "pageToken", value: "token-2")
            ]
        )
    }

    func testAllMediaItemsStopsWhenPageTokenRepeats() async throws {
        let looping = Data("""
        {"mediaItems": [{"id": "a", "type": "PHOTO"}], "nextPageToken": "same-token"}
        """.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [
            .init(body: looping),
            .init(body: looping)
        ])

        let items = try await makeClient(mock: mock).allMediaItems(sessionID: "session-1")
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(mock.requests.count, 2)
    }

    func testHTTPErrorMappingExposesOnlyStatusAndCategory() async throws {
        let secretBody = Data(#"{"error": {"message": "secret-detail token=abc"}}"#.utf8)
        let mock = GooglePhotosHTTPClientMock(stubs: [.init(statusCode: 401, body: secretBody)])

        do {
            _ = try await makeClient(mock: mock).fetchSession(id: "session-1")
            XCTFail("401 응답이 오류로 매핑되어야 합니다.")
        } catch let error as GooglePhotosPickerError {
            XCTAssertEqual(error, .http(statusCode: 401, category: .unauthorized))
            let message = error.localizedDescription
            XCTAssertFalse(message.contains("secret-detail"))
            XCTAssertFalse(message.contains("token=abc"))
            XCTAssertTrue(message.contains("401"))
        }
    }

    func testHTTPErrorCategoryMapping() {
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 400), .badRequest)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 401), .unauthorized)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 403), .forbidden)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 404), .notFound)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 429), .rateLimited)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 500), .serverError)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 503), .serverError)
        XCTAssertEqual(GooglePhotosHTTPErrorCategory(statusCode: 418), .other)
    }

    func testContentRequestAddsBearerTokenAndDownloadSuffix() async throws {
        let mock = GooglePhotosHTTPClientMock()
        let item = GooglePhotosPickedMediaItem(
            id: "video-1",
            createTime: nil,
            type: .video,
            mediaFile: GooglePhotosMediaFile(
                baseURL: "https://lh3.googleusercontent.com/p/video-1",
                mimeType: "video/mp4",
                filename: "MOV_0001.MP4",
                metadata: nil
            )
        )

        let request = try await makeClient(mock: mock).contentRequest(for: item)
        XCTAssertEqual(request.url?.absoluteString, "https://lh3.googleusercontent.com/p/video-1=dv")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
    }
}
