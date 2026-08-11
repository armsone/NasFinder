import SwiftUI

struct FavoriteShelfView: View {
    @EnvironmentObject private var favoriteStore: FavoriteStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("즐겨찾기", systemImage: "star.fill")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                NavigationLink {
                    FavoriteListView()
                } label: {
                    Text("더 보기")
                        .font(.subheadline.weight(.semibold))
                }
            }

            if favoriteStore.items.isEmpty {
                Text("파일이나 폴더를 길게 눌러 즐겨찾기에 추가하세요.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 9) {
                        ForEach(favoriteStore.items.prefix(5)) { favorite in
                            NavigationLink {
                                FavoriteDestinationView(favorite: favorite)
                            } label: {
                                FavoriteCell(favorite: favorite, side: 52)
                            }
                            .buttonStyle(.plain)
                        }

                        if favoriteStore.items.count > 5 {
                            NavigationLink {
                                FavoriteListView()
                            } label: {
                                VStack(spacing: 6) {
                                    Image(systemName: "ellipsis")
                                        .font(.headline)
                                        .frame(width: 52, height: 52)
                                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 11))
                                    Text("더 보기")
                                        .font(.caption2)
                                        .lineLimit(1)
                                }
                                .frame(width: 56)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct FavoriteListView: View {
    @EnvironmentObject private var favoriteStore: FavoriteStore

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
                                Button("즐겨찾기에서 제거", systemImage: "star.slash", role: .destructive) {
                                    favoriteStore.remove(id: favorite.id)
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

            Text(favorite.name)
                .font(.caption2)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: max(side, 56))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(favorite.name)
    }

    private var service: (any RemoteFileService)? {
        guard let connection = connectionStore.connections.first(where: {
            $0.id == favorite.connectionID
        }), let credential = try? connectionStore.credential(for: connection) else {
            return nil
        }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

private struct FavoriteDestinationView: View {
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
                    description: Text("이 항목의 네트워크 위치가 삭제되었거나 로그인 정보가 없습니다.")
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
