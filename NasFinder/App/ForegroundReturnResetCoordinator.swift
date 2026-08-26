import Combine
import SwiftUI

/// Decides when a scene-phase change means "the user left NasFinder and came
/// back", which resets navigation and media state to the dashboard.
///
/// Only a genuine background stay followed by activation resets. Cold launch
/// (`inactive -> active`) and transient inactivity such as Control Center,
/// the notification shade or an in-app authentication sheet never reset.
enum ForegroundReturnResetPolicy {
    struct Transition: Equatable {
        let wasInBackground: Bool
        let shouldReset: Bool
    }

    static func transition(
        wasInBackground: Bool,
        phase: ScenePhase
    ) -> Transition {
        switch phase {
        case .background:
            return Transition(wasInBackground: true, shouldReset: false)
        case .active:
            return Transition(wasInBackground: false, shouldReset: wasInBackground)
        case .inactive:
            return Transition(wasInBackground: wasInBackground, shouldReset: false)
        @unknown default:
            return Transition(wasInBackground: wasInBackground, shouldReset: false)
        }
    }
}

@MainActor
final class ForegroundReturnResetCoordinator: ObservableObject {
    static let shared = ForegroundReturnResetCoordinator()

    /// Increments once per background-to-active return that should reset the
    /// app to the dashboard. Observers reset on every change.
    @Published private(set) var resetGeneration = 0
    private(set) var wasInBackground = false

    init() {}

    func scenePhaseDidChange(_ phase: ScenePhase) {
        let transition = ForegroundReturnResetPolicy.transition(
            wasInBackground: wasInBackground,
            phase: phase
        )
        wasInBackground = transition.wasInBackground
        if transition.shouldReset {
            resetGeneration &+= 1
        }
    }
}
