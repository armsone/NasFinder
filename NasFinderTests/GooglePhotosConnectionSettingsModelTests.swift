import Foundation
import XCTest
@testable import NasFinder

private struct SettingsHarnessError: Error {}

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
}

@MainActor
final class GooglePhotosConnectionSettingsModelTests: XCTestCase {
    private func makeCredential(accessToken: String = "token") -> GooglePhotosCredential {
        GooglePhotosCredential(
            accessToken: accessToken,
            refreshToken: "refresh",
            expirationDate: nil,
            grantedScopes: [GooglePhotosOAuthConfiguration.pickerScope]
        )
    }

    private func makeModel(
        storedCredential: LockedBox<GooglePhotosCredential?>,
        revokeCallCount: LockedBox<Int>,
        revokeFails: Bool = false,
        removeCallCount: LockedBox<Int>,
        removeFails: Bool = false
    ) -> GooglePhotosConnectionSettingsModel {
        GooglePhotosConnectionSettingsModel(
            dependencies: .init(
                loadCredential: { storedCredential.current },
                removeCredential: {
                    removeCallCount.current += 1
                    if removeFails { throw SettingsHarnessError() }
                    storedCredential.current = nil
                },
                revoke: { _ in
                    revokeCallCount.current += 1
                    if revokeFails { throw SettingsHarnessError() }
                }
            )
        )
    }

    func testConnectionStateReflectsStoredCredential() {
        let stored = LockedBox<GooglePhotosCredential?>(nil)
        let model = makeModel(
            storedCredential: stored,
            revokeCallCount: LockedBox(0),
            removeCallCount: LockedBox(0)
        )
        XCTAssertFalse(model.isConnected)

        stored.current = makeCredential()
        model.refreshConnectionState()
        XCTAssertTrue(model.isConnected)
    }

    func testDisconnectRevokesThenRemovesCredential() async {
        let stored = LockedBox<GooglePhotosCredential?>(makeCredential())
        let revokeCalls = LockedBox(0)
        let removeCalls = LockedBox(0)
        let model = makeModel(
            storedCredential: stored,
            revokeCallCount: revokeCalls,
            removeCallCount: removeCalls
        )
        XCTAssertTrue(model.isConnected)

        await model.disconnect()

        XCTAssertEqual(revokeCalls.current, 1)
        XCTAssertEqual(removeCalls.current, 1)
        XCTAssertNil(stored.current)
        XCTAssertFalse(model.isConnected)
        XCTAssertNotNil(model.resultMessage)
    }

    func testDisconnectRemovesLocalCredentialEvenWhenRevokeFails() async {
        let stored = LockedBox<GooglePhotosCredential?>(makeCredential())
        let revokeCalls = LockedBox(0)
        let removeCalls = LockedBox(0)
        let model = makeModel(
            storedCredential: stored,
            revokeCallCount: revokeCalls,
            revokeFails: true,
            removeCallCount: removeCalls
        )

        await model.disconnect()

        XCTAssertEqual(revokeCalls.current, 1)
        XCTAssertEqual(removeCalls.current, 1)
        XCTAssertNil(stored.current)
        XCTAssertFalse(model.isConnected)
        XCTAssertNotNil(model.resultMessage)
    }

    func testDisconnectReportsRemovalFailureAndStaysConnected() async {
        let stored = LockedBox<GooglePhotosCredential?>(makeCredential())
        let model = makeModel(
            storedCredential: stored,
            revokeCallCount: LockedBox(0),
            removeCallCount: LockedBox(0),
            removeFails: true
        )

        await model.disconnect()

        XCTAssertNotNil(stored.current)
        XCTAssertTrue(model.isConnected)
        XCTAssertNotNil(model.resultMessage)
    }

    func testDisconnectWithoutCredentialSkipsRevokeButClearsState() async {
        let stored = LockedBox<GooglePhotosCredential?>(nil)
        let revokeCalls = LockedBox(0)
        let removeCalls = LockedBox(0)
        let model = makeModel(
            storedCredential: stored,
            revokeCallCount: revokeCalls,
            removeCallCount: removeCalls
        )

        await model.disconnect()

        XCTAssertEqual(revokeCalls.current, 0)
        XCTAssertEqual(removeCalls.current, 1)
        XCTAssertFalse(model.isConnected)
    }
}
