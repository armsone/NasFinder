import XCTest
@testable import NasFinder

@MainActor
final class FavoriteStoreTests: XCTestCase {
    func testFolderMosaicUsesOnlyFirstNineMediaFiles() {
        let connectionID = UUID()
        let folder = RemoteFileItem(
            connectionID: connectionID,
            path: "/folder",
            name: "folder",
            kind: .folder,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let text = RemoteFileItem(
            connectionID: connectionID,
            path: "/note.txt",
            name: "note.txt",
            kind: .file,
            size: 1,
            modifiedAt: nil,
            contentTypeIdentifier: "public.plain-text"
        )
        let media = (0..<12).map { index in
            RemoteFileItem(
                connectionID: connectionID,
                path: "/\(index).jpg",
                name: "\(index).jpg",
                kind: .file,
                size: 1,
                modifiedAt: nil,
                contentTypeIdentifier: "public.jpeg"
            )
        }

        let result = FavoriteFolderMosaicPolicy.candidates(
            from: [folder, text] + media
        )

        XCTAssertEqual(result.count, 9)
        XCTAssertEqual(result.map(\.name), (0..<9).map { "\($0).jpg" })
    }

    func testFavoriteFolderThumbnailPrefersSheetThenMosaicThenFolderIcon() {
        XCTAssertEqual(
            FavoriteFolderThumbnailDisplayPolicy.content(
                hasSheetImage: true,
                sheetLookupFinished: true
            ),
            .sheetImage
        )
        XCTAssertEqual(
            FavoriteFolderThumbnailDisplayPolicy.content(
                hasSheetImage: true,
                sheetLookupFinished: false
            ),
            .sheetImage
        )
        XCTAssertEqual(
            FavoriteFolderThumbnailDisplayPolicy.content(
                hasSheetImage: false,
                sheetLookupFinished: true
            ),
            .mosaicFallback
        )
        XCTAssertEqual(
            FavoriteFolderThumbnailDisplayPolicy.content(
                hasSheetImage: false,
                sheetLookupFinished: false
            ),
            .loadingPlaceholder
        )
    }

    func testSkinToneBlurRequiresDominantSampleFraction() {
        XCTAssertFalse(
            SkinToneBlurPolicy.shouldBlur(skinToneCount: 41, sampleCount: 100)
        )
        XCTAssertTrue(
            SkinToneBlurPolicy.shouldBlur(skinToneCount: 42, sampleCount: 100)
        )
        XCTAssertTrue(SkinToneBlurPolicy.isSkinTone(red: 214, green: 154, blue: 120))
        XCTAssertFalse(SkinToneBlurPolicy.isSkinTone(red: 80, green: 150, blue: 210))
    }

    func testFavoriteShelfOnlyBeginsReorderingForLongHorizontalMovement() {
        XCTAssertFalse(
            FavoriteShelfInteractionPolicy.shouldBeginReordering(
                translation: CGSize(width: 11, height: 0)
            )
        )
        XCTAssertFalse(
            FavoriteShelfInteractionPolicy.shouldBeginReordering(
                translation: CGSize(width: 20, height: 21)
            )
        )
        XCTAssertTrue(
            FavoriteShelfInteractionPolicy.shouldBeginReordering(
                translation: CGSize(width: -12, height: 3)
            )
        )
    }

    func testFavoritePersistsAndCanBeRemoved() throws {
        let suiteName = "FavoriteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let item = RemoteFileItem(
            connectionID: UUID(),
            path: "/share/folder/clip.mp4",
            name: "clip.mp4",
            kind: .file,
            size: 123,
            modifiedAt: Date(timeIntervalSince1970: 456),
            contentTypeIdentifier: "public.mpeg-4"
        )

        let store = FavoriteStore(defaults: defaults)
        store.toggle(item)

        XCTAssertTrue(store.contains(item))
        XCTAssertEqual(store.items.map(\.id), [item.id])
        XCTAssertEqual(FavoriteStore(defaults: defaults).items.map(\.id), [item.id])

        store.toggle(item)
        XCTAssertFalse(store.contains(item))
        XCTAssertTrue(FavoriteStore(defaults: defaults).items.isEmpty)
    }

    func testFavoritePreservesCloudIdentityAndReadsLegacyPayload() throws {
        let connectionID = UUID()
        let cloudItem = RemoteFileItem(
            connectionID: connectionID,
            path: "/old-name.mov",
            remoteIdentifier: "drive-item-7",
            parentRemoteIdentifier: "drive-root",
            revisionIdentifier: "rev-3",
            name: "old-name.mov",
            kind: .file,
            size: 99,
            modifiedAt: nil,
            contentTypeIdentifier: "public.movie"
        )
        let favorite = FavoriteItem(item: cloudItem)
        let decoded = try JSONDecoder().decode(
            FavoriteItem.self,
            from: JSONEncoder().encode(favorite)
        )

        XCTAssertEqual(decoded.remoteItem.remoteIdentifier, "drive-item-7")
        XCTAssertEqual(decoded.remoteItem.parentRemoteIdentifier, "drive-root")
        XCTAssertEqual(decoded.remoteItem.revisionIdentifier, "rev-3")
        XCTAssertEqual(decoded.id, cloudItem.id)

        let legacyJSON = """
        {
          "connectionID": "\(connectionID.uuidString)",
          "path": "/legacy.mov",
          "name": "legacy.mov",
          "kind": "file",
          "size": 1,
          "contentTypeIdentifier": "public.movie",
          "addedAt": 0
        }
        """
        let legacy = try JSONDecoder().decode(
            FavoriteItem.self,
            from: Data(legacyJSON.utf8)
        )

        XCTAssertNil(legacy.remoteIdentifier)
        XCTAssertEqual(legacy.id, "\(connectionID.uuidString):/legacy.mov")
    }

    func testFavoriteSupportsFoldersAndKeepsInsertionOrder() throws {
        let suiteName = "FavoriteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let connectionID = UUID()
        let folder = RemoteFileItem(
            connectionID: connectionID,
            path: "/share/folder",
            name: "folder",
            kind: .folder,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let file = RemoteFileItem(
            connectionID: connectionID,
            path: "/share/file.txt",
            name: "file.txt",
            kind: .file,
            size: 1,
            modifiedAt: nil,
            contentTypeIdentifier: "public.plain-text"
        )

        let store = FavoriteStore(defaults: defaults)
        store.toggle(folder)
        store.toggle(file)

        XCTAssertEqual(store.items.map(\.name), ["folder", "file.txt"])
        XCTAssertTrue(store.items[0].remoteItem.isDirectory)
    }

    func testRemovingFavoriteUsesExactIDWhenNamesMatch() throws {
        let suiteName = "FavoriteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let connectionID = UUID()
        let first = RemoteFileItem(
            connectionID: connectionID,
            path: "/share/first/clip.mp4",
            name: "clip.mp4",
            kind: .file,
            size: 1,
            modifiedAt: nil,
            contentTypeIdentifier: "public.mpeg-4"
        )
        let second = RemoteFileItem(
            connectionID: connectionID,
            path: "/share/second/clip.mp4",
            name: "clip.mp4",
            kind: .file,
            size: 2,
            modifiedAt: nil,
            contentTypeIdentifier: "public.mpeg-4"
        )

        let store = FavoriteStore(defaults: defaults)
        store.toggle(first)
        store.toggle(second)
        store.remove(id: second.id)

        XCTAssertEqual(store.items.map(\.id), [first.id])
        XCTAssertTrue(store.contains(first))
        XCTAssertFalse(store.contains(second))
    }

    func testMovingFavoriteUsesExactIDAndPersistsOrder() throws {
        let suiteName = "FavoriteStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let connectionID = UUID()
        let items = ["first", "second", "third"].map { name in
            RemoteFileItem(
                connectionID: connectionID,
                path: "/share/\(name).mp4",
                name: "\(name).mp4",
                kind: .file,
                size: 1,
                modifiedAt: nil,
                contentTypeIdentifier: "public.mpeg-4"
            )
        }

        let store = FavoriteStore(defaults: defaults)
        items.forEach(store.toggle)
        store.move(id: items[2].id, to: 0)

        let expectedIDs = [items[2].id, items[0].id, items[1].id]
        XCTAssertEqual(store.items.map(\.id), expectedIDs)
        XCTAssertEqual(FavoriteStore(defaults: defaults).items.map(\.id), expectedIDs)
    }
}
