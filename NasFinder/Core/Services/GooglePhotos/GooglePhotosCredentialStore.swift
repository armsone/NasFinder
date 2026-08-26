import Foundation
import Security

/// Google Photos Picker 전용 OAuth 자격 증명. Drive용 `OAuthCredential`과 별도 타입이다.
struct GooglePhotosCredential: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date?
    let grantedScopes: [String]

    func isExpired(now: Date = Date(), leeway: TimeInterval = 60) -> Bool {
        guard let expirationDate else { return false }
        return now.addingTimeInterval(leeway) >= expirationDate
    }
}

protocol GooglePhotosCredentialStoring: Sendable {
    func save(_ credential: GooglePhotosCredential) throws
    func load() throws -> GooglePhotosCredential?
    func remove() throws
}

/// Google Photos 자격 증명을 별도 서비스/계정으로 저장하는 Keychain 저장소.
/// 기존 Drive OAuth 토큰 저장소(`KeychainCredentialStore`)와 항목이 겹치지 않는다.
struct GooglePhotosKeychainCredentialStore: GooglePhotosCredentialStoring, @unchecked Sendable {
    private let service = "com.armsone.nasfinder.google-photos.oauth-credential.v1"
    private let account = "google-photos-picker"

    private var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NasFinderKeychainAccessGroup") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }
        return value
    }

    func save(_ credential: GooglePhotosCredential) throws {
        let data = try JSONEncoder().encode(credential)
        var query = baseQuery()
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw keychainError(updateStatus)
        }

        attributes.forEach { query[$0.key] = $0.value }
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw keychainError(addStatus)
        }
    }

    func load() throws -> GooglePhotosCredential? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }
        return try JSONDecoder().decode(GooglePhotosCredential.self, from: data)
    }

    func remove() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery() -> [String: Any] {
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

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 오류"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}
