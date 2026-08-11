import SwiftUI

struct FileBrowserContainerView: View {
    @EnvironmentObject private var store: ConnectionStore
    let connection: RemoteConnection
    let path: String
    let title: String

    init(connection: RemoteConnection, path: String? = nil, title: String? = nil) {
        self.connection = connection
        self.path = path ?? connection.normalizedRootPath
        self.title = title ?? connection.name
    }

    var body: some View {
        Group {
            if let service {
                FileBrowserView(
                    connection: connection,
                    path: path,
                    service: service,
                    title: title
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
