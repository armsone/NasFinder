import CryptoKit
import XCTest
@testable import NasFinder

final class FolderSuperThumbnailTests: XCTestCase {
    func testFolderNamingMatchesPortableIdentityFormula() {
        let name = "가족 여행"
        let filename = FolderSuperThumbnailNaming.thumbnailFilename(folderName: name)
        XCTAssertEqual(
            filename,
            FolderSuperThumbnailNaming.thumbnailFilename(
                folderName: name.decomposedStringWithCanonicalMapping
            )
        )
        let identity = "engine=1|kind=folder|name=\(name.precomposedStringWithCanonicalMapping)"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(filename, "v1-folder-\(digest).jpg")
        XCTAssertEqual(
            FolderSuperThumbnailNaming.emptyMarkerFilename(folderName: name),
            "v1-folder-\(digest).empty"
        )
    }

    func testDisplayRoutingLooksUpFoldersOnly() {
        let connectionID = UUID()
        let folder = makeItem(
            connectionID: connectionID,
            path: "/media/여행",
            name: "여행",
            kind: .folder
        )
        let file = makeItem(
            connectionID: connectionID,
            path: "/media/one.mp4",
            name: "one.mp4",
            kind: .file
        )
        XCTAssertTrue(FolderSuperThumbnailDisplayPolicy.shouldLookup(item: folder))
        XCTAssertFalse(FolderSuperThumbnailDisplayPolicy.shouldLookup(item: file))
        XCTAssertNil(
            FolderSuperThumbnailDisplayPolicy.negativeCacheDuration(
                for: .data(Data([1]))
            )
        )
        XCTAssertEqual(
            FolderSuperThumbnailDisplayPolicy.negativeCacheDuration(for: .emptyIndexed),
            10 * 60
        )
        XCTAssertEqual(
            FolderSuperThumbnailDisplayPolicy.negativeCacheDuration(for: .missing),
            60
        )
    }

    /// The Mac helper already blurs a skin-tone dominant folder sheet once
    /// (1.5 pt on the final sheet). Display consumers that blur file
    /// thumbnails must not add a second blur to folder sheets.
    func testFolderSheetsNeverReceiveDisplayTimeSkinToneBlur() {
        XCTAssertFalse(FolderSuperThumbnailDisplayPolicy.appliesDisplayTimeSkinToneBlur)
        XCTAssertFalse(
            FolderSuperThumbnailDisplayPolicy.detectsSkinToneDominance(requestedByConsumer: true)
        )
        XCTAssertFalse(
            FolderSuperThumbnailDisplayPolicy.detectsSkinToneDominance(requestedByConsumer: false)
        )
        // File thumbnails keep the consumer's own policy.
        XCTAssertTrue(SkinToneBlurPolicy.shouldBlur(skinToneCount: 42, sampleCount: 100))
    }

    func testFolderSheetLookupFindsGeneratedRecordEmptyMarkerAndMissingState() async {
        let storage = FolderVaultTestStorage()
        let service = FolderVaultTestService(storage: storage)
        let vault = SuperThumbnailVault()
        let sheetData = Data("folder-sheet-jpeg".utf8)
        let folder = makeItem(
            connectionID: service.connection.id,
            path: "/media/여행",
            name: "여행",
            kind: .folder
        )
        await storage.createDirectory("/media/여행")
        await storage.createDirectory("/media/.NasFinder-Vault")
        await storage.store(
            sheetData,
            path: "/media/.NasFinder-Vault/"
                + FolderSuperThumbnailNaming.thumbnailFilename(folderName: "여행")
        )
        guard case .data(let restored) = await vault.folderSheet(
            for: folder,
            service: service
        ) else {
            return XCTFail("생성된 폴더 시트를 찾아야 합니다.")
        }
        XCTAssertEqual(restored, sheetData)

        let empty = makeItem(
            connectionID: service.connection.id,
            path: "/media/빈 폴더",
            name: "빈 폴더",
            kind: .folder
        )
        await storage.createDirectory("/media/빈 폴더")
        await storage.store(
            Data("{}".utf8),
            path: "/media/.NasFinder-Vault/"
                + FolderSuperThumbnailNaming.emptyMarkerFilename(folderName: "빈 폴더")
        )
        await vault.invalidateListings()
        guard case .emptyIndexed = await vault.folderSheet(
            for: empty,
            service: service
        ) else {
            return XCTFail("빈 폴더는 명시적 색인 상태를 돌려줘야 합니다.")
        }

        let unknown = makeItem(
            connectionID: service.connection.id,
            path: "/media/미처리",
            name: "미처리",
            kind: .folder
        )
        await storage.createDirectory("/media/미처리")
        await vault.invalidateListings()
        guard case .missing = await vault.folderSheet(
            for: unknown,
            service: service
        ) else {
            return XCTFail("레코드가 없는 폴더는 재시도 가능해야 합니다.")
        }
    }

    func testMissingVaultDirectoryReportsMissingWithoutError() async {
        let storage = FolderVaultTestStorage()
        let service = FolderVaultTestService(storage: storage)
        let folder = makeItem(
            connectionID: service.connection.id,
            path: "/media/여행",
            name: "여행",
            kind: .folder
        )
        await storage.createDirectory("/media/여행")
        guard case .missing = await SuperThumbnailVault().folderSheet(
            for: folder,
            service: service
        ) else {
            return XCTFail("Vault가 없는 디렉터리는 missing이어야 합니다.")
        }
    }

    func testOldFileRecordsRemainReadableNextToNewFolderRecords() async {
        let storage = FolderVaultTestStorage()
        let service = FolderVaultTestService(storage: storage)
        let vault = SuperThumbnailVault()
        let modifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let file = RemoteFileItem(
            connectionID: service.connection.id,
            path: "/media/one.mp4",
            name: "one.mp4",
            kind: .file,
            size: 1_024,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: nil
        )
        // Legacy file record name derived independently from the documented
        // portable identity: engine, NFC name, size, epoch milliseconds.
        let identity = "engine=1|name=one.mp4|size=1024|modified=1700000000000"
        let digest = SHA256.hash(data: Data(identity.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let fileData = Data("legacy-file-thumb".utf8)
        await storage.createDirectory("/media/.NasFinder-Vault")
        await storage.store(fileData, path: "/media/.NasFinder-Vault/v1-\(digest).jpg")
        await storage.store(
            Data("new-folder-record".utf8),
            path: "/media/.NasFinder-Vault/"
                + FolderSuperThumbnailNaming.thumbnailFilename(folderName: "여행")
        )

        let restored = await vault.data(for: file, service: service)
        XCTAssertEqual(restored, fileData)
    }

    private func makeItem(
        connectionID: UUID,
        path: String,
        name: String,
        kind: RemoteFileItem.ItemKind
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: name,
            kind: kind,
            size: kind == .folder ? nil : 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}

private actor FolderVaultTestStorage {
    private var directories: Set<String> = ["/media"]
    private var files: [String: Data] = [:]

    func createDirectory(_ path: String) {
        directories.insert(path)
    }

    func store(_ data: Data, path: String) {
        files[path] = data
    }

    func data(at path: String) -> Data? { files[path] }

    func list(_ path: String, connectionID: UUID) -> [RemoteFileItem] {
        let prefix = path == "/" ? "/" : "\(path)/"
        var seen: Set<String> = []
        var result: [RemoteFileItem] = []
        for directory in directories where directory.hasPrefix(prefix) && directory != path {
            let remainder = String(directory.dropFirst(prefix.count))
            guard !remainder.contains("/"), seen.insert(remainder).inserted else { continue }
            result.append(
                RemoteFileItem(
                    connectionID: connectionID,
                    path: directory,
                    name: remainder,
                    kind: .folder,
                    size: nil,
                    modifiedAt: nil,
                    contentTypeIdentifier: nil
                )
            )
        }
        for filePath in files.keys where filePath.hasPrefix(prefix) {
            let remainder = String(filePath.dropFirst(prefix.count))
            guard !remainder.contains("/"), seen.insert(remainder).inserted else { continue }
            result.append(
                RemoteFileItem(
                    connectionID: connectionID,
                    path: filePath,
                    name: remainder,
                    kind: .file,
                    size: Int64(files[filePath]?.count ?? 0),
                    modifiedAt: nil,
                    contentTypeIdentifier: nil
                )
            )
        }
        return result
    }
}

private struct FolderVaultTestService: RemoteFileService, Sendable {
    let connection: RemoteConnection
    let storage: FolderVaultTestStorage

    init(storage: FolderVaultTestStorage) {
        self.storage = storage
        connection = RemoteConnection(
            id: UUID(),
            name: "Folder Vault Test",
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
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        guard let data = await storage.data(at: item.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try data.write(to: url)
        return url
    }
}
