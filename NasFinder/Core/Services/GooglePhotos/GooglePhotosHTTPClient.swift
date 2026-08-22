import Foundation

/// Google Photos Picker 관련 네트워크 호출을 테스트에서 대체할 수 있도록 하는 최소 HTTP 추상화.
protocol GooglePhotosHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: GooglePhotosHTTPClient {}
