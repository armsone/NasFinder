import Foundation
import XCTest
@testable import NasFinder

@MainActor
final class MacDirectUpdateManagerTests: XCTestCase {
    private let release = DirectUpdateRelease(
        version: "2.1.3",
        build: "202608260900",
        releaseNotes: "더 안전한 Mac 업데이트",
        downloadURL: URL(string: "https://github.com/armsone/NasFinder/releases/download/mac-v2.1.3/NasFinder-Mac-2.1.3-202608260900.dmg")!,
        assetName: "NasFinder-Mac-2.1.3-202608260900.dmg",
        expectedSHA256: String(repeating: "a", count: 64),
        expectedByteCount: 1_024
    )

    func testNoUpdateWithAutomaticDownloadOnAndOffNeverDownloads() async {
        for automaticallyDownloads in [false, true] {
            let transfer = TransferStub { _, _, _, _ in URL(filePath: "/tmp/unexpected") }
            let manager = makeManager(provider: ProviderStub([nil]), transfer: transfer)
            manager.automaticallyDownloadsUpdates = automaticallyDownloads

            manager.checkForUpdates(manual: false)
            await waitUntil { manager.state == .latest }

            XCTAssertEqual(transfer.downloadCount, 0)
        }
    }

    func testAvailableUpdateShowsValidatedVersionBuildAndManualChoice() async {
        let transfer = TransferStub { _, _, _, _ in URL(filePath: "/tmp/unexpected") }
        let manager = makeManager(provider: ProviderStub([release]), transfer: transfer)

        manager.checkForUpdates()
        await waitUntil { manager.state == .available(self.release) }

        XCTAssertEqual(transfer.downloadCount, 0)
    }

    func testAutomaticDownloadHonorsUserToggle() async {
        for automaticallyDownloads in [false, true] {
            let transfer = TransferStub { [release] _, _, _, _ in
                URL(filePath: "/tmp/\(release.assetName)")
            }
            let manager = makeManager(provider: ProviderStub([release]), transfer: transfer)
            manager.automaticallyDownloadsUpdates = automaticallyDownloads

            manager.checkAtStartupIfNeeded()
            if automaticallyDownloads {
                await waitUntil { if case .installReady = manager.state { true } else { false } }
                XCTAssertEqual(transfer.downloadCount, 1)
            } else {
                await waitUntil { manager.state == .available(self.release) }
                XCTAssertEqual(transfer.downloadCount, 0)
            }
        }
    }

    func testDownloadingReportsProgressAndSupportsPauseResume() async {
        let transfer = TransferStub { _, _, _, progress in
            progress(0.42)
            try await Task.sleep(for: .seconds(60))
            return URL(filePath: "/tmp/unreachable")
        }
        let manager = makeManager(provider: ProviderStub([release]), transfer: transfer)
        manager.checkForUpdates()
        await waitUntil { manager.state == .available(self.release) }

        manager.downloadAvailableUpdate()
        await waitUntil {
            manager.state == .downloading(self.release, progress: 0.42, isPaused: false)
        }
        manager.pauseDownload()
        XCTAssertEqual(manager.state, .downloading(release, progress: 0.42, isPaused: true))
        manager.resumeDownload()
        XCTAssertEqual(manager.state, .downloading(release, progress: 0.42, isPaused: false))
        XCTAssertEqual(transfer.pauseCount, 1)
        XCTAssertEqual(transfer.resumeCount, 1)
        manager.cancelDownload()
    }

    func testCancellationStopsTransferAndReturnsToAvailable() async {
        let transfer = TransferStub { _, _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return URL(filePath: "/tmp/unreachable")
        }
        let manager = makeManager(provider: ProviderStub([release]), transfer: transfer)
        manager.checkForUpdates()
        await waitUntil { manager.state == .available(self.release) }
        manager.downloadAvailableUpdate()
        await waitUntil { transfer.downloadCount == 1 }

        manager.cancelDownload()

        XCTAssertEqual(manager.state, .available(release))
        XCTAssertEqual(transfer.cancelCount, 1)
    }

    func testFailureCanRetrySuccessfully() async {
        let transfer = TransferStub { [release] invocation, _, _, _ in
            if invocation == 1 {
                throw URLError(.networkConnectionLost)
            }
            return URL(filePath: "/tmp/\(release.assetName)")
        }
        let manager = makeManager(provider: ProviderStub([release]), transfer: transfer)
        manager.checkForUpdates()
        await waitUntil { manager.state == .available(self.release) }
        manager.downloadAvailableUpdate()
        await waitUntil { if case .error = manager.state { true } else { false } }

        manager.retry()
        await waitUntil { if case .installReady = manager.state { true } else { false } }

        XCTAssertEqual(transfer.downloadCount, 2)
    }

    func testIntegrityOrSignatureFailureIsRefusedBeforeHandoff() async {
        for failure in [DirectUpdateError.integrityMismatch, .invalidDeveloperSignature] {
            let handoff = HandoffStub(result: true)
            let verifier = VerifierStub { _, _ in throw failure }
            let manager = makeManager(
                provider: ProviderStub([release]),
                transfer: TransferStub { [release] _, _, _, _ in URL(filePath: "/tmp/\(release.assetName)") },
                verifier: verifier,
                handoff: handoff
            )
            manager.checkForUpdates()
            await waitUntil { manager.state == .available(self.release) }
            manager.downloadAvailableUpdate()
            await waitUntil { if case .error = manager.state { true } else { false } }

            manager.handoffInstaller()
            XCTAssertEqual(handoff.openCount, 0)
        }
    }

    func testRealVerifierDeletesIntegrityAndSignatureFailures() async throws {
        let verifier = MacDirectUpdateArtifactVerifier()

        let integrityURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".dmg")
        try Data("abc".utf8).write(to: integrityURL)
        var invalidIntegrity = release
        invalidIntegrity = DirectUpdateRelease(
            version: invalidIntegrity.version,
            build: invalidIntegrity.build,
            releaseNotes: invalidIntegrity.releaseNotes,
            downloadURL: invalidIntegrity.downloadURL,
            assetName: invalidIntegrity.assetName,
            expectedSHA256: String(repeating: "0", count: 64),
            expectedByteCount: 3
        )
        do {
            try await verifier.verify(fileURL: integrityURL, release: invalidIntegrity)
            XCTFail("잘못된 해시를 허용하면 안 됩니다.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: integrityURL.path))

        let signatureURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString + ".dmg")
        try Data("abc".utf8).write(to: signatureURL)
        let unsignedRelease = DirectUpdateRelease(
            version: release.version,
            build: release.build,
            releaseNotes: release.releaseNotes,
            downloadURL: release.downloadURL,
            assetName: release.assetName,
            expectedSHA256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
            expectedByteCount: 3
        )
        do {
            try await verifier.verify(fileURL: signatureURL, release: unsignedRelease)
            XCTFail("서명 없는 파일을 허용하면 안 됩니다.")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL.path))
    }

    func testVerifiedArtifactOnlyReachesUserControlledSystemHandoff() async {
        let verifier = VerifierStub { _, _ in }
        let handoff = HandoffStub(result: true)
        let manager = makeManager(
            provider: ProviderStub([release]),
            transfer: TransferStub { [release] _, _, _, progress in
                progress(1)
                return URL(filePath: "/tmp/\(release.assetName)")
            },
            verifier: verifier,
            handoff: handoff
        )
        manager.checkForUpdates()
        await waitUntil { manager.state == .available(self.release) }
        manager.downloadAvailableUpdate()
        await waitUntil { if case .installReady = manager.state { true } else { false } }

        XCTAssertEqual(verifier.verifyCount, 1)
        XCTAssertEqual(handoff.openCount, 0)
        manager.handoffInstaller()
        await waitUntil { manager.didHandoffInstaller }

        XCTAssertEqual(handoff.openCount, 1)
        XCTAssertTrue(manager.didHandoffInstaller)
    }

    func testMetadataRequiresExactProductMacUniversalVersionBuildAssetAndHTTPSDigest() throws {
        let valid = githubReleaseJSON(
            productID: "com.armsone.nasfinder",
            targetOS: "macOS",
            architectures: "arm64,x86_64",
            assetName: release.assetName,
            assetURL: release.downloadURL.absoluteString,
            digest: "sha256:\(release.expectedSHA256)"
        )
        let parsed = try XCTUnwrap(
            GitHubDirectUpdateReleaseProvider.validatedLatestRelease(
                from: valid,
                currentVersion: "2.1.2",
                currentBuild: "202608251949"
            )
        )
        XCTAssertEqual(parsed.version, release.version)
        XCTAssertEqual(parsed.build, release.build)
        XCTAssertEqual(parsed.assetName, release.assetName)
        XCTAssertEqual(parsed.downloadURL, release.downloadURL)
        XCTAssertEqual(parsed.expectedSHA256, release.expectedSHA256)
        XCTAssertEqual(parsed.expectedByteCount, release.expectedByteCount)

        let invalidCases: [Data] = [
            githubReleaseJSON(productID: "com.example.other"),
            githubReleaseJSON(targetOS: "iOS"),
            githubReleaseJSON(architectures: "arm64"),
            githubReleaseJSON(assetName: "NasFinder-iOS-2.1.3.ipa"),
            githubReleaseJSON(assetURL: "http://example.com/NasFinder-Mac-2.1.3-202608260900.dmg"),
            githubReleaseJSON(digest: "sha256:bad"),
            githubReleaseJSON(tag: "mac-v2.1"),
            githubReleaseJSON(build: "not-a-build"),
        ]
        for data in invalidCases {
            XCTAssertThrowsError(
                try GitHubDirectUpdateReleaseProvider.validatedLatestRelease(
                    from: data,
                    currentVersion: "2.1.2",
                    currentBuild: "202608251949"
                )
            )
        }
    }

    private func makeManager(
        provider: ProviderStub,
        transfer: TransferStub,
        verifier: VerifierStub = VerifierStub { _, _ in },
        handoff: HandoffStub = HandoffStub(result: true)
    ) -> MacDirectUpdateManager {
        let suiteName = "MacDirectUpdateManagerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return MacDirectUpdateManager(
            releaseProvider: provider,
            transfer: transfer,
            verifier: verifier,
            handoff: handoff,
            currentVersion: "2.1.2",
            currentBuild: "202608251949",
            defaults: defaults,
            automaticDownloadPermitted: { true }
        )
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 1_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("예상 상태로 전환되지 않았습니다.")
    }

    private func githubReleaseJSON(
        tag: String = "mac-v2.1.3",
        productID: String = "com.armsone.nasfinder",
        targetOS: String = "macOS",
        architectures: String = "arm64,x86_64",
        build: String = "202608260900",
        assetName: String = "NasFinder-Mac-2.1.3-202608260900.dmg",
        assetURL: String = "https://github.com/armsone/NasFinder/releases/download/mac-v2.1.3/NasFinder-Mac-2.1.3-202608260900.dmg",
        digest: String = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    ) -> Data {
        let body = """
        Product-ID: \(productID)
        Target-OS: \(targetOS)
        Architectures: \(architectures)
        Build-Number: \(build)
        더 안전한 Mac 업데이트
        """
        return try! JSONSerialization.data(withJSONObject: [[
            "tag_name": tag,
            "body": body,
            "draft": false,
            "prerelease": false,
            "assets": [[
                "name": assetName,
                "browser_download_url": assetURL,
                "digest": digest,
                "size": 1_024,
            ]],
        ]])
    }
}

private actor ProviderStub: DirectUpdateReleaseProviding {
    private var results: [DirectUpdateRelease?]

    init(_ results: [DirectUpdateRelease?]) {
        self.results = results
    }

    func latestRelease(currentVersion: String, currentBuild: String) async throws -> DirectUpdateRelease? {
        guard !results.isEmpty else { return nil }
        return results.removeFirst()
    }
}

private final class TransferStub: DirectUpdateTransferring, @unchecked Sendable {
    typealias Handler = @Sendable (
        Int,
        DirectUpdateRelease,
        Bool,
        @escaping @Sendable (Double) -> Void
    ) async throws -> URL
    private let lock = NSLock()
    private let handler: Handler
    private var _downloadCount = 0
    private var _pauseCount = 0
    private var _resumeCount = 0
    private var _cancelCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var downloadCount: Int { lock.withLock { _downloadCount } }
    var pauseCount: Int { lock.withLock { _pauseCount } }
    var resumeCount: Int { lock.withLock { _resumeCount } }
    var cancelCount: Int { lock.withLock { _cancelCount } }

    func download(
        _ release: DirectUpdateRelease,
        permitsConstrainedNetworkAccess: Bool,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let invocation = lock.withLock {
            _downloadCount += 1
            return _downloadCount
        }
        return try await handler(invocation, release, permitsConstrainedNetworkAccess, progress)
    }

    func pause() { lock.withLock { _pauseCount += 1 } }
    func resume() { lock.withLock { _resumeCount += 1 } }
    func cancel() { lock.withLock { _cancelCount += 1 } }
}

private final class VerifierStub: DirectUpdateArtifactVerifying, @unchecked Sendable {
    typealias Handler = @Sendable (URL, DirectUpdateRelease) async throws -> Void
    private let lock = NSLock()
    private let handler: Handler
    private var _verifyCount = 0

    init(handler: @escaping Handler) { self.handler = handler }
    var verifyCount: Int { lock.withLock { _verifyCount } }

    func verify(fileURL: URL, release: DirectUpdateRelease) async throws {
        lock.withLock { _verifyCount += 1 }
        try await handler(fileURL, release)
    }
}

private final class HandoffStub: DirectUpdateInstallerHandingOff, @unchecked Sendable {
    private let result: Bool
    private(set) var openCount = 0

    init(result: Bool) { self.result = result }

    @MainActor
    func openInstaller(at fileURL: URL) async -> Bool {
        openCount += 1
        return result
    }
}
