import XCTest
@testable import NasFinder

final class RemoteThumbnailDiskCacheTests: XCTestCase {
    func testStatisticsAndRemovalOnlyAffectThumbnailDirectory() async throws {
        let parentURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let cacheURL = parentURL.appending(path: "RemoteThumbnails.v2", directoryHint: .isDirectory)
        let siblingURL = parentURL.appending(path: "keep.txt", directoryHint: .notDirectory)
        let defaultsName = "RemoteThumbnailDiskCacheTests.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: parentURL)
            UserDefaults(suiteName: defaultsName)?
                .removePersistentDomain(forName: defaultsName)
        }
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )
        try Data("keep".utf8).write(to: siblingURL)
        let cache = RemoteThumbnailDiskCache(
            directoryURL: cacheURL,
            userDefaultsSuiteName: defaultsName
        )

        await cache.store(Data(repeating: 0xA1, count: 100), forKey: "first")
        await cache.store(Data(repeating: 0xB2, count: 200), forKey: "second")
        let beforeRemoval = await cache.statistics()
        XCTAssertEqual(beforeRemoval.fileCount, 2)
        XCTAssertEqual(beforeRemoval.totalBytes, 300)

        let generationBeforeRemoval = await cache.currentGeneration()
        await cache.removeAll()
        await cache.store(
            Data(repeating: 0xC3, count: 400),
            forKey: "late-store",
            expectedGeneration: generationBeforeRemoval
        )
        let afterRemoval = await cache.statistics()
        XCTAssertEqual(afterRemoval.fileCount, 0)
        XCTAssertEqual(afterRemoval.totalBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingURL.path))
    }

    func testAutomaticLimitPersistsOnlySupportedChoices() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let defaultsName = "RemoteThumbnailDiskCacheTests.\(UUID().uuidString)"
        defer {
            try? FileManager.default.removeItem(at: cacheURL)
            UserDefaults(suiteName: defaultsName)?
                .removePersistentDomain(forName: defaultsName)
        }
        let cache = RemoteThumbnailDiskCache(
            directoryURL: cacheURL,
            userDefaultsSuiteName: defaultsName
        )
        let selectedLimit = try XCTUnwrap(
            RemoteThumbnailDiskCache.automaticLimitOptions.first
        )

        await cache.setAutomaticLimitBytes(selectedLimit)
        let selectedStatistics = await cache.statistics()
        XCTAssertEqual(selectedStatistics.automaticLimitBytes, selectedLimit)

        await cache.setAutomaticLimitBytes(123)
        let invalidStatistics = await cache.statistics()
        XCTAssertEqual(invalidStatistics.automaticLimitBytes, selectedLimit)
    }
}
