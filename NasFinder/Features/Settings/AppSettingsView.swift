import SwiftUI

struct AppSettingsView: View {
    let connectionCount: Int

    var body: some View {
        List {
            Section("앱") {
                NavigationLink {
                    AppIconSettingsView()
                } label: {
                    Label("앱 아이콘", systemImage: "app.badge")
                }
            }

            Section("연동 및 도움말") {
                NavigationLink {
                    FilesAppIntegrationGuideView(connectionCount: connectionCount)
                } label: {
                    Label("Apple 파일 앱 연동", systemImage: "folder")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }
}
