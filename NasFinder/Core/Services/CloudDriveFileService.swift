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

    private func listDropbox(directory: String) async throws -> [RemoteFileItem] {
        var request = authorizedRequest(URL(string: "https://api.dropboxapi.com/2/files/list_folder")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["path": directory == "/" ? "" : directory])
        let object = try await json(request)
        let entries = object["entries"] as? [[String: Any]] ?? []
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
        let object = try await json(authorizedRequest(URL(string: endpoint)!))
        let entries = object["value"] as? [[String: Any]] ?? []
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
        components.queryItems = [
            URLQueryItem(name: "q", value: "'\(parentID)' in parents and trashed = false"),
            URLQueryItem(name: "fields", value: "files(id,name,mimeType,size,modifiedTime,md5Checksum,parents)"),
            URLQueryItem(name: "pageSize", value: "1000")
        ]
        let object = try await json(authorizedRequest(components.url!))
        let entries = object["files"] as? [[String: Any]] ?? []
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

    private func refreshAccessTokenIfNeeded() async throws {
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
            provider: oauth.provider,
            accessToken: accessToken,
            refreshToken: (object["refresh_token"] as? String) ?? refreshToken,
            expirationDate: expiresIn.map { Date().addingTimeInterval($0) },
            accountIdentifier: oauth.accountIdentifier,
            grantedScopes: (object["scope"] as? String)?.split(separator: " ").map(String.init)
                ?? oauth.grantedScopes
        )
        try credentialStore.save(.oauth(refreshed), for: connection.id)
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
            let message = String(data: data, encoding: .utf8) ?? "클라우드 서비스가 요청을 거부했습니다."
            throw CloudDriveError.http(message)
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
            modifiedAt: modified.flatMap { ISO8601DateFormatter().date(from: $0) },
            contentTypeIdentifier: mimeType.flatMap { UTType(mimeType: $0)?.identifier }
        )
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

    var errorDescription: String? {
        switch self {
        case .invalidItem: "파일 식별자가 없어 요청을 완료할 수 없습니다."
        case .invalidResponse: "클라우드 서비스의 응답을 읽지 못했습니다."
        case .unsupportedProvider: "아직 지원하지 않는 클라우드 서비스입니다."
        case let .folderNotFound(path): "폴더를 찾지 못했습니다: \(path)"
        case let .http(message): message
        case .signInRequired: "로그인이 만료되었습니다. 연결 설정에서 이 계정을 다시 연결해 주세요."
        }
    }
}

private extension String {
    var withLeadingSlash: String { hasPrefix("/") ? self : "/\(self)" }
}
