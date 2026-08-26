import XCTest
@testable import NasFinder

final class FileProviderThumbnailCacheTests: XCTestCase {
    func testSynchronizesThumbnailsCreatedAfterEarlierMigration() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let container = root.appendingPathComponent("group", isDirectory: true)
        let superCache = root.appendingPathComponent("SuperThumbnails.v1", isDirectory: true)
        let remoteCache = root.appendingPathComponent("RemoteThumbnails.v2", isDirectory: true)
        try FileManager.default.createDirectory(at: superCache, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteCache, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data([1, 2, 3]).write(to: superCache.appendingPathComponent("super-key"))
        try Data([4, 5, 6]).write(to: remoteCache.appendingPathComponent("remote-key"))
        let suiteName = "FileProviderThumbnailCacheTests.\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let cache = FileProviderThumbnailCache(
            containerURL: container,
            legacyCacheURLs: [superCache, remoteCache],
            migrationDefaultsSuiteName: suiteName
        )
        let firstCount = await cache.migrateExistingCachesIfNeeded()
        try Data([7, 8, 9]).write(to: superCache.appendingPathComponent("later-super-key"))
        let secondCount = await cache.migrateExistingCachesIfNeeded()

        XCTAssertEqual(firstCount, 2)
        XCTAssertEqual(secondCount, 1)
        let destination = container
            .appendingPathComponent("Library/Caches/FileProviderThumbnails.v1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("super-key").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("remote-key").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent("later-super-key").path))
    }
}
