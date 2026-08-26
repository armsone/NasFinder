import SwiftUI
import UIKit

enum FileBrowserCoverFlowPolicy {
    static let visibleCardCountPerSide = 7
    static let preloadCardCountPerSide = visibleCardCountPerSide + 1
    static let maximumMomentumCards: CGFloat = 3
    static let thumbnailRequestStep: CGFloat = 40

    /// Every card requests the same square thumbnail regardless of its live
    /// rendered side. The rendered side changes on every drag frame and while
    /// a card slides toward the center, and `RemoteThumbnailView` restarts its
    /// load whenever the requested size changes. A stable request keeps one
    /// in-flight remote fetch per card, shares one cache entry between the card
    /// and its reflection, and only changes when the layout itself changes.
    static func thumbnailRequestSize(centerSide: CGFloat) -> CGSize {
        let safeSide = max(centerSide.isFinite ? centerSide : 0, 1)
        let side = max(
            (safeSide / thumbnailRequestStep).rounded(.up) * thumbnailRequestStep,
            thumbnailRequestStep
        )
        return CGSize(width: side, height: side)
    }

    static func preloadIndices(
        itemCount: Int,
        scrollPosition: CGFloat
    ) -> [Int] {
        guard itemCount > 0 else { return [] }
        let liveCenter = min(
            max(Int(scrollPosition.rounded()), 0),
            itemCount - 1
        )
        let lower = max(liveCenter - preloadCardCountPerSide, 0)
        let upper = min(liveCenter + preloadCardCountPerSide, itemCount - 1)
        return Array(lower...upper)
    }

    static func restingIndex(
        itemCount: Int,
        scrollPosition: CGFloat,
        translation: CGFloat = 0,
        predictedEndTranslation: CGFloat = 0,
        cardStep: CGFloat = 1
    ) -> Int? {
        guard itemCount > 0 else { return nil }
        let safeStep = max(cardStep, 1)
        let projectedExtraTranslation = predictedEndTranslation - translation
        var momentum = -projectedExtraTranslation / safeStep

        // UIKit's prediction can occasionally point opposite to the actual
        // finger movement at the end of a slow drag. Momentum must only carry
        // the cards in the direction the user was already moving them.
        let dragDirection = -translation
        if dragDirection == 0 || momentum * dragDirection < 0 {
            momentum = 0
        }
        momentum = min(
            max(momentum, -maximumMomentumCards),
            maximumMomentumCards
        )
        let projectedPosition = scrollPosition + momentum
        return min(
            max(Int(projectedPosition.rounded()), 0),
            itemCount - 1
        )
    }
}

enum FileBrowserOverflowPresentationPolicy {
    static func shouldPresentPosterAsOverflow(
        contentSize: CGSize,
        isSelecting: Bool,
        hasItems: Bool
    ) -> Bool {
        hasItems
            && !isSelecting
            && contentSize.width > contentSize.height
            && contentSize.width > 0
            && contentSize.height > 0
    }
}

struct FileBrowserCoverFlowGeometry: Equatable {
    let centerSide: CGFloat
    let squareCenterY: CGFloat
    let squareBottom: CGFloat
    let floorCenterY: CGFloat
}

enum FileBrowserCoverFlowGeometryPolicy {
    static let horizontalInset: CGFloat = 16
    static let chromeClearance: CGFloat = 60
    static let reflectionReserve: CGFloat = 64

    static func geometry(
        in size: CGSize,
        safeAreaTop: CGFloat,
        safeAreaLeading: CGFloat = 0,
        safeAreaBottom: CGFloat,
        safeAreaTrailing: CGFloat = 0
    ) -> FileBrowserCoverFlowGeometry {
        let usableWidth = max(
            size.width
                - safeAreaLeading
                - safeAreaTrailing
                - horizontalInset * 2,
            1
        )
        let top = min(max(safeAreaTop + chromeClearance, 0), size.height)
        let bottom = max(
            min(size.height - safeAreaBottom - reflectionReserve, size.height),
            top + 1
        )
        let usableHeight = max(bottom - top, 1)
        let centerSide = max(min(usableWidth, usableHeight), 1)
        let squareCenterY = top + usableHeight / 2
        let squareBottom = squareCenterY + centerSide / 2
        let floorCenterY = min(
            size.height - safeAreaBottom,
            squareBottom + reflectionReserve / 2
        )
        return FileBrowserCoverFlowGeometry(
            centerSide: centerSide,
            squareCenterY: squareCenterY,
            squareBottom: squareBottom,
            floorCenterY: floorCenterY
        )
    }
}

enum FileBrowserCoverFlowBackground: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }
    var title: String { self == .light ? "흰색" : "검정" }
    var usesDarkBackground: Bool { self == .dark }

    init(usesDarkBackground: Bool) {
        self = usesDarkBackground ? .dark : .light
    }
}

struct FileBrowserNavigationAppearanceModifier: ViewModifier {
    let isCoverFlow: Bool
    let usesDarkBackground: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCoverFlow {
            content
                .toolbarBackground(
                    usesDarkBackground
                        ? Color(red: 5.0 / 255.0, green: 5.0 / 255.0, blue: 6.0 / 255.0)
                        : Color.white,
                    for: .navigationBar
                )
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(
                    usesDarkBackground ? .dark : .light,
                    for: .navigationBar
                )
        } else {
            content
        }
    }
}

struct FileBrowserDeviceRotationModifier: ViewModifier {
    let onChange: @MainActor (UIDeviceOrientation) -> Void

    func body(content: Content) -> some View {
        content
            .onAppear {
                UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            }
            .onDisappear {
                UIDevice.current.endGeneratingDeviceOrientationNotifications()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIDevice.orientationDidChangeNotification
                )
            ) { _ in
                onChange(UIDevice.current.orientation)
            }
    }
}

struct FileBrowserSearchModifier: ViewModifier {
    let isEnabled: Bool
    @Binding var text: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.searchable(
                text: $text,
                placement: .navigationBarDrawer(displayMode: .automatic),
                prompt: "현재 폴더 검색"
            )
        } else {
            content
        }
    }
}

@MainActor
enum FileBrowserOrientationController {
    private static var activeRequestCount = 0

    static func beginCoverFlow() {
        activeRequestCount += 1
        request(.landscape)
    }

    static func endCoverFlow() {
        activeRequestCount = max(activeRequestCount - 1, 0)
        guard activeRequestCount == 0 else { return }
        request(.portrait)
    }

    private static func request(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) else {
            return
        }
        scene.requestGeometryUpdate(
            .iOS(interfaceOrientations: orientations)
        ) { _ in
            // Rotation can be temporarily unavailable during another system
            // presentation. The next layout change requests it again.
        }
    }
}

enum FileBrowserCoverFlowChromePolicy {
    static let buttonSize: CGFloat = 44
    static let horizontalPadding: CGFloat = 12
    static let safeAreaTopPadding: CGFloat = 4
    static let itemSpacing: CGFloat = 8

    static func titleMaximumWidth(containerWidth: CGFloat) -> CGFloat {
        min(containerWidth * 0.44, 340)
    }

    static func foreground(usesDarkBackground: Bool) -> Color {
        usesDarkBackground ? .white.opacity(0.88) : .black.opacity(0.82)
    }

    static func background(usesDarkBackground: Bool) -> Color {
        usesDarkBackground ? .white.opacity(0.10) : .white.opacity(0.92)
    }

    static func border(usesDarkBackground: Bool) -> Color {
        usesDarkBackground ? .white.opacity(0.16) : .black.opacity(0.10)
    }
}

struct FileBrowserCoverFlowNavigationChrome<Content: View>: View {
    let usesDarkBackground: Bool
    private let content: (CGFloat) -> Content

    init(
        usesDarkBackground: Bool,
        @ViewBuilder content: @escaping (CGFloat) -> Content
    ) {
        self.usesDarkBackground = usesDarkBackground
        self.content = content
    }

    var body: some View {
        GeometryReader { geometry in
            content(geometry.size.width)
                .padding(.horizontal, FileBrowserCoverFlowChromePolicy.horizontalPadding)
                .padding(
                    .top,
                    geometry.safeAreaInsets.top
                        + FileBrowserCoverFlowChromePolicy.safeAreaTopPadding
                )
                .frame(maxWidth: .infinity, alignment: .top)
                .animation(.easeInOut(duration: 0.20), value: usesDarkBackground)
        }
    }
}

struct FileBrowserCoverFlowChromeIcon: View {
    enum Kind: Equatable {
        case back
        case more
    }

    let kind: Kind
    let usesDarkBackground: Bool

    var body: some View {
        Image(systemName: kind == .back ? "chevron.left" : "ellipsis")
            .font(
                kind == .back
                    ? .system(size: 22, weight: .semibold)
                    : .system(size: 16, weight: .bold)
            )
            .frame(
                width: FileBrowserCoverFlowChromePolicy.buttonSize,
                height: FileBrowserCoverFlowChromePolicy.buttonSize
            )
            .contentShape(Circle())
            .foregroundStyle(kind == .more ? SkyBreezeTheme.accent : foreground)
            .background(background, in: Circle())
            .overlay {
                Circle().stroke(border, lineWidth: 1)
            }
            .shadow(
                color: .black.opacity(usesDarkBackground ? 0.40 : 0.10),
                radius: 8,
                y: 2
            )
    }

    private var foreground: Color {
        FileBrowserCoverFlowChromePolicy.foreground(
            usesDarkBackground: usesDarkBackground
        )
    }

    private var background: Color {
        FileBrowserCoverFlowChromePolicy.background(
            usesDarkBackground: usesDarkBackground
        )
    }

    private var border: Color {
        FileBrowserCoverFlowChromePolicy.border(
            usesDarkBackground: usesDarkBackground
        )
    }
}

struct FileBrowserCoverFlowChromeModifier: ViewModifier {
    let isActive: Bool

    func body(content: Content) -> some View {
        content
            .navigationBarBackButtonHidden(isActive)
            .toolbar(isActive ? .hidden : .visible, for: .navigationBar)
    }
}

struct FileBrowserCoverFlowView<Item: Identifiable, Thumbnail: View>: View {
    private let sideCardScale: CGFloat = 0.80

    let items: [Item]
    @Binding var usesDarkBackground: Bool
    let itemName: (Item) -> String
    let thumbnail: (Item, CGSize) -> Thumbnail
    let onActivate: (Item) -> Void
    let onShowActions: ((Item) -> Void)?

    @State private var selectedIndex = 0
    @State private var scrollPosition: CGFloat = 0
    @State private var dragStartPosition: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let layout = FileBrowserCoverFlowGeometryPolicy.geometry(
                in: proxy.size,
                safeAreaTop: proxy.safeAreaInsets.top,
                safeAreaLeading: proxy.safeAreaInsets.leading,
                safeAreaBottom: proxy.safeAreaInsets.bottom,
                safeAreaTrailing: proxy.safeAreaInsets.trailing
            )
            let step = cardStep(
                for: proxy.size.width,
                centerSide: layout.centerSide
            )
            ZStack {
                Rectangle()
                    .fill(coverFlowBackground)
                    .allowsHitTesting(false)

                LinearGradient(
                    colors: floorGlowColors,
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: usesDarkBackground ? 72 : 82)
                .blur(radius: usesDarkBackground ? 5 : 8)
                .position(x: proxy.size.width / 2, y: layout.floorCenterY)
                .allowsHitTesting(false)

                ForEach(visibleIndices, id: \.self) { index in
                    coverCard(
                        item: items[index],
                        index: index,
                        availableSize: proxy.size,
                        layout: layout
                    )
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(flowGesture(step: step))
        }
        .background(coverFlowBackground)
        .animation(.easeInOut(duration: 0.20), value: usesDarkBackground)
        .onChange(of: items.map(\.id), initial: true) { _, _ in
            selectedIndex = min(max(selectedIndex, 0), max(items.count - 1, 0))
            scrollPosition = CGFloat(selectedIndex)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("오버플로우 보기")
    }

    private var selectedItem: Item? {
        guard items.indices.contains(selectedIndex) else { return nil }
        return items[selectedIndex]
    }

    private var visibleIndices: [Int] {
        FileBrowserCoverFlowPolicy.preloadIndices(
            itemCount: items.count,
            scrollPosition: scrollPosition
        ).sorted {
            abs($0 - selectedIndex) > abs($1 - selectedIndex)
        }
    }

    @ViewBuilder
    private func coverCard(
        item: Item,
        index: Int,
        availableSize: CGSize,
        layout: FileBrowserCoverFlowGeometry
    ) -> some View {
        let baseWidth = cardBaseWidth(
            for: availableSize,
            centerSide: layout.centerSide
        )
        let step = cardStep(
            for: availableSize.width,
            centerSide: layout.centerSide
        )
        let distance = CGFloat(index) - scrollPosition
        let absoluteDistance = abs(distance)
        let emphasis = max(1 - absoluteDistance, 0)
        let isSelected = index == selectedIndex
        let cornerRadius = 13 + emphasis * 5
        let centralTarget = layout.centerSide
        let renderedSide = renderedSide(
            for: absoluteDistance,
            baseWidth: baseWidth,
            centralTarget: centralTarget
        )
        let sidePush = horizontalPush(
            for: distance,
            baseWidth: baseWidth,
            centralTarget: centralTarget
        )
        let maximumReflectionHeight: CGFloat = usesDarkBackground
            ? (emphasis > 0 ? 44 : 32)
            : 20
        let reflectionRatio: CGFloat = usesDarkBackground ? 0.15 : 0.10
        let reflectionHeight = min(renderedSide * reflectionRatio, maximumReflectionHeight)
        let totalHeight = renderedSide + 2 + reflectionHeight
        let centerY = layout.squareBottom - renderedSide + totalHeight / 2
        let thumbnailRequestSize = FileBrowserCoverFlowPolicy.thumbnailRequestSize(
            centerSide: layout.centerSide
        )

        ZStack(alignment: .top) {
            thumbnail(item, thumbnailRequestSize)
            .frame(width: renderedSide, height: renderedSide)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(
                        cardBorderColor(emphasis: emphasis),
                        lineWidth: usesDarkBackground
                            ? 0.75 + emphasis * 0.25
                            : 0.6 + emphasis * 0.4
                    )
            }

            thumbnail(item, thumbnailRequestSize)
            .frame(width: renderedSide, height: renderedSide)
            .scaleEffect(x: 1, y: -1)
            .frame(width: renderedSide, height: reflectionHeight, alignment: .top)
            .clipped()
            .opacity(reflectionOpacity(emphasis: emphasis))
            .blur(radius: usesDarkBackground ? 0.65 : 0.8)
            .mask {
                LinearGradient(
                    colors: [
                        .white.opacity(usesDarkBackground ? 0.72 : 0.58),
                        .clear
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .offset(y: renderedSide + (usesDarkBackground ? 1 : 2))
            .allowsHitTesting(false)
        }
        .frame(width: renderedSide, height: totalHeight, alignment: .top)
        .rotation3DEffect(
            .degrees(rotation(for: distance)),
            axis: (x: 0, y: 1, z: 0),
            anchor: .bottom,
            perspective: 0.74
        )
        .position(
            x: availableSize.width / 2 + distance * step + sidePush,
            y: centerY
        )
        .opacity(opacity(for: absoluteDistance))
        .shadow(
            color: cardShadowColor(emphasis: emphasis),
            radius: 4 + emphasis * (usesDarkBackground ? 8 : 10)
        )
        .zIndex(Double(20 - absoluteDistance))
        .compositingGroup()
        .contentShape(Rectangle())
        .onTapGesture {
            onActivate(item)
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onShowActions?(item)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(itemName(item))
        .accessibilityHint("두 번 탭하여 열기")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    private func flowGesture(step: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if !isDragging {
                    isDragging = true
                    dragStartPosition = scrollPosition
                }
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    scrollPosition = clampedPosition(
                        dragStartPosition - value.translation.width / step
                    )
                }
            }
            .onEnded { value in
                let target = FileBrowserCoverFlowPolicy.restingIndex(
                    itemCount: items.count,
                    scrollPosition: scrollPosition,
                    translation: value.translation.width,
                    predictedEndTranslation: value.predictedEndTranslation.width,
                    cardStep: step
                ) ?? selectedIndex
                isDragging = false
                settle(at: target)
            }
    }

    private func select(_ index: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(index, items.startIndex), items.index(before: items.endIndex))
        guard next != selectedIndex else { return }
        UISelectionFeedbackGenerator().selectionChanged()
        withAnimation(.smooth(duration: 0.28, extraBounce: 0)) {
            selectedIndex = next
            scrollPosition = CGFloat(next)
        }
    }

    private func settle(at index: Int) {
        guard !items.isEmpty else { return }
        let next = min(max(index, items.startIndex), items.index(before: items.endIndex))
        if next != selectedIndex {
            UISelectionFeedbackGenerator().selectionChanged()
        }
        withAnimation(.smooth(duration: 0.28, extraBounce: 0)) {
            selectedIndex = next
            scrollPosition = CGFloat(next)
        }
    }

    private func cardStep(for width: CGFloat, centerSide: CGFloat) -> CGFloat {
        min(
            max(max(width * 0.055, centerSide * 0.16), 44),
            min(max(width * 0.12, 66), 120)
        )
    }

    private func cardBaseWidth(for size: CGSize, centerSide: CGFloat) -> CGFloat {
        min(
            max(size.width * 0.24, 180),
            min(centerSide * 0.62, 420)
        )
    }

    private func clampedPosition(_ position: CGFloat) -> CGFloat {
        min(max(position, 0), CGFloat(max(items.count - 1, 0)))
    }

    private func renderedSide(
        for distance: CGFloat,
        baseWidth: CGFloat,
        centralTarget: CGFloat
    ) -> CGFloat {
        let surroundingScale: CGFloat
        if distance <= 1 {
            surroundingScale = 1.08 - 0.16 * distance
        } else {
            surroundingScale = max(0.60, 0.92 - 0.08 * (distance - 1))
        }
        let focus = max(1 - distance, 0)
        let easedFocus = smoothstep(focus)
        let sideSide = baseWidth * surroundingScale * sideCardScale
        return sideSide + (centralTarget - sideSide) * easedFocus
    }

    private func horizontalPush(
        for distance: CGFloat,
        baseWidth: CGFloat,
        centralTarget: CGFloat
    ) -> CGFloat {
        guard distance != 0 else { return 0 }
        let travel = smoothstep(min(max(abs(distance), 0), 1))
        let fullPush = max(
            (centralTarget - baseWidth * 0.92 * sideCardScale) / 2 + 18,
            44
        )
        return (distance < 0 ? -1 : 1)
            * fullPush
            * travel
    }

    private func smoothstep(_ value: CGFloat) -> CGFloat {
        let clamped = min(max(value, 0), 1)
        return clamped * clamped * (3 - 2 * clamped)
    }

    private func opacity(for distance: CGFloat) -> Double {
        if distance > 5 {
            return max(0, Double(8 - distance) * 0.14)
        }
        return max(0.16, 1 - Double(distance) * 0.115)
    }

    private var coverFlowBackground: Color {
        usesDarkBackground
            ? Color(red: 5.0 / 255.0, green: 5.0 / 255.0, blue: 6.0 / 255.0)
            : .white
    }

    private var floorGlowColors: [Color] {
        usesDarkBackground
            ? [.white.opacity(0.13), .white.opacity(0.035), .clear]
            : [.black.opacity(0.060), .clear]
    }

    private func cardBorderColor(emphasis: CGFloat) -> Color {
        usesDarkBackground
            ? .white.opacity(0.10 + emphasis * 0.08)
            : .black.opacity(0.08 + emphasis * 0.08)
    }

    private func reflectionOpacity(emphasis: CGFloat) -> Double {
        usesDarkBackground
            ? 0.22 + Double(emphasis) * 0.14
            : 0.16 + Double(emphasis) * 0.12
    }

    private func cardShadowColor(emphasis: CGFloat) -> Color {
        usesDarkBackground
            ? .white.opacity(Double(emphasis) * 0.06)
            : .black.opacity(0.08 + Double(emphasis) * 0.09)
    }

    private func rotation(for distance: CGFloat) -> Double {
        let clamped = min(max(distance, -1), 1)
        return -Double(clamped) * 42
    }
}
