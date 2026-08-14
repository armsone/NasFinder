import Foundation
import XCTest
@testable import NasFinder

final class WebHardFileStoreTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var store: WebHardFileStore!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "WebHardFileStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        store = try WebHardFileStore(rootURL: temporaryDirectory)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        store = nil
    }

    func testTraversalCannotEscapeRoot() throws {
        XCTAssertThrowsError(try store.list(path: "/../")) { error in
            XCTAssertEqual(error as? WebHardFileStoreError, .invalidPath)
        }
        XCTAssertThrowsError(try store.prepareUpload(path: "/folder/../../outside.txt")) { error in
            XCTAssertEqual(error as? WebHardFileStoreError, .invalidPath)
        }
    }

    func testUploadCreatesIntermediateFoldersAndKeepsExistingFile() throws {
        let first = try store.prepareUpload(path: "/Photos/Trip/photo.txt")
        try Data("first".utf8).write(to: first.temporaryURL)
        try store.commitUpload(first)

        let second = try store.prepareUpload(path: "/Photos/Trip/photo.txt")
        try Data("second".utf8).write(to: second.temporaryURL)
        try store.commitUpload(second)

        let items = try store.list(path: "/Photos/Trip")
        XCTAssertEqual(items.map(\.name), ["photo (1).txt", "photo.txt"])
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL(path: "/Photos/Trip/photo.txt")),
            Data("first".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: store.fileURL(path: "/Photos/Trip/photo (1).txt")),
            Data("second".utf8)
        )
    }

    func testListingHidesSymbolicLinks() throws {
        let outside = temporaryDirectory.deletingLastPathComponent().appendingPathComponent(
            "outside-\(UUID().uuidString).txt"
        )
        try Data("private".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: temporaryDirectory.appendingPathComponent("link.txt"),
            withDestinationURL: outside
        )

        XCTAssertTrue(try store.list(path: "/").isEmpty)
        XCTAssertThrowsError(try store.fileURL(path: "/link.txt"))
    }

    func testFolderArchiveHasZipHeadersAndFileName() throws {
        try store.createDirectory(path: "/Folder")
        let upload = try store.prepareUpload(path: "/Folder/hello.txt")
        try Data("hello".utf8).write(to: upload.temporaryURL)
        try store.commitUpload(upload)

        let archive = try WebHardZipArchive.create(
            from: store.directoryURL(path: "/Folder"),
            in: temporaryDirectory
        )
        let data = try Data(contentsOf: archive)

        XCTAssertTrue(data.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        XCTAssertNotNil(data.range(of: Data("hello.txt".utf8)))
        XCTAssertNotNil(data.range(of: Data([0x50, 0x4B, 0x05, 0x06])))
    }

    func testHTTPServerUploadsListsAndDownloadsFile() async throws {
        let server = WebHardHTTPServer(store: store)
        let ready = expectation(description: "server ready")
        let portRecorder = WebHardPortRecorder()
        server.start(
            address: WebHardNetworkAddress(
                interfaceName: "lo0",
                address: "127.0.0.1",
                kind: .other
            ),
            password: "TESTPASSWORD"
        ) { state in
            if case let .ready(port) = state {
                portRecorder.store(port)
                ready.fulfill()
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(portRecorder.value)
        defer { server.stop() }

        let baseURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)"))
        let (pageData, pageResponse) = try await URLSession.shared.data(from: baseURL)
        XCTAssertEqual((pageResponse as? HTTPURLResponse)?.statusCode, 200)
        let page = try XCTUnwrap(String(data: pageData, encoding: .utf8))
        XCTAssertTrue(page.contains("id=\"receive\""))
        XCTAssertTrue(page.contains("id=\"files\""))
        XCTAssertFalse(page.contains("id=\"folder\""))
        XCTAssertTrue(page.contains("webkitGetAsEntry"))
        XCTAssertTrue(page.contains("file.webkitRelativePath||file.name"))
        XCTAssertTrue(page.contains("await load(current);status.textContent=`${done}개 올림`"))

        var upload = URLRequest(
            url: baseURL.appendingPathComponent("api/file").appending(
                queryItems: [
                    URLQueryItem(name: "path", value: "/Folder/hello.txt"),
                    URLQueryItem(name: "password", value: "TESTPASSWORD"),
                ]
            )
        )
        upload.httpMethod = "PUT"
        upload.httpBody = Data("hello web hard".utf8)
        let (_, uploadResponse) = try await URLSession.shared.data(for: upload)
        XCTAssertEqual((uploadResponse as? HTTPURLResponse)?.statusCode, 201)

        let listURL = baseURL.appendingPathComponent("api/list").appending(
            queryItems: [
                URLQueryItem(name: "path", value: "/Folder"),
                URLQueryItem(name: "password", value: "TESTPASSWORD"),
            ]
        )
        let (listData, listResponse) = try await URLSession.shared.data(from: listURL)
        XCTAssertEqual((listResponse as? HTTPURLResponse)?.statusCode, 200)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let items = try decoder.decode([WebHardFileItem].self, from: listData)
        XCTAssertEqual(items.map(\.name), ["hello.txt"])

        let fileURL = baseURL.appendingPathComponent("api/file").appending(
            queryItems: [
                URLQueryItem(name: "path", value: "/Folder/hello.txt"),
                URLQueryItem(name: "password", value: "TESTPASSWORD"),
            ]
        )
        let (fileData, fileResponse) = try await URLSession.shared.data(from: fileURL)
        XCTAssertEqual((fileResponse as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(fileData, Data("hello web hard".utf8))

        let unauthorizedURL = baseURL.appendingPathComponent("api/list").appending(
            queryItems: [URLQueryItem(name: "path", value: "/")]
        )
        let (_, unauthorizedResponse) = try await URLSession.shared.data(from: unauthorizedURL)
        XCTAssertEqual((unauthorizedResponse as? HTTPURLResponse)?.statusCode, 401)
    }

    func testHTTPServerAllowsAccessWithoutOptionalPassword() async throws {
        let server = WebHardHTTPServer(store: store)
        let ready = expectation(description: "server ready without password")
        let portRecorder = WebHardPortRecorder()
        server.start(
            address: WebHardNetworkAddress(
                interfaceName: "lo0",
                address: "127.0.0.1",
                kind: .other
            ),
            password: ""
        ) { state in
            if case let .ready(port) = state {
                portRecorder.store(port)
                ready.fulfill()
            }
        }
        await fulfillment(of: [ready], timeout: 5)
        let port = try XCTUnwrap(portRecorder.value)
        defer { server.stop() }

        let listURL = try XCTUnwrap(
            URL(string: "http://127.0.0.1:\(port)/api/list?path=/")
        )
        let (_, response) = try await URLSession.shared.data(from: listURL)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}

private final class WebHardPortRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: UInt16?

    var value: UInt16? {
        lock.withLock { storedValue }
    }

    func store(_ value: UInt16) {
        lock.withLock { storedValue = value }
    }
}
