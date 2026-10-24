import XCTest
@testable import NasFinder

/// 미디어 고르기 선택이 화면 수명과 분리돼 유지되는지. 화면 pop·재생성은 같은 세션 객체를 다시 만나는 것으로 모델링한다.
@MainActor
final class LocalPhotoLibrarySelectionStoreTests: XCTestCase {
    private func entry(id: String, url: URL?, owns: Bool = true) -> LocalPhotoSelectionEntry {
        let item = RemoteFileItem(connectionID: LocalPhotoLibraryFileService.connectionID, path: id, name: "\(id).jpg",
                                  kind: .file, size: nil, modifiedAt: nil, contentTypeIdentifier: "public.jpeg")
        var value = LocalPhotoSelectionEntry(id: id, item: item, url: url, isVideo: false, thumbnail: nil, origin: .file)
        value.ownsURL = owns
        return value
    }

    func testStoreForTheSameScopeReturnsTheSameSessionSoSelectionSurvivesViewRecreation() {
        let first = LocalPhotoLibrarySelectionStore.store(for: .trailer)
        first.releaseAll()
        first.entries = [entry(id: "a", url: nil), entry(id: "b", url: nil)]
        first.sourcePage = .files
        // 화면이 사라졌다 다시 만들어져도 같은 세션을 만난다.
        let again = LocalPhotoLibrarySelectionStore.store(for: .trailer)
        XCTAssertTrue(first === again)
        XCTAssertEqual(again.entries.map(\.id), ["a", "b"], "선택 순서가 유지돼야 합니다.")
        XCTAssertEqual(again.sourcePage, .files)
        XCTAssertFalse(LocalPhotoLibrarySelectionStore.store(for: .library) === first, "맥락이 다르면 선택을 섞지 않습니다.")
        first.releaseAll()
    }

    func testReleaseAllDeletesOnlyOwnedCopiesAndKeepsReadOnlyOriginals() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("selection-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let owned = directory.appendingPathComponent("owned.jpg")
        let original = directory.appendingPathComponent("original.jpg")
        try Data([1]).write(to: owned)
        try Data([2]).write(to: original)
        let store = LocalPhotoLibrarySelectionStore.store(for: .mediaMusic)
        store.entries = [entry(id: "o", url: owned, owns: true), entry(id: "r", url: original, owns: false)]
        store.releaseAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: owned.path), "앱 소유 임시 사본은 명시적 비우기에서 지워집니다.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path), "폰하드 등 읽기 전용 원본은 지우지 않습니다.")
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testDiscardOwnedFileIsPerEntryAndNotImpliedByNavigation() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("selection-keep-\(UUID().uuidString).jpg")
        try Data([3]).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = LocalPhotoLibrarySelectionStore.store(for: .project)
        store.releaseAll()
        store.entries = [entry(id: "keep", url: url)]
        // 화면을 떠나는 것만으로는 사본이 사라지지 않는다(세션이 소유한다).
        _ = LocalPhotoLibrarySelectionStore.store(for: .project)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.discardOwnedFile(of: store.entries[0])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        store.releaseAll()
    }
}
