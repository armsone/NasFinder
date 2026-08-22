import XCTest
@testable import NasFinder

final class SuperThumbnailVaultTests: XCTestCase {
    func testSimultaneousVaultProcessesGrantOnlyOneLease() async throws {
        let storage = VaultTestStorage()
        let serviceA = VaultTestService(storage: storage)
        let serviceB = VaultTestService(
            storage: storage,
            connectionID: serviceA.connection.id
        )
        let item = makeItems(connectionID: serviceA.connection.id)[0]
        let vaultA = SuperThumbnailVault()
        let vaultB = SuperThumbnailVault()

        async let first = vaultA.claim(
            item,
            workerID: "worker-a",
            service: serviceA
        )
        async let second = vaultB.claim(
            item,
            workerID: "worker-b",
            service: serviceB
        )
        let results = await [first, second]
        let leases = results.compactMap { result -> SuperThumbnailCooperativeLease? in
            guard case .acquired(let lease) = result else { return nil }
            return lease
        }
        XCTAssertEqual(leases.count, 1)
        if let lease = leases.first {
            await vaultA.release(lease, service: serviceA)
            await vaultB.release(lease, service: serviceB)
        }
    }

    func testExpiredWorkerAndLeaseCanBeRecovered() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let item = makeItems(connectionID: service.connection.id)[0]
        let vault = SuperThumbnailVault()
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await vault.registerWorker(
            "worker-a",
            rootPath: "/media",
            service: service,
            now: startedAt
        )
        let active = try await vault.activeWorkerIDs(
            rootPath: "/media",
            service: service,
            now: startedAt.addingTimeInterval(89)
        )
        XCTAssertEqual(active, Set(["worker-a"]))
        let expired = try await vault.activeWorkerIDs(
            rootPath: "/media",
            service: service,
            now: startedAt.addingTimeInterval(91)
        )
        XCTAssertTrue(expired.isEmpty)

        let first = await vault.claim(
            item,
            workerID: "worker-a",
            service: service,
            now: startedAt
        )
        guard case .acquired = first else {
            return XCTFail("첫 임대를 만들지 못했습니다.")
        }
        let recovered = await vault.claim(
            item,
            workerID: "worker-b",
            service: service,
            now: startedAt.addingTimeInterval(181)
        )
        guard case .acquired(let recoveredLease) = recovered else {
            return XCTFail("만료된 임대를 다른 기기가 회수해야 합니다.")
        }
        await vault.release(recoveredLease, service: service)
    }

    func testMultipleDevicesLeaseEachItemToOnlyOneWorker() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let item = makeItems(connectionID: service.connection.id)[0]
        let vault = SuperThumbnailVault.shared
        try await vault.registerWorker(
            "worker-a",
            rootPath: "/media",
            service: service
        )
        try await vault.registerWorker(
            "worker-b",
            rootPath: "/media",
            service: service
        )

        let first = await vault.claim(
            item,
            workerID: "worker-a",
            service: service
        )
        guard case .acquired(let firstLease) = first else {
            return XCTFail("첫 번째 기기가 작업을 선점해야 합니다.")
        }
        let competing = await vault.claim(
            item,
            workerID: "worker-b",
            service: service
        )
        guard case .deferred = competing else {
            return XCTFail("다른 기기는 같은 작업을 건너뛰어야 합니다.")
        }

        await vault.release(firstLease, service: service)
        let reassigned = await vault.claim(
            item,
            workerID: "worker-b",
            service: service
        )
        guard case .acquired(let secondLease) = reassigned else {
            return XCTFail("임대 해제 후 다른 기기가 작업을 가져가야 합니다.")
        }
        await vault.release(secondLease, service: service)
        await vault.unregisterWorker(
            "worker-a",
            rootPath: "/media",
            service: service
        )
        await vault.unregisterWorker(
            "worker-b",
            rootPath: "/media",
            service: service
        )
    }

    func testCooperativeCompletionPublishesEachResultImmediately() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let items = makeItems(connectionID: service.connection.id)
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: items,
            service: service
        )

        let result = await run.markCompleted(
            items[0],
            cooperative: true,
            localData: { Data($0.name.utf8) }
        )

        XCTAssertEqual(result.storedItemIDs, Set([items[0].id]))
        let storedCount = await storage.vaultFileCount()
        XCTAssertEqual(storedCount, 1)
    }

    func testNowWaitsForWholeFolderBeforeUploadingExistingLocalResults() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let items = makeItems(connectionID: service.connection.id)
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: items,
            service: service
        )
        let payloads = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Data($0.name.utf8)) })

        let first = await run.markCompleted(items[0]) { payloads[$0.id] }
        XCTAssertEqual(first.storedCount, 0)
        XCTAssertFalse(first.didAttempt)
        let countAfterFirst = await storage.vaultFileCount()
        XCTAssertEqual(countAfterFirst, 0)

        let second = await run.markCompleted(items[1]) { payloads[$0.id] }
        XCTAssertEqual(second.storedCount, 2)
        XCTAssertTrue(second.didAttempt)
        let countAfterSecond = await storage.vaultFileCount()
        XCTAssertEqual(countAfterSecond, 2)
    }

    func testLaterUploadsOnlyWhenRunFinishes() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let items = makeItems(connectionID: service.connection.id)
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .later),
            items: items,
            service: service
        )
        let payloads = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Data($0.name.utf8)) })

        for item in items {
            let stored = await run.markCompleted(item) { payloads[$0.id] }
            XCTAssertEqual(stored.storedCount, 0)
        }
        let countBeforeFinish = await storage.vaultFileCount()
        XCTAssertEqual(countBeforeFinish, 0)
        let finished = await run.finish { payloads[$0.id] }
        XCTAssertEqual(finished.storedCount, 2)
        let countAfterFinish = await storage.vaultFileCount()
        XCTAssertEqual(countAfterFinish, 2)
    }

    func testResumeUploadsCachedThumbnailImmediately() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let items = makeItems(connectionID: service.connection.id)
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: items,
            service: service
        )
        let available = items[0]
        let expected = Data("cached-before-resume".utf8)

        let result = await run.uploadAvailable(
            available,
            localData: { item in item.id == available.id ? expected : nil }
        )

        XCTAssertTrue(result.didAttempt)
        XCTAssertEqual(result.storedItemIDs, Set([available.id]))
        let storedCount = await storage.vaultFileCount()
        XCTAssertEqual(storedCount, 1)
    }

    func testAnotherConnectionCanRestoreSameFileFromNASVault() async throws {
        let storage = VaultTestStorage()
        let writer = VaultTestService(storage: storage)
        let writerItem = makeItems(connectionID: writer.connection.id)[0]
        let writerRun = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: [writerItem],
            service: writer
        )
        let expected = Data("shared-thumbnail".utf8)
        let stored = await writerRun.markCompleted(writerItem) { _ in expected }
        XCTAssertEqual(stored.storedCount, 1)

        let reader = VaultTestService(storage: storage)
        let readerItem = makeItems(connectionID: reader.connection.id)[0]
        let readerRun = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: [readerItem],
            service: reader
        )
        let restored = await readerRun.restoredData(for: readerItem)
        XCTAssertEqual(restored, expected)
    }

    func testNowRetriesCancelledUploadBeforeMarkingFolderStored() async throws {
        let storage = VaultTestStorage(cancelledUploadCount: 1)
        let service = VaultTestService(storage: storage)
        let items = makeItems(connectionID: service.connection.id)
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: items,
            service: service
        )
        let payloads = Dictionary(uniqueKeysWithValues: items.map { ($0.id, Data($0.name.utf8)) })

        _ = await run.markCompleted(items[0]) { payloads[$0.id] }
        let result = await run.markCompleted(items[1]) { payloads[$0.id] }

        XCTAssertNil(result.errorDescription)
        XCTAssertTrue(result.didAttempt)
        XCTAssertEqual(result.storedCount, 2)
        let uploadAttempts = await storage.uploadAttemptCount()
        XCTAssertGreaterThanOrEqual(uploadAttempts, 3)
        let storedCount = await storage.vaultFileCount()
        XCTAssertEqual(storedCount, 2)
    }

    func testRemovingNASVaultKeepsLocalPayloadAndDeletesOnlyVaultFiles() async throws {
        let storage = VaultTestStorage()
        let service = VaultTestService(storage: storage)
        let item = makeItems(connectionID: service.connection.id)[0]
        let run = SuperThumbnailVaultRun(
            options: .init(isEnabled: true, timing: .now),
            items: [item],
            service: service
        )
        let localPayload = Data("keep-on-phone".utf8)
        _ = await run.markCompleted(item) { _ in localPayload }

        let removed = try await SuperThumbnailVault.shared.removeVaults(
            startingAt: "/media",
            service: service
        )
        XCTAssertEqual(removed, 1)
        let remaining = await storage.vaultFileCount()
        XCTAssertEqual(remaining, 0)
        XCTAssertEqual(localPayload, Data("keep-on-phone".utf8))
    }

    private func makeItems(connectionID: UUID) -> [RemoteFileItem] {
        ["one.avi", "two.mkv"].map { name in
            RemoteFileItem(
                connectionID: connectionID,
                path: "/media/\(name)",
                name: name,
                kind: .file,
                size: 1_024,
                modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                contentTypeIdentifier: nil
            )
        }
    }
}

private actor VaultTestStorage {
    private var directories: Set<String> = ["/media"]
    private var files: [String: Data] = [:]
    private var cancelledUploadCount: Int
    private var uploadAttempts = 0

    init(cancelledUploadCount: Int = 0) {
        self.cancelledUploadCount = cancelledUploadCount
    }

    func list(_ path: String, connectionID: UUID) -> [RemoteFileItem] {
        let prefix = path == "/" ? "/" : "\(path)/"
        var seen: Set<String> = []
        var result: [RemoteFileItem] = []
        for directory in directories where directory.hasPrefix(prefix) && directory != path {
            let remainder = String(directory.dropFirst(prefix.count))
            guard !remainder.contains("/"), seen.insert(remainder).inserted else { continue }
            result.append(item(path: directory, name: remainder, directory: true, connectionID: connectionID))
        }
        for filePath in files.keys where filePath.hasPrefix(prefix) {
            let remainder = String(filePath.dropFirst(prefix.count))
            guard !remainder.contains("/"), seen.insert(remainder).inserted else { continue }
            result.append(item(path: filePath, name: remainder, directory: false, connectionID: connectionID))
        }
        return result
    }

    func createDirectory(_ path: String) throws {
        guard directories.insert(path).inserted else {
            throw RemoteFileOperationError.conflict(
                sourcePath: path,
                destinationPath: path
            )
        }
    }
    func store(_ data: Data, path: String) { files[path] = data }
    func beginUpload() throws {
        uploadAttempts += 1
        if cancelledUploadCount > 0 {
            cancelledUploadCount -= 1
            throw CancellationError()
        }
    }
    func uploadAttemptCount() -> Int { uploadAttempts }
    func data(at path: String) -> Data? { files[path] }
    func containsFile(at path: String) -> Bool { files[path] != nil }
    func remove(_ path: String) { files[path] = nil; directories.remove(path) }
    func rename(from: String, to: String) { files[to] = files.removeValue(forKey: from) }
    func vaultFileCount() -> Int {
        files.keys.filter { $0.contains("/\(SuperThumbnailVault.directoryName)/") }.count
    }

    private func item(
        path: String,
        name: String,
        directory: Bool,
        connectionID: UUID
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: name,
            kind: directory ? .folder : .file,
            size: directory ? nil : Int64(files[path]?.count ?? 0),
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}

private struct VaultTestService: RemoteFileService, Sendable {
    let connection: RemoteConnection
    let storage: VaultTestStorage

    init(storage: VaultTestStorage, connectionID: UUID = UUID()) {
        self.storage = storage
        connection = RemoteConnection(
            id: connectionID,
            name: "Vault Test",
            kind: .webDAV,
            host: "vault.test",
            username: "tester"
        )
    }

    var capabilities: RemoteFileServiceCapabilities {
        [.createFolder, .rename, .delete, .upload]
    }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        await storage.list(path ?? "/media", connectionID: connection.id)
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        guard let data = await storage.data(at: item.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try data.write(to: url)
        return url
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let path = directoryPath == "/" ? "/\(name)" : "\(directoryPath)/\(name)"
        try await storage.createDirectory(path)
        return RemoteFileItem(
            connectionID: connection.id,
            path: path,
            name: name,
            kind: .folder,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await storage.beginUpload()
        let name = preferredName ?? localURL.lastPathComponent
        let path = "\(directoryPath)/\(name)"
        if await storage.containsFile(at: path) {
            switch conflictPolicy {
            case .fail:
                throw RemoteFileOperationError.conflict(
                    sourcePath: localURL.path,
                    destinationPath: path
                )
            case .skip:
                return .init(
                    operationID: context.operationID,
                    operation: .upload,
                    outcomes: [.skipped(sourcePath: localURL.path, destinationPath: path)]
                )
            case .replace:
                break
            case .keepBoth:
                throw RemoteFileOperationError.conflict(
                    sourcePath: localURL.path,
                    destinationPath: path
                )
            }
        }
        await storage.store(try Data(contentsOf: localURL), path: path)
        return .init(
            operationID: context.operationID,
            operation: .upload,
            outcomes: [.succeeded(sourcePath: localURL.path, destinationPath: path)]
        )
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        let parent = (item.path as NSString).deletingLastPathComponent
        let path = "\(parent)/\(newName)"
        await storage.rename(from: item.path, to: path)
        return RemoteFileItem(
            connectionID: connection.id,
            path: path,
            name: newName,
            kind: item.kind,
            size: item.size,
            modifiedAt: item.modifiedAt,
            contentTypeIdentifier: item.contentTypeIdentifier
        )
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        await storage.remove(item.path)
        return .init(
            operationID: context.operationID,
            operation: .delete,
            outcomes: [.succeeded(sourcePath: item.path)]
        )
    }
}
