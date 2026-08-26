import XCTest
@testable import NasFinderSuperThumbnailMac

final class UpdatePreferenceLogicTests: XCTestCase {
    func testAutomaticDownloadStatusIsExplicit() {
        XCTAssertEqual(UpdatePreferenceLogic.statusText(automaticDownloadEnabled: true), "자동 다운로드 상태: 켬")
        XCTAssertEqual(UpdatePreferenceLogic.statusText(automaticDownloadEnabled: false), "자동 다운로드 상태: 끔")
    }
}
