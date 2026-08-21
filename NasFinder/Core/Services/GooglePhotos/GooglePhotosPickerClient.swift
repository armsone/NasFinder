import Foundation

/// 세션 ID·토큰·URL 등 민감한 값을 절대 포함하지 않는 Picker API 오류.
enum GooglePhotosPickerError: LocalizedError, Equatable, Sendable {
    case invalidResponse
    case invalidContentURL
    case http(statusCode: Int, category: GooglePhotosHTTPErrorCategory)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            "Google Photos 응답을 해석하지 못했습니다."
        case .invalidContentURL:
            "Google Photos 콘텐츠 주소를 구성하지 못했습니다."
        case let .http(statusCode, category):
            "\(category.localizedMessage) (HTTP \(statusCode))"
        }
    }

    /// 상태 코드·카테고리만 노출하는 안전한 응답 검증. 토큰·세션 ID·URL·본문은 절대 포함하지 않는다.
    static func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GooglePhotosPickerError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            throw GooglePhotosPickerError.http(
                statusCode: http.statusCode,
                category: GooglePhotosHTTPErrorCategory(statusCode: http.statusCode)
            )
        }
    }
}

enum GooglePhotosHTTPErrorCategory: String, Equatable, Sendable {
    case badRequest
    case unauthorized
    case forbidden
    case notFound
    case rateLimited
    case serverError
    case other

    init(statusCode: Int) {
        switch statusCode {
        case 400: self = .badRequest
        case 401: self = .unauthorized
        case 403: self = .forbidden
        case 404: self = .notFound
        case 429: self = .rateLimited
        case 500..<600: self = .serverError
        default: self = .other
        }
    }

    var localizedMessage: String {
        switch self {
        case .badRequest: "Google Photos 요청이 올바르지 않습니다."
        case .unauthorized: "Google Photos 인증이 필요합니다. 다시 로그인해 주세요."
        case .forbidden: "Google Photos 접근 권한이 없습니다."
        case .notFound: "Google Photos에서 요청한 항목을 찾을 수 없습니다."
        case .rateLimited: "Google Photos 요청 한도를 초과했습니다. 잠시 후 다시 시도해 주세요."
        case .serverError: "Google Photos 서버 오류가 발생했습니다."
        case .other: "Google Photos 요청이 실패했습니다."
        }
    }
}

/// Google Photos Picker REST 클라이언트. 네트워크와 토큰 공급을 주입받아 테스트할 수 있다.
struct GooglePhotosPickerClient: Sendable {
    static let defaultBaseURL = URL(string: "https://photospicker.googleapis.com")!
    static let defaultMaxItemCount = 50

    let baseURL: URL
    let httpClient: any GooglePhotosHTTPClient
    let accessTokenProvider: @Sendable () async throws -> String

    init(
        baseURL: URL = defaultBaseURL,
        httpClient: any GooglePhotosHTTPClient = URLSession.shared,
        accessTokenProvider: @escaping @Sendable () async throws -> String
    ) {
        self.baseURL = baseURL
        self.httpClient = httpClient
        self.accessTokenProvider = accessTokenProvider
    }

    // MARK: - Sessions

    func createSession(maxItemCount: Int = defaultMaxItemCount) async throws -> GooglePhotosPickingSession {
        var request = try await makeRequest(pathComponents: ["v1", "sessions"], method: "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // int64 필드는 proto JSON 규칙에 따라 문자열로 직렬화한다.
        let body: [String: Any] = ["pickingConfig": ["maxItemCount": String(maxItemCount)]]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await perform(request, decoding: GooglePhotosPickingSession.self)
    }

    func fetchSession(id: String) async throws -> GooglePhotosPickingSession {
        let request = try await makeRequest(pathComponents: ["v1", "sessions", id], method: "GET")
        return try await perform(request, decoding: GooglePhotosPickingSession.self)
    }

    func deleteSession(id: String) async throws {
        let request = try await makeRequest(pathComponents: ["v1", "sessions", id], method: "DELETE")
        _ = try await performRaw(request)
    }

    // MARK: - Media items

    func mediaItemsPage(
        sessionID: String,
        pageToken: String? = nil,
        pageSize: Int? = nil
    ) async throws -> GooglePhotosMediaItemsPage {
        var queryItems = [URLQueryItem(name: "sessionId", value: sessionID)]
        if let pageSize {
            queryItems.append(URLQueryItem(name: "pageSize", value: String(pageSize)))
        }
        if let pageToken {
            queryItems.append(URLQueryItem(name: "pageToken", value: pageToken))
        }
        let request = try await makeRequest(
            pathComponents: ["v1", "mediaItems"],
            method: "GET",
            queryItems: queryItems
        )
        return try await perform(request, decoding: GooglePhotosMediaItemsPage.self)
    }

    /// nextPageToken이 사라질 때까지 모든 페이지를 수집한다.
    func allMediaItems(sessionID: String, pageSize: Int? = nil) async throws -> [GooglePhotosPickedMediaItem] {
        var items: [GooglePhotosPickedMediaItem] = []
        var pageToken: String?
        var seenTokens = Set<String>()
        repeat {
            let page = try await mediaItemsPage(sessionID: sessionID, pageToken: pageToken, pageSize: pageSize)
            items.append(contentsOf: page.mediaItems)
            guard let next = page.nextPageToken, !next.isEmpty,
                  seenTokens.insert(next).inserted else {
                return items
            }
            pageToken = next
        } while true
    }

    // MARK: - Content download

    /// Bearer 토큰이 포함된 원본 콘텐츠 다운로드 요청을 만든다. (사진 `=d`, 동영상 `=dv`)
    func contentRequest(for item: GooglePhotosPickedMediaItem) async throws -> URLRequest {
        let url = try GooglePhotosContentURLBuilder.downloadURL(for: item)
        var request = URLRequest(url: url)
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    // MARK: - Internals

    private func makeRequest(
        pathComponents: [String],
        method: String,
        queryItems: [URLQueryItem]? = nil
    ) async throws -> URLRequest {
        var url = baseURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw GooglePhotosPickerError.invalidResponse
        }
        var request = URLRequest(url: finalURL)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let token = try await accessTokenProvider()
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func perform<T: Decodable>(_ request: URLRequest, decoding type: T.Type) async throws -> T {
        let data = try await performRaw(request)
        guard let decoded = try? JSONDecoder().decode(type, from: data) else {
            throw GooglePhotosPickerError.invalidResponse
        }
        return decoded
    }

    private func performRaw(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await httpClient.data(for: request)
        try GooglePhotosPickerError.validate(response)
        return data
    }
}
