import XCTest
@testable import NasFinder

final class ExternalPlayerHandoffTests: XCTestCase {
    func testSafeHTTPURLRoundTripsAsExactlyOneUrlParameter() throws {
        let original = URL(string: "https://nas.example.com:5006/video/a%20b.mkv")!
        let iina = try XCTUnwrap(ExternalPlayerHandoff.iinaURL(for: original))
        let components = try XCTUnwrap(URLComponents(url: iina, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "iina")
        XCTAssertEqual(components.host, "weblink")
        XCTAssertEqual(components.queryItems?.count, 1)
        XCTAssertEqual(components.queryItems?.first?.name, "url")
        XCTAssertEqual(components.queryItems?.first?.value, original.absoluteString)
    }

    func testUserInfoAndSecretQueriesAreRejectedForOpenAndCopy() {
        let unsafe = [
            "https://user:pw@nas.example.com/a.mp4",
            "https://nas.example.com/a.mp4?_sid=abc",
            "https://nas.example.com/a.mp4?access_token=abc",
            "https://nas.example.com/a.mp4?Signature=abc",
            "https://nas.example.com/a.mp4?auth=abc",
            "https://nas.example.com/a.mp4#token=abc"
        ].compactMap(URL.init(string:))
        XCTAssertEqual(unsafe.count, 6)
        for url in unsafe {
            XCTAssertNil(ExternalPlayerHandoff.iinaURL(for: url), url.absoluteString)
            XCTAssertNil(ExternalPlayerHandoff.copyableText(for: url), url.absoluteString)
        }
    }

    func testNonHTTPSchemesAreBlocked() {
        for text in ["file:///tmp/a.mp4", "ftp://h/a.mp4", "smb://h/a.mp4", "sftp://h/a.mp4", "iina://open?url=x"] {
            let url = URL(string: text)!
            XCTAssertNil(ExternalPlayerHandoff.iinaURL(for: url), text)
            XCTAssertNil(ExternalPlayerHandoff.copyableText(for: url), text)
        }
    }

    func testMaliciousAmpersandsStayInsideOneUrlParameter() throws {
        let original = URL(string: "https://nas.example.com/a.mp4?x=1&mpv_script=evil&mpv_cmd=run")!
        let iina = try XCTUnwrap(ExternalPlayerHandoff.iinaURL(for: original))
        let components = try XCTUnwrap(URLComponents(url: iina, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.queryItems?.map(\.name), ["url"])
        XCTAssertEqual(components.queryItems?.first?.value, original.absoluteString)
        XCTAssertFalse(iina.absoluteString.contains("&"))
    }
}
