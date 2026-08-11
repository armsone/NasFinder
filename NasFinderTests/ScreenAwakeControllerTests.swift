import XCTest
@testable import NasFinder

@MainActor
final class ScreenAwakeControllerTests: XCTestCase {
    func testAutomaticIsTheDefaultMode() {
        let defaults = isolatedDefaults()
        let controller = ScreenAwakeController(
            defaults: defaults,
            setIdleTimerDisabled: { _ in }
        )

        XCTAssertEqual(controller.mode, .automatic)
    }

    func testPolicyOnlyPreventsSleepForActiveAutomaticWork() {
        XCTAssertFalse(
            ScreenAwakePolicy.shouldPreventSleep(
                mode: .automatic,
                appIsActive: true,
                hasActiveWork: false
            )
        )
        XCTAssertTrue(
            ScreenAwakePolicy.shouldPreventSleep(
                mode: .automatic,
                appIsActive: true,
                hasActiveWork: true
            )
        )
        XCTAssertTrue(
            ScreenAwakePolicy.shouldPreventSleep(
                mode: .always,
                appIsActive: true,
                hasActiveWork: false
            )
        )
        XCTAssertFalse(
            ScreenAwakePolicy.shouldPreventSleep(
                mode: .always,
                appIsActive: false,
                hasActiveWork: true
            )
        )
        XCTAssertFalse(
            ScreenAwakePolicy.shouldPreventSleep(
                mode: .off,
                appIsActive: true,
                hasActiveWork: true
            )
        )
    }

    func testIndependentActivitiesReleaseSleepPreventionAfterLastFinish() {
        let defaults = isolatedDefaults()
        var appliedValues: [Bool] = []
        let controller = ScreenAwakeController(
            defaults: defaults,
            setIdleTimerDisabled: { appliedValues.append($0) }
        )
        let first = UUID()
        let second = UUID()

        controller.updateAppIsActive(true)
        controller.beginActivity(first)
        controller.beginActivity(second)
        controller.finishActivity(first)
        XCTAssertTrue(controller.isPreventingSleep)

        controller.finishActivity(second)
        XCTAssertFalse(controller.isPreventingSleep)
        XCTAssertEqual(appliedValues, [true, false])
    }

    func testSelectedModePersists() {
        let defaults = isolatedDefaults()
        let controller = ScreenAwakeController(
            defaults: defaults,
            setIdleTimerDisabled: { _ in }
        )

        controller.mode = .always

        XCTAssertEqual(
            defaults.string(forKey: ScreenAwakeController.defaultsKey),
            ScreenAwakeMode.always.rawValue
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "ScreenAwakeControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
