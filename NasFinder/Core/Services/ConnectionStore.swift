import FileProvider
import Foundation

struct RememberedBrowserLocation: Codable, Equatable {
    let connectionID: UUID
    let path: String
    let title: String
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var connections: [RemoteConnection] = []
    @Published private(set) var preferredConnectionID: UUID?
    @Published private(set) var rememberedBrowserLocation: RememberedBrowserLocation?
    @Published var lastErrorMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: KeychainCredentialStore
    private let storageKey = "connections.v1"
    private let preferredConnectionKey = "preferredConnection.v1"
    private let rememberedBrowserLocationKey = "browser.lastLocation.v1"
    private let writableFileProviderMigrationKey = "fileProvider.sftpWritable.v1"

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.armsone.nasfinder"),
        credentialStore: KeychainCredentialStore = .init(),
        performsFileProviderMaintenance: Bool = true
    ) {
        self.defaults = defaults ?? .standard
        self.credentialStore = credentialStore
        load()
        if performsFileProviderMaintenance {
            Task { [weak self] in
                await self?.restoreMissingFileProviderDomains()
                await self?.refreshFileProviderDomainsForWritableCapabilitiesIfNeeded()
            }
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
        return nil
    }

    func setPreferredConnection(_ connection: RemoteConnection) {
        guard connections.contains(where: { $0.id == connection.id }) else { return }
        preferredConnectionID = connection.id
        defaults.set(connection.id.uuidString, forKey: preferredConnectionKey)
    }

    func clearPreferredConnection() {
        preferredConnectionID = nil
        defaults.removeObject(forKey: preferredConnectionKey)
    }

    var resumableBrowserLocation: RememberedBrowserLocation? {
        guard let rememberedBrowserLocation,
              let connection = connections.first(where: {
                  $0.id == rememberedBrowserLocation.connectionID
              }) else {
            return nil
        }

        let root = connection.normalizedRootPath
        let path = RemotePath.isInside(rememberedBrowserLocation.path, rootPath: root)
            ? rememberedBrowserLocation.path
            : root
        let title = path == rememberedBrowserLocation.path
            ? rememberedBrowserLocation.title
            : connection.name
        return RememberedBrowserLocation(
            connectionID: connection.id,
            path: path,
            title: title
        )
    }

    func rememberBrowserLocation(
        connection: RemoteConnection,
        path: String,
        title: String
    ) {
        guard connections.contains(where: { $0.id == connection.id }),
              RemotePath.isInside(path, rootPath: connection.normalizedRootPath) else {
            return
        }
        let location = RememberedBrowserLocation(
            connectionID: connection.id,
            path: path,
            title: title
        )
        guard rememberedBrowserLocation != location else { return }
        rememberedBrowserLocation = location
        if let data = try? JSONEncoder().encode(location) {
            defaults.set(data, forKey: rememberedBrowserLocationKey)
        }
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
        }
        if let rememberedBrowserLocation,
           removedIDs.contains(rememberedBrowserLocation.connectionID) {
            self.rememberedBrowserLocation = nil
            defaults.removeObject(forKey: rememberedBrowserLocationKey)
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
            } else {
                preferredConnectionID = nil
                defaults.removeObject(forKey: preferredConnectionKey)
            }
            if let locationData = defaults.data(forKey: rememberedBrowserLocationKey),
               let location = try? JSONDecoder().decode(
                   RememberedBrowserLocation.self,
                   from: locationData
               ),
               connections.contains(where: { $0.id == location.connectionID }) {
                rememberedBrowserLocation = location
            } else {
                rememberedBrowserLocation = nil
                defaults.removeObject(forKey: rememberedBrowserLocationKey)
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
