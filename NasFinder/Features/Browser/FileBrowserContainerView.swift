import SwiftUI

struct FileBrowserContainerView: View {
    @EnvironmentObject private var store: ConnectionStore
    let connection: RemoteConnection

    var body: some View {
        Group {
            if let service {
                FileBrowserView(
                    connection: connection,
                    path: connection.normalizedRootPath,
                    service: service,
                    title: connection.name
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
