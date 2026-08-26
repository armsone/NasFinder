import Foundation
import Security

enum OAuthProvider: String, Codable, Sendable, CaseIterable {
    case dropbox
    case microsoft
    case google
    case box
    case pCloud
    case yandex
}

struct OAuthCredential: Codable, Equatable, Sendable {
    let provider: OAuthProvider
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date?
    let accountIdentifier: String?
    let grantedScopes: [String]
}

struct S3Credential: Codable, Equatable, Sendable {
    let accessKeyID: String
    let secretAccessKey: String
    let sessionToken: String?
    let expirationDate: Date?
}

enum CloudCredential: Codable, Equatable, Sendable {
    case oauth(OAuthCredential)
    case s3(S3Credential)
}

struct KeychainCredentialStore: @unchecked Sendable {
    private let passwordService = "com.armsone.nasfinder.credentials"
    private let cloudService = "com.armsone.nasfinder.cloud-credentials.v1"

    private var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NasFinderKeychainAccessGroup") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }
        return value
    }

    func save(_ credential: RemoteCredential, for connectionID: UUID) throws {
        try save(
            Data(credential.password.utf8),
            service: passwordService,
            connectionID: connectionID
        )
    }

    func save(_ credential: CloudCredential, for connectionID: UUID) throws {
        try save(
            try JSONEncoder().encode(credential),
            service: cloudService,
            connectionID: connectionID
        )
    }

    private func save(
        _ data: Data,
        service: String,
        connectionID: UUID
    ) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus)
        }

        var addQuery = query
        attributes.forEach { addQuery[$0.key] = $0.value }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus)
        }
    }

    func credential(for connectionID: UUID) throws -> RemoteCredential? {
        guard let data = try data(
            service: passwordService,
            connectionID: connectionID
        ), let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        return RemoteCredential(password: password)
    }

    func cloudCredential(for connectionID: UUID) throws -> CloudCredential? {
        guard let data = try data(
            service: cloudService,
            connectionID: connectionID
        ) else { return nil }
        return try JSONDecoder().decode(CloudCredential.self, from: data)
    }

    func oauthCredential(for connectionID: UUID) throws -> OAuthCredential? {
        guard case let .oauth(credential)? = try cloudCredential(for: connectionID) else {
            return nil
        }
        return credential
    }

    private func data(service: String, connectionID: UUID) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        return data
    }

    func remove(for connectionID: UUID) throws {
        try remove(service: passwordService, connectionID: connectionID)
        try remove(service: cloudService, connectionID: connectionID)
    }

    private func remove(service: String, connectionID: UUID) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connectionID.uuidString
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 오류"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
