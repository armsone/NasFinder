import XCTest
@testable import NasFinder

@MainActor
final class FavoriteStoreTests: XCTestCase {
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
}
