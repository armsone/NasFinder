import Foundation
import Security

protocol SynologySessionStoring: Sendable {
    func sessionID(for connection: RemoteConnection) throws -> String?
    func saveSessionID(_ sessionID: String, for connection: RemoteConnection) throws
    func removeSession(for connection: RemoteConnection) throws
}

struct KeychainSynologySessionStore: SynologySessionStoring, @unchecked Sendable {
    private struct StoredSession: Codable {
        let connectionIdentity: String
        let sessionID: String
    }

    private let service = "com.armsone.nasfinder.synology-session"

    private var accessGroup: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "NasFinderKeychainAccessGroup") as? String,
              !value.isEmpty,
              !value.contains("$(") else {
            return nil
        }
        return value
    }

    func sessionID(for connection: RemoteConnection) throws -> String? {
        var query = baseQuery(for: connection)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw keychainError(status)
        }

        let stored = try JSONDecoder().decode(StoredSession.self, from: data)
        guard stored.connectionIdentity == connection.synologySessionIdentity else {
            return nil
        }
        return stored.sessionID
    }

    func saveSessionID(_ sessionID: String, for connection: RemoteConnection) throws {
        let stored = StoredSession(
            connectionIdentity: connection.synologySessionIdentity,
            sessionID: sessionID
        )
        let data = try JSONEncoder().encode(stored)
        let query = baseQuery(for: connection)
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

    func removeSession(for connection: RemoteConnection) throws {
        let status = SecItemDelete(baseQuery(for: connection) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw keychainError(status)
        }
    }

    private func baseQuery(for connection: RemoteConnection) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: connection.id.uuidString
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private func keychainError(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "Keychain 오류"
        return NSError(
            domain: NSOSStatusErrorDomain,
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension RemoteConnection {
    var synologySessionIdentity: String {
        let scheme = usesTLS ? "https" : "http"
        return "\(scheme)|\(host.lowercased())|\(port)|\(username)"
    }
}
