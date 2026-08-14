import XCTest
@testable import NasFinder

@MainActor
final class BrowserFeaturePolicyTests: XCTestCase {
    func testSuperThumbnailThermalPolicyBalancesSpeedAndHeat() {
        XCTAssertFalse(ThumbnailThermalPolicy.shouldPause(for: .nominal))
        XCTAssertNil(ThumbnailThermalPolicy.pacingDelayMilliseconds(for: .nominal))
        XCTAssertFalse(ThumbnailThermalPolicy.shouldPause(for: .fair))
        XCTAssertEqual(
            ThumbnailThermalPolicy.pacingDelayMilliseconds(for: .fair),
            500
        )
        XCTAssertTrue(ThumbnailThermalPolicy.shouldPause(for: .serious))
        XCTAssertTrue(ThumbnailThermalPolicy.shouldPause(for: .critical))
    }

    func testHiddenSuperThumbnailStartCountsDownAfterFiveTaps() {
        XCTAssertNil(
            SuperThumbnailHiddenStartPolicy.remainingTapCount(after: 4)
        )
        XCTAssertEqual(
            SuperThumbnailHiddenStartPolicy.remainingTapCount(after: 5),
            5
        )
        XCTAssertEqual(
            SuperThumbnailHiddenStartPolicy.remainingTapCount(after: 9),
            1
        )
        XCTAssertNil(
            SuperThumbnailHiddenStartPolicy.remainingTapCount(after: 10)
        )
    }

    func testCoverFlowBackgroundChoicesMapToStoredBoolean() {
        XCTAssertFalse(
            FileBrowserCoverFlowBackground.light.usesDarkBackground
        )
        XCTAssertTrue(
            FileBrowserCoverFlowBackground.dark.usesDarkBackground
        )
        XCTAssertEqual(
            FileBrowserCoverFlowBackground(usesDarkBackground: false),
            .light
        )
        XCTAssertEqual(
            FileBrowserCoverFlowBackground(usesDarkBackground: true),
            .dark
        )
    }

    func testCoverFlowPreloadsAroundLiveDragPosition() {
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.preloadIndices(
                itemCount: 30,
                scrollPosition: 5.2
            ),
            Array(0...13)
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.preloadIndices(
                itemCount: 30,
                scrollPosition: 10.6
            ),
            Array(3...19)
        )
    }

    func testCoverFlowSlowDragStopsAtTheCardUnderTheFinger() {
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 12.2
            ),
            12
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 12.7
            ),
            13
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 42
            ),
            29
        )
        XCTAssertNil(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 0,
                scrollPosition: 0
            )
        )
    }

    func testCoverFlowMomentumContinuesInTheSwipeDirection() {
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 10.2,
                translation: -80,
                predictedEndTranslation: -170,
                cardStep: 60
            ),
            12
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 10.8,
                translation: 80,
                predictedEndTranslation: 170,
                cardStep: 60
            ),
            9
        )
    }

    func testCoverFlowMomentumIsCappedAndNeverReverses() {
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 10,
                translation: -40,
                predictedEndTranslation: -900,
                cardStep: 60
            ),
            13
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 10.2,
                translation: -80,
                predictedEndTranslation: -20,
                cardStep: 60
            ),
            10
        )
        XCTAssertEqual(
            FileBrowserCoverFlowPolicy.restingIndex(
                itemCount: 30,
                scrollPosition: 28.8,
                translation: -80,
                predictedEndTranslation: -800,
                cardStep: 60
            ),
            29
        )
    }

    func testPathComponentsStayWithinConfiguredRoot() {
        XCTAssertEqual(
            FileBrowserPathNavigation.components(
                currentPath: "/home/media/movies",
                rootPath: "/home"
            ),
            [
                FileBrowserPathComponent(path: "/home", title: "/home"),
                FileBrowserPathComponent(path: "/home/media", title: "media"),
                FileBrowserPathComponent(path: "/home/media/movies", title: "movies")
            ]
        )
        XCTAssertEqual(
            FileBrowserPathNavigation.components(currentPath: "/outside", rootPath: "/home"),
            [FileBrowserPathComponent(path: "/outside", title: "/outside")]
        )
    }

    func testParentFolderStaysWithinConfiguredRoot() {
        XCTAssertEqual(
            FileBrowserPathNavigation.parent(
                currentPath: "/home/media/movies",
                rootPath: "/home"
            ),
            FileBrowserPathComponent(path: "/home/media", title: "media")
        )
        XCTAssertEqual(
            FileBrowserPathNavigation.parent(
                currentPath: "./media/movies",
                rootPath: "."
            ),
            FileBrowserPathComponent(path: "./media", title: "media")
        )
        XCTAssertNil(
            FileBrowserPathNavigation.parent(
                currentPath: "/home",
                rootPath: "/home"
            )
        )
        XCTAssertNil(
            FileBrowserPathNavigation.parent(
                currentPath: "/outside",
                rootPath: "/home"
            )
        )
    }

    func testSingleFileThumbnailDoesNotRequireExternalPower() {
        let file = item(name: "movie.mp4", size: 1_024)
        let folder = item(name: "folder", isDirectory: true)

        XCTAssertFalse(
            ThumbnailPreheatPolicy.requiresExternalPower(
                rootItems: [file],
                recursively: false
            )
        )
        XCTAssertTrue(
            ThumbnailPreheatPolicy.requiresExternalPower(
                rootItems: [folder],
                recursively: false
            )
        )
        XCTAssertTrue(
            ThumbnailPreheatPolicy.requiresExternalPower(
                rootItems: [file],
                recursively: true
            )
        )
    }

    func testThumbnailCommandOnlyAppearsForGeneratableFiles() {
        let video = item(name: "movie.mp4", size: 2_048)
        let unknownSizeVideo = item(name: "unknown.mp4", size: nil)
        let document = item(name: "notes.txt", size: 20)

        XCTAssertTrue(
            ThumbnailPreheatPolicy.canGenerate(
                item: video,
                connectionKind: .sftp,
                supportsRangeStreaming: true
            )
        )
        XCTAssertFalse(
            ThumbnailPreheatPolicy.canGenerate(
                item: unknownSizeVideo,
                connectionKind: .sftp,
                supportsRangeStreaming: true
            )
        )
        XCTAssertFalse(
            ThumbnailPreheatPolicy.canGenerate(
                item: document,
                connectionKind: .synology,
                supportsRangeStreaming: true
            )
        )
    }

    func testSuperThumbnailAlwaysIncludesVideosAndPhotos() {
        let video = item(name: "movie.mkv", size: 2_048)
        let photo = item(name: "photo.heic", size: 4_096)
        let document = item(name: "notes.txt", size: 20)

        XCTAssertTrue(ThumbnailPreheatPolicy.canGenerateSuperThumbnail(item: video))
        XCTAssertTrue(ThumbnailPreheatPolicy.canGenerateSuperThumbnail(item: photo))
        XCTAssertFalse(ThumbnailPreheatPolicy.canGenerateSuperThumbnail(item: document))
    }

    func testFavoriteImportSkipsCanonicalDuplicatesAndAppendsNewAddresses() throws {
        let suiteName = "BrowserFeaturePolicyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("https://Example.com/path/", forKey: BrowserFavoritesStore.storageKey)
        let store = BrowserFavoritesStore(defaults: defaults)
        let data = try JSONEncoder().encode(
            BrowserFavoritesArchive(
                favorites: [
                    "https://example.com/path#section",
                    "https://new.example/files"
                ]
            )
        )

        let result = try store.importArchiveData(data)

        XCTAssertEqual(result, BrowserFavoritesImportResult(addedCount: 1, skippedCount: 1))
        XCTAssertEqual(store.favorites.count, 2)
        XCTAssertEqual(store.favorites.last, "https://new.example/files")
    }

    func testBrowserSessionRetentionIsThirtyMinutes() {
        XCTAssertEqual(NasFinderBrowserSessionStore.retentionInterval, 1_800)
    }

    private func item(
        name: String,
        size: Int64? = nil,
        isDirectory: Bool = false
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: UUID(),
            path: "/\(name)",
            name: name,
            kind: isDirectory ? .folder : .file,
            size: size,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }
}
