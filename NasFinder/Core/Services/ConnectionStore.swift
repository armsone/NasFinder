import FileProvider
import Foundation

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [RemoteConnection] = []
    @Published private(set) var preferredConnectionID: UUID?
    @Published var lastErrorMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: KeychainCredentialStore
    private let storageKey = "connections.v1"
    private let preferredConnectionKey = "preferredConnection.v1"
    private let writableFileProviderMigrationKey = "fileProvider.sftpWritable.v1"

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.armsone.nasfinder"),
        credentialStore: KeychainCredentialStore = .init()
    ) {
        self.defaults = defaults ?? .standard
        self.credentialStore = credentialStore
        load()
        Task { [weak self] in
            await self?.restoreMissingFileProviderDomains()
            await self?.refreshFileProviderDomainsForWritableCapabilitiesIfNeeded()
        }
    }

    func credential(for connection: RemoteConnection) throws -> RemoteCredential {
        guard let credential = try credentialStore.credential(for: connection.id) else {
            throw NasFinderError.credentialsMissing
        }
        return credential
    }

    func add(_ connection: RemoteConnection, password: String) async throws {
        try credentialStore.save(RemoteCredential(password: password), for: connection.id)
        connections.append(connection)
        if preferredConnectionID == nil {
            setPreferredConnection(connection)
        }
        persist()

        do {
            try await FileProviderDomainCoordinator.add(connection)
        } catch {
            lastErrorMessage = "Files 앱 위치를 추가하지 못했습니다: \(error.localizedDescription)"
        }
    }

    var preferredConnection: RemoteConnection? {
        if let preferredConnectionID,
           let connection = connections.first(where: { $0.id == preferredConnectionID }) {
            return connection
        }
        return connections.first(where: { $0.kind == .synology }) ?? connections.first
    }

    func setPreferredConnection(_ connection: RemoteConnection) {
        guard connections.contains(where: { $0.id == connection.id }) else { return }
        preferredConnectionID = connection.id
        defaults.set(connection.id.uuidString, forKey: preferredConnectionKey)
    }

    func update(_ connection: RemoteConnection, password: String) async throws {
        guard let index = connections.firstIndex(where: { $0.id == connection.id }) else {
            throw NasFinderError.invalidResponse
        }

        try credentialStore.save(RemoteCredential(password: password), for: connection.id)
        connections[index] = connection
        persist()

        // A File Provider extension can keep the old connection snapshot for
        // the lifetime of its process. Re-registering the same domain makes
        // Files reopen it with the edited endpoint and display name.
        do {
            try await FileProviderDomainCoordinator.remove(connection)
        } catch {
            // The domain may already be absent. Adding it below is the
            // authoritative operation and produces the useful user error.
        }
        do {
            try await FileProviderDomainCoordinator.add(connection)
        } catch {
            lastErrorMessage = "수정한 연결은 저장했지만 파일 앱 위치를 갱신하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func remove(at offsets: IndexSet) async {
        let validIndices = offsets.filter { connections.indices.contains($0) }
        let removed = validIndices.map { connections[$0] }
        let removedIDs = Set(removed.map(\.id))
        connections.removeAll { removedIDs.contains($0.id) }
        if let preferredConnectionID, removedIDs.contains(preferredConnectionID) {
            self.preferredConnectionID = nil
            defaults.removeObject(forKey: preferredConnectionKey)
            if let fallback = connections.first(where: { $0.kind == .synology }) ?? connections.first {
                setPreferredConnection(fallback)
            }
        }
        persist()

        var failures: [String] = []
        for connection in removed {
            do {
                try await FileProviderDomainCoordinator.remove(connection)
            } catch {
                failures.append("\(connection.name) Files 위치 제거 실패")
            }
            do {
                try credentialStore.remove(for: connection.id)
            } catch {
                failures.append("\(connection.name) 로그인 정보 제거 실패")
            }
        }
        if !failures.isEmpty {
            lastErrorMessage = failures.joined(separator: "\n")
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        let validOffsets = offsets.filter { connections.indices.contains($0) }.sorted()
        guard !validOffsets.isEmpty else { return }

        let movingConnections = validOffsets.map { connections[$0] }
        for index in validOffsets.reversed() {
            connections.remove(at: index)
        }
        let removedBeforeDestination = validOffsets.filter { $0 < destination }.count
        let insertionIndex = min(
            max(destination - removedBeforeDestination, 0),
            connections.count
        )
        connections.insert(contentsOf: movingConnections, at: insertionIndex)
        persist()
    }

    private func restoreMissingFileProviderDomains() async {
        do {
            let existing = try await FileProviderDomainCoordinator.domainIdentifiers()
            for connection in connections where !existing.contains(connection.id.uuidString) {
                try await FileProviderDomainCoordinator.add(connection)
            }
        } catch {
            lastErrorMessage = "Files 앱 위치를 복구하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func refreshFileProviderDomainsForWritableCapabilitiesIfNeeded() async {
        guard !defaults.bool(forKey: writableFileProviderMigrationKey) else { return }
        var failed = false
        for connection in connections {
            do {
                try? await FileProviderDomainCoordinator.remove(connection)
                try await FileProviderDomainCoordinator.add(connection)
            } catch {
                failed = true
            }
        }
        if failed {
            lastErrorMessage = "파일 앱 위치를 새 권한으로 갱신하지 못했습니다. NasFinder를 다시 열어 주세요."
        } else {
            defaults.set(true, forKey: writableFileProviderMigrationKey)
        }
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey) else { return }
        do {
            connections = try JSONDecoder().decode([RemoteConnection].self, from: data)
            if let rawPreferredID = defaults.string(forKey: preferredConnectionKey),
               let preferredID = UUID(uuidString: rawPreferredID),
               connections.contains(where: { $0.id == preferredID }) {
                preferredConnectionID = preferredID
            } else if let fallback = connections.first(where: { $0.kind == .synology })
                        ?? connections.first {
                preferredConnectionID = fallback.id
                defaults.set(fallback.id.uuidString, forKey: preferredConnectionKey)
            }
        } catch {
            lastErrorMessage = "저장된 연결 목록을 읽지 못했습니다."
        }
    }

    private func persist() {
        do {
            defaults.set(try JSONEncoder().encode(connections), forKey: storageKey)
        } catch {
            lastErrorMessage = "연결 목록을 저장하지 못했습니다."
        }
    }
}

enum FileProviderDomainCoordinator {
    static func domainIdentifiers() async throws -> Set<String> {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Set<String>, Error>) in
            NSFileProviderManager.getDomainsWithCompletionHandler { domains, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: Set(domains.map { $0.identifier.rawValue })
                    )
                }
            }
        }
    }

    static func add(_ connection: RemoteConnection) async throws {
        let identifier = NSFileProviderDomainIdentifier(rawValue: connection.id.uuidString)
        let domain = NSFileProviderDomain(identifier: identifier, displayName: connection.name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.add(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    static func remove(_ connection: RemoteConnection) async throws {
        let identifier = NSFileProviderDomainIdentifier(rawValue: connection.id.uuidString)
        let domain = NSFileProviderDomain(identifier: identifier, displayName: connection.name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSFileProviderManager.remove(domain) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }
}
