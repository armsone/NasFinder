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

                NavigationLink {
                    ThemePaletteSettingsView()
                } label: {
                    Label("테마 색 구성", systemImage: "paintpalette")
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

private struct ThemePaletteSettingsView: View {
    private let colors: [ThemeColorRole] = [
        ThemeColorRole(
            name: "주요 글자",
            description: "이름과 핵심 정보",
            color: Color(uiColor: .label)
        ),
        ThemeColorRole(
            name: "보조 글자",
            description: "패널 아이콘과 보조 정보",
            color: Color(uiColor: .secondaryLabel)
        ),
        ThemeColorRole(
            name: "설명",
            description: "조용한 안내와 메타 정보",
            color: Color(uiColor: .tertiaryLabel)
        ),
        ThemeColorRole(
            name: "선택",
            description: "Apple 시스템 파란색",
            color: Color(uiColor: .systemBlue)
        ),
        ThemeColorRole(
            name: "삭제",
            description: "위험하거나 되돌리기 어려운 동작",
            color: Color(uiColor: .systemRed)
        ),
        ThemeColorRole(
            name: "패널 표면",
            description: "라이트·다크 모드 적응형 배경",
            color: Color(uiColor: .secondarySystemBackground)
        ),
    ]

    var body: some View {
        List {
            Section {
                ForEach(colors) { role in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(role.color)
                            .frame(width: 28, height: 28)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .stroke(.separator.opacity(0.45), lineWidth: 0.5)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                                .foregroundStyle(.primary)
                            Text(role.description)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } footer: {
                Text("표시 색은 iPhone의 라이트·다크 모드에 맞춰 자동으로 바뀝니다.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("테마 색 구성")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ThemeColorRole: Identifiable {
    let name: String
    let description: String
    let color: Color

    var id: String { name }
}
