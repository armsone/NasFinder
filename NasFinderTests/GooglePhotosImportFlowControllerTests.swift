import Foundation
import XCTest
@testable import NasFinder

private struct HarnessError: Error {}

/// 테스트 스텁·기록용 스레드 안전 컨테이너.
private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    var current: Value {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }

    func append<Element>(_ element: Element) where Value == [Element] {
        lock.withLock { value.append(element) }
    }

    func popFirst<Element>() -> Element? where Value == [Element] {
        lock.withLock { value.isEmpty ? nil : value.removeFirst() }
    }
}

/// OAuth·Keychain·네트워크·외부 URL 열기를 전혀 수행하지 않는 주입식 의존성 하네스.
@MainActor
private final class FlowHarness {
    let configuration: GooglePhotosOAuthConfiguration
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    let configurationMissing = LockedBox(false)
    let storedCredential = LockedBox<GooglePhotosCredential?>(nil)
    let savedCredentials = LockedBox<[GooglePhotosCredential]>([])
    let authorizeCallCount = LockedBox(0)
    let authorizeResult = LockedBox<Result<GooglePhotosCredential, Error>>(.failure(HarnessError()))
    let refreshCallCount = LockedBox(0)
    let refreshResult = LockedBox<Result<GooglePhotosCredential, Error>>(.failure(HarnessError()))
    let sessionToCreate = LockedBox<GooglePhotosPickingSession?>(nil)
    let createSessionTokens = LockedBox<[String]>([])
    let fetchResults = LockedBox<[GooglePhotosPickingSession]>([])
    let fetchCallCount = LockedBox(0)
    let deletedSessionIDs = LockedBox<[String]>([])
    let deleteSessionFails = LockedBox(false)
    let mediaItems = LockedBox<[GooglePhotosPickedMediaItem]>([])
    let openedURLs = LockedBox<[URL]>([])
    let openURLSucceeds = LockedBox(true)
    let openURLResults = LockedBox<[Bool]>([])
    let closePickerCallCount = LockedBox(0)
    let sleepIntervals = LockedBox<[TimeInterval]>([])
    let failingDownloadItemIDs = LockedBox<Set<String>>([])
    let importedFilenames = LockedBox<[String]>([])

    init() throws {
        configuration = try GooglePhotosOAuthConfiguration.make(
            clientID: "123456-test.apps.googleusercontent.com"
        )
    }

    func makeController() -> GooglePhotosImportFlowController {
        let configuration = self.configuration
        let now = self.now
        let configurationMissing = self.configurationMissing
        let storedCredential = self.storedCredential
        let savedCredentials = self.savedCredentials
        let authorizeCallCount = self.authorizeCallCount
        let authorizeResult = self.authorizeResult
        let refreshCallCount = self.refreshCallCount
        let refreshResult = self.refreshResult
        let sessionToCreate = self.sessionToCreate
        let createSessionTokens = self.createSessionTokens
        let fetchResults = self.fetchResults
        let fetchCallCount = self.fetchCallCount
        let deletedSessionIDs = self.deletedSessionIDs
        let deleteSessionFails = self.deleteSessionFails
        let mediaItems = self.mediaItems
        let openedURLs = self.openedURLs
        let openURLSucceeds = self.openURLSucceeds
        let openURLResults = self.openURLResults
        let closePickerCallCount = self.closePickerCallCount
        let sleepIntervals = self.sleepIntervals
        let failingDownloadItemIDs = self.failingDownloadItemIDs
        let importedFilenames = self.importedFilenames

        let dependencies = GooglePhotosImportFlowController.Dependencies(
            loadConfiguration: {
                if configurationMissing.current {
                    throw GooglePhotosOAuthError.configurationMissing
                }
                return configuration
            },
            loadCredential: { storedCredential.current },
            saveCredential: { credential in
                savedCredentials.append(credential)
                storedCredential.current = credential
            },
            authorize: { _ in
                authorizeCallCount.current += 1
                return try authorizeResult.current.get()
            },
            refresh: { _, _ in
                refreshCallCount.current += 1
                return try refreshResult.current.get()
            },
            createSession: { accessToken in
                createSessionTokens.append(accessToken)
                guard let session = sessionToCreate.current else { throw HarnessError() }
                return session
            },
            fetchSession: { _, sessionID in
                fetchCallCount.current += 1
                if let next: GooglePhotosPickingSession = fetchResults.popFirst() {
                    return next
                }
                return GooglePhotosPickingSession(
                    id: sessionID,
                    pickerURI: nil,
                    pollingConfig: nil,
                    expireTime: nil,
                    pickingConfig: nil,
                    mediaItemsSet: false
                )
            },
            deleteSession: { _, sessionID in
                deletedSessionIDs.append(sessionID)
                if deleteSessionFails.current { throw HarnessError() }
            },
            listMediaItems: { _, _ in mediaItems.current },
            downloadItem: { _, item in
                if failingDownloadItemIDs.current.contains(item.id) { throw HarnessError() }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                try Data("bytes-\(item.id)".utf8).write(to: url)
                return url
            },
            importFile: { _, filename, _ in
                importedFilenames.append(filename)
            },
            openURL: { url in
                openedURLs.append(url)
                return openURLResults.popFirst() ?? openURLSucceeds.current
            },
            closePicker: {
                closePickerCallCount.current += 1
            },
            sleep: { interval in
                sleepIntervals.append(interval)
                await Task.yield()
            },
            now: { now }
        )
        return GooglePhotosImportFlowController(dependencies: dependencies)
    }
}

@MainActor
final class GooglePhotosImportFlowControllerTests: XCTestCase {
    private let pickerURI = "https://photos.google.com/picker/test-flow"

    private func makeCredential(
        accessToken: String,
        refreshToken: String? = "refresh",
        expiresAt: Date?
    ) -> GooglePhotosCredential {
        GooglePhotosCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            expirationDate: expiresAt,
            grantedScopes: [GooglePhotosOAuthConfiguration.pickerScope]
        )
    }

    private func makeSession(
        id: String = "session-1",
        pickerURI: String? = "https://photos.google.com/picker/test-flow",
        mediaItemsSet: Bool = false,
        pollInterval: TimeInterval? = 2.5,
        timeoutIn: TimeInterval? = nil
    ) -> GooglePhotosPickingSession {
        GooglePhotosPickingSession(
            id: id,
            pickerURI: pickerURI,
            pollingConfig: GooglePhotosPollingConfig(pollInterval: pollInterval, timeoutIn: timeoutIn),
            expireTime: nil,
            pickingConfig: nil,
            mediaItemsSet: mediaItemsSet
        )
    }

    private func makePhotoItem(id: String, filename: String) -> GooglePhotosPickedMediaItem {
        GooglePhotosPickedMediaItem(
            id: id,
            createTime: nil,
            type: .photo,
            mediaFile: GooglePhotosMediaFile(
                baseURL: "https://lh3.googleusercontent.com/p/\(id)",
                mimeType: "image/jpeg",
                filename: filename,
                metadata: nil
            )
        )
    }

    private func waitUntil(
        _ condition: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        var iterations = 0
        while !condition() {
            iterations += 1
            if iterations > 200_000 {
                XCTFail("조건이 제한 시간 안에 충족되지 않았습니다.", file: file, line: line)
                throw HarnessError()
            }
            await Task.yield()
        }
    }

    // MARK: - Disclosure gating

    func testConfirmWithoutDisclosureDoesNothing() throws {
        let harness = try FlowHarness()
        let controller = harness.makeController()

        controller.confirmDisclosure()

        XCTAssertEqual(controller.phase, .idle)
        XCTAssertNil(controller.activeFlowTask)
        XCTAssertEqual(harness.authorizeCallCount.current, 0)
        XCTAssertTrue(harness.createSessionTokens.current.isEmpty)
    }

    func testDeclineDisclosureReturnsToIdleWithoutSideEffects() throws {
        let harness = try FlowHarness()
        let controller = harness.makeController()

        controller.presentDisclosure()
        XCTAssertEqual(controller.phase, .disclosure)

        controller.declineDisclosure()
        XCTAssertEqual(controller.phase, .idle)
        XCTAssertEqual(harness.authorizeCallCount.current, 0)
        XCTAssertTrue(harness.savedCredentials.current.isEmpty)
        XCTAssertTrue(harness.createSessionTokens.current.isEmpty)
    }

    // MARK: - Configuration

    func testMissingConfigurationFailsSafelyWithoutAuthorization() async throws {
        let harness = try FlowHarness()
        harness.configurationMissing.current = true
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(
            controller.phase,
            .failed(message: GooglePhotosOAuthError.configurationMissing.localizedDescription)
        )
        XCTAssertEqual(harness.authorizeCallCount.current, 0)
        XCTAssertTrue(harness.createSessionTokens.current.isEmpty)
        XCTAssertTrue(harness.deletedSessionIDs.current.isEmpty)
    }

    // MARK: - Credential resolution

    func testStoredValidCredentialIsUsedWithoutAuthorization() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "stored-token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
        XCTAssertEqual(harness.authorizeCallCount.current, 0)
        XCTAssertEqual(harness.refreshCallCount.current, 0)
        XCTAssertEqual(harness.createSessionTokens.current, ["stored-token"])
        XCTAssertTrue(harness.savedCredentials.current.isEmpty)
    }

    func testExpiredCredentialIsRefreshedAndSaved() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "expired-token",
            expiresAt: harness.now.addingTimeInterval(-10)
        )
        let refreshed = makeCredential(
            accessToken: "refreshed-token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.refreshResult.current = .success(refreshed)
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
        XCTAssertEqual(harness.refreshCallCount.current, 1)
        XCTAssertEqual(harness.authorizeCallCount.current, 0)
        XCTAssertEqual(harness.savedCredentials.current, [refreshed])
        XCTAssertEqual(harness.createSessionTokens.current, ["refreshed-token"])
    }

    func testInvalidGrantOnRefreshTriggersReauthorization() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "expired-token",
            expiresAt: harness.now.addingTimeInterval(-10)
        )
        harness.refreshResult.current = .failure(GooglePhotosOAuthError.reauthorizationRequired)
        let reauthorized = makeCredential(
            accessToken: "new-token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.authorizeResult.current = .success(reauthorized)
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
        XCTAssertEqual(harness.refreshCallCount.current, 1)
        XCTAssertEqual(harness.authorizeCallCount.current, 1)
        XCTAssertEqual(harness.savedCredentials.current, [reauthorized])
        XCTAssertEqual(harness.createSessionTokens.current, ["new-token"])
    }

    func testMissingCredentialTriggersAuthorizationAndSave() async throws {
        let harness = try FlowHarness()
        let authorized = makeCredential(
            accessToken: "fresh-token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.authorizeResult.current = .success(authorized)
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
        XCTAssertEqual(harness.authorizeCallCount.current, 1)
        XCTAssertEqual(harness.savedCredentials.current, [authorized])
        XCTAssertEqual(harness.createSessionTokens.current, ["fresh-token"])
    }

    // MARK: - Happy path with polling

    func testHappyPathPollsWithServerIntervalAndImportsSequentially() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(pollInterval: 2.5)
        harness.fetchResults.current = [
            makeSession(mediaItemsSet: false, pollInterval: 2.5),
            makeSession(mediaItemsSet: true),
        ]
        harness.mediaItems.current = [
            makePhotoItem(id: "p1", filename: "a.jpg"),
            makePhotoItem(id: "p2", filename: "b.jpg"),
        ]
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 2, skipped: 0, failed: 0))
        XCTAssertEqual(harness.openedURLs.current, [URL(string: pickerURI)!])
        XCTAssertEqual(harness.fetchCallCount.current, 2)
        XCTAssertTrue(harness.sleepIntervals.current.contains(2.5))
        XCTAssertEqual(harness.importedFilenames.current, ["a.jpg", "b.jpg"])
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
    }

    // MARK: - Polling pause while inactive

    func testDoesNotPollWhileSceneInactive() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession()
        let controller = harness.makeController()

        controller.setScenePollingAllowed(false)
        controller.presentDisclosure()
        controller.confirmDisclosure()
        let flowTask = controller.activeFlowTask

        try await waitUntil { harness.sleepIntervals.current.count >= 5 }
        XCTAssertEqual(harness.fetchCallCount.current, 0)

        harness.fetchResults.current = [makeSession(mediaItemsSet: true)]
        controller.setScenePollingAllowed(true)
        await flowTask?.value

        XCTAssertGreaterThanOrEqual(harness.fetchCallCount.current, 1)
        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
    }

    // MARK: - Timeout

    func testSelectionTimeoutFailsAndDeletesSessionWithoutFetching() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(timeoutIn: 0)
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(
            controller.phase,
            .failed(message: GooglePhotosImportFlowError.selectionTimedOut.localizedDescription)
        )
        XCTAssertEqual(harness.fetchCallCount.current, 0)
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
    }

    // MARK: - Picker open failure

    func testOpenURLRetriesAfterTransientFailure() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        harness.openURLResults.current = [false, true]
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 0, skipped: 0, failed: 0))
        XCTAssertEqual(harness.openedURLs.current.count, 2)
        XCTAssertTrue(harness.sleepIntervals.current.contains(0.5))
        XCTAssertEqual(harness.closePickerCallCount.current, 1)
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
    }

    func testOpenURLFailureFailsSafelyAndDeletesSession() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "secret-token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession()
        harness.openURLSucceeds.current = false
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        guard case let .failed(message) = controller.phase else {
            XCTFail("실패 단계여야 합니다: \(controller.phase)")
            return
        }
        XCTAssertEqual(message, GooglePhotosImportFlowError.pickerOpenFailed.localizedDescription)
        // 민감한 값(토큰·세션 ID·URL)이 메시지에 노출되지 않아야 한다.
        XCTAssertFalse(message.contains("secret-token"))
        XCTAssertFalse(message.contains("session-1"))
        XCTAssertFalse(message.contains("https"))
        XCTAssertEqual(harness.openedURLs.current.count, 3)
        XCTAssertEqual(harness.closePickerCallCount.current, 1)
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
    }

    // MARK: - Cancellation

    func testCancelWhileWaitingDeletesSessionAndReportsCancelled() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession()
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        let flowTask = controller.activeFlowTask

        try await waitUntil { harness.fetchCallCount.current >= 2 }
        controller.cancel()
        await flowTask?.value

        XCTAssertEqual(controller.phase, .cancelled(imported: 0))
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
        XCTAssertTrue(harness.importedFilenames.current.isEmpty)
    }

    // MARK: - Partial failure and deletion failure

    func testDownloadFailureIsCountedWithoutStoppingOtherItems() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        harness.mediaItems.current = [
            makePhotoItem(id: "fails", filename: "fail.jpg"),
            makePhotoItem(id: "ok", filename: "ok.jpg"),
        ]
        harness.failingDownloadItemIDs.current = ["fails"]
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 1, skipped: 0, failed: 1))
        XCTAssertEqual(harness.importedFilenames.current, ["ok.jpg"])
    }

    func testSessionDeletionFailureDoesNotAffectImportedFiles() async throws {
        let harness = try FlowHarness()
        harness.storedCredential.current = makeCredential(
            accessToken: "token",
            expiresAt: harness.now.addingTimeInterval(3600)
        )
        harness.sessionToCreate.current = makeSession(mediaItemsSet: true)
        harness.mediaItems.current = [makePhotoItem(id: "p1", filename: "a.jpg")]
        harness.deleteSessionFails.current = true
        let controller = harness.makeController()

        controller.presentDisclosure()
        controller.confirmDisclosure()
        await controller.activeFlowTask?.value

        XCTAssertEqual(controller.phase, .finished(imported: 1, skipped: 0, failed: 0))
        XCTAssertEqual(harness.importedFilenames.current, ["a.jpg"])
        XCTAssertEqual(harness.deletedSessionIDs.current, ["session-1"])
    }
}
