import FileProvider
import Foundation

struct RememberedBrowserLocation: Codable, Equatable {
    let connectionID: UUID
    let path: String
    let title: String
}

@MainActor
final class ConnectionStore: ObservableObject {
    /// 모든 저장된 연결(비공개 포함). 저장·삭제·id 조회·정리는 이 전체 목록을 쓴다.
    @Published private(set) var allConnections: [RemoteConnection] = [] {
        didSet { PrivacyMode.shared.setPrivateConnectionIDs(Set(allConnections.filter { $0.isPrivate == true }.map(\.id))) }
    }
    /// 지금 모드에서 보이는 연결(목록·개수·선택지·대표 NAS). 일반 모드에서는 비공개 연결이 빠진다.
    var connections: [RemoteConnection] { allConnections.filter { PrivacyMode.isVisible($0.isPrivate) } }
    @Published private(set) var preferredConnectionID: UUID?
    @Published private(set) var rememberedBrowserLocation: RememberedBrowserLocation?
    @Published var lastErrorMessage: String?

    private let defaults: UserDefaults
    private let credentialStore: KeychainCredentialStore
    private let synologySessionStore: any SynologySessionStoring
    private let storageKey = "connections.v1"
    private let preferredConnectionKey = "preferredConnection.v1"
    private let rememberedBrowserLocationKey = "browser.lastLocation.v1"
    private let writableFileProviderMigrationKey = "fileProvider.sftpWritable.v1"

    init(
        defaults: UserDefaults? = UserDefaults(suiteName: "group.com.armsone.nasfinder"),
        credentialStore: KeychainCredentialStore = .init(),
        synologySessionStore: any SynologySessionStoring = KeychainSynologySessionStore(),
        performsFileProviderMaintenance: Bool = true
    ) {
        self.defaults = defaults ?? .standard
        self.credentialStore = credentialStore
        self.synologySessionStore = synologySessionStore
        load()
        if performsFileProviderMaintenance {
            Task { [weak self] in
                await self?.restoreMissingFileProviderDomains()
                await self?.refreshFileProviderDomainsForWritableCapabilitiesIfNeeded()
            }
        }
    }

    func credential(for connection: RemoteConnection) throws -> RemoteCredential {
        if let credential = try credentialStore.credential(for: connection.id) {
            return credential
        }
        if let cloudCredential = try credentialStore.cloudCredential(for: connection.id) {
            return RemoteCredential(password: "", cloudCredential: cloudCredential)
        }
        throw NasFinderError.credentialsMissing
    }

    func add(_ connection: RemoteConnection, password: String) async throws {
        var connection = connection
        if connection.isPrivate == nil { connection.isPrivate = PrivacyMode.shared.newRecordFlag }
        try credentialStore.save(RemoteCredential(password: password), for: connection.id)
        allConnections.append(connection)
        persist()

        // 비공개 연결은 Files 앱 위치를 새로 만들지 않는다(이미 있는 위치는 지우지 않고 확장 쪽 필터가 숨긴다).
        guard connection.isPrivate != true else { return }
        do {
            try await FileProviderDomainCoordinator.add(connection)
        } catch {
            lastErrorMessage = "Files 앱 위치를 추가하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func add(_ connection: RemoteConnection, oauthCredential: OAuthCredential) async throws {
        var connection = connection
        if connection.isPrivate == nil { connection.isPrivate = PrivacyMode.shared.newRecordFlag }
        try credentialStore.save(.oauth(oauthCredential), for: connection.id)
        allConnections.append(connection)
        persist()
    }

    func update(_ connection: RemoteConnection, oauthCredential: OAuthCredential) async throws {
        guard let index = allConnections.firstIndex(where: { $0.id == connection.id }) else {
            throw NasFinderError.invalidResponse
        }
        try credentialStore.save(.oauth(oauthCredential), for: connection.id)
        var connection = connection
        connection.isPrivate = allConnections[index].isPrivate
        allConnections[index] = connection
        persist()
    }

    /// 이전 버전의 서비스 이름 placeholder를 실제 계정 표시로 보완한다.
    /// 실패한 연결·원본 파일·인증 정보는 삭제하거나 초기화하지 않는다.
    func refreshDropboxAccountMetadata() async {
        let candidates = allConnections.filter {
            $0.kind == .dropbox && ($0.username.isEmpty || $0.username.caseInsensitiveCompare("Dropbox") == .orderedSame)
        }
        for connection in candidates {
            do {
                let originalCredential = try credential(for: connection)
                let service = CloudDriveFileService(connection: connection, credential: originalCredential)
                // 표시 정보 보완은 인증 정보를 쓰지 않고 조회를 시작한 동일한 연결에만 적용한다.
                let account = try await service.dropboxAccountDisplayName(persistRefreshedCredential: false)
                guard let index = allConnections.firstIndex(where: { $0.id == connection.id }),
                      allConnections[index] == connection,
                      try credential(for: allConnections[index]) == originalCredential else { continue }
                allConnections[index].username = account
                persist()
            } catch {
                // 행에서 '계정 정보 확인 필요'로 표시하며 명시적 재연결은 사용자에게 맡긴다.
            }
        }
    }

    var preferredConnection: RemoteConnection? {
        if let preferredConnectionID,
           let connection = allConnections.first(where: { $0.id == preferredConnectionID }),
           PrivacyMode.isVisible(connection.isPrivate) {
            return connection
        }
        return nil
    }

    /// 명시적인 공개/비공개 지정. 플래그만 바꾸고 id·로그인 정보·Files 위치·순서는 건드리지 않는다.
    func setPrivate(_ id: UUID, _ isPrivate: Bool) {
        guard let index = allConnections.firstIndex(where: { $0.id == id }) else { return }
        let flag: Bool? = isPrivate ? true : nil
        guard allConnections[index].isPrivate != flag else { return }
        allConnections[index].isPrivate = flag
        persist()
    }

    func setPreferredConnection(_ connection: RemoteConnection) {
        guard allConnections.contains(where: { $0.id == connection.id }) else { return }
        preferredConnectionID = connection.id
        defaults.set(connection.id.uuidString, forKey: preferredConnectionKey)
    }

    func clearPreferredConnection() {
        preferredConnectionID = nil
        defaults.removeObject(forKey: preferredConnectionKey)
    }

    var resumableBrowserLocation: RememberedBrowserLocation? {
        guard let rememberedBrowserLocation,
              let connection = allConnections.first(where: {
                  $0.id == rememberedBrowserLocation.connectionID
              }),
              PrivacyMode.isVisible(connection.isPrivate) else {
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
        // 프라이버시 모드나 비공개 연결에서는 마지막 위치를 새로 기록하지 않는다(기존 값은 그대로 둔다).
        guard !PrivacyMode.currentlyActive, connection.isPrivate != true,
              allConnections.first(where: { $0.id == connection.id })?.isPrivate != true,
              allConnections.contains(where: { $0.id == connection.id }),
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
        guard let index = allConnections.firstIndex(where: { $0.id == connection.id }) else {
            throw NasFinderError.invalidResponse
        }

        try credentialStore.save(RemoteCredential(password: password), for: connection.id)
        // 수정 화면은 가시성 플래그를 모르므로 저장된 값을 그대로 이어받는다(공개/비공개 전환은 명시 동작만).
        var connection = connection
        connection.isPrivate = allConnections[index].isPrivate
        allConnections[index] = connection
        persist()
        guard connection.isPrivate != true else { return }

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
        // 호출자는 보이는 목록의 인덱스를 준다. 전체 목록의 id로 바꿔 숨겨진 연결을 건드리지 않는다.
        let visible = connections
        let removed = offsets.filter { visible.indices.contains($0) }.map { visible[$0] }
        let removedIDs = Set(removed.map(\.id))
        allConnections.removeAll { removedIDs.contains($0.id) }
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
            if connection.kind == .synology {
                do {
                    try synologySessionStore.removeSession(for: connection)
                } catch {
                    failures.append("\(connection.name) 로그인 세션 제거 실패")
                }
            }
        }
        if !failures.isEmpty {
            lastErrorMessage = failures.joined(separator: "\n")
        }
    }

    func move(from offsets: IndexSet, to destination: Int) {
        // 보이는 목록 기준 인덱스를 전체 목록의 id 위치로 옮긴다. 숨겨진 연결의 상대 순서는 그대로다.
        let visible = connections
        let moving = offsets.filter { visible.indices.contains($0) }.sorted().map { visible[$0] }
        guard !moving.isEmpty else { return }
        let movingIDs = Set(moving.map(\.id))
        // destination은 이동 전 보이는 목록 기준 삽입 위치다. 옮기는 항목 자신은 기준이 될 수 없으므로,
        // destination 이후 첫 번째 '옮기지 않는' 보이는 항목 앞에 넣고(제자리로 옮기면 변화 없음),
        // 그런 항목이 없으면 남은 보이는 항목 중 마지막 뒤에 넣어 숨겨진 연결의 상대 순서를 유지한다.
        let clamped = min(max(destination, 0), visible.count)
        let anchorID = visible[clamped...].first { !movingIDs.contains($0.id) }?.id
        let lastRemainingID = visible.last { !movingIDs.contains($0.id) }?.id
        allConnections.removeAll { movingIDs.contains($0.id) }
        let insertionIndex: Int
        if let anchorID, let index = allConnections.firstIndex(where: { $0.id == anchorID }) {
            insertionIndex = index
        } else if let lastRemainingID, let index = allConnections.firstIndex(where: { $0.id == lastRemainingID }) {
            insertionIndex = index + 1
        } else {
            insertionIndex = allConnections.count
        }
        allConnections.insert(contentsOf: moving, at: insertionIndex)
        persist()
    }

    private func restoreMissingFileProviderDomains() async {
        do {
            let existing = try await FileProviderDomainCoordinator.domainIdentifiers()
            for connection in allConnections
            where connection.kind.supportsFileProvider
                && connection.isPrivate != true
                && !existing.contains(connection.id.uuidString) {
                try await FileProviderDomainCoordinator.add(connection)
            }
            for connection in allConnections
            where !connection.kind.supportsFileProvider
                && existing.contains(connection.id.uuidString) {
                try await FileProviderDomainCoordinator.remove(connection)
            }
        } catch {
            lastErrorMessage = "Files 앱 위치를 복구하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func refreshFileProviderDomainsForWritableCapabilitiesIfNeeded() async {
        guard !defaults.bool(forKey: writableFileProviderMigrationKey) else { return }
        var failed = false
        for connection in allConnections where connection.isPrivate != true {
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
            allConnections = try JSONDecoder().decode([RemoteConnection].self, from: data)
            if let rawPreferredID = defaults.string(forKey: preferredConnectionKey),
               let preferredID = UUID(uuidString: rawPreferredID),
               allConnections.contains(where: { $0.id == preferredID }) {
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
               allConnections.contains(where: { $0.id == location.connectionID }) {
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
            defaults.set(try JSONEncoder().encode(allConnections), forKey: storageKey)
        } catch {
            lastErrorMessage = "연결 목록을 저장하지 못했습니다."
        }
    }
}

enum FileProviderDomainCoordinator {
#if targetEnvironment(macCatalyst)
    static func domainIdentifiers() async throws -> Set<String> { [] }
    static func add(_ connection: RemoteConnection) async throws {}
    static func remove(_ connection: RemoteConnection) async throws {}
#else
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
        guard connection.kind.supportsFileProvider else { return }
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
#endif
}
