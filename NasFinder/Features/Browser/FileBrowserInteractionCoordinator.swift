import Combine
import Foundation

@MainActor
final class FileBrowserInteractionCoordinator: ObservableObject {
    enum Panel: Identifiable, Equatable {
        case browser
        case item(RemoteFileItem)

        var id: String {
            switch self {
            case .browser:
                "browser"
            case .item(let item):
                "item:\(item.id)"
            }
        }
    }

    enum Activation: Equatable {
        case toggleSelection(RemoteFileItem.ID)
        case openFolder(RemoteFileItem)
        case preview(RemoteFileItem)
    }

    @Published var panel: Panel?

    private var actionAfterPanelDismissal: (() -> Void)?

    func showBrowserPanel() {
        actionAfterPanelDismissal = nil
        panel = .browser
    }

    func showItemPanel(_ item: RemoteFileItem) {
        actionAfterPanelDismissal = nil
        panel = .item(item)
    }

    func dismissPanel() {
        actionAfterPanelDismissal = nil
        panel = nil
    }

    func dismissPanel(then action: @escaping @MainActor () -> Void) {
        actionAfterPanelDismissal = action
        panel = nil
    }

    func panelDidDisappear() {
        let action = actionAfterPanelDismissal
        actionAfterPanelDismissal = nil
        action?()
    }

    static func activation(
        for item: RemoteFileItem,
        isSelecting: Bool
    ) -> Activation {
        if isSelecting {
            return .toggleSelection(item.id)
        }
        if item.isDirectory {
            return .openFolder(item)
        }
        return .preview(item)
    }
}
