import SwiftUI

/// 포켓의 + 에서 여는 파인더 출처 목록. 파인더가 보여 주는 내용 출처(저장된 모든 연결·폰하드·기기 파일·즐겨찾기·
/// 내 미디어·Google 포토·웹 브라우저)를 그대로 이어 준다. 새 브라우저·저장소를 만들지 않고 기존 화면을 열며,
/// 거기서 파일·폴더를 고른 뒤 '작업대에 담기'를 누르면 기존 `WorkbenchEntryFactory`가 위치(참조)만 기록한다.
/// 연결은 목록에서 동적으로 읽으므로 새로 추가한 연결도 바로 나타난다. 연결 추가·편집 같은 설정 화면은 내용 출처가 아니라 넣지 않았다.
struct WorkbenchFinderSourcePage: View {
    let pocketID: UUID
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var notice: String?
    private var themeRefresh = ThemeRefresh()

    init(pocketID: UUID) { self.pocketID = pocketID }

    var body: some View {
        let _ = themeRefresh.theme
        List {
            Section {
                Text("출처를 열어 파일이나 폴더를 고른 뒤 \"작업대에 담기\"를 누르세요. 위치만 기록되며 원본은 복사하거나 내려받지 않습니다.")
                    .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
            }
            Section("NAS·네트워크·클라우드 연결") {
                if connectionStore.connections.isEmpty {
                    Text("저장된 연결이 없습니다. 파인더 홈에서 연결을 추가하면 여기에 나타납니다.")
                        .font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary)
                }
                ForEach(connectionStore.connections) { connection in
                    NavigationLink {
                        FileBrowserContainerView(connection: connection, returnToDashboardAction: {})
                            .id(connection.id)
                    } label: {
                        sourceLabel(connection.name, detail: connection.kind.title, systemImage: connection.kind.systemImage)
                    }
                    .accessibilityLabel("\(connection.name) 열기")
                }
            }
            Section("이 기기") {
                NavigationLink { PhoneHardBrowserView() } label: {
                    sourceLabel("폰하드", detail: "이 기기에 저장된 받은 파일", systemImage: "iphone.gen3")
                }
                NavigationLink {
                    DeviceFolderBrowserView(onImportFiles: {
                        notice = "파일을 폰하드로 가져오기는 파인더의 기기 파일에서 합니다. 작업대에는 가져오지 않고 위치만 담을 수 있습니다."
                    })
                } label: {
                    sourceLabel("기기 파일", detail: "허락한 폴더", systemImage: "internaldrive")
                }
                NavigationLink { LocalPhotoLibraryView() } label: {
                    sourceLabel("내 미디어·달력", detail: "사진 보관함·파일·폰하드 선택 탭 포함", systemImage: "photo.on.rectangle")
                }
            }
            Section("즐겨찾기·클라우드·웹") {
                NavigationLink { FavoriteListView() } label: {
                    sourceLabel("즐겨찾기", detail: "별표한 폴더·파일", systemImage: "star")
                }
                NavigationLink { WorkbenchGooglePhotosPage(pocketID: pocketID) } label: {
                    sourceLabel("Google 포토", detail: "내려받지 않고 항목만 담기", systemImage: "cloud")
                }
                NavigationLink { WebBrowserView() } label: {
                    sourceLabel("브라우저", detail: "받은 파일을 폰하드에 저장한 뒤 담기", systemImage: "globe")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(PorcelainMetrics.paper)
        .navigationTitle("파인더에서 담기")
        .navigationBarTitleDisplayMode(.inline)
        .alert("작업대 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    private func sourceLabel(_ title: String, detail: String, systemImage: String) -> some View {
        HStack(spacing: ui(12)) {
            Image(interfaceSystemName: systemImage).frame(width: ui(28))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.ui(.body))
                Text(detail).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}
