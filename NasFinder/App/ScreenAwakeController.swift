import Combine
import Foundation
import UIKit

enum ScreenAwakeMode: String, CaseIterable, Identifiable {
    case automatic
    case always
    case off

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: "오토"
        case .always: "항상 켜짐"
        case .off: "끔"
        }
    }

    var description: String {
        switch self {
        case .automatic:
            "재생·썸네일 생성·다운로드·파일 작업 중에만 화면을 켜 둡니다."
        case .always:
            "NasFinder가 화면에 열려 있는 동안 화면을 켜 둡니다."
        case .off:
            "iPhone의 화면 자동 잠금 설정을 그대로 따릅니다."
        }
    }
}

enum ScreenAwakePolicy {
    static func shouldPreventSleep(
        mode: ScreenAwakeMode,
        appIsActive: Bool,
        hasActiveWork: Bool
    ) -> Bool {
        guard appIsActive else { return false }
        switch mode {
        case .automatic:
            return hasActiveWork
        case .always:
            return true
        case .off:
            return false
        }
    }
}

@MainActor
final class ScreenAwakeController: ObservableObject {
    static let shared = ScreenAwakeController()
    static let defaultsKey = "screenAwakeMode"

    @Published var mode: ScreenAwakeMode {
        didSet {
            defaults.set(mode.rawValue, forKey: Self.defaultsKey)
            applyPolicy()
        }
    }
    @Published private(set) var isPreventingSleep = false

    private let defaults: UserDefaults
    private let setIdleTimerDisabled: (Bool) -> Void
    private var activeActivityIDs: Set<UUID> = []
    private var appIsActive = false

    init(
        defaults: UserDefaults = .standard,
        setIdleTimerDisabled: @escaping (Bool) -> Void = {
            UIApplication.shared.isIdleTimerDisabled = $0
        }
    ) {
        self.defaults = defaults
        self.setIdleTimerDisabled = setIdleTimerDisabled
        mode = defaults.string(forKey: Self.defaultsKey)
            .flatMap(ScreenAwakeMode.init(rawValue:)) ?? .automatic
    }

    func updateAppIsActive(_ isActive: Bool) {
        appIsActive = isActive
        applyPolicy()
    }

    func beginActivity(_ activityID: UUID) {
        guard activeActivityIDs.insert(activityID).inserted else { return }
        applyPolicy()
    }

    func finishActivity(_ activityID: UUID) {
        guard activeActivityIDs.remove(activityID) != nil else { return }
        applyPolicy()
    }

    private func applyPolicy() {
        let shouldPreventSleep = ScreenAwakePolicy.shouldPreventSleep(
            mode: mode,
            appIsActive: appIsActive,
            hasActiveWork: !activeActivityIDs.isEmpty
        )
        guard shouldPreventSleep != isPreventingSleep else { return }
        isPreventingSleep = shouldPreventSleep
        setIdleTimerDisabled(shouldPreventSleep)
    }
}
