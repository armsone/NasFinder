import SwiftUI
import UIKit

/// Presents one coordinator panel as a popover anchored to the modified view.
///
/// The presentation is driven by state this modifier owns and by its own subscription to
/// the coordinator, so every anchor tracks the panel itself instead of depending on the
/// browser body handing each cell a fresh closure binding.
struct FileBrowserPanelPopover<PanelContent: View>: ViewModifier {
    @ObservedObject private var coordinator: FileBrowserInteractionCoordinator
    private let panel: FileBrowserInteractionCoordinator.Panel
    private let panelContent: () -> PanelContent

    @State private var isPresented = false
    @State private var placement = FileBrowserPanelPlacement.standard
    @State private var source = FileBrowserPanelSourceReference()

    init(
        coordinator: FileBrowserInteractionCoordinator,
        panel: FileBrowserInteractionCoordinator.Panel,
        @ViewBuilder panelContent: @escaping () -> PanelContent
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.panel = panel
        self.panelContent = panelContent
    }

    func body(content: Content) -> some View {
        anchored(content)
            .onChange(of: coordinator.isShowing(panel), initial: true) { _, shouldPresent in
                guard isPresented != shouldPresent else { return }
                if shouldPresent {
                    placement = source.placement(for: panel)
                }
                isPresented = shouldPresent
            }
            .onChange(of: isPresented) { _, isPresented in
                coordinator.panelPresentationChanged(isPresented: isPresented)
                if !isPresented {
                    coordinator.panelWasDismissed(panel)
                }
            }
    }

    /// On the Mac the popover is placed by `placement`, which is worked out from where the
    /// anchor sits in the window, so a panel opened from the first or last column stays inside
    /// the window. iPhone and iPad keep the system's own placement.
    @ViewBuilder
    private func anchored(_ content: Content) -> some View {
        if MacUIScale.isMac, #available(iOS 18.0, *) {
            content
                .background {
                    FileBrowserPanelSourceReader(reference: source)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
                .popover(
                    isPresented: $isPresented,
                    attachmentAnchor: placement.attachmentAnchor,
                    arrowEdge: placement.arrowEdge
                ) {
                    popoverContent
                }
        } else {
            content
                .popover(
                    isPresented: $isPresented,
                    attachmentAnchor: .rect(.bounds),
                    arrowEdge: .top
                ) {
                    popoverContent
                }
        }
    }

    private var popoverContent: some View {
        FileBrowserPanelPopoverContent(
            coordinator: coordinator,
            panel: panel,
            content: panelContent
        )
    }
}

/// Where a panel popover attaches to its anchor and which of its edges carries the arrow.
struct FileBrowserPanelPlacement: Equatable {
    /// `nil` attaches to the whole anchor, as the system does by default.
    var anchorPoint: UnitPoint?
    var arrowEdge: Edge?

    /// Below the anchor and centered on it.
    static let standard = FileBrowserPanelPlacement(anchorPoint: nil, arrowEdge: .top)

    var attachmentAnchor: PopoverAttachmentAnchor {
        anchorPoint.map { .point($0) } ?? .rect(.bounds)
    }

    /// The gap UIKit keeps between a popover and the window edge, and the length of its arrow.
    private static let windowMargin: CGFloat = 10
    private static let arrowLength: CGFloat = 13

    /// The size a panel had the last time it was on screen, by kind of panel.
    @MainActor private static var measuredSizes: [String: CGSize] = [:]

    private static func sizeKey(
        for panel: FileBrowserInteractionCoordinator.Panel
    ) -> String {
        switch panel {
        case .browser:
            "browser"
        case .item:
            "item"
        }
    }

    @MainActor
    static func record(_ size: CGSize, for panel: FileBrowserInteractionCoordinator.Panel) {
        guard size.width > 0, size.height > 0 else { return }
        measuredSizes[sizeKey(for: panel)] = size
    }

    @MainActor
    static func panelSize(for panel: FileBrowserInteractionCoordinator.Panel) -> CGSize {
        measuredSizes[sizeKey(for: panel)] ?? CGSize(width: ui(340), height: ui(420))
    }

    /// Picks the side of `source` with room for a popover of `size`, and the point on that side
    /// the arrow meets, so the whole popover lands inside `bounds`. All three are in window
    /// coordinates. The arrow always stays on the anchor itself.
    static func resolve(
        source: CGRect,
        size: CGSize,
        in bounds: CGRect
    ) -> FileBrowserPanelPlacement {
        guard source.width > 0, source.height > 0, !bounds.isEmpty else { return .standard }
        let area = bounds.insetBy(dx: windowMargin, dy: windowMargin)
        let width = min(size.width, area.width)
        let height = min(size.height, area.height)

        // Below or above: the popover is centered on the arrow, so the arrow moves along the
        // anchor only as far as keeps the popover's sides inside the window.
        let inset = min(ui(12), source.width / 2)
        let centerX = min(max(source.midX, area.minX + width / 2), area.maxX - width / 2)
        if centerX >= source.minX + inset, centerX <= source.maxX - inset {
            let x = (centerX - source.minX) / source.width
            let roomBelow = area.maxY - source.maxY
            let roomAbove = source.minY - area.minY
            if roomBelow < height + arrowLength, roomAbove > roomBelow {
                return FileBrowserPanelPlacement(
                    anchorPoint: UnitPoint(x: x, y: 0),
                    arrowEdge: .bottom
                )
            }
            if abs(centerX - source.midX) < 0.5 { return .standard }
            return FileBrowserPanelPlacement(anchorPoint: UnitPoint(x: x, y: 1), arrowEdge: .top)
        }

        // An anchor in the first or last column: beside it, level with it as far as the
        // window's top and bottom allow.
        let required = width + arrowLength
        let roomRight = area.maxX - source.maxX
        let roomLeft = source.minX - area.minX
        guard max(roomRight, roomLeft) >= required else { return .standard }
        let centerY = min(max(source.midY, area.minY + height / 2), area.maxY - height / 2)
        let y = (min(max(centerY, source.minY), source.maxY) - source.minY) / source.height
        if roomRight >= required, roomRight >= roomLeft || roomLeft < required {
            return FileBrowserPanelPlacement(
                anchorPoint: UnitPoint(x: 1, y: y),
                arrowEdge: .leading
            )
        }
        return FileBrowserPanelPlacement(anchorPoint: UnitPoint(x: 0, y: y), arrowEdge: .trailing)
    }
}

/// Holds the UIKit view behind a popover's anchor, so the anchor's place in the window is read
/// at the moment the popover opens.
@MainActor
private final class FileBrowserPanelSourceReference {
    weak var view: UIView?

    nonisolated init() {}

    func placement(
        for panel: FileBrowserInteractionCoordinator.Panel
    ) -> FileBrowserPanelPlacement {
        guard let view, let window = view.window else { return .standard }
        return FileBrowserPanelPlacement.resolve(
            source: view.convert(view.bounds, to: nil),
            size: FileBrowserPanelPlacement.panelSize(for: panel),
            in: window.bounds.inset(by: window.safeAreaInsets)
        )
    }
}

private struct FileBrowserPanelSourceReader: UIViewRepresentable {
    let reference: FileBrowserPanelSourceReference

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        reference.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        reference.view = view
    }
}

/// The popover's root. It lives inside the presentation, so its `dismiss` closes this
/// popover, and its probe hands the coordinator the UIKit presentation to close directly.
private struct FileBrowserPanelPopoverContent<Content: View>: View {
    @ObservedObject private var coordinator: FileBrowserInteractionCoordinator
    private let panel: FileBrowserInteractionCoordinator.Panel
    private let content: () -> Content

    @Environment(\.dismiss) private var dismiss
    @State private var presentationID = UUID()

    init(
        coordinator: FileBrowserInteractionCoordinator,
        panel: FileBrowserInteractionCoordinator.Panel,
        content: @escaping () -> Content
    ) {
        _coordinator = ObservedObject(wrappedValue: coordinator)
        self.panel = panel
        self.content = content
    }

    var body: some View {
        content()
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onChange(of: proxy.size, initial: true) { _, size in
                            FileBrowserPanelPlacement.record(size, for: panel)
                        }
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .background {
                FileBrowserPanelPresentationProbe(
                    interactionCoordinator: coordinator,
                    panelID: panel.id,
                    presentationID: presentationID,
                    dismiss: dismiss
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: coordinator.isShowing(panel), initial: true) { _, isShowing in
                guard !isShowing else { return }
                coordinator.panelDismissRequested()
                dismiss()
            }
            .onDisappear {
                coordinator.panelDidDisappear(panel, presentationID: presentationID)
            }
    }
}

/// Embeds a view controller in the popover so the coordinator can reach the UIKit
/// presentation that hosts this content.
private struct FileBrowserPanelPresentationProbe: UIViewControllerRepresentable {
    let interactionCoordinator: FileBrowserInteractionCoordinator
    let panelID: String
    let presentationID: UUID
    let dismiss: DismissAction

    func makeUIViewController(context: Context) -> FileBrowserPanelPresentationController {
        let controller = FileBrowserPanelPresentationController(
            interactionCoordinator: interactionCoordinator,
            panelID: panelID,
            presentationID: presentationID
        )
        controller.environmentDismiss = dismiss
        interactionCoordinator.registerPresentation(controller)
        return controller
    }

    func updateUIViewController(
        _ controller: FileBrowserPanelPresentationController,
        context: Context
    ) {
        controller.environmentDismiss = dismiss
    }

    static func dismantleUIViewController(
        _ controller: FileBrowserPanelPresentationController,
        coordinator: ()
    ) {
        controller.environmentDismiss = nil
        controller.interactionCoordinator?.unregisterPresentation(controller)
    }
}

private final class FileBrowserPanelPresentationController: UIViewController,
    FileBrowserPanelPresenting {
    private(set) weak var interactionCoordinator: FileBrowserInteractionCoordinator?
    let panelID: String
    let presentationID: UUID
    var environmentDismiss: DismissAction?

    init(
        interactionCoordinator: FileBrowserInteractionCoordinator,
        panelID: String,
        presentationID: UUID
    ) {
        self.interactionCoordinator = interactionCoordinator
        self.panelID = panelID
        self.presentationID = presentationID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        interactionCoordinator?.panelPresentationControllerDidDisappear()
    }

    func dismissPresentation(
        completion: @escaping @MainActor () -> Void
    ) -> FileBrowserPanelDismissalStart {
        // Only a popover presentation is closed here, so a browser that is itself presented
        // can never be dismissed in the popover's place.
        guard let presenter = popoverPresenter,
              let presented = presenter.presentedViewController,
              presented.modalPresentationStyle == .popover else {
            environmentDismiss?()
            return .environment
        }
        guard !presented.isBeingDismissed else {
            return .alreadyDismissing
        }
        presenter.dismiss(animated: true) {
            MainActor.assumeIsolated {
                completion()
            }
        }
        return .presentationController
    }

    /// The controller that presented the popover hosting this probe.
    private var popoverPresenter: UIViewController? {
        if let presentingViewController {
            return presentingViewController
        }
        guard isViewLoaded else { return nil }
        var responder: UIResponder? = view.superview
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller.presentingViewController
            }
            responder = current.next
        }
        return nil
    }
}

extension View {
    /// Applies `popover` when the host supplies one; hosts without item actions pass `nil`.
    @ViewBuilder
    func fileBrowserPanelPopover<PanelContent: View>(
        _ popover: FileBrowserPanelPopover<PanelContent>?
    ) -> some View {
        if let popover {
            modifier(popover)
        } else {
            self
        }
    }
}
