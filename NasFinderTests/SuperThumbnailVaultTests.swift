import XCTest
@testable import NasFinder

final class SuperThumbnailVaultTests: XCTestCase {
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

    func createDirectory(_ path: String) { directories.insert(path) }
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

    init(storage: VaultTestStorage) {
        self.storage = storage
        connection = RemoteConnection(
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
        await storage.createDirectory(path)
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
