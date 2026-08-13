import SwiftUI

struct AppSettingsView: View {
    let connectionCount: Int
    @ObservedObject private var screenAwakeController = ScreenAwakeController.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    @State private var themeIconError: String?

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    var body: some View {
        List {
            themePaletteSection
            AppIconPickerSection(compact: true)
            screenAwakeSection
            filesAppIntegrationSection
            openSourceSection
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: selectedThemeRawValue, initial: true) { _, rawValue in
            guard AppThemePreference.resolved(rawValue) == .digitalRain else { return }
            AppIconChoice.apply(.vibeCoder) { errorMessage in
                themeIconError = errorMessage
            }
        }
        .alert("아이콘을 변경할 수 없습니다", isPresented: themeIconErrorBinding) {
            Button("확인", role: .cancel) { themeIconError = nil }
        } message: {
            Text(themeIconError ?? "잠시 후 다시 시도해 주세요.")
        }
    }

    private var themeIconErrorBinding: Binding<Bool> {
        Binding(
            get: { themeIconError != nil },
            set: { if !$0 { themeIconError = nil } }
        )
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

    private var themePaletteSection: some View {
        Section {
            GeometryReader { geometry in
                let spacing: CGFloat = 8
                let cardWidth = (geometry.size.width - spacing * 2) / 3
                VStack(spacing: spacing) {
                    HStack(spacing: spacing) {
                        ForEach(Array(AppThemePreference.allCases.prefix(3))) { theme in
                            themeCard(theme)
                                .frame(width: cardWidth)
                        }
                    }
                    HStack(spacing: spacing) {
                        ForEach(Array(AppThemePreference.allCases.dropFirst(3))) { theme in
                            themeCard(theme)
                                .frame(width: cardWidth)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 216)
            .listRowInsets(
                EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
            )

            SettingsPanelDescription(
                selectedTheme == .system
                    ? "iPhone의 라이트·다크 모드에 맞춰 자동으로 바뀝니다."
                    : "선택한 테마는 앱을 다시 열어도 유지됩니다."
            )

        } header: {
            SettingsSectionHeader(title: "테마", systemImage: "paintpalette")
        }
    }

    private func themeCard(_ theme: AppThemePreference) -> some View {
        let isSelected = selectedTheme == theme
        return Button {
            withAnimation(.easeInOut(duration: 0.20)) {
                selectedThemeRawValue = theme.rawValue
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Image(systemName: theme.systemImage)
                        .font(.caption.weight(.medium))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                    }
                }
                .foregroundStyle(themePreviewForeground(theme))

                Spacer(minLength: 0)

                Text(theme.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(themePreviewForeground(theme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                HStack(spacing: 3) {
                    ForEach(Array(ThemeServicePalette.colors(for: theme).prefix(4).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: 5, height: 5)
                    }
                }
            }
            .padding(9)
            .frame(height: 104)
            .background {
                ThemePreviewBackground(theme: theme)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        isSelected ? SkyBreezeTheme.accent : Color.secondary.opacity(0.18),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(theme.title) 테마")
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
    }

    private func themePreviewForeground(_ theme: AppThemePreference) -> Color {
        switch theme {
        case .night, .digitalRain: .white
        default: Color(red: 0.10, green: 0.15, blue: 0.16)
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

}

private struct ThemePreviewBackground: View {
    let theme: AppThemePreference

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                gradient
                if theme == .digitalRain {
                    CodeRainDecoration(size: geometry.size)
                        .opacity(0.92)
                }
            }
        }
    }

    private var gradient: LinearGradient {
        switch theme {
        case .system:
            LinearGradient(
                colors: [.white.opacity(0.96), .black.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .day:
            LinearGradient(
                colors: [Color(red: 0.72, green: 0.91, blue: 1), .white],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .night:
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.15, blue: 0.21), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .digitalRain:
            LinearGradient(
                colors: [Color(red: 0.005, green: 0.05, blue: 0.045), .black],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .windyMeadow:
            LinearGradient(
                colors: [
                    Color(red: 0.28, green: 0.76, blue: 0.96),
                    Color(red: 0.73, green: 0.84, blue: 0.38),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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
