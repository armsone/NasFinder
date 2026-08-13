import SwiftUI
import UIKit

enum FileBrowserCoverFlowPolicy {
    static let visibleCardCountPerSide = 7
    static let preloadCardCountPerSide = visibleCardCountPerSide + 1
    static let maximumMomentumCards: CGFloat = 3

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

    @ViewBuilder
    func body(content: Content) -> some View {
        if isCoverFlow {
            content
                .toolbarBackground(Color.white, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.light, for: .navigationBar)
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

struct FileBrowserCoverFlowView: View {
    private let sideCardScale: CGFloat = 0.80

    let items: [RemoteFileItem]
    let service: any RemoteFileService
    let thumbnailReloadVersion: Int
    @Binding var usesDarkBackground: Bool
    let onActivate: (RemoteFileItem) -> Void
    let onShowActions: (RemoteFileItem) -> Void

    @State private var selectedIndex = 0
    @State private var scrollPosition: CGFloat = 0
    @State private var dragStartPosition: CGFloat = 0
    @State private var isDragging = false

    var body: some View {
        GeometryReader { proxy in
            let step = cardStep(for: proxy.size.width)
            let baseline = proxy.size.height - 22
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
                .position(x: proxy.size.width / 2, y: baseline + 18)
                .allowsHitTesting(false)

                ForEach(visibleIndices, id: \.self) { index in
                    coverCard(
                        item: items[index],
                        index: index,
                        availableSize: proxy.size,
                        safeAreaTop: proxy.safeAreaInsets.top,
                        baseline: baseline
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

    private var selectedItem: RemoteFileItem? {
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
        item: RemoteFileItem,
        index: Int,
        availableSize: CGSize,
        safeAreaTop: CGFloat,
        baseline: CGFloat
    ) -> some View {
        let baseWidth = cardBaseWidth(for: availableSize)
        let step = cardStep(for: availableSize.width)
        let distance = CGFloat(index) - scrollPosition
        let absoluteDistance = abs(distance)
        let emphasis = max(1 - absoluteDistance, 0)
        let isSelected = index == selectedIndex
        let cornerRadius = 13 + emphasis * 5
        let centralTarget = centralTargetWidth(
            for: availableSize,
            baseWidth: baseWidth,
            safeAreaTop: safeAreaTop,
            baseline: baseline
        )
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
        let centerY = baseline - renderedSide + totalHeight / 2

        ZStack(alignment: .top) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(width: 360, height: 260),
                reloadVersion: thumbnailReloadVersion
            )
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

            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(width: 360, height: 260),
                reloadVersion: thumbnailReloadVersion
            )
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
            onShowActions(item)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
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

    private func cardStep(for width: CGFloat) -> CGFloat {
        min(max(width * 0.05, 42), 66)
    }

    private func cardBaseWidth(for size: CGSize) -> CGFloat {
        min(
            max(size.width * 0.32, 230),
            min(size.height * 0.72, 310)
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

    private func centralTargetWidth(
        for size: CGSize,
        baseWidth: CGFloat,
        safeAreaTop: CGFloat,
        baseline: CGFloat
    ) -> CGFloat {
        let topClearance = safeAreaTop + 56
        return max(
            min(
                max(baseWidth * 1.26, size.width * 0.38),
                baseline - topClearance,
                460
            ),
            1
        )
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
