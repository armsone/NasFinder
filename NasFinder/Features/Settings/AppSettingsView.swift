import SwiftUI

struct AppSettingsView: View {
    let connectionCount: Int
    @ObservedObject private var screenAwakeController = ScreenAwakeController.shared

    var body: some View {
        List {
            AppIconPickerSection(compact: true)
            screenAwakeSection
            themePaletteSection
            filesAppIntegrationSection
            openSourceSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var screenAwakeSection: some View {
        Section {
            Picker("화면 동작", selection: $screenAwakeController.mode) {
                ForEach(ScreenAwakeMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            SettingsPanelDescription(screenAwakeController.mode.description)
        } header: {
            SettingsSectionHeader(title: "화면 꺼짐 방지", systemImage: "sun.max")
        }
    }

    private let colors: [ThemeColorRole] = [
        ThemeColorRole(
            name: "주요 글자",
            description: "이름과 핵심 정보",
            lightColor: Color(red: 0.11, green: 0.11, blue: 0.12),
            darkColor: Color(red: 0.95, green: 0.95, blue: 0.97)
        ),
        ThemeColorRole(
            name: "보조 글자",
            description: "패널 아이콘과 보조 정보",
            lightColor: Color(red: 0.43, green: 0.43, blue: 0.44),
            darkColor: Color(red: 0.68, green: 0.68, blue: 0.70)
        ),
        ThemeColorRole(
            name: "설명",
            description: "조용한 안내와 메타 정보",
            lightColor: Color(red: 0.55, green: 0.55, blue: 0.58),
            darkColor: Color(red: 0.55, green: 0.55, blue: 0.58)
        ),
        ThemeColorRole(
            name: "선택",
            description: "Apple 시스템 파란색",
            lightColor: Color(red: 0.00, green: 0.48, blue: 1.00),
            darkColor: Color(red: 0.04, green: 0.52, blue: 1.00)
        ),
        ThemeColorRole(
            name: "NAS",
            description: "Synology 네트워크 위치",
            lightColor: Color(red: 0.00, green: 0.48, blue: 1.00),
            darkColor: Color(red: 0.04, green: 0.52, blue: 1.00)
        ),
        ThemeColorRole(
            name: "SFTP",
            description: "SFTP 네트워크 위치",
            lightColor: Color(red: 0.20, green: 0.68, blue: 0.31),
            darkColor: Color(red: 0.19, green: 0.82, blue: 0.35)
        ),
        ThemeColorRole(
            name: "Browser",
            description: "WWW 네트워크 위치",
            lightColor: Color(red: 1.00, green: 0.58, blue: 0.00),
            darkColor: Color(red: 1.00, green: 0.62, blue: 0.04)
        ),
        ThemeColorRole(
            name: "삭제",
            description: "위험하거나 되돌리기 어려운 동작",
            lightColor: Color(red: 1.00, green: 0.23, blue: 0.19),
            darkColor: Color(red: 1.00, green: 0.27, blue: 0.23)
        ),
        ThemeColorRole(
            name: "패널 표면",
            description: "라이트·다크 모드 적응형 배경",
            lightColor: Color(red: 0.95, green: 0.95, blue: 0.97),
            darkColor: Color(red: 0.11, green: 0.11, blue: 0.12)
        ),
    ]

    private var themePaletteSection: some View {
        Section {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Spacer()
                    Text("낮")
                        .frame(width: 38)
                    Text("밤")
                        .frame(width: 38)
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)

                ForEach(Array(colors.enumerated()), id: \.element.id) { index, role in
                    if index > 0 {
                        Divider()
                    }

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(role.name)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                            Text(role.description)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 8)
                        paletteSwatch(role.lightColor, modeName: "낮")
                        paletteSwatch(role.darkColor, modeName: "밤")
                    }
                    .padding(.vertical, 7)
                    .accessibilityElement(children: .combine)
                }

                Divider()
                SettingsPanelDescription(
                    "표시 색은 iPhone의 라이트·다크 모드에 맞춰 자동으로 바뀝니다."
                )
                .padding(.top, 8)
            }
        } header: {
            SettingsSectionHeader(title: "테마 색 구성", systemImage: "paintpalette")
        }
    }

    private var filesAppIntegrationSection: some View {
        Section {
            Text(
                connectionCount == 0
                    ? "먼저 NAS 또는 SFTP 연결을 추가해 주세요."
                    : "현재 저장된 원격 위치 \(connectionCount)개를 Apple 파일 앱에서도 열 수 있습니다."
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)

            SettingsIntegrationStep(number: 1, text: "Apple 파일 앱을 열고 ‘탐색’을 선택합니다.")
            SettingsIntegrationStep(number: 2, text: "오른쪽 위의 더 보기(…)에서 ‘편집’을 선택합니다.")
            SettingsIntegrationStep(number: 3, text: "‘위치’에서 NasFinder의 서버 이름을 켭니다.")
            SettingsIntegrationStep(number: 4, text: "서버 이름을 선택해 원격 파일을 엽니다.")

            SettingsPanelDescription(
                "SFTP는 파일 작업을 지원하며, Synology 위치는 열기와 내려받기를 지원합니다."
            )
        } header: {
            SettingsSectionHeader(title: "Apple 파일 앱 연동", systemImage: "folder")
        }
    }

    private var openSourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 5) {
                Text("VLCKit 4.0.0a23")
                    .font(.subheadline)
                Text("일부 호환 영상 재생에 VideoLAN의 VLCKit을 사용합니다. VLCKit은 GNU LGPL 2.1 이상으로 제공됩니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Link(
                "라이선스 보기",
                destination: URL(string: "https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html")!
            )
            Link(
                "VLCKit 소스 코드",
                destination: URL(string: "https://github.com/videolan/vlckit/tree/4.0.0-a23")!
            )
        } header: {
            SettingsSectionHeader(title: "오픈 소스", systemImage: "chevron.left.forwardslash.chevron.right")
        }
    }

    private func paletteSwatch(_ color: Color, modeName: String) -> some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(color)
            .frame(width: 38, height: 28)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(.separator.opacity(0.55), lineWidth: 0.5)
            }
            .accessibilityLabel("\(modeName) 모드 색상")
    }
}

private struct SettingsIntegrationStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number, format: .number)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(SkyBreezeTheme.accent, in: Circle())

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ThemeColorRole: Identifiable {
    let name: String
    let description: String
    let lightColor: Color
    let darkColor: Color

    var id: String { name }
}
