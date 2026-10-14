import Combine
import Foundation
import OSLog

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

    /// A follow-up waiting for one specific popover presentation to finish closing.
    private struct PendingAction {
        let request: Int
        let presentationID: UUID?
        let panelID: String?
        let action: @MainActor () -> Void
    }

    private struct WeakPresentation {
        weak var presentation: (any FileBrowserPanelPresenting)?
    }

    private var pendingAction: PendingAction?
    private var queuedActionCount = 0
    private var presentations: [WeakPresentation] = []

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder",
        category: "file-browser-panel"
    )

    func showBrowserPanel() {
        clearPendingAction()
        panel = .browser
    }

    func showItemPanel(_ item: RemoteFileItem) {
        clearPendingAction()
        panel = .item(item)
    }

    /// Whether `candidate` is the panel that should be on screen. Compared by identity so a
    /// refreshed copy of the same item keeps its popover.
    func isShowing(_ candidate: Panel) -> Bool {
        panel?.id == candidate.id
    }

    func dismissPanel() {
        clearPendingAction()
        panel = nil
    }

    /// Closes the popover that is on screen from inside the tap itself and runs `action` once
    /// that presentation has really finished closing. The UIKit dismissal is requested here
    /// directly; the published state alone was observed to leave the Mac popover on screen.
    func dismissPanel(then action: @escaping @MainActor () -> Void) {
        let replacedPending = pendingAction != nil
        let target = presentationToDismiss()
        queuedActionCount += 1
        let request = queuedActionCount
        let pending = PendingAction(
            request: request,
            presentationID: target?.presentationID,
            panelID: target?.panelID ?? panel?.id,
            action: action
        )
        pendingAction = pending
        panel = nil
        Self.logger.notice("panel action queued: request \(request, privacy: .public), replaced pending \(replacedPending ? 1 : 0, privacy: .public)")

        guard let target else {
            if pending.panelID == nil {
                Self.logger.notice("panel direct dismiss: nothing presented, running request \(request, privacy: .public)")
                runPendingAction(request: request)
            } else {
                Self.logger.notice("panel direct dismiss: no presentation registered, request \(request, privacy: .public) waits for content")
            }
            return
        }
        let start = target.dismissPresentation { [weak self] in
            self?.panelPresentationDismissalCompleted(request: request)
        }
        Self.logger.notice("panel direct dismiss: \(start.rawValue, privacy: .public), request \(request, privacy: .public)")
    }

    /// The popover content exists; its presentation can now be closed directly.
    func registerPresentation(_ presentation: any FileBrowserPanelPresenting) {
        presentations.removeAll { $0.presentation == nil || $0.presentation === presentation }
        presentations.append(WeakPresentation(presentation: presentation))
        Self.logger.notice("panel presentation registered: live \(self.presentations.count, privacy: .public)")
    }

    func unregisterPresentation(_ presentation: any FileBrowserPanelPresenting) {
        presentations.removeAll { $0.presentation == nil || $0.presentation === presentation }
        Self.logger.notice("panel presentation unregistered: live \(self.presentations.count, privacy: .public)")
    }

    /// UIKit reported the popover's view controller leaving the screen. Logged apart from the
    /// SwiftUI signals so a presentation that stays up despite a request is visible.
    func panelPresentationControllerDidDisappear() {
        Self.logger.notice("panel controller disappeared: pending \(self.pendingAction != nil ? 1 : 0, privacy: .public)")
    }

    /// The popover content saw that its panel is no longer current and is asking its own
    /// presentation to close.
    func panelDismissRequested() {
        Self.logger.notice("panel dismiss requested: pending \(self.pendingAction != nil ? 1 : 0, privacy: .public)")
    }

    /// The anchor's presentation state actually flipped.
    func panelPresentationChanged(isPresented: Bool) {
        Self.logger.notice("panel presentation state: \(isPresented ? 1 : 0, privacy: .public)")
    }

    /// The popover's presentation state reporting `false`. Only a panel that is still showing
    /// was closed by the user; after `dismissPanel(then:)`, or once another item's panel has
    /// taken over, the report is an echo and must not drop the follow-up or the new panel.
    func panelWasDismissed(_ dismissed: Panel) {
        guard isShowing(dismissed) else {
            Self.logger.notice("panel dismissal echo ignored: pending \(self.pendingAction != nil ? 1 : 0, privacy: .public)")
            return
        }
        Self.logger.notice("panel closed by user")
        dismissPanel()
    }

    /// The popover content left the hierarchy. Only the presentation the follow-up was queued
    /// against may run it; a late report from another cell's popover is ignored.
    func panelDidDisappear(_ disappeared: Panel, presentationID: UUID) {
        guard let pending = pendingAction else {
            Self.logger.notice("panel content disappeared: pending 0")
            return
        }
        let isAwaited: Bool
        if let awaited = pending.presentationID {
            isAwaited = awaited == presentationID
        } else {
            isAwaited = pending.panelID == disappeared.id
        }
        guard isAwaited else {
            Self.logger.notice("panel content disappeared: pending 1, other presentation ignored")
            return
        }
        Self.logger.notice("panel content disappeared: pending 1, running request \(pending.request, privacy: .public)")
        runPendingAction(request: pending.request)
    }

    /// UIKit's own dismissal completion for the request that asked for it.
    private func panelPresentationDismissalCompleted(request: Int) {
        guard pendingAction?.request == request else {
            Self.logger.notice("panel dismissal completed: request \(request, privacy: .public) no longer pending")
            return
        }
        Self.logger.notice("panel dismissal completed: running request \(request, privacy: .public)")
        runPendingAction(request: request)
    }

    private func runPendingAction(request: Int) {
        guard let pending = pendingAction, pending.request == request else { return }
        clearPendingAction()
        pending.action()
    }

    /// The presentation of the current panel, or, once the panel state is already cleared,
    /// whichever popover is still on screen.
    private func presentationToDismiss() -> (any FileBrowserPanelPresenting)? {
        presentations.removeAll { $0.presentation == nil }
        let live = presentations.compactMap(\.presentation)
        guard let panelID = panel?.id else { return live.last }
        return live.last { $0.panelID == panelID }
    }

    private func clearPendingAction() {
        pendingAction = nil
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

/// How a direct request to close a popover presentation was carried out.
enum FileBrowserPanelDismissalStart: String {
    /// UIKit accepted the dismissal and will call the completion.
    case presentationController = "uikit dismiss started"
    /// The presentation was already closing; its content's disappearance finishes the request.
    case alreadyDismissing = "uikit dismiss already in progress"
    /// No popover presentation was found, so the content's own dismiss action was used.
    case environment = "environment dismiss"
}

/// A popover presentation on screen that the coordinator can close directly.
@MainActor
protocol FileBrowserPanelPresenting: AnyObject {
    var panelID: String { get }
    var presentationID: UUID { get }

    /// `completion` is called only for `.presentationController`.
    func dismissPresentation(
        completion: @escaping @MainActor () -> Void
    ) -> FileBrowserPanelDismissalStart
}
