import XCTest
@testable import NasFinder

final class RemoteThumbnailDiskCacheTests: XCTestCase {
    @MainActor
    func testStoreNotificationIsDeliveredOnMainThread() async throws {
        let cacheURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let defaultsName = "RemoteThumbnailDiskCacheTests.\(UUID().uuidString)"
        let notificationExpectation = expectation(description: "thumbnail stored notification")
        let observer = NotificationCenter.default.addObserver(
            forName: .remoteThumbnailDiskCacheDidStore,
            object: nil,
            queue: nil
        ) { _ in
            XCTAssertTrue(Thread.isMainThread)
            notificationExpectation.fulfill()
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            try? FileManager.default.removeItem(at: cacheURL)
            UserDefaults(suiteName: defaultsName)?
                .removePersistentDomain(forName: defaultsName)
        }
        let cache = RemoteThumbnailDiskCache(
            directoryURL: cacheURL,
            userDefaultsSuiteName: defaultsName
        )

        await cache.store(Data([0xA1]), forKey: "main-thread-notification")
        await fulfillment(of: [notificationExpectation], timeout: 1)
    }

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

    func testFolderRefreshRemovesOnlySpecifiedItemsAndRejectsLateStores() async throws {
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
        let refreshedItem = makeItem(path: "/folder/refreshed.avi")
        let preservedItem = makeItem(path: "/other/preserved.avi")
        let refreshedKey = RemoteThumbnailCacheKey.remoteData(
            for: refreshedItem,
            size: .small
        )
        let preservedKey = RemoteThumbnailCacheKey.remoteData(
            for: preservedItem,
            size: .small
        )

        await cache.store(Data([0xA1]), forKey: refreshedKey)
        await cache.store(Data([0xB2]), forKey: preservedKey)
        let generationBeforeRefresh = await cache.currentGeneration()

        await cache.removeData(for: [refreshedItem])
        await cache.store(
            Data([0xC3]),
            forKey: refreshedKey,
            expectedGeneration: generationBeforeRefresh
        )

        let refreshedData = await cache.data(forKey: refreshedKey)
        let preservedData = await cache.data(forKey: preservedKey)
        XCTAssertNil(refreshedData)
        XCTAssertEqual(preservedData, Data([0xB2]))
    }

    private func makeItem(path: String) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!,
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: .file,
            size: 123_456,
            modifiedAt: Date(timeIntervalSince1970: 100),
            contentTypeIdentifier: "public.avi"
        )
    }
}
