import Foundation
import XCTest
@testable import NasFinder

@MainActor
final class SynologyFileServiceTests: XCTestCase {
    func testConnectionUsesConfiguredHTTPSDSMEndpointAndFolderList() async throws {
        let fixture = SynologyAPIFixture(rootPath: "/share")
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Info", "query"):
                return .json(
                    #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi"},"SYNO.FileStation.List":{"path":"entry.cgi"}}}"#
                )
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        try await service.testConnection()

        let requests = fixture.requests.values
        XCTAssertEqual(requests.count, 3)

        let discovery = requests[0]
        XCTAssertEqual(discovery.url.scheme, "https")
        XCTAssertEqual(discovery.url.port, 5001)
        XCTAssertEqual(discovery.url.path, "/webapi/query.cgi")
        XCTAssertEqual(discovery.timeoutInterval, 15)

        let authentication = requests[1]
        XCTAssertEqual(authentication.url.scheme, "https")
        XCTAssertEqual(authentication.url.port, 5001)
        XCTAssertEqual(authentication.url.path, "/webapi/auth.cgi")
        XCTAssertEqual(authentication.formFields["version"], "6")
        XCTAssertEqual(authentication.formFields["session"], "FileStation")
        XCTAssertEqual(authentication.timeoutInterval, 30)

        let listing = requests[2]
        XCTAssertEqual(listing.url.scheme, "https")
        XCTAssertEqual(listing.url.port, 5001)
        XCTAssertEqual(listing.url.path, "/webapi/entry.cgi")
        XCTAssertEqual(listing.formFields["version"], "2")
        XCTAssertEqual(listing.formFields["folder_path"], "/share")
        XCTAssertEqual(listing.formFields["_sid"], "test-sid")
        XCTAssertEqual(listing.timeoutInterval, 30)
    }

    func testConnectionUsesHTTPAndListShareForConfiguredRoot() async throws {
        let fixture = SynologyAPIFixture(
            rootPath: "/",
            usesTLS: false,
            port: 5000
        )
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Info", "query"):
                return .json(
                    #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi"},"SYNO.FileStation.List":{"path":"entry.cgi"}}}"#
                )
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list_share"):
                return .json(#"{"success":true,"data":{"shares":[]}}"#)
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        try await service.testConnection()

        let listing = try XCTUnwrap(fixture.requests.values.last)
        XCTAssertEqual(listing.url.scheme, "http")
        XCTAssertEqual(listing.url.port, 5000)
        XCTAssertEqual(listing.url.path, "/webapi/entry.cgi")
        XCTAssertEqual(listing.formFields["method"], "list_share")
        XCTAssertNil(listing.formFields["folder_path"])
    }

    func testCreateFolderAndRenameUseVersionTwoArrayParameters() async throws {
        let fixture = SynologyAPIFixture()
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            case ("SYNO.FileStation.CreateFolder", "create"):
                return .json(
                    #"{"success":true,"data":{"folders":[{"name":"Photos","path":"/share/Photos","isdir":true}]}}"#
                )
            case ("SYNO.FileStation.Rename", "rename"):
                return .json(
                    #"{"success":true,"data":{"files":[{"name":"Pictures","path":"/share/Pictures","isdir":true}]}}"#
                )
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        let context = RemoteOperationContext()
        let created = try await service.createFolder(
            named: "Photos",
            in: "/share",
            context: context
        )
        let renamed = try await service.rename(
            created,
            to: "Pictures",
            context: context
        )

        XCTAssertEqual(created.path, "/share/Photos")
        XCTAssertTrue(created.isDirectory)
        XCTAssertEqual(renamed.path, "/share/Pictures")

        let requests = fixture.requests.values
        let create = try XCTUnwrap(
            requests.first { $0.formFields["api"] == "SYNO.FileStation.CreateFolder" }
        )
        XCTAssertEqual(create.formFields["version"], "2")
        XCTAssertEqual(
            try decodeStringArray(create.formFields["folder_path"]),
            ["/share"]
        )
        XCTAssertEqual(
            try decodeStringArray(create.formFields["name"]),
            ["Photos"]
        )

        let rename = try XCTUnwrap(
            requests.first { $0.formFields["api"] == "SYNO.FileStation.Rename" }
        )
        XCTAssertEqual(rename.formFields["version"], "2")
        XCTAssertEqual(
            try decodeStringArray(rename.formFields["path"]),
            ["/share/Photos"]
        )
        XCTAssertEqual(
            try decodeStringArray(rename.formFields["name"]),
            ["Pictures"]
        )
    }

    func testDeletePollsStatusReportsProgressAndFinishes() async throws {
        let fixture = SynologyAPIFixture()
        let statusCalls = LockedBox(0)
        let progress = LockedBox<[RemoteOperationProgress]>([])
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.Delete", "start"):
                return .json(#"{"success":true,"data":{"taskid":"delete-1"}}"#)
            case ("SYNO.FileStation.Delete", "status"):
                let call = statusCalls.withLock { value in
                    value += 1
                    return value
                }
                if call == 1 {
                    return .json(
                        #"{"success":true,"data":{"processed_num":1,"total":2,"path":"/share/old","processing_path":"/share/old/a","finished":false,"progress":0.5}}"#
                    )
                }
                return .json(
                    #"{"success":true,"data":{"processed_num":2,"total":2,"path":"/share/old","processing_path":"/share/old/b","finished":true,"progress":1}}"#
                )
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        let context = RemoteOperationContext { update in
            progress.withLock { $0.append(update) }
        }
        let result = try await service.delete(
            fixture.item(path: "/share/old", name: "old", kind: .folder),
            recursive: true,
            context: context
        )

        XCTAssertEqual(result.operation, .delete)
        XCTAssertEqual(result.succeeded.count, 1)
        XCTAssertEqual(statusCalls.values, 2)
        XCTAssertTrue(
            progress.values.contains {
                $0.phase == .deleting
                    && $0.completedUnitCount == 1
                    && $0.totalUnitCount == 2
            }
        )

        let start = try XCTUnwrap(
            fixture.requests.values.first {
                $0.formFields["api"] == "SYNO.FileStation.Delete"
                    && $0.formFields["method"] == "start"
            }
        )
        XCTAssertEqual(try decodeStringArray(start.formFields["path"]), ["/share/old"])
        XCTAssertEqual(start.formFields["recursive"], "true")
    }

    func testCancelledDeleteStopsServerTaskAndReturnsPartialResult() async throws {
        let fixture = SynologyAPIFixture(pollInterval: .milliseconds(1))
        let statusCalls = LockedBox(0)
        let didStop = LockedBox(false)
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.Delete", "start"):
                return .json(#"{"success":true,"data":{"taskid":"delete-cancel"}}"#)
            case ("SYNO.FileStation.Delete", "status"):
                statusCalls.withLock { $0 += 1 }
                return .json(
                    #"{"success":true,"data":{"processed_num":0,"total":10,"path":"/share/old","processing_path":"/share/old","finished":false,"progress":0}}"#
                )
            case ("SYNO.FileStation.Delete", "stop"):
                didStop.withLock { $0 = true }
                return .json(#"{"success":true}"#)
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        let operation = Task {
            try await service.delete(
                fixture.item(path: "/share/old", name: "old", kind: .folder),
                recursive: true,
                context: RemoteOperationContext()
            )
        }
        for _ in 0..<200 where statusCalls.values == 0 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertGreaterThan(statusCalls.values, 0)
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("Cancellation should throw a partial-result error")
        } catch let error as RemoteOperationInterruptedError {
            XCTAssertEqual(error.reason, .cancelled)
            XCTAssertTrue(error.partialResult.wasCancelled)
            XCTAssertEqual(error.partialResult.operation, .delete)
        }
        XCTAssertTrue(didStop.values)
    }

    func testCopyMoveVersionThreeUsesStartStatusAndConflictParameters() async throws {
        let fixture = SynologyAPIFixture()
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            case ("SYNO.FileStation.CopyMove", "start"):
                return .json(#"{"success":true,"data":{"taskid":"copy-move-1"}}"#)
            case ("SYNO.FileStation.CopyMove", "status"):
                return .json(
                    #"{"success":true,"data":{"processed_size":12,"total":12,"path":"/share/source.txt","dest_folder_path":"/share/destination","finished":true,"progress":1}}"#
                )
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        let source = fixture.item(
            path: "/share/source.txt",
            name: "source.txt",
            kind: .file,
            size: 12
        )
        let copy = try await service.copy(
            source,
            to: "/share/destination",
            conflictPolicy: .replace,
            strategy: .serverSideOnly,
            context: RemoteOperationContext()
        )
        let move = try await service.move(
            source,
            to: "/share/destination",
            conflictPolicy: .fail,
            strategy: .serverSideOnly,
            context: RemoteOperationContext()
        )

        XCTAssertEqual(copy.succeeded.first?.destinationPath, "/share/destination/source.txt")
        XCTAssertEqual(move.operation, .move)
        let starts = fixture.requests.values.filter {
            $0.formFields["api"] == "SYNO.FileStation.CopyMove"
                && $0.formFields["method"] == "start"
        }
        XCTAssertEqual(starts.count, 2)
        XCTAssertEqual(starts[0].formFields["version"], "3")
        XCTAssertEqual(try decodeStringArray(starts[0].formFields["path"]), [source.path])
        XCTAssertEqual(try decodeString(starts[0].formFields["dest_folder_path"]), "/share/destination")
        XCTAssertEqual(starts[0].formFields["overwrite"], "true")
        XCTAssertEqual(starts[0].formFields["remove_src"], "false")
        XCTAssertNil(starts[1].formFields["overwrite"])
        XCTAssertEqual(starts[1].formFields["remove_src"], "true")
    }

    func testUploadUsesDiskBackedMultipartWithFilePartLast() async throws {
        let fixture = SynologyAPIFixture()
        let multipartRequest = LockedBox<SynologyRecordedRequest?>(nil)
        let service = fixture.makeService { request in
            if request.contentType.hasPrefix("multipart/form-data") {
                multipartRequest.withLock { $0 = request }
                return .json(#"{"success":true}"#)
            }
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        let localURL = FileManager.default.temporaryDirectory
            .appending(path: "NasFinder-Synology-Upload-\(UUID().uuidString).txt")
        let payload = Data("binary upload payload".utf8)
        XCTAssertTrue(FileManager.default.createFile(atPath: localURL.path, contents: payload))
        defer { try? FileManager.default.removeItem(at: localURL) }

        let result = try await service.upload(
            localURL: localURL,
            to: "/share/uploads",
            preferredName: "테스트.txt",
            conflictPolicy: .fail,
            context: RemoteOperationContext()
        )

        XCTAssertEqual(result.succeeded.first?.destinationPath, "/share/uploads/테스트.txt")
        let request = try XCTUnwrap(multipartRequest.values)
        let contentLength = try XCTUnwrap(Int(request.headers["Content-Length"] ?? ""))
        XCTAssertEqual(contentLength, request.body.count)

        let bodyText = String(decoding: request.body, as: UTF8.self)
        XCTAssertTrue(bodyText.contains("name=\"api\"\r\n\r\nSYNO.FileStation.Upload"))
        XCTAssertTrue(bodyText.contains("name=\"path\"\r\n\r\n/share/uploads"))
        XCTAssertTrue(bodyText.contains("name=\"file\"; filename=\"테스트.txt\""))
        let payloadRange = try XCTUnwrap(request.body.range(of: payload))
        let closingBoundary = Data("\r\n--".utf8)
        let boundaryRange = try XCTUnwrap(
            request.body.range(of: closingBoundary, options: .backwards)
        )
        XCTAssertLessThan(payloadRange.lowerBound, boundaryRange.lowerBound)
        XCTAssertEqual(request.body[payloadRange], payload[...])
    }

    func testDetailedSynologyConflictBecomesTypedOperationError() async throws {
        let fixture = SynologyAPIFixture()
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            case ("SYNO.FileStation.CreateFolder", "create"):
                return .json(
                    #"{"success":false,"error":{"code":1100,"errors":[{"code":414,"path":"/share/Photos"}]}}"#
                )
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        do {
            _ = try await service.createFolder(
                named: "Photos",
                in: "/share",
                context: RemoteOperationContext()
            )
            XCTFail("The detailed API conflict should throw")
        } catch let error as RemoteFileOperationError {
            guard case .conflict(let source, let destination) = error else {
                return XCTFail("Unexpected typed error: \(error)")
            }
            XCTAssertEqual(source, "/share/Photos")
            XCTAssertEqual(destination, "/share/Photos")
        }
    }

    func testConnectionVerifiesWebAPIAuthenticationAndRootPathInOrder() async throws {
        let fixture = SynologyAPIFixture()
        let service = fixture.makeService { request in
            let fields = request.formFields
            switch (fields["api"], fields["method"]) {
            case ("SYNO.API.Info", "query"):
                return .json(
                    #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi","minVersion":1,"maxVersion":7},"SYNO.FileStation.List":{"path":"entry.cgi","minVersion":1,"maxVersion":2}}}"#
                )
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":true,"data":{"sid":"test-sid"}}"#)
            case ("SYNO.FileStation.List", "list"):
                return .json(#"{"success":true,"data":{"files":[]}}"#)
            default:
                throw SynologyMockError.unexpectedRequest(fields)
            }
        }
        defer { fixture.unregister() }

        try await service.testConnection()

        let requests = fixture.requests.values
        XCTAssertEqual(requests.map { $0.formFields["api"] }, [
            "SYNO.API.Info",
            "SYNO.API.Auth",
            "SYNO.FileStation.List"
        ])
        XCTAssertEqual(requests.first?.url.path, "/webapi/query.cgi")
        XCTAssertEqual(requests.first?.timeoutInterval, 15)
    }

    func testConnectionReportsAuthenticationAsTheVerifiedFailureStage() async throws {
        let fixture = SynologyAPIFixture()
        let service = fixture.makeService { request in
            switch (request.formFields["api"], request.formFields["method"]) {
            case ("SYNO.API.Info", "query"):
                return .json(
                    #"{"success":true,"data":{"SYNO.API.Auth":{"path":"auth.cgi"},"SYNO.FileStation.List":{"path":"entry.cgi"}}}"#
                )
            case ("SYNO.API.Auth", "login"):
                return .json(#"{"success":false,"error":{"code":400}}"#)
            default:
                throw SynologyMockError.unexpectedRequest(request.formFields)
            }
        }
        defer { fixture.unregister() }

        do {
            try await service.testConnection()
            XCTFail("Invalid DSM credentials should fail the connection test")
        } catch let failure as SynologyConnectionTestFailure {
            XCTAssertEqual(failure.stage, .authentication)
            XCTAssertTrue(failure.underlying is SynologyAuthenticationError)
        }
    }

    private func decodeStringArray(_ value: String?) throws -> [String] {
        let value = try XCTUnwrap(value)
        return try JSONDecoder().decode([String].self, from: Data(value.utf8))
    }

    private func decodeString(_ value: String?) throws -> String {
        let value = try XCTUnwrap(value)
        return try JSONDecoder().decode(String.self, from: Data(value.utf8))
    }
}

private final class SynologyAPIFixture: @unchecked Sendable {
    let requests = LockedBox<[SynologyRecordedRequest]>([])
    private let host = "\(UUID().uuidString.lowercased()).nasfinder.invalid"
    private let pollInterval: Duration
    private let rootPath: String
    private let usesTLS: Bool
    private let port: Int
    private lazy var connection = RemoteConnection(
        name: "Mock NAS",
        kind: .synology,
        host: host,
        port: port,
        username: "tester",
        rootPath: rootPath,
        usesTLS: usesTLS
    )

    init(
        rootPath: String = "/share",
        usesTLS: Bool = true,
        port: Int? = nil,
        pollInterval: Duration = .zero
    ) {
        self.rootPath = rootPath
        self.usesTLS = usesTLS
        self.port = port ?? (usesTLS ? 5001 : 5000)
        self.pollInterval = pollInterval
    }

    func makeService(
        handler: @escaping @Sendable (SynologyRecordedRequest) throws -> SynologyStubResponse
    ) -> SynologyFileService {
        SynologyMockURLProtocol.register(host: host) { [requests] request in
            let recorded = SynologyRecordedRequest(request)
            requests.withLock { $0.append(recorded) }
            return try handler(recorded)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SynologyMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return SynologyFileService(
            connection: connection,
            credential: RemoteCredential(password: "secret"),
            session: session,
            pollInterval: pollInterval
        )
    }

    func item(
        path: String,
        name: String,
        kind: RemoteFileItem.ItemKind,
        size: Int64? = nil
    ) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connection.id,
            path: path,
            name: name,
            kind: kind,
            size: size,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
    }

    func unregister() {
        SynologyMockURLProtocol.unregister(host: host)
    }
}

private struct SynologyRecordedRequest: Sendable {
    let url: URL
    let headers: [String: String]
    let body: Data
    let timeoutInterval: TimeInterval

    init(_ request: URLRequest) {
        url = request.url ?? URL(string: "about:blank")!
        headers = request.allHTTPHeaderFields ?? [:]
        body = Self.readBody(from: request)
        timeoutInterval = request.timeoutInterval
    }

    var contentType: String {
        headers["Content-Type"] ?? headers["content-type"] ?? ""
    }

    var formFields: [String: String] {
        guard contentType.hasPrefix("application/x-www-form-urlencoded") else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = String(data: body, encoding: .utf8)
        return Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map {
                ($0.name, $0.value ?? "")
            }
        )
    }

    private static func readBody(from request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(buffer, count: count)
        }
        return body
    }
}

private struct SynologyStubResponse: Sendable {
    let statusCode: Int
    let headers: [String: String]
    let data: Data

    static func json(_ value: String, statusCode: Int = 200) -> Self {
        Self(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json"],
            data: Data(value.utf8)
        )
    }
}

private enum SynologyMockError: Error {
    case missingHandler
    case invalidResponseURL
    case unexpectedRequest([String: String])
}

private final class SynologyMockURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> SynologyStubResponse

    private static let handlers = LockedBox<[String: Handler]>([:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { $0.removeValue(forKey: host) }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return handlers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let url = request.url,
                  let host = url.host,
                  let handler = Self.handlers.withLock({ $0[host] }) else {
                throw SynologyMockError.missingHandler
            }
            let stub = try handler(request)
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: stub.statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: stub.headers
            ) else {
                throw SynologyMockError.invalidResponseURL
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: stub.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var values: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    @discardableResult
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
