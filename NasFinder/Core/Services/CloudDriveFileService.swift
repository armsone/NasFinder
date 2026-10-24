import Foundation
import UniformTypeIdentifiers

actor CloudDriveFileService: RemoteFileService {
    let connection: RemoteConnection
    nonisolated let capabilities: RemoteFileServiceCapabilities = []
    nonisolated let permitsFullDownloadForVideoThumbnail = false

    private var oauth: OAuthCredential
    private let credentialStore = KeychainCredentialStore()
    private var googleFolderIDs: [String: String] = ["/": "root"]

    init(connection: RemoteConnection, credential: RemoteCredential) {
        self.connection = connection
        guard case let .oauth(oauth)? = credential.cloudCredential else {
            preconditionFailure("Cloud connection requires an OAuth credential")
        }
        self.oauth = oauth
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        try await refreshAccessTokenIfNeeded()
        let directory = normalized(path)
        switch oauth.provider {
        case .dropbox: return try await listDropbox(directory: directory)
        case .microsoft: return try await listOneDrive(directory: directory)
        case .google: return try await listGoogleDrive(directory: directory)
        case .box, .pCloud, .yandex:
            throw CloudDriveError.unsupportedProvider
        }
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await refreshAccessTokenIfNeeded()
        let request: URLRequest
        switch oauth.provider {
        case .dropbox:
            var value = authorizedRequest(URL(string: "https://content.dropboxapi.com/2/files/download")!)
            value.httpMethod = "POST"
            value.setValue(jsonString(["path": item.path]), forHTTPHeaderField: "Dropbox-API-Arg")
            request = value
        case .microsoft:
            let path = encodedPath(item.path)
            request = authorizedRequest(URL(string: "https://graph.microsoft.com/v1.0/me/drive/root:\(path):/content")!)
        case .google:
            guard let identifier = item.remoteIdentifier else { throw CloudDriveError.invalidItem }
            request = authorizedRequest(URL(string: "https://www.googleapis.com/drive/v3/files/\(identifier)?alt=media")!)
        case .box, .pCloud, .yandex:
            throw CloudDriveError.unsupportedProvider
        }
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)
        try validate(response)
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("NasFinder-\(UUID().uuidString)-\(item.name)")
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    func testConnection() async throws {
        _ = try await list(directory: "/")
    }

    /// 표시용 계정 정보만 가져온다. 연결의 UUID나 파일 경로는 바꾸지 않는다.
    func dropboxAccountDisplayName(persistRefreshedCredential: Bool = true) async throws -> String {
        guard oauth.provider == .dropbox else { throw CloudDriveError.unsupportedProvider }
        try await refreshAccessTokenIfNeeded(persistCredential: persistRefreshedCredential)
        var request = authorizedRequest(URL(string: "https://api.dropboxapi.com/2/users/get_current_account")!)
        request.httpMethod = "POST"
        let object = try await json(request)
        let email = (object["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = ((object["name"] as? [String: Any])?["display_name"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let email, !email.isEmpty { return email }
        if let name, !name.isEmpty { return name }
        throw CloudDriveError.invalidResponse
    }

    private func listDropbox(directory: String) async throws -> [RemoteFileItem] {
        var request = authorizedRequest(URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": directory == "/" ? "" : directory])
        var object = try await json(request)
        var entries = object["entries"] as? [[String: Any]] ?? []
        // 한 번에 다 오지 않은 폴더는 cursor로 다음 묶음을 끝까지 이어 받는다(files/list_folder/continue).
        var pages = 1
        while object["has_more"] as? Bool == true,
              let cursor = object["cursor"] as? String, !cursor.isEmpty {
            try Self.checkNextPage(&pages)
            var next = authorizedRequest(URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!)
            next.httpMethod = "POST"
            next.setValue("application/json", forHTTPHeaderField: "Content-Type")
            next.httpBody = try JSONSerialization.data(withJSONObject: ["cursor": cursor])
            object = try await json(next)
            entries += object["entries"] as? [[String: Any]] ?? []
        }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let tag = entry[".tag"] as? String else { return nil }
            let itemPath = entry["path_display"] as? String ?? childPath(directory, name)
            return item(
                path: itemPath,
                identifier: entry["id"] as? String,
                revision: entry["rev"] as? String,
                name: name,
                isFolder: tag == "folder",
                size: (entry["size"] as? NSNumber)?.int64Value,
                modified: entry["server_modified"] as? String,
                mimeType: nil
            )
        }
    }

    private func listOneDrive(directory: String) async throws -> [RemoteFileItem] {
        let endpoint = directory == "/"
            ? "https://graph.microsoft.com/v1.0/me/drive/root/children"
            : "https://graph.microsoft.com/v1.0/me/drive/root:\(encodedPath(directory)):/children"
        var object = try await json(authorizedRequest(URL(string: endpoint)!))
        var entries = object["value"] as? [[String: Any]] ?? []
        // 다음 쪽 주소(@odata.nextLink)가 있으면 같은 인증으로 끝까지 이어 받는다.
        var pages = 1
        while let nextLink = object["@odata.nextLink"] as? String,
              let nextURL = URL(string: nextLink), nextURL.host == "graph.microsoft.com" {
            try Self.checkNextPage(&pages)
            object = try await json(authorizedRequest(nextURL))
            entries += object["value"] as? [[String: Any]] ?? []
        }
        return entries.compactMap { entry in
            guard let name = entry["name"] as? String else { return nil }
            let file = entry["file"] as? [String: Any]
            return item(
                path: childPath(directory, name),
                identifier: entry["id"] as? String,
                revision: entry["eTag"] as? String,
                name: name,
                isFolder: entry["folder"] != nil,
                size: (entry["size"] as? NSNumber)?.int64Value,
                modified: entry["lastModifiedDateTime"] as? String,
                mimeType: file?["mimeType"] as? String
            )
        }
    }

    private func listGoogleDrive(directory: String) async throws -> [RemoteFileItem] {
        let parentID = try await googleFolderID(for: directory)
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        let baseQuery = [
            URLQueryItem(name: "q", value: "'\(parentID)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,size,modifiedTime,md5Checksum,parents)"),
            URLQueryItem(name: "pageSize", value: "1000")
        ]
        components.queryItems = baseQuery
        var object = try await json(authorizedRequest(components.url!))
        var entries = object["files"] as? [[String: Any]] ?? []
        // nextPageToken이 있으면 같은 조건으로 다음 쪽을 끝까지 이어 받는다.
        var pages = 1
        while let token = object["nextPageToken"] as? String, !token.isEmpty {
            try Self.checkNextPage(&pages)
            components.queryItems = baseQuery + [URLQueryItem(name: "pageToken", value: token)]
            object = try await json(authorizedRequest(components.url!))
            entries += object["files"] as? [[String: Any]] ?? []
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, let name = entry["name"] as? String else { return nil }
            let path = childPath(directory, name)
            let isFolder = entry["mimeType"] as? String == "application/vnd.google-apps.folder"
            if isFolder { googleFolderIDs[path] = id }
            return item(
                path: path,
                identifier: id,
                revision: entry["md5Checksum"] as? String,
                name: name,
                isFolder: isFolder,
                size: (entry["size"] as? NSString)?.longLongValue,
                modified: entry["modifiedTime"] as? String,
                mimeType: entry["mimeType"] as? String
            )
        }
    }

    /// 다음 쪽을 받기 전에 취소를 확인하고, 서버가 같은 쪽을 계속 돌려주는 경우를 막는 상한을 둔다.
    private static let maximumListPages = 500

    private static func checkNextPage(_ pages: inout Int) throws {
        try Task.checkCancellation()
        pages += 1
        guard pages <= maximumListPages else { throw CloudDriveError.tooManyPages }
    }

    private func googleFolderID(for path: String) async throws -> String {
        if let cached = googleFolderIDs[path] { return cached }
        var currentPath = "/"
        var parentID = "root"
        for component in path.split(separator: "/").map(String.init) {
            currentPath = childPath(currentPath, component)
            if let cached = googleFolderIDs[currentPath] {
                parentID = cached
                continue
            }
            var parts = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            let escaped = component.replacingOccurrences(of: "'", with: "\\'")
            parts.queryItems = [
                URLQueryItem(name: "q", value: "'\(parentID)' in parents and name = '\(escaped)' and mimeType = 'application/vnd.google-apps.folder' and trashed = false"),
                URLQueryItem(name: "fields", value: "files(id)"),
                URLQueryItem(name: "pageSize", value: "2")
            ]
            let object = try await json(authorizedRequest(parts.url!))
            guard let id = (object["files"] as? [[String: Any]])?.first?["id"] as? String else {
                throw CloudDriveError.folderNotFound(path)
            }
            googleFolderIDs[currentPath] = id
            parentID = id
        }
        return parentID
    }

    private func authorizedRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(oauth.accessToken)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func refreshAccessTokenIfNeeded(persistCredential: Bool = true) async throws {
        let originalOAuth = oauth
        guard let expirationDate = oauth.expirationDate,
              expirationDate <= Date().addingTimeInterval(60) else { return }
        guard let refreshToken = oauth.refreshToken, !refreshToken.isEmpty else {
            throw CloudDriveError.signInRequired
        }

        let configuration = try CloudOAuthConfiguration.configuration(for: oauth.provider)
        var parameters = [
            "client_id": configuration.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken
        ]
        if oauth.provider == .microsoft || oauth.provider == .google {
            parameters["scope"] = configuration.scopes.joined(separator: " ")
        }

        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = FormURLEncoder.encode(parameters)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = object["access_token"] as? String else {
            throw CloudDriveError.invalidResponse
        }

        let expiresIn = (object["expires_in"] as? NSNumber)?.doubleValue
        let refreshed = OAuthCredential(
            provider: originalOAuth.provider,
            accessToken: accessToken,
            refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
            expirationDate: expiresIn.map { Date().addingTimeInterval($0) },
            accountIdentifier: originalOAuth.accountIdentifier,
            grantedScopes: (object["scope"] as? String)?.split(separator: " ").map(String.init)
                ?? originalOAuth.grantedScopes
        )
        if persistCredential {
            let credentialStore = self.credentialStore
            let connectionID = connection.id
            // ConnectionStore의 삭제·재연결 쓰기와 같은 actor에서 비교와 저장을 연속 실행한다.
            // 응답 대기 중 제거되거나 교체된 자격 증명을 복원/덮어쓰지 않는다.
            let saved = try await MainActor.run {
                guard try credentialStore.cloudCredential(for: connectionID) == .oauth(originalOAuth) else {
                    return false
                }
                try credentialStore.save(.oauth(refreshed), for: connectionID)
                return true
            }
            guard saved else { throw CloudDriveError.signInRequired }
        }
        oauth = refreshed
    }

    private func json(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudDriveError.invalidResponse
        }
        return object
    }

    private func validate(_ response: URLResponse, data: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            // 서버 응답 본문(계정·내부 정보가 섞일 수 있음)은 화면에 보이지 않고 상태 코드만 알린다.
            let status = (response as? HTTPURLResponse)?.statusCode
            throw CloudDriveError.http(CloudDriveError.message(forStatus: status))
        }
    }

    private func item(
        path: String,
        identifier: String?,
        revision: String?,
        name: String,
        isFolder: Bool,
        size: Int64?,
        modified: String?,
        mimeType: String?
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connection.id,
            path: path,
            remoteIdentifier: identifier,
            parentRemoteIdentifier: nil,
            revisionIdentifier: revision,
            name: name,
            kind: isFolder ? .folder : .file,
            size: size,
            modifiedAt: modified.flatMap(Self.parseDate),
            contentTypeIdentifier: mimeType.flatMap { UTType(mimeType: $0)?.identifier }
        )
    }

    /// 소수 초가 붙은 시각(예: 2026-10-22T01:02:03.456Z)과 붙지 않은 시각을 모두 읽는다.
    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private func normalized(_ path: String?) -> String {
        let trimmed = (path ?? connection.normalizedRootPath).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "." ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/\(trimmed)")
    }

    private func childPath(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/\(name)" : "\(parent)/\(name)"
    }

    private func encodedPath(_ path: String) -> String {
        path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0)
        }.joined(separator: "/").withLeadingSlash
    }

    private func jsonString(_ object: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: object)
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

enum CloudDriveError: LocalizedError, Sendable {
    case invalidItem
    case invalidResponse
    case unsupportedProvider
    case folderNotFound(String)
    case http(String)
    case signInRequired
    case tooManyPages

    static func message(forStatus status: Int?) -> String {
        switch status {
        case 401: "클라우드 서비스가 로그인을 받아들이지 않았습니다. 연결 설정에서 이 계정을 다시 연결해 주세요. (HTTP 401)"
        case 403: "클라우드 서비스가 이 요청을 허용하지 않았습니다. 권한을 확인해 주세요. (HTTP 403)"
        case 404: "클라우드에서 항목을 찾지 못했습니다. (HTTP 404)"
        case 429: "클라우드 서비스 요청이 많아 잠시 거부되었습니다. 잠시 후 다시 시도해 주세요. (HTTP 429)"
        case let code?: "클라우드 서비스가 요청을 거부했습니다. (HTTP \(code))"
        case nil: "클라우드 서비스가 올바른 응답을 보내지 않았습니다."
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidItem: "파일 식별자가 없어 요청을 완료할 수 없습니다."
        case .invalidResponse: "클라우드 서비스의 응답을 읽지 못했습니다."
        case .unsupportedProvider: "아직 지원하지 않는 클라우드 서비스입니다."
        case let .folderNotFound(path): "폴더를 찾지 못했습니다: \(path)"
        case let .http(message): message
        case .signInRequired: "로그인이 만료되었습니다. 연결 설정에서 이 계정을 다시 연결해 주세요."
        case .tooManyPages: "폴더 항목이 너무 많아 목록을 끝까지 받지 못했습니다."
        }
    }
}

private extension String {
    var withLeadingSlash: String { hasPrefix("/") ? self : "/\(self)" }
}
