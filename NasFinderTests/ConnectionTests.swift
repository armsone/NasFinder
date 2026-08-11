import XCTest
import Citadel
@testable import NasFinder

final class ConnectionTests: XCTestCase {
    @MainActor
    func testPreferredConnectionCanBeClearedAndStaysCleared() throws {
        let suiteName = "ConnectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.example.com",
            username: "tester"
        )
        defaults.set(
            try JSONEncoder().encode([connection]),
            forKey: "connections.v1"
        )

        let store = ConnectionStore(
            defaults: defaults,
            performsFileProviderMaintenance: false
        )
        XCTAssertNil(store.preferredConnection)

        store.setPreferredConnection(connection)
        XCTAssertEqual(store.preferredConnection?.id, connection.id)
        store.clearPreferredConnection()
        XCTAssertNil(store.preferredConnection)

        let reloadedStore = ConnectionStore(
            defaults: defaults,
            performsFileProviderMaintenance: false
        )
        XCTAssertNil(reloadedStore.preferredConnection)
    }

    func testSynologyRootPathIsNormalized() {
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.example.com",
            username: "tester",
            rootPath: "photo"
        )

        XCTAssertEqual(connection.normalizedRootPath, "/photo")
        XCTAssertEqual(connection.endpointDescription, "https://nas.example.com:5001")
    }

    func testSFTPKeepsDotAsRoot() {
        let connection = RemoteConnection(
            name: "Server",
            kind: .sftp,
            host: "files.example.com",
            username: "tester"
        )

        XCTAssertEqual(connection.normalizedRootPath, ".")
        XCTAssertEqual(connection.port, 22)
    }

    func testSFTPRootPathTrimsWhitespace() {
        let connection = RemoteConnection(
            name: "Server",
            kind: .sftp,
            host: "files.example.com",
            username: "tester",
            rootPath: "  /media/videos  "
        )

        XCTAssertEqual(connection.normalizedRootPath, "/media/videos")
    }

    func testCommonPhotoAndVideoExtensionsAreRecognizedForThumbnails() {
        let connectionID = UUID()
        let photo = RemoteFileItem(
            connectionID: connectionID,
            path: "/photo/FAMILY.HEIC",
            name: "FAMILY.HEIC",
            kind: .file,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let video = RemoteFileItem(
            connectionID: connectionID,
            path: "/video/archive.MKV",
            name: "archive.MKV",
            kind: .file,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )
        let legacyVideo = RemoteFileItem(
            connectionID: connectionID,
            path: "/video/archive.ASF",
            name: "archive.ASF",
            kind: .file,
            size: nil,
            modifiedAt: nil,
            contentTypeIdentifier: nil
        )

        XCTAssertTrue(photo.isImage)
        XCTAssertTrue(video.isVideo)
        XCTAssertTrue(legacyVideo.isVideo)
    }

    func testQuickLookThumbnailCandidatesIncludeDocumentsAndAudio() {
        let connectionID = UUID()
        let filenames = [
            "report.DOCX",
            "budget.xlsx",
            "slides.pptx",
            "notes.md",
            "book.epub",
            "recording.m4a"
        ]

        for filename in filenames {
            let item = RemoteFileItem(
                connectionID: connectionID,
                path: "/files/\(filename)",
                name: filename,
                kind: .file,
                size: nil,
                modifiedAt: nil,
                contentTypeIdentifier: nil
            )
            XCTAssertTrue(item.supportsQuickLookThumbnail, filename)
        }
    }

    func testSFTPAddressAcceptsPastedURLAndExtractsPort() throws {
        let parsed = try ServerAddressParser.parse(
            "  sftp://files.example.com:2222/  ",
            kind: .sftp
        )

        XCTAssertEqual(parsed.host, "files.example.com")
        XCTAssertEqual(parsed.explicitPort, 2222)
        XCTAssertNil(parsed.inferredTLS)
    }

    func testSFTPAddressAcceptsHostAndPortWithoutScheme() throws {
        let parsed = try ServerAddressParser.parse("files.example.com:2022", kind: .sftp)

        XCTAssertEqual(parsed.host, "files.example.com")
        XCTAssertEqual(parsed.explicitPort, 2022)
    }

    func testSFTPAddressNormalizesBracketedIPv6() throws {
        let parsed = try ServerAddressParser.parse("[2001:db8::1]:2222", kind: .sftp)

        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertEqual(parsed.explicitPort, 2222)
    }

    func testSFTPAddressKeepsUnbracketedIPv6Literal() throws {
        let parsed = try ServerAddressParser.parse("2001:db8::1", kind: .sftp)

        XCTAssertEqual(parsed.host, "2001:db8::1")
        XCTAssertNil(parsed.explicitPort)
    }

    func testSynologyAddressInfersTLSFromScheme() throws {
        let http = try ServerAddressParser.parse("http://nas.local:5000", kind: .synology)
        let https = try ServerAddressParser.parse("https://nas.local:5001", kind: .synology)

        XCTAssertEqual(http.inferredTLS, false)
        XCTAssertEqual(https.inferredTLS, true)
    }

    func testSynologySchemeWithoutPortUsesMatchingDSMDefault() throws {
        let http = try ServerAddressParser.parse("http://nas.local", kind: .synology)
        let https = try ServerAddressParser.parse("https://nas.local/", kind: .synology)

        XCTAssertEqual(http.inferredTLS, false)
        XCTAssertNil(http.explicitPort)
        XCTAssertEqual(
            ConnectionKind.synologyPort(usesTLS: try XCTUnwrap(http.inferredTLS)),
            5000
        )
        XCTAssertEqual(https.inferredTLS, true)
        XCTAssertNil(https.explicitPort)
        XCTAssertEqual(
            ConnectionKind.synologyPort(usesTLS: try XCTUnwrap(https.inferredTLS)),
            5001
        )
    }

    func testSynologyAddressResynchronizesAfterConnectionKindChange() throws {
        // This models returning from SFTP to Synology while the host field
        // already contains an HTTP URL. The host value itself does not change,
        // so the kind-change handler must synchronize it explicitly.
        let parsed = try ServerAddressParser.parse("http://nas.local", kind: .synology)
        let settings = parsed.synchronizedSynologySettings(
            currentPort: 5001,
            currentUsesTLS: true
        )

        XCTAssertEqual(settings, SynologyAddressSettings(port: 5000, usesTLS: false))
    }

    func testSynologyTLSToggleSwitchesOnlyStandardImplicitPorts() {
        XCTAssertEqual(
            ConnectionKind.synologyPortAfterTLSToggle(
                currentPort: 5001,
                from: true,
                to: false,
                hasExplicitPort: false
            ),
            5000
        )
        XCTAssertEqual(
            ConnectionKind.synologyPortAfterTLSToggle(
                currentPort: 5000,
                from: false,
                to: true,
                hasExplicitPort: false
            ),
            5001
        )
        XCTAssertEqual(
            ConnectionKind.synologyPortAfterTLSToggle(
                currentPort: 8443,
                from: true,
                to: false,
                hasExplicitPort: false
            ),
            8443,
            "A manually entered custom port must be preserved"
        )
        XCTAssertEqual(
            ConnectionKind.synologyPortAfterTLSToggle(
                currentPort: 5001,
                from: true,
                to: false,
                hasExplicitPort: true
            ),
            5001,
            "A port embedded in the address must be preserved"
        )
    }

    func testAddressRejectsEmbeddedCredentialsAndPath() {
        XCTAssertThrowsError(
            try ServerAddressParser.parse("sftp://user:secret@nas.local:22", kind: .sftp)
        ) { error in
            XCTAssertEqual(error as? ServerAddressError, .credentialsNotAllowed)
        }
        XCTAssertThrowsError(
            try ServerAddressParser.parse("sftp://nas.local/home/user", kind: .sftp)
        ) { error in
            XCTAssertEqual(error as? ServerAddressError, .pathNotAllowed)
        }
    }

    func testAddressRejectsWrongSchemeAndInvalidPort() {
        XCTAssertThrowsError(
            try ServerAddressParser.parse("https://nas.local", kind: .sftp)
        ) { error in
            XCTAssertEqual(error as? ServerAddressError, .unsupportedScheme("https"))
        }
        XCTAssertThrowsError(
            try ServerAddressParser.parse("sftp://nas.local:65536", kind: .sftp)
        ) { error in
            XCTAssertEqual(error as? ServerAddressError, .invalidPort)
        }
    }

    func testSFTPDiagnosticsIdentifyAddressAndTransportStages() {
        let dnsError = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCannotFindHost
        )
        let connectionError = NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(ECONNREFUSED)
        )

        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(for: dnsError, rootPath: ".").stage,
            .addressResolution
        )
        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(for: connectionError, rootPath: ".").stage,
            .transport
        )
    }

    func testSFTPDiagnosticsIdentifyAuthenticationAndSubsystemStages() {
        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(
                for: SSHClientError.allAuthenticationOptionsFailed,
                rootPath: "."
            ).stage,
            .authentication
        )
        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(
                for: SFTPError.missingResponse,
                rootPath: "."
            ).stage,
            .subsystem
        )
    }

    func testSFTPDiagnosticsIdentifyTimeoutAndNegotiationStages() {
        struct TimeoutError: Error, CustomStringConvertible {
            let description = "connectTimeout(30 seconds)"
        }
        struct NegotiationError: Error, CustomStringConvertible {
            let description = "no common algorithm for key exchange"
        }

        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(
                for: TimeoutError(),
                rootPath: "."
            ).stage,
            .transport
        )
        XCTAssertEqual(
            SFTPConnectionDiagnostics.diagnostic(
                for: NegotiationError(),
                rootPath: "."
            ).stage,
            .negotiation
        )
    }

    func testSFTPDiagnosticReferenceDoesNotExposeErrorDescription() {
        struct SensitiveTestError: LocalizedError {
            var errorDescription: String? {
                "password=do-not-log path=/private/family"
            }
        }

        let diagnostic = SFTPConnectionDiagnostics.diagnostic(
            for: SensitiveTestError(),
            rootPath: "/private/family"
        )

        XCTAssertFalse(diagnostic.reference.contains("do-not-log"))
        XCTAssertFalse(diagnostic.reference.contains("/private/family"))
        XCTAssertFalse(diagnostic.userMessage.contains("do-not-log"))
        XCTAssertFalse(diagnostic.userMessage.contains("/private/family"))
    }

    func testSynologyDiagnosticsIdentifyTimeoutAndTLSStages() {
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.local",
            port: 5001,
            username: "tester",
            usesTLS: true
        )
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let certificate = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorServerCertificateUntrusted
        )

        let timeoutDiagnostic = SynologyConnectionDiagnostics.diagnostic(
            for: SynologyConnectionTestFailure(stage: .webAPI, underlying: timeout),
            connection: connection
        )
        XCTAssertEqual(timeoutDiagnostic.stage, .transport)
        XCTAssertTrue(timeoutDiagnostic.message.contains("5001"))
        XCTAssertTrue(timeoutDiagnostic.message.contains("SFTP"))

        XCTAssertEqual(
            SynologyConnectionDiagnostics.diagnostic(
                for: certificate,
                connection: connection
            ).stage,
            .tls
        )
    }

    func testURLSessionCancellationIsNormalizedAcrossSynologyDiagnostics() {
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.local",
            username: "tester"
        )
        let cancelled = NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorCancelled
        )
        let wrapped = SynologyConnectionTestFailure(
            stage: .rootPath,
            underlying: cancelled
        )

        XCTAssertTrue(RemoteRequestCancellation.isCancellation(cancelled))
        XCTAssertTrue(RemoteRequestCancellation.normalized(cancelled) is CancellationError)
        XCTAssertEqual(
            SynologyConnectionDiagnostics.diagnostic(
                for: wrapped,
                connection: connection
            ).stage,
            .cancelled
        )
    }

    @MainActor
    func testFileBrowserDoesNotPresentAnErrorForCancelledListing() async {
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.local",
            username: "tester"
        )
        let viewModel = FileBrowserViewModel(
            connection: connection,
            path: "/home",
            service: CancelledListService(connection: connection)
        )

        await viewModel.load()

        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testSynologyDiagnosticsPreserveVerifiedTestStage() {
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.local",
            username: "tester"
        )

        for stage in [
            SynologyDiagnosticStage.webAPI,
            .authentication,
            .rootPath
        ] {
            let diagnostic = SynologyConnectionDiagnostics.diagnostic(
                for: SynologyConnectionTestFailure(
                    stage: stage,
                    underlying: SynologyConnectionProbeError.invalidWebAPIResponse
                ),
                connection: connection
            )
            XCTAssertEqual(diagnostic.stage, stage)
        }
    }

    func testSynologyDiagnosticDoesNotExposeArbitraryErrorDescription() {
        struct SensitiveTestError: LocalizedError {
            var errorDescription: String? {
                "password=do-not-log path=/private/family"
            }
        }
        let connection = RemoteConnection(
            name: "NAS",
            kind: .synology,
            host: "nas.local",
            username: "tester"
        )
        let diagnostic = SynologyConnectionDiagnostics.diagnostic(
            for: SynologyConnectionTestFailure(
                stage: .authentication,
                underlying: SensitiveTestError()
            ),
            connection: connection
        )

        XCTAssertFalse(diagnostic.reference.contains("do-not-log"))
        XCTAssertFalse(diagnostic.reference.contains("/private/family"))
        XCTAssertFalse(diagnostic.userMessage.contains("do-not-log"))
        XCTAssertFalse(diagnostic.userMessage.contains("/private/family"))
    }
}

private struct CancelledListService: RemoteFileService {
    let connection: RemoteConnection

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        throw NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        throw CancellationError()
    }
}
