import Foundation
@testable import NasFinder

/// Google Photos 테스트 전용 HTTP 목. 실제 네트워크에 접근하지 않는다.
final class GooglePhotosHTTPClientMock: GooglePhotosHTTPClient, @unchecked Sendable {
    struct StubResponse {
        var statusCode: Int = 200
        var body: Data = Data("{}".utf8)
    }

    private let lock = NSLock()
    private var pendingStubs: [StubResponse]
    private var recordedRequests: [URLRequest] = []

    init(stubs: [StubResponse] = []) {
        pendingStubs = stubs
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let stub = lock.withLock {
            recordedRequests.append(request)
            return pendingStubs.isEmpty ? StubResponse() : pendingStubs.removeFirst()
        }
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://example.invalid")!,
            statusCode: stub.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: nil
        )!
        return (stub.body, response)
    }
}
