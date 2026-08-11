import SwiftUI

struct FavoriteShelfView: View {
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @State private var favoritePendingRemovalID: FavoriteItem.ID?

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
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 9) {
                        ForEach(favoriteStore.items) { favorite in
                            FavoriteShelfTile(
                                favorite: favorite,
                                open: { openFavorite(favorite) },
                                requestRemoval: {
                                    favoritePendingRemovalID = favorite.id
                                }
                            )
                            .id(favorite.id)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .confirmationDialog(
            "즐겨찾기에서 제거할까요?",
            isPresented: removalConfirmationBinding,
            titleVisibility: .visible,
            presenting: favoritePendingRemoval
        ) { favorite in
            Button("제거", role: .destructive) {
                favoriteStore.remove(id: favorite.id)
                favoritePendingRemovalID = nil
            }
            Button("취소", role: .cancel) {
                favoritePendingRemovalID = nil
            }
        } message: { favorite in
            Text("‘\(favorite.name)’ 항목을 즐겨찾기에서 제거합니다.")
        }
    }

    private var favoritePendingRemoval: FavoriteItem? {
        guard let favoritePendingRemovalID else { return nil }
        return favoriteStore.items.first { $0.id == favoritePendingRemovalID }
    }

    private var removalConfirmationBinding: Binding<Bool> {
        Binding(
            get: { favoritePendingRemovalID != nil },
            set: { if !$0 { favoritePendingRemovalID = nil } }
        )
    }
}

private struct FavoriteShelfTile: View {
    let favorite: FavoriteItem
    let open: () -> Void
    let requestRemoval: () -> Void

    var body: some View {
        FavoriteCell(favorite: favorite, side: 52)
            .frame(width: 56)
            .contentShape(Rectangle())
            .gesture(
                ExclusiveGesture(
                    LongPressGesture(minimumDuration: 0.55),
                    TapGesture()
                )
                .onEnded { result in
                    switch result {
                    case .first(true):
                        requestRemoval()
                    case .second:
                        open()
                    default:
                        break
                    }
                }
            )
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                open()
            }
            .accessibilityAction(named: Text("즐겨찾기에서 제거")) {
                requestRemoval()
            }
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
                    RemoteThumbnailView(
                        item: favorite.remoteItem,
                        service: service,
                        size: CGSize(width: side, height: side)
                    )
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
        }
    }

    var favoriteBadgeColor: Color {
        switch self {
        case .synology: SkyBreezeTheme.nasBlue
        case .sftp: SkyBreezeTheme.sftpGreen
        }
    }

    var dashboardSourceName: String {
        switch self {
        case .synology: "NAS"
        case .sftp: "SFTP"
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
