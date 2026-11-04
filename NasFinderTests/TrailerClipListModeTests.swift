import XCTest
@testable import NasFinder

final class TrailerClipListModeTests: XCTestCase {
    func testTitlesAndPersistedRawValuesAreStable() {
        XCTAssertEqual(TrailerClipListMode.allCases.map(\.title), ["자세히", "썸네일", "포스터"])
        XCTAssertEqual(TrailerClipListMode.allCases.map(\.rawValue), ["detail", "thumbnail", "poster"])
        XCTAssertEqual(TrailerClipListMode(rawValue: "poster"), .poster)
        XCTAssertNil(TrailerClipListMode(rawValue: "unknown"))
    }

    func testOnlyGridModesUseFixedInspector() {
        XCTAssertFalse(TrailerClipListMode.detail.isGrid)
        XCTAssertTrue(TrailerClipListMode.thumbnail.isGrid)
        XCTAssertTrue(TrailerClipListMode.poster.isGrid)
    }
}
