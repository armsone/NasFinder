import SwiftUI

struct FileBrowserContainerView: View {
    @EnvironmentObject private var store: ConnectionStore
    let connection: RemoteConnection
    let path: String
    let title: String
    let returnToDashboardAction: ReturnToDashboardAction
    var onPickMedia: (([RemoteFileItem], any RemoteFileService) -> Void)?
    /// 영상 만들기 NAS·네트워크 페이지에서만 지정한다. 맨 처음 폴더의 뒤로가 연결 목록으로 돌아간다.
    var onExitSelection: (() -> Void)?

    init(
        connection: RemoteConnection,
        path: String? = nil,
        title: String? = nil,
        returnToDashboardAction: @escaping ReturnToDashboardAction,
        onPickMedia: (([RemoteFileItem], any RemoteFileService) -> Void)? = nil,
        onExitSelection: (() -> Void)? = nil
    ) {
        self.onPickMedia = onPickMedia
        self.onExitSelection = onExitSelection
        self.connection = connection
        self.path = path ?? connection.normalizedRootPath
        self.title = title ?? connection.name
        self.returnToDashboardAction = returnToDashboardAction
    }

    var body: some View {
        Group {
            if let service, let onPickMedia, let onExitSelection {
                MediaSelectionBrowser(
                    connection: connection,
                    rootPath: path,
                    rootTitle: title,
                    service: service,
                    onExitRoot: onExitSelection,
                    onPickMedia: onPickMedia
                )
            } else if let service {
                FileBrowserView(
                    connection: connection,
                    path: path,
                    service: service,
                    title: title,
                    returnToDashboardAction: returnToDashboardAction,
                    onPickMedia: onPickMedia
                )
            } else {
                ContentUnavailableView(
                    "로그인 정보 없음",
                    systemImage: "key.slash",
                    description: Text("연결을 삭제한 뒤 다시 추가해 주세요.")
                )
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    private var service: (any RemoteFileService)? {
        guard let credential = try? store.credential(for: connection) else { return nil }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

/// 영상 만들기 선택기 안의 폴더 이동. 대시보드 NavigationStack에 push하지 않고 이 화면이 폴더 경로를
/// 직접 가진다. 뒤로는 폴더 한 단계만 되돌리고, 바구니는 부모 선택기에 그대로 남는다.
struct MediaSelectionBrowser: View {
    let connection: RemoteConnection
    let rootPath: String
    let rootTitle: String
    let service: any RemoteFileService
    /// 맨 처음 폴더에서 뒤로를 눌렀을 때. nil이면 맨 처음 폴더에는 뒤로 버튼이 없다.
    var onExitRoot: (() -> Void)?
    let onPickMedia: ([RemoteFileItem], any RemoteFileService) -> Void
    @State private var folders: [FileBrowserPathComponent] = []

    var body: some View {
        let path = folders.last?.path ?? rootPath
        FileBrowserView(
            connection: connection,
            path: path,
            service: service,
            title: folders.last?.title ?? rootTitle,
            returnToDashboardAction: {},
            onPickMedia: onPickMedia
        )
        .embeddedAsSourcePage(
            MediaSelectionNavigation(
                open: open,
                goBack: folders.isEmpty ? onExitRoot : goBackOneFolder
            )
        )
        .id(path)
    }

    private func goBackOneFolder() {
        if !folders.isEmpty { folders.removeLast() }
    }

    private func open(_ path: String, _ title: String) {
        if path == rootPath {
            folders.removeAll()
        } else if let index = folders.firstIndex(where: { $0.path == path }) {
            folders.removeSubrange((index + 1)...)
        } else {
            folders.append(FileBrowserPathComponent(path: path, title: title))
        }
    }
}
