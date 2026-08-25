import Foundation

/// UI state for the vault cleanup that runs before a fresh rebuild
/// (“새로하기”). Discovery has no known total, so it renders as an
/// indeterminate indicator; deletion has an exact total and advances only
/// after each vault directory is actually removed.
enum VaultCleanupPhase: Equatable, Sendable {
    case idle
    case discovering
    case removing(completed: Int, total: Int)

    var isActive: Bool { self != .idle }

    var isDeterminate: Bool {
        if case .removing = self { return true }
        return false
    }

    var fractionCompleted: Double {
        guard case let .removing(completed, total) = self, total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var activityText: String {
        switch self {
        case .idle:
            return ""
        case .discovering:
            return ".NasFinder-Vault 폴더를 찾는 중…"
        case let .removing(completed, total):
            return total == 0
                ? "삭제할 보관본이 없습니다."
                : "보관본을 삭제하는 중 · \(completed) / \(total)"
        }
    }

    var countText: String {
        guard case let .removing(completed, total) = self else { return "" }
        return "\(completed.formatted()) / \(total.formatted())"
    }

    var accessibilityValueText: String {
        switch self {
        case .idle:
            return ""
        case .discovering:
            return "보관본 폴더를 찾는 중"
        case let .removing(completed, total):
            return "전체 \(total)개 중 \(completed)개 삭제됨"
        }
    }
}
