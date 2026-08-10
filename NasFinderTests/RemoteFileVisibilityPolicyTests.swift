import XCTest
@testable import NasFinder

final class RemoteFileVisibilityPolicyTests: XCTestCase {
    func testDotPrefixedFilesAndFoldersAreHidden() {
        XCTAssertFalse(RemoteFileVisibilityPolicy.shouldDisplay(filename: ".DS_Store"))
        XCTAssertFalse(RemoteFileVisibilityPolicy.shouldDisplay(filename: ".git"))
        XCTAssertFalse(RemoteFileVisibilityPolicy.shouldDisplay(filename: "."))
        XCTAssertFalse(RemoteFileVisibilityPolicy.shouldDisplay(filename: ".."))
    }

    func testOrdinaryNamesAndEmbeddedDotsRemainVisible() {
        XCTAssertTrue(RemoteFileVisibilityPolicy.shouldDisplay(filename: "photo.jpg"))
        XCTAssertTrue(RemoteFileVisibilityPolicy.shouldDisplay(filename: "family.video.mp4"))
        XCTAssertTrue(RemoteFileVisibilityPolicy.shouldDisplay(filename: "가족 사진.HEIC"))
    }
}
