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

    static func shouldBeginReordering(translation: CGSize) -> Bool {
        abs(translation.width) >= reorderActivationDistance
            && abs(translation.width) > abs(translation.height)
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
    @State private var favoritePendingRemovalID: FavoriteItem.ID?
    @State private var tileFrames: [FavoriteItem.ID: CGRect] = [:]
    @State private var shelfWidth: CGFloat = 0
    @State private var dragState: FavoriteShelfDragState?
    @State private var autoScrollDirection = 0

    let openFavorite: (FavoriteItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if favoriteStore.items.isEmpty {
                Text("파일이나 폴더를 길게 눌러 즐겨찾기에 추가하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollViewReader { scrollProxy in
                    ZStack(alignment: .topLeading) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 9) {
                                ForEach(favoriteStore.items) { favorite in
                                    FavoriteShelfTile(
                                        favorite: favorite,
                                        open: { openFavorite(favorite) },
                                        isBeingReordered: dragState?.favorite.id == favorite.id,
                                        isRemovalPresented: Binding(
                                            get: { favoritePendingRemovalID == favorite.id },
                                            set: { isPresented in
                                                if !isPresented,
                                                   favoritePendingRemovalID == favorite.id {
                                                    favoritePendingRemovalID = nil
                                                }
                                            }
                                        ),
                                        remove: {
                                            favoriteStore.remove(id: favorite.id)
                                            favoritePendingRemovalID = nil
                                        },
                                        longPressChanged: { value in
                                            updateLongPress(favorite: favorite, value: value)
                                        },
                                        interactionEnded: { translation in
                                            finishInteraction(
                                                favoriteID: favorite.id,
                                                translation: translation
                                            )
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

                        if let dragState {
                            FavoriteCell(favorite: dragState.favorite, side: 52)
                                .frame(width: 56)
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
        .padding(.vertical, 4)
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
            favoritePendingRemovalID = nil
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
            favoritePendingRemovalID = favoriteID
        }
    }
}

private struct FavoriteShelfTile: View {
    let favorite: FavoriteItem
    let open: () -> Void
    let isBeingReordered: Bool
    @Binding var isRemovalPresented: Bool
    let remove: () -> Void
    let longPressChanged: (FavoriteShelfLongPressValue) -> Void
    let interactionEnded: (CGSize) -> Void
    @State private var suppressNextOpen = false

    var body: some View {
        FavoriteCell(favorite: favorite, side: 52)
            .frame(width: 56)
            .contentShape(Rectangle())
            .shadow(
                color: isRemovalPresented ? .black.opacity(0.18) : .clear,
                radius: 5,
                y: 3
            )
            .opacity(isBeingReordered ? 0 : 1)
            .background {
                FavoriteShelfLongPressRecognizer(
                    changed: { value in
                        suppressNextOpen = true
                        longPressChanged(value)
                    },
                    ended: { value, completed in
                        if completed {
                            interactionEnded(value.translation)
                        }
                        releaseOpenSuppression()
                    }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .onTapGesture {
                guard !suppressNextOpen else { return }
                open()
            }
            .popover(
                isPresented: $isRemovalPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                FavoriteRemovalPopover(
                    favoriteName: favorite.name,
                    cancel: { isRemovalPresented = false },
                    remove: remove
                )
                .presentationCompactAdaptation(.popover)
            }
            .animation(.easeOut(duration: 0.16), value: isRemovalPresented)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                open()
            }
            .accessibilityAction(named: Text("즐겨찾기에서 제거")) {
                interactionEnded(.zero)
            }
    }

    private func releaseOpenSuppression() {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            suppressNextOpen = false
        }
    }
}

private struct FavoriteShelfLongPressRecognizer: UIViewRepresentable {
    let changed: (FavoriteShelfLongPressValue) -> Void
    let ended: (FavoriteShelfLongPressValue, Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(changed: changed, ended: ended)
    }

    func makeUIView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        context.coordinator.attachmentView = view
        return view
    }

    func updateUIView(_ uiView: AttachmentView, context: Context) {
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
            recognizer.allowableMovement = 18
            recognizer.cancelsTouchesInView = false
            recognizer.delaysTouchesBegan = false
            recognizer.delegate = self
            return recognizer
        }()

        init(
            changed: @escaping (FavoriteShelfLongPressValue) -> Void,
            ended: @escaping (FavoriteShelfLongPressValue, Bool) -> Void
        ) {
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

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldReceive touch: UITouch
        ) -> Bool {
            guard let attachmentView else { return false }
            return attachmentView.bounds.contains(touch.location(in: attachmentView))
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

private struct FavoriteRemovalPopover: View {
    let favoriteName: String
    let cancel: () -> Void
    let remove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "star.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.72))
                    .frame(width: 30, height: 30)
                    .background(.primary.opacity(0.07), in: Circle())
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text("즐겨찾기에서 제거")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.88))

                    Text(favoriteName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider()
                .opacity(0.45)

            HStack(spacing: 8) {
                Button("유지", role: .cancel, action: cancel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary.opacity(0.68))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.primary.opacity(0.06), in: Capsule())

                Button("제거", role: .destructive, action: remove)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(.red.opacity(0.11), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .frame(width: 224)
        .presentationBackground(.ultraThinMaterial)
        .presentationCornerRadius(20)
    }
}

struct FavoriteListView: View {
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @State private var favoritePendingRemoval: FavoriteItem?

    private let columns = Array(
        repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
        count: 4
    )

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
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(favoriteStore.items) { favorite in
                            NavigationLink {
                                FavoriteDestinationView(favorite: favorite)
                            } label: {
                                FavoriteCell(favorite: favorite, side: 72)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("즐겨찾기에서 제거…", systemImage: "star.slash", role: .destructive) {
                                    favoritePendingRemoval = favorite
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
        }
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

    let favorite: FavoriteItem
    let side: CGFloat

    var body: some View {
        VStack(spacing: 6) {
            Group {
                if let service {
                    if favorite.remoteItem.isDirectory {
                        FavoriteFolderMosaicView(
                            folder: favorite.remoteItem,
                            service: service,
                            side: side
                        )
                    } else {
                        RemoteThumbnailView(
                            item: favorite.remoteItem,
                            service: service,
                            size: CGSize(width: side, height: side)
                        )
                    }
                } else {
                    Image(systemName: favorite.remoteItem.systemImage)
                        .font(.system(size: side * 0.38))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: side, height: side)
            .background(SkyBreezeTheme.thumbnailSurface, in: RoundedRectangle(cornerRadius: 11))
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(SkyBreezeTheme.thumbnailBorder, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .topTrailing) {
                if let connectionKind {
                    FavoriteConnectionBadge(kind: connectionKind, side: side)
                        .padding(4)
                }
            }

            Text(favorite.name)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: max(side, 56))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var connection: RemoteConnection? {
        connectionStore.connections.first { $0.id == favorite.connectionID }
    }

    private var connectionKind: ConnectionKind? {
        connection?.kind
    }

    private var accessibilityLabel: String {
        guard let connectionKind else { return favorite.name }
        return "\(favorite.name), \(connectionKind.dashboardSourceName)"
    }

    private var service: (any RemoteFileService)? {
        guard let connection,
              let credential = try? connectionStore.credential(for: connection) else {
            return nil
        }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

private struct FavoriteFolderMosaicView: View {
    let folder: RemoteFileItem
    let service: any RemoteFileService
    let side: CGFloat

    @State private var items: [RemoteFileItem] = []
    @State private var isLoading = true

    private let spacing: CGFloat = 1

    var body: some View {
        Group {
            if items.isEmpty {
                Image(systemName: "folder.fill")
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
                                size: CGSize(width: cellSide, height: cellSide),
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
}

private struct FavoriteConnectionBadge: View {
    let kind: ConnectionKind
    let side: CGFloat

    var body: some View {
        Text(kind.favoriteBadgeLetter)
            .font(.system(size: max(8, side * 0.15), weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: max(15, side * 0.25), height: max(15, side * 0.25))
            .background(kind.favoriteBadgeColor.opacity(0.88), in: Circle())
            .accessibilityHidden(true)
    }
}

private extension ConnectionKind {
    var favoriteBadgeLetter: String {
        switch self {
        case .synology: "N"
        case .sftp: "S"
        case .smb: "M"
        case .webDAV: "W"
        case .ftp: "F"
        }
    }

    var favoriteBadgeColor: Color {
        ThemeServicePalette.color(
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
        connectionStore.connections.first { $0.id == favorite.connectionID }
    }

    private var service: (any RemoteFileService)? {
        guard let connection,
              let credential = try? connectionStore.credential(for: connection) else {
            return nil
        }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}
