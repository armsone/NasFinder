import SwiftUI
import UIKit

enum FileBrowserCoverFlowPolicy {
    static let visibleCardCountPerSide = 7
    static let preloadCardCountPerSide = visibleCardCountPerSide + 1

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
                LinearGradient(
                    colors: [Color.black.opacity(0.045), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 82)
                .blur(radius: 8)
                .position(x: proxy.size.width / 2, y: baseline + 18)

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
            .gesture(flowGesture(step: step))
        }
        .background(Color.white)
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
        let maximumReflectionHeight: CGFloat = 18
        let reflectionHeight = min(renderedSide * 0.08, maximumReflectionHeight)
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
                        Color.black.opacity(0.08 + emphasis * 0.08),
                        lineWidth: 0.6 + emphasis * 0.4
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
            .opacity(0.12 + emphasis * 0.10)
            .blur(radius: 0.8)
            .mask {
                LinearGradient(
                    colors: [.white.opacity(0.58), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .offset(y: renderedSide + 2)
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
            color: .black.opacity(0.08 + emphasis * 0.09),
            radius: 4 + emphasis * 10,
            y: 0
        )
        .zIndex(Double(20 - absoluteDistance))
        .compositingGroup()
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelected {
                onActivate(item)
            } else {
                select(index)
            }
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            onShowActions(item)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityHint(isSelected ? "두 번 탭하여 열기" : "두 번 탭하여 선택")
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
                let projectedPosition = clampedPosition(
                    dragStartPosition - value.predictedEndTranslation.width / step
                )
                let maximumMovement: CGFloat = 5
                let lower = max(CGFloat(selectedIndex) - maximumMovement, 0)
                let upper = min(
                    CGFloat(selectedIndex) + maximumMovement,
                    CGFloat(max(items.count - 1, 0))
                )
                let target = Int(min(max(projectedPosition.rounded(), lower), upper))
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
                max(baseWidth * 1.22, size.width * 0.34),
                baseline - topClearance,
                432
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

    private func rotation(for distance: CGFloat) -> Double {
        let clamped = min(max(distance, -1), 1)
        return -Double(clamped) * 42
    }
}
