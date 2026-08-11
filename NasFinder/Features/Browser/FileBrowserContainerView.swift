import SwiftUI

struct FileBrowserContainerView: View {
    @EnvironmentObject private var store: ConnectionStore
    let connection: RemoteConnection
    let path: String
    let title: String
    let returnToDashboardAction: ReturnToDashboardAction

    init(
        connection: RemoteConnection,
        path: String? = nil,
        title: String? = nil,
        returnToDashboardAction: @escaping ReturnToDashboardAction
    ) {
        self.connection = connection
        self.path = path ?? connection.normalizedRootPath
        self.title = title ?? connection.name
        self.returnToDashboardAction = returnToDashboardAction
    }

    var body: some View {
        Group {
            if let service {
                FileBrowserView(
                    connection: connection,
                    path: path,
                    service: service,
                    title: title,
                    returnToDashboardAction: returnToDashboardAction
                )
            } else {
                ContentUnavailableView(
                    "로그인 정보 없음",
                    systemImage: "key.slash",
                    description: Text("연결을 삭제한 뒤 다시 추가해 주세요.")
                )
            }
        }
    }

    private var service: (any RemoteFileService)? {
        guard let credential = try? store.credential(for: connection) else { return nil }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}
