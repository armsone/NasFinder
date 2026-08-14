import CryptoKit
import Foundation

enum SuperThumbnailVaultTiming: String, Codable, CaseIterable, Sendable {
    case now
    case later
}

struct SuperThumbnailVaultOptions: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var timing: SuperThumbnailVaultTiming

    static let recommended = Self(isEnabled: true, timing: .now)
}

struct SuperThumbnailVaultStoreResult: Equatable, Sendable {
    let storedItemIDs: Set<String>
    let attemptedItemIDs: Set<String>
    let errorDescription: String?
    let didAttempt: Bool

    var storedCount: Int { storedItemIDs.count }

    static let empty = Self(
        storedItemIDs: [],
        attemptedItemIDs: [],
        errorDescription: nil,
        didAttempt: false
    )
}

enum SuperThumbnailCooperativeClaim: Sendable {
    case uncoordinated
    case acquired(SuperThumbnailCooperativeLease)
    case deferred
}

struct SuperThumbnailCooperativeLease: Sendable {
    let itemID: String
    let vaultPath: String
    let directoryName: String
    let token: String
}

private struct SuperThumbnailWorkerRecord: Codable, Sendable {
    let workerID: String
    let expiresAt: Date
}

private struct SuperThumbnailLeaseRecord: Codable, Sendable {
    let workerID: String
    let token: String
    let expiresAt: Date
}

actor SuperThumbnailVault {
    static let shared = SuperThumbnailVault()

    static let directoryName = ".NasFinder-Vault"
    private static let engineVersion = 1
    private static let workersDirectoryName = ".workers-v1"
    private static let workerLifetime: TimeInterval = 90
    private static let leaseLifetime: TimeInterval = 180
    private static let leaseRecordName = ".owner.json"
    private var directoryEntries: [String: [RemoteFileItem]] = [:]
    private var missingLeaseFirstSeen: [String: Date] = [:]

    func data(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        refreshListing: Bool = false
    ) async -> Data? {
        guard supportsVault(service) else { return nil }
        let directory = parentDirectory(of: item.path)
        let vaultPath = appending(Self.directoryName, to: directory)
        do {
            if refreshListing {
                directoryEntries[listingKey(vaultPath, service: service)] = nil
            }
            let entries = try await entries(in: vaultPath, service: service)
            guard let stored = entries.first(where: { $0.name == filename(for: item) }) else {
                return nil
            }
            let localURL = try await service.download(stored)
            defer { try? FileManager.default.removeItem(at: localURL) }
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    func registerWorker(
        _ workerID: String,
        rootPath: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async throws {
        guard supportsVault(service) else { return }
        let workersPath = try await ensureWorkersDirectory(
            rootPath: rootPath,
            service: service
        )
        let record = SuperThumbnailWorkerRecord(
            workerID: workerID,
            expiresAt: now.addingTimeInterval(Self.workerLifetime)
        )
        try await uploadJSON(
            record,
            named: workerFilename(workerID),
            to: workersPath,
            conflictPolicy: .replace,
            service: service
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
    }

    func activeWorkerIDs(
        rootPath: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async throws -> Set<String> {
        guard supportsVault(service) else { return [] }
        let workersPath = try await ensureWorkersDirectory(
            rootPath: rootPath,
            service: service
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
        let workerItems = try await entries(in: workersPath, service: service)
            .filter { !$0.isDirectory && $0.name.hasPrefix("worker-") }
        var active: Set<String> = []
        for workerItem in workerItems {
            guard let record: SuperThumbnailWorkerRecord = await decodedJSON(
                from: workerItem,
                service: service
            ) else { continue }
            if record.expiresAt > now {
                active.insert(record.workerID)
            } else {
                _ = try? await service.delete(
                    workerItem,
                    recursive: false,
                    context: RemoteOperationContext()
                )
            }
        }
        directoryEntries[listingKey(workersPath, service: service)] = nil
        return active
    }

    func unregisterWorker(
        _ workerID: String,
        rootPath: String,
        service: any RemoteFileService
    ) async {
        guard supportsVault(service),
              let workersPath = try? await ensureWorkersDirectory(
                  rootPath: rootPath,
                  service: service
              ) else { return }
        directoryEntries[listingKey(workersPath, service: service)] = nil
        guard let workerItem = try? await entries(in: workersPath, service: service)
            .first(where: { $0.name == workerFilename(workerID) }) else { return }
        _ = try? await service.delete(
            workerItem,
            recursive: false,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
    }

    func claim(
        _ item: RemoteFileItem,
        workerID: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async -> SuperThumbnailCooperativeClaim {
        guard supportsVault(service) else { return .uncoordinated }
        let mediaDirectory = parentDirectory(of: item.path)
        do {
            let vaultPath = try await ensureVaultDirectory(
                in: mediaDirectory,
                service: service
            )
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            var vaultEntries = try await entries(in: vaultPath, service: service)
            if vaultEntries.contains(where: { $0.name == filename(for: item) }) {
                return .deferred
            }

            let directoryName = leaseDirectoryName(for: item)
            if let existingLease = vaultEntries.first(where: {
                $0.name == directoryName && $0.isDirectory
            }) {
                if await leaseIsActive(
                    existingLease,
                    service: service,
                    now: now
                ) {
                    return .deferred
                }
                _ = try? await service.delete(
                    existingLease,
                    recursive: true,
                    context: RemoteOperationContext()
                )
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                vaultEntries = try await entries(in: vaultPath, service: service)
                if vaultEntries.contains(where: { $0.name == filename(for: item) }) {
                    return .deferred
                }
            }

            let leaseDirectory: RemoteFileItem
            do {
                leaseDirectory = try await service.createFolder(
                    named: directoryName,
                    in: vaultPath,
                    context: RemoteOperationContext()
                )
            } catch {
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                return .deferred
            }

            let token = UUID().uuidString
            let record = SuperThumbnailLeaseRecord(
                workerID: workerID,
                token: token,
                expiresAt: now.addingTimeInterval(Self.leaseLifetime)
            )
            do {
                try await uploadJSON(
                    record,
                    named: Self.leaseRecordName,
                    to: leaseDirectory.path,
                    conflictPolicy: .replace,
                    service: service
                )
            } catch {
                _ = try? await service.delete(
                    leaseDirectory,
                    recursive: true,
                    context: RemoteOperationContext()
                )
                return .deferred
            }
            return .acquired(
                SuperThumbnailCooperativeLease(
                    itemID: item.id,
                    vaultPath: vaultPath,
                    directoryName: directoryName,
                    token: token
                )
            )
        } catch {
            return .uncoordinated
        }
    }

    func release(
        _ lease: SuperThumbnailCooperativeLease,
        service: any RemoteFileService
    ) async {
        directoryEntries[listingKey(lease.vaultPath, service: service)] = nil
        guard let leaseDirectory = try? await entries(
            in: lease.vaultPath,
            service: service
        ).first(where: {
            $0.name == lease.directoryName && $0.isDirectory
        }) else { return }
        directoryEntries[listingKey(leaseDirectory.path, service: service)] = nil
        guard let recordItem = try? await entries(
            in: leaseDirectory.path,
            service: service
        ).first(where: { $0.name == Self.leaseRecordName }),
              let record: SuperThumbnailLeaseRecord = await decodedJSON(
                  from: recordItem,
                  service: service
              ),
              record.token == lease.token else { return }
        _ = try? await service.delete(
            leaseDirectory,
            recursive: true,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(lease.vaultPath, service: service)] = nil
    }

    func storeFolder(
        _ items: [RemoteFileItem],
        service: any RemoteFileService,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard supportsVault(service), !items.isEmpty else { return .empty }
        let mediaDirectory = parentDirectory(of: items[0].path)
        let attemptedItemIDs = Set(items.map(\.id))
        var storedItemIDs: Set<String> = []
        do {
            let vaultPath = try await ensureVaultDirectory(
                in: mediaDirectory,
                service: service
            )
            for item in items {
                try Task.checkCancellation()
                guard parentDirectory(of: item.path) == mediaDirectory,
                      let data = await localData(item),
                      !data.isEmpty else { continue }
                let name = filename(for: item)
                let currentEntries = try await entries(in: vaultPath, service: service)
                if currentEntries.contains(where: { $0.name == name }) {
                    storedItemIDs.insert(item.id)
                    continue
                }
                try await atomicallyUpload(
                    data,
                    named: name,
                    to: vaultPath,
                    service: service
                )
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                storedItemIDs.insert(item.id)
            }
            return .init(
                storedItemIDs: storedItemIDs,
                attemptedItemIDs: attemptedItemIDs,
                errorDescription: nil,
                didAttempt: true
            )
        } catch {
            return .init(
                storedItemIDs: storedItemIDs,
                attemptedItemIDs: attemptedItemIDs,
                errorDescription: vaultErrorDescription(error),
                didAttempt: true
            )
        }
    }

    func storedItemIDs(
        for items: [RemoteFileItem],
        service: any RemoteFileService
    ) async throws -> Set<String> {
        guard supportsVault(service), !items.isEmpty else { return [] }
        directoryEntries.removeAll()
        var stored: Set<String> = []
        for (directory, folderItems) in Dictionary(grouping: items, by: {
            parentDirectory(of: $0.path)
        }) {
            try Task.checkCancellation()
            let vaultPath = appending(Self.directoryName, to: directory)
            let siblings = try await entries(in: directory, service: service)
            guard siblings.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { continue }
            let names = Set(try await entries(in: vaultPath, service: service).map(\.name))
            for item in folderItems where names.contains(filename(for: item)) {
                stored.insert(item.id)
            }
        }
        return stored
    }

    func invalidateListings() {
        directoryEntries.removeAll()
    }

    func removeVaults(
        startingAt rootPath: String,
        service: any RemoteFileService
    ) async throws -> Int {
        guard service.capabilities.contains(.delete) else { return 0 }
        var pendingDirectories = [rootPath]
        var removedFiles = 0
        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            let directory = pendingDirectories.removeFirst()
            let children = try await service.list(directory: directory)
            for child in children where child.isDirectory {
                if child.name == Self.directoryName {
                    let vaultItems = try await service.list(directory: child.path)
                    for vaultItem in vaultItems where !vaultItem.isDirectory {
                        _ = try await service.delete(
                            vaultItem,
                            recursive: false,
                            context: RemoteOperationContext()
                        )
                        removedFiles += 1
                    }
                    _ = try await service.delete(
                        child,
                        recursive: true,
                        context: RemoteOperationContext()
                    )
                } else if RemoteFileVisibilityPolicy.shouldDisplay(filename: child.name) {
                    pendingDirectories.append(child.path)
                }
            }
        }
        directoryEntries.removeAll()
        return removedFiles
    }

    private func supportsVault(_ service: any RemoteFileService) -> Bool {
        service.capabilities.contains(.createFolder)
            && service.capabilities.contains(.upload)
            && service.capabilities.contains(.rename)
            && service.capabilities.contains(.delete)
    }

    private func ensureVaultDirectory(
        in mediaDirectory: String,
        service: any RemoteFileService
    ) async throws -> String {
        let vaultPath = appending(Self.directoryName, to: mediaDirectory)
        let siblings = try await entries(in: mediaDirectory, service: service)
        if siblings.contains(where: { $0.name == Self.directoryName && $0.isDirectory }) {
            return vaultPath
        }
        do {
            _ = try await service.createFolder(
                named: Self.directoryName,
                in: mediaDirectory,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(mediaDirectory, service: service)] = nil
            let refreshed = try await entries(in: mediaDirectory, service: service)
            guard refreshed.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { throw error }
        }
        directoryEntries[listingKey(mediaDirectory, service: service)] = nil
        directoryEntries[listingKey(vaultPath, service: service)] = []
        return vaultPath
    }

    private func ensureWorkersDirectory(
        rootPath: String,
        service: any RemoteFileService
    ) async throws -> String {
        let vaultPath = try await ensureVaultDirectory(
            in: rootPath,
            service: service
        )
        let workersPath = appending(Self.workersDirectoryName, to: vaultPath)
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        let vaultEntries = try await entries(in: vaultPath, service: service)
        if vaultEntries.contains(where: {
            $0.name == Self.workersDirectoryName && $0.isDirectory
        }) {
            return workersPath
        }
        do {
            _ = try await service.createFolder(
                named: Self.workersDirectoryName,
                in: vaultPath,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            let refreshed = try await entries(in: vaultPath, service: service)
            guard refreshed.contains(where: {
                $0.name == Self.workersDirectoryName && $0.isDirectory
            }) else { throw error }
        }
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        directoryEntries[listingKey(workersPath, service: service)] = []
        return workersPath
    }

    private func workerFilename(_ workerID: String) -> String {
        "worker-\(workerID).json"
    }

    private func leaseDirectoryName(for item: RemoteFileItem) -> String {
        let name = filename(for: item)
        return ".claim-" + String(name.dropLast(".jpg".count))
    }

    private func leaseIsActive(
        _ leaseDirectory: RemoteFileItem,
        service: any RemoteFileService,
        now: Date
    ) async -> Bool {
        let key = listingKey(leaseDirectory.path, service: service)
        directoryEntries[listingKey(leaseDirectory.path, service: service)] = nil
        guard let items = try? await entries(
            in: leaseDirectory.path,
            service: service
        ),
              let recordItem = items.first(where: {
                  $0.name == Self.leaseRecordName && !$0.isDirectory
              }),
              let record: SuperThumbnailLeaseRecord = await decodedJSON(
                  from: recordItem,
                  service: service
              ) else {
            if let modifiedAt = leaseDirectory.modifiedAt {
                return modifiedAt.addingTimeInterval(Self.leaseLifetime) > now
            }
            let firstSeen = missingLeaseFirstSeen[key] ?? now
            missingLeaseFirstSeen[key] = firstSeen
            return firstSeen.addingTimeInterval(Self.leaseLifetime) > now
        }
        missingLeaseFirstSeen[key] = nil
        return record.expiresAt > now
    }

    private func uploadJSON<Value: Encodable>(
        _ value: Value,
        named name: String,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        service: any RemoteFileService
    ) async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try JSONEncoder().encode(value).write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }
        _ = try await service.upload(
            localURL: localURL,
            to: directoryPath,
            preferredName: name,
            conflictPolicy: conflictPolicy,
            context: RemoteOperationContext()
        )
    }

    private func decodedJSON<Value: Decodable>(
        from item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> Value? {
        guard let localURL = try? await service.download(item) else { return nil }
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe) else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
    }

    private func atomicallyUpload(
        _ data: Data,
        named finalName: String,
        to vaultPath: String,
        service: any RemoteFileService
    ) async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try data.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let temporaryName = ".upload-\(UUID().uuidString).tmp"
        _ = try await service.upload(
            localURL: localURL,
            to: vaultPath,
            preferredName: temporaryName,
            conflictPolicy: .fail,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        let currentEntries = try await entries(in: vaultPath, service: service)
        guard let temporaryItem = currentEntries.first(where: { $0.name == temporaryName }) else {
            throw SuperThumbnailVaultError.uploadVerificationFailed
        }
        if currentEntries.contains(where: { $0.name == finalName }) {
            _ = try? await service.delete(
                temporaryItem,
                recursive: false,
                context: RemoteOperationContext()
            )
            return
        }
        do {
            _ = try await service.rename(
                temporaryItem,
                to: finalName,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            let refreshed = try await entries(in: vaultPath, service: service)
            guard refreshed.contains(where: { $0.name == finalName }) else {
                throw error
            }
            _ = try? await service.delete(
                temporaryItem,
                recursive: false,
                context: RemoteOperationContext()
            )
        }
    }

    private func entries(
        in path: String,
        service: any RemoteFileService
    ) async throws -> [RemoteFileItem] {
        let key = listingKey(path, service: service)
        if let cached = directoryEntries[key] { return cached }
        let listed = try await service.list(directory: path)
        directoryEntries[key] = listed
        return listed
    }

    private func listingKey(
        _ path: String,
        service: any RemoteFileService
    ) -> String {
        "\(service.connection.id.uuidString)|\(path)"
    }

    private func filename(for item: RemoteFileItem) -> String {
        let identity = [
            "engine=\(Self.engineVersion)",
            "name=\(item.name.precomposedStringWithCanonicalMapping)",
            "size=\(item.size ?? -1)",
            "modified=\(Int64((item.modifiedAt?.timeIntervalSince1970 ?? 0) * 1_000))",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "v\(Self.engineVersion)-"
            + digest.map { String(format: "%02x", $0) }.joined()
            + ".jpg"
    }

    private func vaultErrorDescription(_ error: Error) -> String {
        if RemoteRequestCancellation.isCancellation(error) {
            return "업로드가 중단되어 자동 재시도 목록에 보관했습니다."
        }
        return error.localizedDescription
    }

    private func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { return path.hasPrefix("/") ? "/" : "." }
        return parent
    }

    private func appending(_ name: String, to path: String) -> String {
        if path == "/" { return "/\(name)" }
        if path == "." { return "./\(name)" }
        return path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
    }
}

private actor SuperThumbnailCooperationSession {
    private static let heartbeatInterval: Duration = .seconds(30)
    private static let peerRefreshInterval: TimeInterval = 5

    private let workerID: String
    private let rootPath: String
    private let service: any RemoteFileService
    private var heartbeatTask: Task<Void, Never>?
    private var lastPeerRefresh = Date.distantPast
    private var cachedHasPeers = false

    init(
        workerID: String,
        rootPath: String,
        service: any RemoteFileService
    ) {
        self.workerID = workerID
        self.rootPath = rootPath
        self.service = service
    }

    func start() async {
        guard heartbeatTask == nil else { return }
        do {
            try await SuperThumbnailVault.shared.registerWorker(
                workerID,
                rootPath: rootPath,
                service: service
            )
        } catch {
            return
        }
        let currentWorkerID = workerID
        let currentRootPath = rootPath
        let currentService = service
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                try? await SuperThumbnailVault.shared.registerWorker(
                    currentWorkerID,
                    rootPath: currentRootPath,
                    service: currentService
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(750))
        _ = await hasPeers(forceRefresh: true)
    }

    func hasPeers(forceRefresh: Bool = false) async -> Bool {
        guard heartbeatTask != nil else { return false }
        let now = Date()
        if !forceRefresh,
           now.timeIntervalSince(lastPeerRefresh) < Self.peerRefreshInterval {
            return cachedHasPeers
        }
        do {
            let active = try await SuperThumbnailVault.shared.activeWorkerIDs(
                rootPath: rootPath,
                service: service,
                now: now
            )
            cachedHasPeers = active.contains { $0 != workerID }
        } catch {
            cachedHasPeers = false
        }
        lastPeerRefresh = now
        return cachedHasPeers
    }

    func claim(_ item: RemoteFileItem) async -> SuperThumbnailCooperativeClaim {
        guard await hasPeers() else { return .uncoordinated }
        return await SuperThumbnailVault.shared.claim(
            item,
            workerID: workerID,
            service: service
        )
    }

    func release(_ lease: SuperThumbnailCooperativeLease) async {
        await SuperThumbnailVault.shared.release(lease, service: service)
    }

    func stop() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await SuperThumbnailVault.shared.unregisterWorker(
            workerID,
            rootPath: rootPath,
            service: service
        )
    }
}

private enum SuperThumbnailVaultError: LocalizedError {
    case uploadVerificationFailed

    var errorDescription: String? {
        "NAS Vault 업로드 결과를 확인하지 못했습니다."
    }
}

actor SuperThumbnailVaultRun {
    private static let maximumUploadAttempts = 3
    private static let retryDelay: Duration = .milliseconds(250)
    private let options: SuperThumbnailVaultOptions
    private let service: any RemoteFileService
    private let folderItems: [String: [RemoteFileItem]]
    private let cooperationSession: SuperThumbnailCooperationSession?
    private var completedItemIDs: Set<String> = []
    private var uploadedFolders: Set<String> = []

    init(
        options: SuperThumbnailVaultOptions,
        items: [RemoteFileItem],
        service: any RemoteFileService,
        cooperationRootPath: String? = nil,
        workerID: String? = nil
    ) {
        self.options = options
        self.service = service
        folderItems = Dictionary(grouping: items) {
            ($0.path as NSString).deletingLastPathComponent
        }
        if options.isEnabled,
           options.timing == .now,
           let cooperationRootPath,
           let workerID {
            cooperationSession = SuperThumbnailCooperationSession(
                workerID: workerID,
                rootPath: cooperationRootPath,
                service: service
            )
        } else {
            cooperationSession = nil
        }
    }

    func startCooperation() async {
        await cooperationSession?.start()
    }

    func stopCooperation() async {
        await cooperationSession?.stop()
    }

    func restoredData(for item: RemoteFileItem) async -> Data? {
        guard options.isEnabled else { return nil }
        return await SuperThumbnailVault.shared.data(for: item, service: service)
    }

    func cooperativeRestoredData(
        for item: RemoteFileItem,
        forceRefresh: Bool
    ) async -> Data? {
        guard cooperationSession != nil, forceRefresh else { return nil }
        return await SuperThumbnailVault.shared.data(
            for: item,
            service: service,
            refreshListing: true
        )
    }

    func cooperativeClaim(
        _ item: RemoteFileItem
    ) async -> SuperThumbnailCooperativeClaim {
        guard let cooperationSession else { return .uncoordinated }
        return await cooperationSession.claim(item)
    }

    func releaseCooperativeLease(
        _ lease: SuperThumbnailCooperativeLease
    ) async {
        await cooperationSession?.release(lease)
    }

    func registerCompleted(_ item: RemoteFileItem) {
        guard options.isEnabled else { return }
        completedItemIDs.insert(item.id)
    }

    func markCompleted(
        _ item: RemoteFileItem,
        cooperative: Bool = false,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        registerCompleted(item)
        guard options.timing == .now else { return .empty }
        if cooperative {
            return await storeFolderWithRetry([item], localData: localData)
        }
        let folder = (item.path as NSString).deletingLastPathComponent
        guard !uploadedFolders.contains(folder),
              let items = folderItems[folder],
              items.allSatisfy({ completedItemIDs.contains($0.id) }) else {
            return .empty
        }
        let result = await storeFolderWithRetry(
            items,
            localData: localData
        )
        if result.errorDescription == nil, result.didAttempt {
            uploadedFolders.insert(folder)
        }
        return result
    }

    func uploadAvailable(
        _ item: RemoteFileItem,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled, options.timing == .now else { return .empty }
        registerCompleted(item)
        return await storeFolderWithRetry([item], localData: localData)
    }

    func finish(
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        var storedItemIDs: Set<String> = []
        var attemptedItemIDs: Set<String> = []
        var firstError: String?
        for (folder, items) in folderItems where !uploadedFolders.contains(folder) {
            let result = await storeFolderWithRetry(
                items.filter { completedItemIDs.contains($0.id) },
                localData: localData
            )
            storedItemIDs.formUnion(result.storedItemIDs)
            attemptedItemIDs.formUnion(result.attemptedItemIDs)
            firstError = firstError ?? result.errorDescription
            if result.errorDescription == nil,
               result.didAttempt,
               items.allSatisfy({ completedItemIDs.contains($0.id) }) {
                uploadedFolders.insert(folder)
            }
        }
        return .init(
            storedItemIDs: storedItemIDs,
            attemptedItemIDs: attemptedItemIDs,
            errorDescription: firstError,
            didAttempt: !attemptedItemIDs.isEmpty || firstError != nil
        )
    }

    func verifyStoredItemIDs() async throws -> Set<String> {
        guard options.isEnabled else { return [] }
        return try await SuperThumbnailVault.shared.storedItemIDs(
            for: folderItems.values.flatMap { $0 },
            service: service
        )
    }

    private func storeFolderWithRetry(
        _ items: [RemoteFileItem],
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        var latestResult = SuperThumbnailVaultStoreResult.empty
        for attempt in 1...Self.maximumUploadAttempts {
            guard !Task.isCancelled else { return latestResult }
            latestResult = await SuperThumbnailVault.shared.storeFolder(
                items,
                service: service,
                localData: localData
            )
            guard latestResult.errorDescription != nil else { return latestResult }
            guard attempt < Self.maximumUploadAttempts, !Task.isCancelled else {
                return latestResult
            }
            do {
                try await Task.sleep(for: Self.retryDelay)
            } catch {
                return latestResult
            }
        }
        return latestResult
    }
}
