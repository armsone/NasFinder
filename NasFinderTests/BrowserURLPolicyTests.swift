import XCTest
@testable import NasFinder

final class BrowserURLPolicyTests: XCTestCase {
    func testAddressAddsSecureSchemeAndRejectsNonWebSchemes() {
        XCTAssertEqual(
            BrowserURLPolicy.normalizedURL(from: "example.com/path")?.absoluteString,
            "https://example.com/path"
        )
        XCTAssertEqual(
            BrowserURLPolicy.normalizedURL(from: " http://example.com ")?.absoluteString,
            "http://example.com"
        )
        XCTAssertNil(BrowserURLPolicy.normalizedURL(from: "file:///tmp/private"))
        XCTAssertNil(BrowserURLPolicy.normalizedURL(from: "javascript:alert(1)"))
    }

    func testSuggestedDownloadFilenameRemovesPathSeparators() {
        let response = URLResponse(
            url: URL(string: "https://example.com/fallback.pdf")!,
            mimeType: "application/pdf",
            expectedContentLength: 20,
            textEncodingName: nil
        )

        XCTAssertEqual(
            BrowserURLPolicy.safeFilename("folder/bad:name.pdf", response: response),
            "folder-bad-name.pdf"
        )
        XCTAssertEqual(
            BrowserURLPolicy.safeFilename("", response: response),
            "fallback.pdf"
        )
    }
}
