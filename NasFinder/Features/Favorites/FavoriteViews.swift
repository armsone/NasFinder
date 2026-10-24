import SwiftUI
import UIKit

private struct FavoriteShelfTileFramesKey: PreferenceKey {
    static let defaultValue: [FavoriteItem.ID: CGRect] = [:]

    static func reduce(
        value: inout [FavoriteItem.ID: CGRect],
        nextValue: () -> [FavoriteItem.ID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct FavoriteShelfWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct FavoriteShelfDragState {
    let favorite: FavoriteItem
    let centerOffset: CGSize
    var location: CGPoint
}

struct FavoriteShelfLongPressValue: Equatable {
    let location: CGPoint
    let translation: CGSize
}

enum FavoriteShelfInteractionPolicy {
    static let reorderActivationDistance: CGFloat = 12
    /// 홀드가 인식되기 전에 이 거리 이상 움직이면 길게 누르기가 실패하고 선반은 그대로 스크롤된다.
    static let holdAllowableMovement: CGFloat = 10

    static func shouldBeginReordering(translation: CGSize) -> Bool {
        hypot(translation.width, translation.height) >= reorderActivationDistance
    }
}

enum FavoriteFolderMosaicPolicy {
    static let maximumItemCount = 9

    static func candidates(from items: [RemoteFileItem]) -> [RemoteFileItem] {
        Array(
            items
                .filter { !$0.isDirectory && ($0.isImage || $0.isVideo) }
                .prefix(maximumItemCount)
        )
    }
}

/// Favorite folder cells try the same Mac helper-generated folder Super
/// Thumbnail sheet the browser uses before falling back to the direct-child
/// mosaic, and only show the plain folder icon once both are unavailable.
enum FavoriteFolderThumbnailDisplayPolicy {
    enum Content: Equatable {
        case sheetImage
        case mosaicFallback
        case loadingPlaceholder
    }

    static func content(hasSheetImage: Bool, sheetLookupFinished: Bool) -> Content {
        if hasSheetImage { return .sheetImage }
        if sheetLookupFinished { return .mosaicFallback }
        return .loadingPlaceholder
    }
}

private actor FavoriteFolderMosaicCache {
    static let shared = FavoriteFolderMosaicCache()

    private struct Entry {
        let items: [RemoteFileItem]
        let storedAt: Date
    }

    private let lifetime: TimeInterval = 60
    private var entriesByFolderID: [String: Entry] = [:]

    func items(for folder: RemoteFileItem) -> [RemoteFileItem]? {
        guard let entry = entriesByFolderID[folder.id],
              Date().timeIntervalSince(entry.storedAt) < lifetime else {
            entriesByFolderID.removeValue(forKey: folder.id)
            return nil
        }
        return entry.items
    }

    func store(_ items: [RemoteFileItem], for folder: RemoteFileItem) {
        entriesByFolderID[folder.id] = Entry(items: items, storedAt: Date())
    }
}

struct FavoriteShelfView: View {
    private static let edgeScrollInset: CGFloat = 34

    @EnvironmentObject private var favoriteStore: FavoriteStore
    /// 홀드할 때 잡은 즐겨찾기(원래 ID·연결·경로). 작업 호스트가 끝날 때까지 바뀌지 않는다.
    @State private var actionFavorite: FavoriteItem?
    /// 타일이 사라졌을 때(즐겨찾기 해제 등) 쓰는, 홀드할 때의 타일 자리.
    @State private var actionAnchor = CGRect.zero
    @State private var tileFrames: [FavoriteItem.ID: CGRect] = [:]
    @State private var shelfWidth: CGFloat = 0
    @State private var dragState: FavoriteShelfDragState?
    @State private var autoScrollDirection = 0

    let openFavorite: (FavoriteItem) -> Void
    /// 즐겨찾기 커버 한 변. 기본값은 기존 크기다.
    var tileSide: CGFloat = ui(52)
    /// Porcelain 홈 타일 폭(폰·패드 68, Mac 88). 커버는 그대로, 커버·이름은 이 폭 안에서 가운데 정렬.
    var captionWidth: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: ui(12)) {
            if favoriteStore.items.isEmpty {
                Text("길게 눌러 즐겨찾기에 추가하세요.")
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, ui(8))
            } else {
                ScrollViewReader { scrollProxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 8) {
                                ForEach(favoriteStore.items) { favorite in
                                    FavoriteShelfTile(
                                        favorite: favorite,
                                        side: tileSide,
                                        captionWidth: captionWidth,
                                        open: { openFavorite(favorite) },
                                        isBeingReordered: dragState?.favorite.id == favorite.id,
                                        remove: { favoriteStore.remove(id: favorite.id) },
                                        showActions: { showActions(for: favorite.id) },
                                        longPressChanged: { value in
                                            updateLongPress(favorite: favorite, value: value)
                                        },
                                        interactionEnded: { translation in
                                            finishInteraction(
                                                favoriteID: favorite.id,
                                                translation: translation
                                            )
                                        },
                                        interactionCancelled: {
                                            dragState = nil
                                            autoScrollDirection = 0
                                        }
                                    )
                                    .id(favorite.id)
                                    .background {
                                        GeometryReader { geometry in
                                            Color.clear.preference(
                                                key: FavoriteShelfTileFramesKey.self,
                                                value: [
                                                    favorite.id: geometry.frame(
                                                        in: .named("favoriteShelf")
                                                    )
                                                ]
                                            )
                                        }
                                    }
                                }
                            }
                        }
                        .scrollClipDisabled()
                        .scrollDisabled(dragState != nil)

                        if let dragState {
                            FavoriteCell(favorite: dragState.favorite, side: tileSide, captionWidth: captionWidth)
                                .frame(width: max(tileSide + ui(4), captionWidth ?? 0))
                                .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                                .position(
                                    x: dragState.location.x + dragState.centerOffset.width,
                                    y: dragState.location.y + dragState.centerOffset.height
                                )
                                .allowsHitTesting(false)
                                .zIndex(2)
                        }
                    }
                    .coordinateSpace(name: "favoriteShelf")
                    .background {
                        GeometryReader { geometry in
                            Color.clear.preference(
                                key: FavoriteShelfWidthKey.self,
                                value: geometry.size.width
                            )
                        }
                    }
                    .onPreferenceChange(FavoriteShelfTileFramesKey.self) { tileFrames = $0 }
                    .onPreferenceChange(FavoriteShelfWidthKey.self) { shelfWidth = $0 }
                    .task(id: autoScrollDirection) {
                        await autoScroll(
                            using: scrollProxy,
                            direction: autoScrollDirection
                        )
                    }
                    .onDisappear {
                        dragState = nil
                        autoScrollDirection = 0
                    }
                }
            }
        }
        // 홈을 그대로 둔 채 누른 타일 자리에 작업 패널을 띄운다. 화면 이동·시트·브라우저 화면이 없다.
        // 선반의 유일한 자식이 원점에 있어 타일 좌표("favoriteShelf")를 그대로 쓴다.
        // 즐겨찾기가 모두 사라져도 진행 중인 후속 작업이 끝날 때까지 호스트는 남는다.
        .overlay(alignment: .topLeading) {
            if let actionFavorite {
                FavoriteHomeActionHost(
                    favorite: actionFavorite,
                    anchor: tileFrames[actionFavorite.id] ?? actionAnchor,
                    finish: {
                        FileBrowserInteractionCoordinator.logFavoriteActionHost("host finished")
                        self.actionFavorite = nil
                    }
                )
                .id(actionFavorite.id)
            }
        }
        .padding(.vertical, ui(4))
    }

    /// 길게 눌렀다 뗀 즐겨찾기의 작업 호스트를 연다. 앞 호스트가 아직 후속 작업을 가지고 있으면
    /// 그 작업을 끊지 않도록 새로 열지 않는다.
    private func showActions(for favoriteID: FavoriteItem.ID) {
        guard actionFavorite == nil,
              let favorite = favoriteStore.items.first(where: { $0.id == favoriteID }) else {
            FileBrowserInteractionCoordinator.logFavoriteActionHost(
                actionFavorite == nil ? "show ignored: favorite missing" : "show ignored: host busy"
            )
            return
        }
        actionAnchor = tileFrames[favoriteID] ?? .zero
        FileBrowserInteractionCoordinator.logFavoriteActionHost(
            "show: anchor \(tileFrames[favoriteID] == nil ? "missing" : "tile")"
        )
        actionFavorite = favorite
    }

    private func updateLongPress(
        favorite: FavoriteItem,
        value: FavoriteShelfLongPressValue
    ) {
        guard let frame = tileFrames[favorite.id] else { return }
        let location = CGPoint(
            x: frame.minX + value.location.x,
            y: frame.minY + value.location.y
        )

        if dragState == nil {
            guard FavoriteShelfInteractionPolicy.shouldBeginReordering(
                translation: value.translation
            ) else {
                return
            }
            dragState = FavoriteShelfDragState(
                favorite: favorite,
                centerOffset: CGSize(
                    width: frame.width / 2 - value.location.x + value.translation.width,
                    height: frame.height / 2 - value.location.y + value.translation.height
                ),
                location: location
            )
        } else {
            guard dragState?.favorite.id == favorite.id else { return }
            dragState?.location = location
        }

        updateAutoScrollDirection(at: location.x)
        moveDraggedFavoriteToward(locationX: location.x)
    }

    private func moveDraggedFavoriteToward(locationX: CGFloat) {
        guard let draggedID = dragState?.favorite.id,
              let destinationID = tileFrames
                .filter({ $0.key != draggedID })
                .min(by: {
                    abs($0.value.midX - locationX) < abs($1.value.midX - locationX)
                })?
                .key,
              let source = favoriteStore.items.firstIndex(where: { $0.id == draggedID }),
              let destination = favoriteStore.items.firstIndex(where: {
                  $0.id == destinationID
              }),
              source != destination else {
            return
        }

        let sourceFrame = tileFrames[draggedID]
        let destinationFrame = tileFrames[destinationID]
        guard crossedDestinationCenter(
            locationX: locationX,
            source: source,
            destination: destination,
            sourceFrame: sourceFrame,
            destinationFrame: destinationFrame
        ) else {
            return
        }

        withAnimation(.easeOut(duration: 0.12)) {
            favoriteStore.move(id: draggedID, to: destination)
        }
    }

    private func crossedDestinationCenter(
        locationX: CGFloat,
        source: Int,
        destination: Int,
        sourceFrame: CGRect?,
        destinationFrame: CGRect?
    ) -> Bool {
        guard let destinationFrame else { return false }
        if destination > source {
            return locationX >= destinationFrame.midX
        }
        if destination < source {
            return locationX <= destinationFrame.midX
        }
        return sourceFrame == nil
    }

    private func updateAutoScrollDirection(at locationX: CGFloat) {
        guard shelfWidth > 0 else {
            autoScrollDirection = 0
            return
        }
        if locationX <= Self.edgeScrollInset {
            autoScrollDirection = -1
        } else if locationX >= shelfWidth - Self.edgeScrollInset {
            autoScrollDirection = 1
        } else {
            autoScrollDirection = 0
        }
    }

    @MainActor
    private func autoScroll(using proxy: ScrollViewProxy, direction: Int) async {
        guard direction != 0 else { return }
        while !Task.isCancelled,
              autoScrollDirection == direction,
              let draggedID = dragState?.favorite.id {
            do {
                try await Task.sleep(nanoseconds: 160_000_000)
            } catch {
                return
            }

            guard let source = favoriteStore.items.firstIndex(where: { $0.id == draggedID }) else {
                return
            }
            let destination = source + direction
            guard favoriteStore.items.indices.contains(destination) else { continue }

            withAnimation(.easeOut(duration: 0.14)) {
                favoriteStore.move(id: draggedID, to: destination)
                proxy.scrollTo(
                    draggedID,
                    anchor: direction > 0 ? .trailing : .leading
                )
            }
        }
    }

    private func finishInteraction(
        favoriteID: FavoriteItem.ID,
        translation: CGSize
    ) {
        let wasReordering = dragState?.favorite.id == favoriteID
        dragState = nil
        autoScrollDirection = 0

        if !wasReordering, hypot(translation.width, translation.height) < 12 {
            showActions(for: favoriteID)
        }
    }
}

private struct FavoriteShelfTile: View {
    let favorite: FavoriteItem
    var side: CGFloat = ui(52)
    var captionWidth: CGFloat? = nil
    let open: () -> Void
    let isBeingReordered: Bool
    let remove: () -> Void
    let showActions: () -> Void
    let longPressChanged: (FavoriteShelfLongPressValue) -> Void
    let interactionEnded: (CGSize) -> Void
    let interactionCancelled: () -> Void
    /// 길게 누르기가 인식된 터치 시퀀스의 탭(손 떼기·마우스 버튼 놓기)을 막는 게이트.
    /// 시간 지연이 아니라 recognizer가 .began에서 잠그고 다음 새 터치가 들어올 때만 푼다.
    @State private var openGate = FavoriteShelfLongPressRecognizer.OpenGate()

    var body: some View {
        FavoriteCell(favorite: favorite, side: side, captionWidth: captionWidth)
            .frame(width: max(side + ui(4), captionWidth ?? 0))
            .contentShape(Rectangle())
            .opacity(isBeingReordered ? 0 : 1)
            .background {
                FavoriteShelfLongPressRecognizer(
                    openGate: openGate,
                    changed: { value in
                        longPressChanged(value)
                    },
                    ended: { value, completed in
                        if completed {
                            interactionEnded(value.translation)
                        } else {
                            interactionCancelled()
                        }
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onTapGesture {
                guard !openGate.isLocked else { return }
                open()
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                open()
            }
            .accessibilityAction(named: Text("작업 메뉴")) {
                showActions()
            }
            .accessibilityAction(named: Text("즐겨찾기 해제")) {
                remove()
            }
    }
}

private struct FavoriteShelfLongPressRecognizer: UIViewRepresentable {
    /// 타일과 recognizer가 공유하는 동기 플래그. @State 값 전파·SwiftUI 탭 콜백 순서와 무관하게
    /// 같은 터치 시퀀스 안에서는 항상 잠긴 값을 읽는다.
    @MainActor
    final class OpenGate {
        fileprivate(set) var isLocked = false
    }

    let openGate: OpenGate
    let changed: (FavoriteShelfLongPressValue) -> Void
    let ended: (FavoriteShelfLongPressValue, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(openGate: openGate, changed: changed, ended: ended)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.attachmentView = view
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
        context.coordinator.openGate = openGate
        context.coordinator.changed = changed
        context.coordinator.ended = ended
        context.coordinator.attachIfNeeded()
    }

    static func dismantleUIView(_ uiView: AttachmentView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class AttachmentView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.attachIfNeeded()
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var openGate: OpenGate
        var changed: (FavoriteShelfLongPressValue) -> Void
        var ended: (FavoriteShelfLongPressValue, Bool) -> Void
        weak var attachmentView: UIView?
        weak var attachedWindow: UIWindow?
        private var initialLocation = CGPoint.zero

        private lazy var recognizer: UILongPressGestureRecognizer = {
            let recognizer = UILongPressGestureRecognizer(
                target: self,
                action: #selector(handleLongPress(_:))
            )
            recognizer.minimumPressDuration = 0.55
            recognizer.allowableMovement = FavoriteShelfInteractionPolicy.holdAllowableMovement
            // 인식 순간 UIKit이 뷰로 가던 터치를 취소해 SwiftUI 탭이 손 떼기/버튼 놓기를 클릭으로 받지 않게 한다.
            // 다른 recognizer(가로 ScrollView pan)는 영향이 없고 아래 동시 인식 허용으로 스크롤이 유지된다.
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            // 손가락(direct)과 Mac 주 마우스 버튼·iPad 트랙패드(indirectPointer) 모두 같은 경로로 받는다.
            // buttonMaskRequired 기본값(.primary)이라 보조 클릭은 홀드로 인식하지 않는다.
            recognizer.allowedTouchTypes = [
                UITouch.TouchType.direct,
                .indirectPointer,
                .pencil
            ].map { NSNumber(value: $0.rawValue) }
            recognizer.delegate = self
            return recognizer
        }()

        init(
            openGate: OpenGate,
            changed: @escaping (FavoriteShelfLongPressValue) -> Void,
            ended: @escaping (FavoriteShelfLongPressValue, Bool) -> Void
        ) {
            self.openGate = openGate
            self.changed = changed
            self.ended = ended
        }

        func attachIfNeeded() {
            guard let window = attachmentView?.window else {
                detach()
                return
            }
            guard attachedWindow !== window else { return }
            detach()
            window.addGestureRecognizer(recognizer)
            attachedWindow = window
        }

        func detach() {
            attachedWindow?.removeGestureRecognizer(recognizer)
            attachedWindow = nil
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard let attachmentView else { return }
            let location = recognizer.location(in: attachmentView)

            switch recognizer.state {
            case .began:
                // 탭 콜백보다 먼저, 인식 시점에 동기적으로 잠근다. ended/cancelled/failed에서는 풀지 않는다.
                openGate.isLocked = true
                initialLocation = location
                changed(value(at: location))
            case .changed:
                changed(value(at: location))
            case .ended:
                ended(value(at: location), true)
            case .cancelled, .failed:
                ended(value(at: location), false)
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let attachmentView else { return false }
            return attachmentView.bounds.contains(gestureRecognizer.location(in: attachmentView))
        }

        /// 윈도우 단위 길게 누르기가 가로 ScrollView의 pan을 막지 않도록 동시 인식을 허용한다.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let attachmentView,
                  attachmentView.bounds.contains(touch.location(in: attachmentView)) else {
                return false
            }
            // shouldReceive는 새 터치가 들어올 때만 불린다. 이 타일에서 새 터치 시퀀스가 시작될 때만
            // 게이트를 풀고, 이미 인식된 홀드가 진행 중이면(.began/.changed) 풀지 않아 그 손 떼기는 계속 막힌다.
            if recognizer.state == .possible {
                openGate.isLocked = false
            }
            return true
        }

        private func value(at location: CGPoint) -> FavoriteShelfLongPressValue {
            FavoriteShelfLongPressValue(
                location: location,
                translation: CGSize(
                    width: location.x - initialLocation.x,
                    height: location.y - initialLocation.y
                )
            )
        }
    }
}

/// 즐겨찾기를 길게 눌렀다 떼면 홈 위, 누른 타일 자리에 기존 항목 작업 패널을 띄우는 호스트.
/// 화면 이동·브라우저 화면·상위 폴더 시트 없이 홈을 그대로 둔다. 연결과 서비스는 홀드할 때 잡은
/// 즐겨찾기의 연결로 한 번만 만들어 이 호스트가 끝날 때까지 가지며, 메인 브라우저의 선택·경로와 무관하다.
/// 상위 폴더를 확인할 수 없으면(루트·연결 없음·이동·삭제·로드 실패) 파일 작업 없이 안내와 즐겨찾기 해제만 띄운다.
private struct FavoriteHomeActionHost: View {
    private struct Context {
        let connection: RemoteConnection
        let service: any RemoteFileService
    }

    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    let favorite: FavoriteItem
    let anchor: CGRect
    let finish: @MainActor () -> Void
    @State private var context: Context?
    @State private var failureMessage: String?
    @State private var showsFailure = false

    /// 루트 폴더 즐겨찾기는 상위 폴더가 없어 삭제·이름 변경·이동 같은 작업 패널을 만들지 않는다.
    private var isRootFavorite: Bool {
        let trimmed = favorite.path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "/" || trimmed == "."
    }

    private var parentPath: String {
        let parent = (favorite.path as NSString).deletingLastPathComponent
        return parent.isEmpty ? "/" : parent
    }

    var body: some View {
        // 처음에는 context·failureMessage가 모두 nil이다. 빈 Group에는 onAppear를 받을 자식이 없어
        // prepare가 불리지 않았으므로, 항상 있는 투명 바탕을 둔 ZStack에 onAppear를 건다.
        ZStack(alignment: .topLeading) {
            Color.clear
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            if let failureMessage {
                failureAnchor(failureMessage)
            } else if let context {
                FileBrowserView(
                    connection: context.connection,
                    path: parentPath,
                    service: context.service,
                    title: favorite.name,
                    favoriteActionHost: FileBrowserView.FavoriteActionHost(
                        favoriteID: favorite.id,
                        snapshot: favorite.remoteItem,
                        anchor: anchor,
                        unfavorite: { favoriteStore.remove(id: favorite.id) },
                        resolutionFailed: { failureMessage = $0 },
                        finished: finish
                    )
                )
            }
        }
        .onAppear(perform: prepare)
    }

    private func prepare() {
        guard context == nil, failureMessage == nil else { return }
        FileBrowserInteractionCoordinator.logFavoriteActionHost("host prepare")
        guard !isRootFavorite else {
            FileBrowserInteractionCoordinator.logFavoriteActionHost("host failure: root")
            failureMessage = "루트 폴더는 상위 폴더가 없어 파일 작업을 할 수 없습니다. 즐겨찾기 해제만 가능합니다."
            return
        }
        if favorite.connectionID == LocalInboxFileService.connectionID {
            // PhoneHard is on this device and is not one of the saved connections.
            FileBrowserInteractionCoordinator.logFavoriteActionHost("host context: phone hard")
            context = Context(
                connection: LocalInboxFileService.phoneHardConnection,
                service: LocalInboxFileService()
            )
            return
        }
        guard let connection = connectionStore.connections.first(where: {
                  $0.id == favorite.connectionID
              }),
              let credential = try? connectionStore.credential(for: connection) else {
            FileBrowserInteractionCoordinator.logFavoriteActionHost("host failure: connection")
            failureMessage = "이 항목의 네트워크 연결이 삭제되었거나 로그인 정보가 없습니다."
            return
        }
        FileBrowserInteractionCoordinator.logFavoriteActionHost("host context: remote")
        context = Context(
            connection: connection,
            service: RemoteFileServiceFactory.make(connection: connection, credential: credential)
        )
    }

    private func failureAnchor(_ message: String) -> some View {
        Color.clear
            .frame(width: max(anchor.width, 1), height: max(anchor.height, 1))
            .popover(isPresented: $showsFailure, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                VStack(alignment: .leading, spacing: ui(10)) {
                    Text(favorite.name)
                        .font(.ui(.subheadline))
                        .lineLimit(2)
                    Text(message)
                        .font(.ui(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: ui(12)) {
                        Button(role: .destructive) {
                            favoriteStore.remove(id: favorite.id)
                            showsFailure = false
                        } label: {
                            Label("즐겨찾기 해제", interfaceSystemImage: "star.slash")
                        }
                        Spacer(minLength: 0)
                        Button("닫기") { showsFailure = false }
                    }
                    .font(.ui(.subheadline))
                }
                .padding(ui(16))
                .frame(idealWidth: ui(300), maxWidth: ui(300))
                .presentationCompactAdaptation(.popover)
            }
            .position(x: anchor.midX, y: anchor.midY)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityHidden(true)
            .onAppear { showsFailure = true }
            .onChange(of: showsFailure) { _, isShowing in
                if !isShowing { finish() }
            }
    }
}

struct FavoriteListView: View {
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var favoritePendingRemoval: FavoriteItem?

    private var columns: [GridItem] {
        let count: Int
        if dynamicTypeSize.isAccessibilitySize {
            count = 2
        } else if horizontalSizeClass == .regular {
            count = 6
        } else {
            count = 3
        }
        return Array(
            repeating: GridItem(.flexible(), spacing: ui(12), alignment: .top),
            count: count
        )
    }

    var body: some View {
        Group {
            if favoriteStore.items.isEmpty {
                ContentUnavailableView(
                    "즐겨찾기가 없습니다",
                    systemImage: "star",
                    description: Text("원격 파일이나 폴더를 길게 눌러 추가할 수 있습니다.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: ui(18)) {
                        ForEach(favoriteStore.items) { favorite in
                            NavigationLink {
                                FavoriteDestinationView(favorite: favorite)
                            } label: {
                                FavoriteCell(favorite: favorite, side: ui(72))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                let position = favoriteStore.items.firstIndex { $0.id == favorite.id }
                                Section("순서") {
                                    Button("앞으로 이동", interfaceSystemImage: "arrow.up") {
                                        if let position { favoriteStore.move(id: favorite.id, to: position - 1) }
                                    }
                                    .disabled((position ?? 0) == 0)
                                    Button("뒤로 이동", interfaceSystemImage: "arrow.down") {
                                        if let position { favoriteStore.move(id: favorite.id, to: position + 1) }
                                    }
                                    .disabled(position == nil || position == favoriteStore.items.count - 1)
                                }
                                if favorite.isPrivate == true {
                                    Button("공개로 전환", interfaceSystemImage: "eye") { favoriteStore.setPrivate(id: favorite.id, false) }
                                } else {
                                    Button("비공개로 전환", interfaceSystemImage: "eye.slash") { favoriteStore.setPrivate(id: favorite.id, true) }
                                }
                                Button("즐겨찾기에서 제거…", interfaceSystemImage: "star.slash", role: .destructive) {
                                    favoritePendingRemoval = favorite
                                }
                            }
                        }
                    }
                    .padding(ui(16))
                }
            }
        }
        .background(SkyBreezeBackground())
        .navigationTitle("즐겨찾기")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "즐겨찾기에서 제거할까요?",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: favoritePendingRemoval
        ) { favorite in
            Button("제거", role: .destructive) {
                favoriteStore.remove(id: favorite.id)
                favoritePendingRemoval = nil
            }
            Button("취소", role: .cancel) {
                favoritePendingRemoval = nil
            }
        } message: { favorite in
            Text("‘\(favorite.name)’ 항목을 즐겨찾기에서 제거합니다.")
        }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { favoritePendingRemoval != nil },
            set: { if !$0 { favoritePendingRemoval = nil } }
        )
    }
}

private struct FavoriteCell: View {
    @EnvironmentObject private var connectionStore: ConnectionStore

    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    let favorite: FavoriteItem
    let side: CGFloat
    /// Porcelain 타일 폭. 없으면 커버 폭과 같다. 긴 이름 때문에 넓히지 않는다.
    var captionWidth: CGFloat? = nil

    /// 6개 테마 모두 같은 승인안 셀을 쓴다.
    private var isPorcelain: Bool { true }

    var body: some View {
        if isPorcelain {
            porcelainBody
        } else {
            legacyBody
        }
    }

    /// 6개 테마 공통(승인 보드 01): 테두리·서비스 배지 없는 커버, 아래에 순수 이름(두 줄까지 예약). 커버·이름 모두 가운데 정렬.
    private var porcelainBody: some View {
        VStack(alignment: .center, spacing: 5) {
            cover
                .frame(width: side, height: side)
                .background(SkyBreezeTheme.thumbnailSurface)
                .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.coverCorner, style: .continuous))

            Text(favorite.name)
                .porcelainFont(.favorite)
                .foregroundStyle(PorcelainMetrics.graphite)
                // 이름이 한 줄이어도 두 줄 높이를 잡아 선반의 커버·이름 줄을 맞춘다.
                .multilineTextAlignment(.center)
                .lineLimit(2, reservesSpace: true)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: max(side, captionWidth ?? 0), alignment: .center)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var cover: some View {
        coverContent
            .environment(\.remoteThumbnailFillsFrame, true)
    }

    @ViewBuilder
    private var coverContent: some View {
        if let service {
            if favorite.remoteItem.isDirectory {
                FavoriteFolderThumbnailView(
                    folder: favorite.remoteItem,
                    service: service,
                    side: side
                )
            } else {
                RemoteThumbnailView(
                    item: favorite.remoteItem,
                    service: service,
                    size: CGSize(width: side / MacUIScale.factor, height: side / MacUIScale.factor)
                )
            }
        } else {
            Image(interfaceSystemName: favorite.remoteItem.systemImage, pointSize: side * 0.38)
                .font(.system(size: side * 0.38))
                .foregroundStyle(.secondary)
        }
    }

    private var legacyBody: some View {
        VStack(spacing: ui(6)) {
            Group {
                if let service {
                    if favorite.remoteItem.isDirectory {
                        FavoriteFolderThumbnailView(
                            folder: favorite.remoteItem,
                            service: service,
                            side: side
                        )
                    } else {
                        RemoteThumbnailView(
                            item: favorite.remoteItem,
                            service: service,
                            size: CGSize(width: side / MacUIScale.factor, height: side / MacUIScale.factor)
                        )
                    }
                } else {
                    Image(interfaceSystemName: favorite.remoteItem.systemImage, pointSize: side * 0.38)
                        .font(.system(size: side * 0.38))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .background(SkyBreezeTheme.thumbnailSurface, in: RoundedRectangle(cornerRadius: ui(11)))
            .overlay {
                RoundedRectangle(cornerRadius: ui(11))
                    .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: ui(11)))
            .overlay(alignment: .topTrailing) {
                if let connectionKind {
                    FavoriteConnectionBadge(kind: connectionKind, side: side)
                        .padding(ui(4))
                }
            }

            Text(favorite.name)
                .font(.ui(.caption2))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: max(side, ui(56)))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var connection: RemoteConnection? {
        // PhoneHard is on this device and is not one of the saved connections.
        if favorite.connectionID == LocalInboxFileService.connectionID {
            return LocalInboxFileService.phoneHardConnection
        }
        return connectionStore.connections.first { $0.id == favorite.connectionID }
    }

    /// PhoneHard carries no service badge: it is not a NAS or any other network service.
    private var connectionKind: ConnectionKind? {
        favorite.connectionID == LocalInboxFileService.connectionID ? nil : connection?.kind
    }

    private var accessibilityLabel: String {
        if favorite.connectionID == LocalInboxFileService.connectionID {
            return "\(favorite.name), 폰하드"
        }
        guard let connectionKind else { return favorite.name }
        return "\(favorite.name), \(connectionKind.dashboardSourceName)"
    }

    private var service: (any RemoteFileService)? {
        if favorite.connectionID == LocalInboxFileService.connectionID {
            return LocalInboxFileService()
        }
        guard let connection,
              let credential = try? connectionStore.credential(for: connection) else {
            return nil
        }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

/// Prefers the folder Super Thumbnail sheet discovered via the shared
/// `RemoteThumbnailLoader`/`SuperThumbnailVault` lookup used by the browser.
/// Falls back to the existing direct-child mosaic only once that lookup
/// finishes without a usable sheet (missing, indexed empty, or an error), and
/// falls back to the plain folder icon only once the mosaic is also empty.
private struct FavoriteFolderThumbnailView: View {
    let folder: RemoteFileItem
    let service: any RemoteFileService
    let side: CGFloat

    @StateObject private var loader = RemoteThumbnailLoader()
    @State private var sheetLookupFinished = false
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        Group {
            switch FavoriteFolderThumbnailDisplayPolicy.content(
                hasSheetImage: loader.image != nil,
                sheetLookupFinished: sheetLookupFinished
            ) {
            case .sheetImage:
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: side, height: side)
                        .clipped()
                }
            case .mosaicFallback:
                FavoriteFolderMosaicView(
                    folder: folder,
                    service: service,
                    side: side
                )
            case .loadingPlaceholder:
                Image(interfaceSystemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.06)
                    .foregroundStyle(SkyBreezeTheme.folderBlue)
                    .overlay {
                        ProgressView()
                            .controlSize(.mini)
                    }
            }
        }
        .frame(width: side, height: side)
        .task(id: folder.id) {
            sheetLookupFinished = false
            await loader.load(
                item: folder,
                service: service,
                size: CGSize(width: side / MacUIScale.factor, height: side / MacUIScale.factor),
                reloadVersion: 0
            )
            sheetLookupFinished = true
        }
        .accessibilityHidden(true)
    }
}

private struct FavoriteFolderMosaicView: View {
    let folder: RemoteFileItem
    let service: any RemoteFileService
    let side: CGFloat

    @Environment(\.remoteThumbnailFillsFrame) private var fillsFrame
    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = true

    private let spacing: CGFloat = 1
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        Group {
            if items.isEmpty {
                Image(interfaceSystemName: "folder.fill")
                    .resizable()
                    .scaledToFit()
                    .padding(side * 0.06)
                    .foregroundStyle(SkyBreezeTheme.folderBlue)
                    .overlay {
                        if isLoading {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
            } else if fillsFrame {
                filledMosaic
            } else {
                let cellSide = (side - spacing * 2) / 3
                LazyVGrid(
                    columns: Array(
                        repeating: GridItem(.fixed(cellSide), spacing: spacing),
                        count: 3
                    ),
                    spacing: spacing
                ) {
                    ForEach(0..<FavoriteFolderMosaicPolicy.maximumItemCount, id: \.self) {
                        index in
                        if items.indices.contains(index) {
                            RemoteThumbnailView(
                                item: items[index],
                                service: service,
                                size: CGSize(
                                    width: cellSide / MacUIScale.factor,
                                    height: cellSide / MacUIScale.factor
                                ),
                                blursSkinToneDominantImage: true
                            )
                            .frame(width: cellSide, height: cellSide)
                        } else {
                            SkyBreezeTheme.folderBlue.opacity(0.08)
                                .frame(width: cellSide, height: cellSide)
                        }
                    }
                }
            }
        }
        .frame(width: side, height: side)
        .task(id: folder.id) {
            if let cached = await FavoriteFolderMosaicCache.shared.items(for: folder) {
                items = cached
                isLoading = false
                return
            }
            do {
                let children = try await service.list(directory: folder.path)
                let candidates = FavoriteFolderMosaicPolicy.candidates(from: children)
                await FavoriteFolderMosaicCache.shared.store(candidates, for: folder)
                items = candidates
            } catch {
                items = []
            }
            isLoading = false
        }
        .accessibilityHidden(true)
    }

    /// Porcelain 정사각 커버: 실제 항목 수만큼만 행을 나눠 커버 전체를 채운다(빈 칸 없음).
    /// 마지막 행은 남은 항목이 폭을 나눠 쓴다. 각 칸은 채워 자른다.
    private var filledMosaic: some View {
        let count = items.count
        let columns = count <= 1 ? 1 : (count <= 4 ? 2 : 3)
        let rows = (count + columns - 1) / columns
        let rowHeight = (side - spacing * CGFloat(rows - 1)) / CGFloat(rows)
        return VStack(spacing: spacing) {
            ForEach(0..<rows, id: \.self) { row in
                let start = row * columns
                let rowItems = Array(items[start..<min(start + columns, count)])
                let cellWidth = (side - spacing * CGFloat(rowItems.count - 1)) / CGFloat(rowItems.count)
                HStack(spacing: spacing) {
                    ForEach(rowItems, id: \.id) { item in
                        RemoteThumbnailView(
                            item: item,
                            service: service,
                            size: CGSize(
                                width: cellWidth / MacUIScale.factor,
                                height: rowHeight / MacUIScale.factor
                            ),
                            blursSkinToneDominantImage: true
                        )
                        .frame(width: cellWidth, height: rowHeight)
                        .clipped()
                    }
                }
            }
        }
    }
}

private struct FavoriteConnectionBadge: View {
    let kind: ConnectionKind
    let side: CGFloat

    var body: some View {
        Text(kind.favoriteBadgeLetter)
            .font(.system(size: max(8, side * 0.15), weight: .bold, design: .rounded))
            .foregroundStyle(kind.favoriteBadgeForegroundColor)
            .frame(width: max(15, side * 0.25), height: max(15, side * 0.25))
            .background(kind.favoriteBadgeColor, in: Circle())
            .overlay {
                Circle()
                    .stroke(SkyBreezeTheme.thumbnailSurface.opacity(0.9), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

private extension ConnectionKind {
    var favoriteBadgeLetter: String {
        ThemeServicePalette.badgeLetter(forServiceIdentifier: rawValue)
    }

    var favoriteBadgeColor: Color {
        ThemeServicePalette.color(
            forServiceIdentifier: rawValue,
            theme: .current
        )
    }

    var favoriteBadgeForegroundColor: Color {
        ThemeServicePalette.foregroundColor(
            forServiceIdentifier: rawValue,
            theme: .current
        )
    }

    var dashboardSourceName: String {
        switch self {
        case .synology: "NAS"
        case .sftp: "SFTP"
        case .smb: "SMB"
        case .webDAV: "WebDAV"
        case .ftp: "FTP"
        case .dropbox: "Dropbox"
        case .oneDrive: "OneDrive"
        case .googleDrive: "Google Drive"
        }
    }
}

struct FavoriteDestinationView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    let favorite: FavoriteItem

    var body: some View {
        Group {
            if let connection, let service {
                if favorite.remoteItem.isDirectory {
                    FileBrowserView(
                        connection: connection,
                        path: favorite.path,
                        service: service,
                        title: favorite.name
                    )
                } else {
                    RemotePreviewView(
                        item: favorite.remoteItem,
                        sequentialItems: [favorite.remoteItem],
                        service: service
                    )
                }
            } else {
                ContentUnavailableView(
                    "연결을 찾을 수 없습니다",
                    systemImage: "externaldrive.badge.xmark",
                    description: Text("이 항목의 네트워크 연결이 삭제되었거나 로그인 정보가 없습니다.")
                )
            }
        }
    }

    private var connection: RemoteConnection? {
        // PhoneHard is on this device and is not one of the saved connections.
        if favorite.connectionID == LocalInboxFileService.connectionID {
            return LocalInboxFileService.phoneHardConnection
        }
        return connectionStore.connections.first { $0.id == favorite.connectionID }
    }

    private var service: (any RemoteFileService)? {
        if favorite.connectionID == LocalInboxFileService.connectionID {
            return LocalInboxFileService()
        }
        guard let connection,
              let credential = try? connectionStore.credential(for: connection) else {
            return nil
        }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

/// 영상 만들기 + 메뉴의 즐겨찾기 선택 화면. 저장된 사진·영상 파일과 폴더만 고를 수 있고,
/// 폴더는 기존 미디어 선택 브라우저로 열며 파일은 같은 반환 경로로 그 항목만 넘긴다.
struct MediaFavoritePickerView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @State private var errorMessage: String?
    /// 연 폴더 즐겨찾기는 push하지 않고 이 화면이 가진다. 뒤로가 상위 영상 만들기 화면을 닫지 않게 한다.
    @State private var openedFolder: FavoriteItem?
    let onPickMedia: ([RemoteFileItem], any RemoteFileService) -> Void

    var body: some View {
        Group {
            if let openedFolder, let connection = connection(for: openedFolder), let service = service(for: connection) {
                MediaSelectionBrowser(connection: connection, rootPath: openedFolder.path, rootTitle: openedFolder.name,
                                      service: service, onExitRoot: { self.openedFolder = nil }, onPickMedia: onPickMedia)
                    .id(openedFolder.id)
            } else if favoriteStore.items.isEmpty {
                ContentUnavailableView(
                    "즐겨찾기가 없습니다",
                    systemImage: "star",
                    description: Text("파일 목록에서 사진·영상이나 폴더를 즐겨찾기에 추가하면 여기에 나타납니다.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: ui(84), maximum: ui(110)), spacing: ui(10), alignment: .top)],
                              alignment: .center, spacing: ui(12)) {
                        ForEach(favoriteStore.items) { favorite in row(favorite) }
                    }.padding(ui(12))
                }
            }
        }
        .navigationTitle("즐겨찾기")
        .navigationBarTitleDisplayMode(.inline)
        .alert("즐겨찾기 알림", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("확인", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @ViewBuilder private func row(_ favorite: FavoriteItem) -> some View {
        let item = favorite.remoteItem
        if item.isDirectory {
            if let connection = connection(for: favorite), service(for: connection) != nil {
                Button { openedFolder = favorite } label: {
                    FavoriteCell(favorite: favorite, side: ui(76))
                }.buttonStyle(.plain)
            } else {
                FavoriteCell(favorite: favorite, side: ui(76)).opacity(0.45)
                    .accessibilityHint("연결을 찾을 수 없거나 로그인 정보가 없습니다")
            }
        } else if item.isTrailerEligible {
            Button { pick(favorite) } label: {
                FavoriteCell(favorite: favorite, side: ui(76))
            }.buttonStyle(.plain)
        } else {
            FavoriteCell(favorite: favorite, side: ui(76)).opacity(0.45)
                .accessibilityHint("사진·영상이 아니라 담을 수 없습니다")
        }
    }

    private func pick(_ favorite: FavoriteItem) {
        guard let connection = connection(for: favorite), let service = service(for: connection) else {
            errorMessage = "\(favorite.name): 연결을 찾을 수 없거나 로그인 정보가 없어 가져올 수 없습니다. 연결을 확인해 주세요."
            return
        }
        onPickMedia([favorite.remoteItem], service)
    }

    private func connection(for favorite: FavoriteItem) -> RemoteConnection? {
        if favorite.connectionID == LocalInboxFileService.connectionID { return LocalInboxFileService.phoneHardConnection }
        return connectionStore.connections.first { $0.id == favorite.connectionID }
    }

    private func service(for connection: RemoteConnection) -> (any RemoteFileService)? {
        if connection.id == LocalInboxFileService.connectionID { return LocalInboxFileService() }
        guard let credential = try? connectionStore.credential(for: connection) else { return nil }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}
