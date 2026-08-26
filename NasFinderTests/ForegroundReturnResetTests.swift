import SwiftUI
import XCTest
@testable import NasFinder

@MainActor
final class ForegroundReturnResetTests: XCTestCase {
    func testColdLaunchAndTransientInactivityNeverReset() {
        let coordinator = ForegroundReturnResetCoordinator()

        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertEqual(coordinator.resetGeneration, 0)

        // Control Center, notification shade or an authentication sheet.
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertEqual(coordinator.resetGeneration, 0)
        XCTAssertFalse(coordinator.wasInBackground)
    }

    func testReturningFromBackgroundResetsExactlyOncePerStay() {
        let coordinator = ForegroundReturnResetCoordinator()
        coordinator.scenePhaseDidChange(.active)

        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.background)
        XCTAssertTrue(coordinator.wasInBackground)
        XCTAssertEqual(coordinator.resetGeneration, 0)

        coordinator.scenePhaseDidChange(.inactive)
        XCTAssertEqual(coordinator.resetGeneration, 0)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertEqual(coordinator.resetGeneration, 1)
        XCTAssertFalse(coordinator.wasInBackground)

        // A later transient inactivity does not reset again.
        coordinator.scenePhaseDidChange(.inactive)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertEqual(coordinator.resetGeneration, 1)

        coordinator.scenePhaseDidChange(.background)
        coordinator.scenePhaseDidChange(.active)
        XCTAssertEqual(coordinator.resetGeneration, 2)
    }

    func testPolicyTransitionsAreDeterministic() {
        XCTAssertEqual(
            ForegroundReturnResetPolicy.transition(
                wasInBackground: false,
                phase: .active
            ),
            ForegroundReturnResetPolicy.Transition(wasInBackground: false, shouldReset: false)
        )
        XCTAssertEqual(
            ForegroundReturnResetPolicy.transition(
                wasInBackground: true,
                phase: .active
            ),
            ForegroundReturnResetPolicy.Transition(wasInBackground: false, shouldReset: true)
        )
        XCTAssertEqual(
            ForegroundReturnResetPolicy.transition(
                wasInBackground: true,
                phase: .inactive
            ),
            ForegroundReturnResetPolicy.Transition(wasInBackground: true, shouldReset: false)
        )
    }
}
