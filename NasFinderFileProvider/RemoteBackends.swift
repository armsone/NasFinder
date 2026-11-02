import Citadel
import CryptoKit
import Foundation
import NIO
import NIOSSH
import Security

actor SynologyProviderBackend: ProviderRemoteBackend {
    private let connection: ProviderConnection
    private let password: String
    private let session: URLSession
    private let sessionStore = ProviderSynologySessionStore()
    private var sessionID: String?

    init(
        connection: ProviderConnection,
        password: String,
        session: URLSession = .shared
    ) {
        self.connection = connection
        self.password = password
        self.session = session
    }

    func list(directory: String) async throws -> [ProviderRemoteNode] {
        try await authenticatedRequest { sid in
            let isRoot = directory == "/"
            var parameters = self.commonParameters(
                api: "SYNO.FileStation.List",
                version: "2",
                method: isRoot ? "list_share" : "list",
                sid: sid
            )
            if !isRoot {
                parameters["folder_path"] = directory
            }
            parameters["additional"] = "[\"size\",\"time\"]"
            parameters["sort_by"] = "name"
            parameters["sort_direction"] = "asc"

            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.timeoutInterval = 5
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTP(response)
            let envelope = try JSONDecoder().decode(
                SynologyProviderEnvelope<SynologyProviderListData>.self,
                from: data
            )
            try self.validate(envelope)
            let nodes = envelope.data?.files ?? envelope.data?.shares ?? []
            return nodes.map { node in
                ProviderRemoteNode(
                    path: node.path,
                    name: node.name,
                    isDirectory: node.isDirectory,
                    size: node.additional?.size ?? node.size,
                    modifiedAt: node.additional?.time?.modifiedDate
                )
            }
        }
    }

    func download(path: String, to destinationURL: URL) async throws {
        try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Download",
                version: "2",
                method: "download",
                sid: sid
            ).merging([
                "path": path,
                "mode": "download"
            ]) { _, new in new }
            let request = try self.request(script: "entry.cgi", parameters: parameters)
            let (temporaryURL, response) = try await self.session.download(for: request)
            try self.validateHTTP(response)
            if self.isJSONResponse(response) {
                let data = try Data(contentsOf: temporaryURL)
                let envelope = try JSONDecoder().decode(
                    SynologyProviderEnvelope<SynologyProviderDownloadErrorData>.self,
                    from: data
                )
                try self.validate(envelope)
                throw CocoaError(
                    .fileReadCorruptFile,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Synology returned JSON instead of the requested file."
                    ]
                )
            }
            try Task.checkCancellation()
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
        }
    }

    func thumbnail(path: String, size: ProviderThumbnailSize) async throws -> Data? {
        try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Thumb",
                version: "2",
                method: "get",
                sid: sid
            ).merging([
                "path": path,
                "size": size.rawValue,
                "rotate": "0"
            ]) { _, new in new }
            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.timeoutInterval = 12
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTP(response)
            guard data.count <= 4 * 1_024 * 1_024 else { return nil }
            if self.isJSONResponse(response) { return nil }
            return data.isEmpty ? nil : data
        }
    }

    func vaultThumbnail(for node: ProviderRemoteNode) async throws -> Data? {
        let parent = (node.path as NSString).deletingLastPathComponent
        let vaultDirectory = parent.isEmpty ? "/.NasFinder-Vault" : "\(parent)/.NasFinder-Vault"
        let vaultPath = "\(vaultDirectory)/\(Self.vaultThumbnailFilename(for: node))"
        return try await authenticatedRequest { sid in
            let parameters = self.commonParameters(
                api: "SYNO.FileStation.Download",
                version: "2",
                method: "download",
                sid: sid
            ).merging([
                "path": vaultPath,
                "mode": "download"
            ]) { _, new in new }
            var request = try self.request(script: "entry.cgi", parameters: parameters)
            request.timeoutInterval = 12
            let (data, response) = try await self.session.data(for: request)
            try self.validateHTTP(response)
            guard data.count <= 4 * 1_024 * 1_024 else { return nil }
            if self.isJSONResponse(response) {
                let envelope = try JSONDecoder().decode(
                    SynologyProviderEnvelope<SynologyProviderDownloadErrorData>.self,
                    from: data
                )
                try self.validate(envelope)
                return nil
            }
            return data.isEmpty ? nil : data
        }
    }

    private static func vaultThumbnailFilename(for node: ProviderRemoteNode) -> String {
        let identity = [
            "engine=1",
            "name=\(node.name.precomposedStringWithCanonicalMapping)",
            "size=\(node.size ?? -1)",
            "modified=\(Int64((node.modifiedAt?.timeIntervalSince1970 ?? 0) * 1_000))",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "v1-" + digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private func authenticatedRequest<T: Sendable>(
        _ operation: (String) async throws -> T
    ) async throws -> T {
        let sid = try await validSessionID()
        do {
            return try await operation(sid)
        } catch let error as SynologyProviderAPIError where error.isAuthenticationError {
            sessionID = nil
            try? sessionStore.removeSession(for: connection)
            let refreshedSID = try await validSessionID()
            return try await operation(refreshedSID)
        }
    }

    private func validSessionID() async throws -> String {
        if let sessionID { return sessionID }
        if let storedSessionID = try? sessionStore.sessionID(for: connection) {
            sessionID = storedSessionID
            return storedSessionID
        }

        var request = try request(
            script: "auth.cgi",
            parameters: [
                "api": "SYNO.API.Auth",
                "version": "6",
                "method": "login",
                "account": connection.username,
                "passwd": password,
                "session": "FileStation",
                "format": "sid"
            ]
        )
        request.timeoutInterval = 5
        let (data, response) = try await session.data(for: request)
        try validateHTTP(response)
        let envelope = try JSONDecoder().decode(
            SynologyProviderEnvelope<SynologyProviderAuthData>.self,
            from: data
        )
        try validate(envelope)
        guard let sid = envelope.data?.sid else {
            throw SynologyProviderAPIError(code: -1)
        }
        sessionID = sid
        try? sessionStore.saveSessionID(sid, for: connection)
        return sid
    }

    private func request(script: String, parameters: [String: String]) throws -> URLRequest {
        let scheme = connection.usesTLS ? "https" : "http"
        guard !connection.host.isEmpty else {
            throw NasFinderFileProviderErrors.invalidConfiguration
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = connection.host
        components.port = connection.port
        components.path = "/webapi/\(script)"
        guard let url = components.url else {
            throw NasFinderFileProviderErrors.invalidConfiguration
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/x-www-form-urlencoded; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.httpBody = ProviderFormURLEncoder.encode(parameters)
        request.timeoutInterval = 45
        return request
    }

    private func commonParameters(
        api: String,
        version: String,
        method: String,
        sid: String
    ) -> [String: String] {
        [
            "api": api,
            "version": version,
            "method": method,
            "_sid": sid
        ]
    }

    private func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw CocoaError(
                .fileReadUnknown,
                userInfo: [
                    NSLocalizedDescriptionKey: "The Synology NAS did not return a successful response."
                ]
            )
        }
    }

    private func isJSONResponse(_ response: URLResponse) -> Bool {
        if response.mimeType?.localizedCaseInsensitiveContains("json") == true {
            return true
        }
        guard let http = response as? HTTPURLResponse else { return false }
        return http.value(forHTTPHeaderField: "Content-Type")?
            .localizedCaseInsensitiveContains("json") == true
    }

    private func validate<T>(_ envelope: SynologyProviderEnvelope<T>) throws {
        guard envelope.success else {
            throw SynologyProviderAPIError(code: envelope.error?.code ?? -1)
        }
    }
}

private struct ProviderSynologySessionStore {
    private enum LookupResult {
        case success(String)
        case failure(OSStatus)
    }

    private struct StoredSession: Codable {
        let connectionIdentity: String
        let sessionID: String
    }

    private let service = "com.armsone.nasfinder.synology-session"

    func sessionID(for connection: ProviderConnection) throws -> String? {
        let configuredGroup = keychainAccessGroup
        if let configuredGroup {
            switch copySession(for: connection, accessGroup: configuredGroup) {
            case .success(let sessionID): return sessionID
            case .failure(let status)
                where status != errSecItemNotFound && status != errSecMissingEntitlement:
                throw keychainError(status)
            case .failure: break
            }
        }

        switch copySession(for: connection, accessGroup: nil) {
        case .success(let sessionID): return sessionID
        case .failure(let status) where status == errSecItemNotFound: return nil
        case .failure(let status): throw keychainError(status)
        }
    }

    func saveSessionID(_ sessionID: String, for connection: ProviderConnection) throws {
        let stored = StoredSession(
            connectionIdentity: identity(for: connection),
            sessionID: sessionID
        )
        let data = try JSONEncoder().encode(stored)
        try write(data, account: connection.id.uuidString, accessGroup: keychainAccessGroup)
    }

    func removeSession(for connection: ProviderConnection) throws {
        let status = SecItemDelete(
            baseQuery(account: connection.id.uuidString, accessGroup: keychainAccessGroup) as CFDictionary
        )
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private var keychainAccessGroup: String? {
        guard let value = Bundle.main.object(
            forInfoDictionaryKey: NasFinderFileProviderIdentifiers.keychainAccessGroupInfoKey
        ) as? String,
              value.hasSuffix("com.armsone.nasfinder.shared") else {
            return nil
        }
        return value
    }

    private func copySession(
        for connection: ProviderConnection,
        accessGroup: String?
    ) -> LookupResult {
        var query = baseQuery(account: connection.id.uuidString, accessGroup: accessGroup)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return .failure(status) }
        guard let data = result as? Data,
              let stored = try? JSONDecoder().decode(StoredSession.self, from: data),
              stored.connectionIdentity == identity(for: connection) else {
            return .failure(errSecDecode)
        }
        return .success(stored.sessionID)
    }

    private func write(_ data: Data, account: String, accessGroup: String?) throws {
        let query = baseQuery(account: account, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else { throw keychainError(updateStatus) }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw keychainError(addStatus) }
    }

    private func baseQuery(account: String, accessGroup: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func identity(for connection: ProviderConnection) -> String {
        let scheme = connection.usesTLS ? "https" : "http"
        return "\(scheme)|\(connection.host.lowercased())|\(connection.port)|\(connection.username)"
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String?
            ?? "Keychain error (\(status))"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

struct SFTPProviderBackend: ProviderRemoteBackend {
    private let connection: ProviderConnection
    private let password: String

    init(connection: ProviderConnection, password: String) {
        self.connection = connection
        self.password = password
    }

    var supportsMutations: Bool { true }

    func list(directory: String) async throws -> [ProviderRemoteNode] {
        try await withSFTP { sftp in
            let batches = try await sftp.listDirectory(atPath: directory)
            return batches
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
                .map { component in
                    let permissions = component.attributes.permissions
                    let isDirectory = permissions.map { ($0 & 0o170000) == 0o040000 }
                        ?? component.longname.hasPrefix("d")
                    return ProviderRemoteNode(
                        path: Self.appending(component.filename, to: directory),
                        name: component.filename,
                        isDirectory: isDirectory,
                        size: component.attributes.size.flatMap(Int64.init(exactly:)),
                        modifiedAt: component.attributes.accessModificationTime?.modificationTime
                    )
                }
        }
    }

    func download(path: String, to destinationURL: URL) async throws {
        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        do {
            try await withSFTP { sftp in
                try await sftp.withFile(filePath: path, flags: .read) { file in
                    let handle = try FileHandle(forWritingTo: destinationURL)
                    defer { try? handle.close() }

                    var offset: UInt64 = 0
                    let chunkSize: UInt32 = 128 * 1_024
                    while !Task.isCancelled {
                        var buffer = try await file.read(from: offset, length: chunkSize)
                        guard buffer.readableBytes > 0 else { break }
                        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
                        try handle.write(contentsOf: Data(bytes))
                        offset += UInt64(bytes.count)
                    }
                    try Task.checkCancellation()
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destinationURL)
            throw error
        }
    }

    func createFolder(path: String) async throws {
        try await withSFTP { sftp in
            try await sftp.createDirectory(atPath: path)
            let parent = (path as NSString).deletingLastPathComponent
            let name = (path as NSString).lastPathComponent
            let entries = try await sftp.listDirectory(atPath: parent.isEmpty ? "." : parent)
                .flatMap(\.components)
            guard entries.contains(where: { component in
                let isDirectory = component.attributes.permissions.map {
                    ($0 & 0o170000) == 0o040000
                } ?? component.longname.hasPrefix("d")
                return component.filename == name && isDirectory
            }) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    /// 새 파일만 만든다. 대상을 직접 열지 않고 같은 폴더의 임시 파일에 먼저 올려 크기를 확인한 뒤 게시한다.
    /// Citadel 0.12.1은 v3 rename만 제공해 기존 파일을 안전하게 교체할 수 없으므로 내용 교체는 지원하지 않는다.
    func upload(localURL: URL, to path: String) async throws {
        let source = try ProviderSFTPUploadSource(url: localURL)
        try await withSFTP { sftp in
            let parent = Self.parentDirectory(of: path)
            let name = (path as NSString).lastPathComponent
            guard try await !Self.listing(of: parent, using: sftp)
                .contains(where: { $0.filename == name }) else {
                throw NasFinderFileProviderErrors.filenameCollision
            }

            let stagingPath = Self.appending(
                ".nasfinder-upload-\(UUID().uuidString.lowercased()).tmp",
                to: parent
            )
            try await Self.stage(source, at: stagingPath, using: sftp)

            do {
                try Task.checkCancellation()
                // 업로드하는 동안 다른 클라이언트가 같은 이름을 만들었으면 덮어쓰지 않는다.
                guard try await !Self.listing(of: parent, using: sftp)
                    .contains(where: { $0.filename == name }) else {
                    throw NasFinderFileProviderErrors.filenameCollision
                }
                try Task.checkCancellation()
            } catch {
                try? await sftp.remove(at: stagingPath)
                throw error
            }

            try await Self.commitNewFile(
                stagingPath: stagingPath,
                path: path,
                expectedSize: source.size,
                using: sftp
            )
        }
    }

    /// 배타적으로 만든 이 임시 파일만 이 작업의 소유이므로, 실패하면 그것만 지운다.
    private static func stage(
        _ source: ProviderSFTPUploadSource,
        at stagingPath: String,
        using sftp: SFTPClient
    ) async throws {
        let localFile = try FileHandle(forReadingFrom: source.url)
        defer { try? localFile.close() }
        let remoteFile = try await sftp.openFile(
            filePath: stagingPath,
            flags: [.write, .create, .forceCreate]
        )

        do {
            var offset: UInt64 = 0
            do {
                while let data = try localFile.read(upToCount: 256 * 1_024),
                      !data.isEmpty {
                    try Task.checkCancellation()
                    guard UInt64(data.count) <= source.size - offset else {
                        throw ProviderSFTPUploadError.sourceChanged
                    }
                    var buffer = ByteBuffer()
                    buffer.writeBytes(data)
                    try await remoteFile.write(buffer, at: offset)
                    offset += UInt64(data.count)
                }
                try await remoteFile.close()
            } catch {
                try? await remoteFile.close()
                throw error
            }
            guard offset == source.size else {
                throw ProviderSFTPUploadError.sourceChanged
            }
            try source.requireUnchanged()

            let staged = try await sftp.getAttributes(at: stagingPath)
            guard staged.size == offset else {
                throw ProviderSFTPUploadError.verificationFailed
            }
        } catch {
            try? await sftp.remove(at: stagingPath)
            throw error
        }
    }

    /// SFTP v3 rename은 대상이 있으면 실패해야 하므로, 그 사이 생긴 파일을 덮어쓰지 않는다.
    private static func commitNewFile(
        stagingPath: String,
        path: String,
        expectedSize: UInt64,
        using sftp: SFTPClient
    ) async throws {
        let parent = parentDirectory(of: path)
        let name = (path as NSString).lastPathComponent
        let stagingName = (stagingPath as NSString).lastPathComponent
        do {
            try await sftp.rename(at: stagingPath, to: path)
        } catch {
            // 응답만 유실됐을 수 있다. 임시 이름이 남아 있을 때만 실제 실패로 보고 임시 파일을 지운다.
            guard let entries = try? await listing(of: parent, using: sftp) else { throw error }
            if entries.contains(where: { $0.filename == stagingName }) {
                try? await sftp.remove(at: stagingPath)
                if entries.contains(where: { $0.filename == name }) {
                    throw NasFinderFileProviderErrors.filenameCollision
                }
                throw error
            }
        }
        try await verifyPublished(
            name: name,
            stagingName: stagingName,
            in: parent,
            expectedSize: expectedSize,
            using: sftp
        )
    }

    private static func verifyPublished(
        name: String,
        stagingName: String,
        in parent: String,
        expectedSize: UInt64,
        using sftp: SFTPClient
    ) async throws {
        let entries = try await listing(of: parent, using: sftp)
        guard !entries.contains(where: { $0.filename == stagingName }),
              let published = entries.first(where: { $0.filename == name }),
              isRegularFile(published),
              published.attributes.size == expectedSize else {
            throw ProviderSFTPUploadError.verificationFailed
        }
    }

    private static func listing(
        of directory: String,
        using sftp: SFTPClient
    ) async throws -> [SFTPPathComponent] {
        try await sftp.listDirectory(atPath: directory).flatMap(\.components)
    }

    private static func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "." : parent
    }

    private static func isRegularFile(_ component: SFTPPathComponent) -> Bool {
        component.attributes.permissions.map { ($0 & 0o170000) == 0o100000 }
            ?? component.longname.hasPrefix("-")
    }

    func rename(from sourcePath: String, to destinationPath: String) async throws {
        try await withSFTP { sftp in
            try await sftp.rename(at: sourcePath, to: destinationPath)
            let parent = (destinationPath as NSString).deletingLastPathComponent
            let name = (destinationPath as NSString).lastPathComponent
            let entries = try await sftp.listDirectory(atPath: parent.isEmpty ? "." : parent)
                .flatMap(\.components)
            guard entries.contains(where: { $0.filename == name }) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    func delete(path: String, isDirectory: Bool) async throws {
        try await withSFTP { sftp in
            try await Self.deleteRecursively(
                path: path,
                isDirectory: isDirectory,
                using: sftp
            )
        }
    }

    private static func deleteRecursively(
        path: String,
        isDirectory: Bool,
        using sftp: SFTPClient
    ) async throws {
        try Task.checkCancellation()
        if isDirectory {
            let entries = try await sftp.listDirectory(atPath: path)
                .flatMap(\.components)
                .filter { $0.filename != "." && $0.filename != ".." }
            for entry in entries {
                let childIsDirectory = entry.attributes.permissions.map {
                    ($0 & 0o170000) == 0o040000
                } ?? entry.longname.hasPrefix("d")
                try await deleteRecursively(
                    path: appending(entry.filename, to: path),
                    isDirectory: childIsDirectory,
                    using: sftp
                )
            }
            try await sftp.rmdir(at: path)
        } else {
            try await sftp.remove(at: path)
        }

        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let remaining = try await sftp.listDirectory(atPath: parent.isEmpty ? "." : parent)
            .flatMap(\.components)
        guard !remaining.contains(where: { $0.filename == name }) else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    private func withSFTP<T: Sendable>(
        _ operation: @escaping @Sendable (SFTPClient) async throws -> T
    ) async throws -> T {
        let validator = SSHHostKeyValidator.custom(
            ProviderSSHHostKeyValidator(expectedKey: connection.trustedHostKey)
        )
        let client = try await SSHClient.connect(
            host: connection.host,
            port: connection.port,
            authenticationMethod: .passwordBased(
                username: connection.username,
                password: password
            ),
            hostKeyValidator: validator,
            reconnect: .never,
            algorithms: .all
        )

        do {
            let sftp = try await client.openSFTP()
            do {
                let result = try await operation(sftp)
                try await sftp.close()
                try await client.close()
                return result
            } catch {
                try? await sftp.close()
                try? await client.close()
                throw error
            }
        } catch {
            try? await client.close()
            throw error
        }
    }

    private static func appending(_ name: String, to directory: String) -> String {
        if directory == "/" { return "/\(name)" }
        if directory == "." { return "./\(name)" }
        return directory.hasSuffix("/")
            ? "\(directory)\(name)"
            : "\(directory)/\(name)"
    }
}

private final class ProviderSSHHostKeyValidator:
    NIOSSHClientServerAuthenticationDelegate,
    @unchecked Sendable {
    private let expectedKey: String?

    init(expectedKey: String?) {
        self.expectedKey = expectedKey
    }

    func validateHostKey(
        hostKey: NIOSSHPublicKey,
        validationCompletePromise: EventLoopPromise<Void>
    ) {
        let presentedFingerprint = Self.fingerprint(for: hostKey)
        guard let expectedKey,
              Self.fingerprint(forStoredValue: expectedKey) == presentedFingerprint else {
            validationCompletePromise.fail(
                ProviderSFTPHostKeyError(fingerprint: presentedFingerprint)
            )
            return
        }
        validationCompletePromise.succeed(())
    }

    private static func fingerprint(forStoredValue value: String) -> String? {
        if value.hasPrefix("SHA256:") {
            return value
        }
        guard let key = try? NIOSSHPublicKey(openSSHPublicKey: value) else {
            return nil
        }
        return fingerprint(for: key)
    }

    private static func fingerprint(for key: NIOSSHPublicKey) -> String {
        var buffer = ByteBuffer()
        key.write(to: &buffer)
        let digest = SHA256.hash(data: Data(buffer.readableBytesView))
        let encoded = Data(digest)
            .base64EncodedString()
            .replacingOccurrences(of: "=", with: "")
        return "SHA256:\(encoded)"
    }
}

/// 업로드할 로컬 파일의 시작 시점 상태. 전송이 끝난 뒤 그대로인지 확인하는 데 쓴다.
private struct ProviderSFTPUploadSource: Sendable {
    let url: URL
    let size: UInt64
    private let modifiedAt: Date?

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.uint64Value else {
            throw ProviderSFTPUploadError.sourceNotRegularFile
        }
        self.url = url
        self.size = size
        modifiedAt = attributes[.modificationDate] as? Date
    }

    func requireUnchanged() throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.uint64Value == size,
              attributes[.modificationDate] as? Date == modifiedAt else {
            throw ProviderSFTPUploadError.sourceChanged
        }
    }
}

private enum ProviderSFTPUploadError: LocalizedError, Sendable {
    case sourceNotRegularFile
    case sourceChanged
    case verificationFailed

    var errorDescription: String? {
        switch self {
        case .sourceNotRegularFile:
            "Only regular files can be uploaded."
        case .sourceChanged:
            "The file changed while it was being uploaded. Try again."
        case .verificationFailed:
            "The server could not confirm the upload."
        }
    }
}

private struct ProviderSFTPHostKeyError: LocalizedError, Sendable {
    let fingerprint: String

    var errorDescription: String? {
        "The SFTP host key is missing or changed (\(fingerprint)). Verify it in NasFinder before reconnecting."
    }
}

private enum ProviderFormURLEncoder {
    static func encode(_ parameters: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._~")
        )
        let body = parameters
            .sorted { $0.key < $1.key }
            .map { key, value in
                let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
                let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
                return "\(encodedKey)=\(encodedValue)"
            }
            .joined(separator: "&")
        return Data(body.utf8)
    }
}

private struct SynologyProviderEnvelope<Payload: Decodable>: Decodable {
    let success: Bool
    let data: Payload?
    let error: SynologyProviderErrorPayload?
}

private struct SynologyProviderErrorPayload: Decodable {
    let code: Int
}

private struct SynologyProviderAuthData: Decodable {
    let sid: String
}

private struct SynologyProviderDownloadErrorData: Decodable {}

private struct SynologyProviderListData: Decodable {
    let files: [SynologyProviderNode]?
    let shares: [SynologyProviderNode]?
}

private struct SynologyProviderNode: Decodable {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: Int64?
    let additional: SynologyProviderAdditional?

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case isDirectory = "isdir"
        case size
        case additional
    }
}

private struct SynologyProviderAdditional: Decodable {
    let size: Int64?
    let time: SynologyProviderTime?
}

private struct SynologyProviderTime: Decodable {
    let mtime: TimeInterval?
    var modifiedDate: Date? { mtime.map(Date.init(timeIntervalSince1970:)) }
}

private struct SynologyProviderAPIError: LocalizedError, Sendable {
    let code: Int

    var isAuthenticationError: Bool { [106, 107, 119].contains(code) }

    var errorDescription: String? {
        switch code {
        case 105:
            "This Synology account does not have permission to use the requested API."
        case 106, 107, 119:
            "Synology authentication failed or expired."
        case 400:
            "This Synology account cannot perform the requested file operation."
        case 408:
            "The remote Synology file or folder no longer exists."
        default:
            "Synology File Station returned error \(code)."
        }
    }
}
