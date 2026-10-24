import Foundation
import XCTest
@testable import NasFinder

final class LoopbackRangeHTTPTests: XCTestCase {
    // MARK: - Request Parsing

    func testParseValidGetRequest() {
        let raw = "GET /v/abcdef0123456789 HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        guard case let .request(req) = result else {
            XCTFail("Expected .request, got \(result)")
            return
        }
        XCTAssertEqual(req.method, .get)
        XCTAssertEqual(req.target, "/v/abcdef0123456789")
        XCTAssertEqual(req.headers["host"], "127.0.0.1:8080")
    }

    func testParseValidHeadRequest() {
        let raw = "HEAD /v/token123 HTTP/1.1\r\nHost: 127.0.0.1:9090\r\nRange: bytes=0-1023\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        guard case let .request(req) = result else {
            XCTFail("Expected .request, got \(result)")
            return
        }
        XCTAssertEqual(req.method, .head)
        XCTAssertEqual(req.headers["range"], "bytes=0-1023")
    }

    func testParseIncompleteRequest() {
        let raw = "GET /v/token HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(result, .incomplete)
    }

    func testParseUnsupportedMethod() {
        let raw = "POST /v/token HTTP/1.1\r\nHost: 127.0.0.1:8080\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(result, .rejected(405))
    }

    func testParseDuplicateUniqueHeaderRejected() {
        let raw = "GET /v/token HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nHost: 127.0.0.1:9090\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(result, .rejected(400))
    }

    func testParseNonZeroContentLengthRejected() {
        let raw = "GET /v/token HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nContent-Length: 42\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(result, .rejected(400))
    }

    func testParseTransferEncodingRejected() {
        let raw = "GET /v/token HTTP/1.1\r\nHost: 127.0.0.1:8080\r\nTransfer-Encoding: chunked\r\n\r\n"
        let result = LoopbackHTTP.parse(Data(raw.utf8))
        XCTAssertEqual(result, .rejected(400))
    }

    // MARK: - Host / Origin / Route Rejection

    func testRejectionValid() {
        let req = LoopbackHTTPRequest(
            method: .get,
            target: "/v/mysecrettoken",
            headers: ["host": "127.0.0.1:54321"]
        )
        let status = LoopbackHTTP.rejection(for: req, token: "mysecrettoken", boundPort: 54321)
        XCTAssertNil(status)
    }

    func testRejectionInvalidHost() {
        let req = LoopbackHTTPRequest(
            method: .get,
            target: "/v/mysecrettoken",
            headers: ["host": "localhost:54321"]
        )
        let status = LoopbackHTTP.rejection(for: req, token: "mysecrettoken", boundPort: 54321)
        XCTAssertEqual(status, 403)
    }

    func testRejectionInvalidOrigin() {
        let req = LoopbackHTTPRequest(
            method: .get,
            target: "/v/mysecrettoken",
            headers: [
                "host": "127.0.0.1:54321",
                "origin": "http://evil.com"
            ]
        )
        let status = LoopbackHTTP.rejection(for: req, token: "mysecrettoken", boundPort: 54321)
        XCTAssertEqual(status, 403)
    }

    func testRejectionWrongTokenRoute() {
        let req = LoopbackHTTPRequest(
            method: .get,
            target: "/v/wrongtoken",
            headers: ["host": "127.0.0.1:54321"]
        )
        let status = LoopbackHTTP.rejection(for: req, token: "mysecrettoken", boundPort: 54321)
        XCTAssertEqual(status, 404)
    }

    // MARK: - Range Resolution

    func testResolveRangeNilReturnsFull() {
        let res = LoopbackHTTP.resolveRange(nil, size: 1000)
        XCTAssertEqual(res, .full)
    }

    func testResolveRangeExplicitSpan() {
        let res = LoopbackHTTP.resolveRange("bytes=0-499", size: 1000)
        XCTAssertEqual(res, .partial(0...499))
    }

    func testResolveRangeOpenEnd() {
        let res = LoopbackHTTP.resolveRange("bytes=500-", size: 1000)
        XCTAssertEqual(res, .partial(500...999))
    }

    func testResolveRangeSuffix() {
        let res = LoopbackHTTP.resolveRange("bytes=-200", size: 1000)
        XCTAssertEqual(res, .partial(800...999))
    }

    func testResolveRangeBeyondSizeIsUnsatisfiable() {
        let res = LoopbackHTTP.resolveRange("bytes=1500-2000", size: 1000)
        XCTAssertEqual(res, .unsatisfiable)
    }

    func testResolveRangeMultipleRangesUnsatisfiable() {
        let res = LoopbackHTTP.resolveRange("bytes=0-100,200-300", size: 1000)
        XCTAssertEqual(res, .unsatisfiable)
    }

    func testResolveRangeZeroSizeIsUnsatisfiable() {
        let res = LoopbackHTTP.resolveRange("bytes=0-0", size: 0)
        XCTAssertEqual(res, .unsatisfiable)
    }

    // MARK: - Response Heads

    func testSuccessHeadPartialContent() {
        let resolution = LoopbackRangeResolution.partial(0...99)
        guard let (headData, span) = LoopbackHTTP.successHead(
            resolution: resolution,
            size: 500,
            contentType: "video/mp4"
        ) else {
            XCTFail("Expected success head")
            return
        }
        XCTAssertEqual(span, 0...99)
        let headString = String(data: headData, encoding: .utf8) ?? ""
        XCTAssertTrue(headString.contains("HTTP/1.1 206 Partial Content"))
        XCTAssertTrue(headString.contains("Content-Range: bytes 0-99/500"))
        XCTAssertTrue(headString.contains("Content-Length: 100"))
        XCTAssertTrue(headString.contains("Accept-Ranges: bytes"))
        XCTAssertTrue(headString.contains("Content-Type: video/mp4"))
        XCTAssertTrue(headString.contains("Connection: close"))
    }

    func testErrorHead416() {
        let data = LoopbackHTTP.errorHead(status: 416, size: 500)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("HTTP/1.1 416 Range Not Satisfiable"))
        XCTAssertTrue(str.contains("Content-Range: bytes */500"))
        XCTAssertTrue(str.contains("Content-Length: 0"))
    }

    func testErrorHead405() {
        let data = LoopbackHTTP.errorHead(status: 405)
        let str = String(data: data, encoding: .utf8) ?? ""
        XCTAssertTrue(str.contains("HTTP/1.1 405 Method Not Allowed"))
        XCTAssertTrue(str.contains("Allow: GET, HEAD"))
    }

    // MARK: - URLSessionBoundedRangeReader Content-Range Parsing

    func testParseContentRangeValid() {
        XCTAssertEqual(
            URLSessionBoundedRangeReader.parseContentRange("bytes 0-499/1000"),
            0...499
        )
    }

    func testParseContentRangeReversedBoundsReturnsNil() {
        XCTAssertNil(URLSessionBoundedRangeReader.parseContentRange("bytes 500-200/1000"))
    }

    func testParseContentRangeNegativeBoundsReturnsNil() {
        XCTAssertNil(URLSessionBoundedRangeReader.parseContentRange("bytes -10-20/1000"))
        XCTAssertNil(URLSessionBoundedRangeReader.parseContentRange("bytes 10--5/1000"))
    }

    // MARK: - LoopbackPlaybackRelayManager Capacity & Rejection

    func testRelayLimitReachedErrorDescription() {
        let error = LoopbackRelayError.relayLimitReached
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription?.contains("최대 4개") == true)
    }

    @MainActor
    func testPendingCapacityRejectionAndNonEviction() {
        let manager = LoopbackPlaybackRelayManager(observeTermination: false)
        XCTAssertTrue(manager.hasCapacity(for: "relay-1"))

        let dummyTask1 = Task<URL, Error> { URL(string: "http://127.0.0.1:8080/v/1")! }
        let dummyTask2 = Task<URL, Error> { URL(string: "http://127.0.0.1:8080/v/2")! }
        let dummyTask3 = Task<URL, Error> { URL(string: "http://127.0.0.1:8080/v/3")! }
        let dummyTask4 = Task<URL, Error> { URL(string: "http://127.0.0.1:8080/v/4")! }

        manager.registerPendingStartForTesting(id: "relay-1", task: dummyTask1)
        manager.registerPendingStartForTesting(id: "relay-2", task: dummyTask2)
        manager.registerPendingStartForTesting(id: "relay-3", task: dummyTask3)
        manager.registerPendingStartForTesting(id: "relay-4", task: dummyTask4)

        // 5th new request must be rejected to protect existing capacity
        XCTAssertFalse(manager.hasCapacity(for: "relay-5"))

        // Same-ID pending requests must be reusable before capacity check
        XCTAssertTrue(manager.hasCapacity(for: "relay-1"))
        XCTAssertTrue(manager.hasCapacity(for: "relay-4"))

        dummyTask1.cancel()
        dummyTask2.cancel()
        dummyTask3.cancel()
        dummyTask4.cancel()
    }
}
