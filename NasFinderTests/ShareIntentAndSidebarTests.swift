import XCTest
@testable import NasFinder

final class ShareIntentAndSidebarTests: XCTestCase {
    @MainActor
    func testShareIntentDeepLinkParsingIsStrict() {
        let batch = UUID()
        XCTAssertNotNil(ShareIntentCoordinator.parse(URL(string: "nasfinder://share-intent?batch=\(batch.uuidString)&intent=photoSelect")!))
        XCTAssertEqual(ShareIntentCoordinator.parse(URL(string: "nasfinder://share-intent?batch=\(batch.uuidString)&intent=makeVideo")!)?.intent, .makeVideo)
        XCTAssertNil(ShareIntentCoordinator.parse(URL(string: "nasfinder://share-intent?batch=not-a-uuid&intent=makeVideo")!))
        XCTAssertNil(ShareIntentCoordinator.parse(URL(string: "nasfinder://share-intent?batch=\(batch.uuidString)&intent=deleteAll")!))
        XCTAssertNil(ShareIntentCoordinator.parse(URL(string: "nasfinder://inbox?id=\(batch.uuidString)")!), "기존 inbox 딥링크는 건드리지 않습니다.")
        XCTAssertNil(ShareIntentCoordinator.parse(URL(string: "https://share-intent?batch=\(batch.uuidString)&intent=makeVideo")!))
    }

    func testFavoritesRowJoinsExistingSidebarOrderWithoutMovingSavedPreferences() {
        let connection = UUID()
        let withFavorites = SidebarFinderItemID.current(connectionIDs: [connection], showsGooglePhotos: true)
        XCTAssertTrue(withFavorites.contains(SidebarFinderItemID.favorites))
        // 즐겨찾기가 생기기 전에 사용자가 저장한 순서.
        let saved = [SidebarFinderItemID.browser, connection.uuidString, SidebarFinderItemID.phoneHard,
                     SidebarFinderItemID.photos, SidebarFinderItemID.googlePhotos, SidebarFinderItemID.deviceFiles]
        let merged = SidebarOrderPolicy.normalized(stored: saved, current: withFavorites)
        XCTAssertEqual(Array(merged.prefix(saved.count)), saved, "기존 사용자 순서는 그대로여야 합니다.")
        let missing = withFavorites.filter { !saved.contains($0) }
        XCTAssertTrue(missing.contains(SidebarFinderItemID.favorites))
        XCTAssertEqual(Array(merged.dropFirst(saved.count)), missing, "저장되지 않은 현재 행은 현재 순서대로 꼬리에 붙습니다.")
        XCTAssertEqual(Set(merged), Set(withFavorites))
        // 저장된 순서가 없으면 즐겨찾기가 기본 맨 앞에 있다.
        let defaults = SidebarFinderItemID.current(connectionIDs: [], showsGooglePhotos: false)
        XCTAssertEqual(defaults.first, SidebarFinderItemID.favorites)
        XCTAssertTrue(defaults.contains(SidebarFinderItemID.photos))
        XCTAssertTrue(defaults.contains(SidebarFinderItemID.deviceFiles))
        XCTAssertTrue(defaults.contains(SidebarFinderItemID.phoneHard))
    }

    func testVideoMaterialsLabelChangesOnlyTheDisplayNotTheStoredIdentifier() {
        XCTAssertEqual(VideoDestination.basket.title, "작업대")
        XCTAssertEqual(VideoDestination.basket.rawValue, "재료함", "사이드바 순서 저장 키는 바뀌면 안 됩니다.")
        XCTAssertEqual(ToolsDestination.transfer.rawValue, "사진 전송")
        XCTAssertEqual(ToolsDestination.transfer.title, "미디어 전송")
        XCTAssertEqual(ToolsDestination.selection.title, "사진 선별")
    }
}
