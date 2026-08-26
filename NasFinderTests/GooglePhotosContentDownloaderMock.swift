import Foundation
@testable import NasFinder

/// Google Photos 다운로드 primitive 테스트 전용 목. 실제 네트워크에 접근하지 않고
/// 로컬 임시 파일 URL을 돌려준다.
final class GooglePhotosContentDownloaderMock: GooglePhotosContentDownloader, @unchecked Sendable {
    enum Stub {
        case success(fileContents: Data, statusCode: Int = 200)
        case failure(Error)
    }

    private let lock = NSLock()
    private var pendingStubs: [Stub]
    private var recordedRequests: [URLRequest] = []
    private var createdTempURLs: [URL] = []

    init(stubs: [Stub] = []) {
        pendingStubs = stubs
    }

    var requests: [URLRequest] {
        lock.withLock { recordedRequests }
    }

    /// 테스트가 끝난 뒤 생성된 임시 파일을 정리한다.
    func cleanUpCreatedTempFiles() {
        let urls = lock.withLock { createdTempURLs }
        for url in urls {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func download(for request: URLRequest) async throws -> (URL, URLResponse) {
        let stub: Stub? = lock.withLock {
            recordedRequests.append(request)
            return pendingStubs.isEmpty ? nil : pendingStubs.removeFirst()
        }

        switch stub {
        case .none:
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let url = try writeTempFile(Data())
            return (url, response)

        case let .failure(error):
            throw error

        case let .success(fileContents, statusCode):
            let response = HTTPURLResponse(
                url: request.url ?? URL(string: "https://example.invalid")!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )!
            let url = try writeTempFile(fileContents)
            return (url, response)
        }
    }

    private func writeTempFile(_ contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try contents.write(to: url)
        lock.withLock { createdTempURLs.append(url) }
        return url
    }
}
