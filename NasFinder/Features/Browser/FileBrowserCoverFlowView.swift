import SwiftUI
import UIKit

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
            VStack(spacing: 0) {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        colors: [Color.black.opacity(0.045), .clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 82)
                    .blur(radius: 8)

                    ForEach(visibleIndices, id: \.self) { index in
                        coverCard(
                            item: items[index],
                            index: index,
                            availableSize: proxy.size
                        )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(flowGesture(step: step))

            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
            .padding(.bottom, 4)
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
        guard !items.isEmpty else { return [] }
        let lower = max(selectedIndex - 6, items.startIndex)
        let upper = min(selectedIndex + 6, items.index(before: items.endIndex))
        return Array(lower...upper).sorted {
            abs($0 - selectedIndex) > abs($1 - selectedIndex)
        }
    }

    @ViewBuilder
    private func coverCard(
        item: RemoteFileItem,
        index: Int,
        availableSize: CGSize
    ) -> some View {
        let baseWidth = min(
            max(availableSize.width * 0.34, 220),
            min(availableSize.height * 0.78, 310)
        )
        let baseHeight = baseWidth
        let step = cardStep(for: availableSize.width)
        let distance = CGFloat(index) - scrollPosition
        let absoluteDistance = abs(distance)
        let emphasis = max(1 - absoluteDistance, 0)
        let isSelected = index == selectedIndex
        let cornerRadius = 13 + emphasis * 5
        let scaleValue = scale(for: absoluteDistance)
        let reflectionHeight = baseHeight * 0.24

        RemoteThumbnailView(
            item: item,
            service: service,
            size: CGSize(width: 360, height: 260),
            reloadVersion: thumbnailReloadVersion
        )
        .frame(width: baseWidth, height: baseHeight)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: cornerRadius)
                .stroke(
                    Color.black.opacity(0.14 + emphasis * 0.22),
                    lineWidth: 0.7 + emphasis * 0.8
                )
        }
        .scaleEffect(scaleValue, anchor: .bottom)
        .overlay(alignment: .bottom) {
            RemoteThumbnailView(
                item: item,
                service: service,
                size: CGSize(width: 360, height: 260),
                reloadVersion: thumbnailReloadVersion
            )
            .frame(
                width: baseWidth * scaleValue,
                height: reflectionHeight * scaleValue
            )
            .scaleEffect(x: 1, y: -1)
            .opacity(0.17 + emphasis * 0.13)
            .blur(radius: 0.45)
            .mask {
                LinearGradient(
                    colors: [.white.opacity(0.68), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .offset(y: reflectionHeight * scaleValue + 2)
            .allowsHitTesting(false)
        }
        .rotation3DEffect(
            .degrees(rotation(for: distance)),
            axis: (x: 0, y: 1, z: 0),
            anchor: .bottom,
            perspective: 0.62
        )
        .offset(
            x: distance * step,
            y: 0
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
        withAnimation(.smooth(duration: 0.22)) {
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
        withAnimation(.smooth(duration: 0.2)) {
            selectedIndex = next
            scrollPosition = CGFloat(next)
        }
    }

    private func cardStep(for width: CGFloat) -> CGFloat {
        min(max(width * 0.075, 48), 70)
    }

    private func clampedPosition(_ position: CGFloat) -> CGFloat {
        min(max(position, 0), CGFloat(max(items.count - 1, 0)))
    }

    private func scale(for distance: CGFloat) -> CGFloat {
        max(0.34, 1 - distance * 0.13)
    }

    private func opacity(for distance: CGFloat) -> Double {
        if distance > 5 {
            return max(0, Double(6 - distance) * 0.425)
        }
        return max(0.16, 1 - Double(distance) * 0.115)
    }

    private func rotation(for distance: CGFloat) -> Double {
        let clamped = min(max(distance, -1), 1)
        return -Double(clamped) * 58
    }
}
