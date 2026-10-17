import SwiftUI

struct AppSettingsView: View {
    let connectionCount: Int
    @ObservedObject private var screenAwakeController = ScreenAwakeController.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.system.rawValue
    #if targetEnvironment(macCatalyst)
    @ObservedObject private var updateManager = MacDirectUpdateManager.shared
    #endif

    private var selectedTheme: AppThemePreference {
        .resolved(selectedThemeRawValue)
    }

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    var body: some View {
        List {
            themePaletteSection
            AppIconPickerSection(compact: true)
            screenAwakeSection
            filesAppIntegrationSection
            storageMaintenanceSection
            #if targetEnvironment(macCatalyst)
            macUpdateSection
            #endif
            openSourceSection
            creatorSection
        }
        .frame(maxWidth: isRunningOnMac ? ui(1_360) : nil)
        .environment(\.defaultMinListRowHeight, ui(isRunningOnMac ? 72 : 44))
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(SkyBreezeBackground())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
    }

    #if targetEnvironment(macCatalyst)
    private var macUpdateSection: some View {
        Section {
            Toggle("업데이트 자동 다운로드", isOn: $updateManager.automaticallyDownloadsUpdates)

            updateStatusView

            HStack(spacing: ui(12)) {
                updatePrimaryButton
                updateSecondaryButtons
            }
        } header: {
            SettingsSectionHeader(title: "Mac 업데이트", systemImage: "arrow.down.circle")
        } footer: {
            Text("Mac용 직접 배포판에서만 사용합니다. 설치는 확인된 DMG를 연 뒤 사용자가 직접 진행합니다.")
                .font(MacUIScale.sectionNoteFont)
        }
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateManager.state {
        case .idle:
            SettingsPanelDescription("새 버전이 있는지 확인할 수 있습니다.")
        case .checking:
            Label("업데이트 확인 중", systemImage: "arrow.triangle.2.circlepath")
        case .latest:
            Label("최신 버전 사용 중", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        case .available(let release):
            updateReleaseSummary(release, title: "새 버전 발견")
        case .downloading(let release, let progress, let isPaused):
            VStack(alignment: .leading, spacing: ui(8)) {
                updateReleaseSummary(release, title: isPaused ? "다운로드 일시정지" : "다운로드 중")
                ProgressView(value: progress)
                    .accessibilityValue("\(Int(progress * 100))퍼센트")
            }
        case .installReady(let release, _):
            updateReleaseSummary(release, title: "설치 준비됨")
            if updateManager.didHandoffInstaller {
                SettingsPanelDescription("DMG를 열었습니다. Finder에서 NasFinder를 설치해 주세요.")
            }
        case .error(let message, _):
            Label(message, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.red)
        }
    }

    private func updateReleaseSummary(_ release: DirectUpdateRelease, title: String) -> some View {
        VStack(alignment: .leading, spacing: ui(5)) {
            Text(title).font(.ui(.subheadline).weight(.semibold))
            Text("NasFinder \(release.version) · 빌드 \(release.build) · \(formattedSize(release.expectedByteCount))")
                .font(.ui(.caption))
                .foregroundStyle(.secondary)
            if let firstNote = release.releaseNotes
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .first(where: { !$0.contains(":") && !$0.isEmpty }) {
                Text(firstNote)
                    .font(.ui(.caption))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
    }

    @ViewBuilder
    private var updatePrimaryButton: some View {
        switch updateManager.state {
        case .available:
            Button("다운로드") { updateManager.downloadAvailableUpdate() }
        case .installReady:
            Button("DMG 열기") { updateManager.handoffInstaller() }
        case .error:
            Button("다시 시도") { updateManager.retry() }
        case .idle, .latest:
            Button("업데이트 확인") { updateManager.checkForUpdates() }
        case .checking, .downloading:
            EmptyView()
        }
    }

    @ViewBuilder
    private var updateSecondaryButtons: some View {
        switch updateManager.state {
        case .downloading(_, _, let isPaused):
            Button(isPaused ? "계속" : "일시정지") {
                if isPaused {
                    updateManager.resumeDownload()
                } else {
                    updateManager.pauseDownload()
                }
            }
            Button("취소", role: .cancel) { updateManager.cancelDownload() }
        case .checking:
            Button("취소", role: .cancel) { updateManager.cancelDownload() }
        default:
            EmptyView()
        }
    }

    private func formattedSize(_ byteCount: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
    #endif

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
            SettingsSectionHeader(title: "화면", systemImage: "sun.max")
        }
    }

    private var themePaletteSection: some View {
        Section {
            GeometryReader { geometry in
                let spacing: CGFloat = ui(8)
                let cardWidth = (geometry.size.width - spacing * 2) / 3
                LazyVGrid(
                    columns: Array(repeating: GridItem(.fixed(cardWidth), spacing: spacing), count: 3),
                    spacing: spacing
                ) {
                    ForEach(AppThemePreference.allCases) { theme in
                        themeCard(theme)
                    }
                }
            }
            .frame(height: ui(328))
            .listRowInsets(
                EdgeInsets(top: ui(10), leading: ui(12), bottom: ui(10), trailing: ui(12))
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
            VStack(alignment: .leading, spacing: ui(7)) {
                HStack {
                    Image(systemName: theme.systemImage)
                        .font(.ui(.caption).weight(.medium))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.ui(.caption))
                    }
                }
                .foregroundStyle(themePreviewForeground(theme))

                Spacer(minLength: 0)

                Text(theme.title)
                    .font(.ui(.caption).weight(.semibold))
                    .foregroundStyle(themePreviewForeground(theme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)

                HStack(spacing: ui(3)) {
                    ForEach(Array(ThemeServicePalette.colors(for: theme).prefix(4).enumerated()), id: \.offset) { _, color in
                        Circle().fill(color).frame(width: ui(5), height: ui(5))
                    }
                }
            }
            .padding(ui(9))
            .frame(height: ui(104))
            .background {
                ThemePreviewBackground(theme: theme)
                    .clipShape(RoundedRectangle(cornerRadius: ui(12)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: ui(12))
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
        case .night, .digitalRain, .workbench: .white
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
            .font(.ui(.subheadline))
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

    private var storageMaintenanceSection: some View {
        Section {
            ThumbnailCacheSettingsLink()
            SuperThumbnailLink()
        } header: {
            SettingsSectionHeader(title: "썸네일 저장공간", systemImage: "photo.stack")
        }
    }

    private var openSourceSection: some View {
        Section {
            VStack(alignment: .leading, spacing: ui(5)) {
                Text("VLCKit 4.0.0a23")
                    .font(.ui(.subheadline))
                Text("일부 호환 영상 재생에 VideoLAN의 VLCKit을 사용합니다. VLCKit은 GNU LGPL 2.1 이상으로 제공됩니다.")
                    .font(.ui(.caption))
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

    private var creatorSection: some View {
        Section {
            Link(
                destination: URL(string: "https://github.com/armsone")!
            ) {
                Label("GitHub · armsone", systemImage: "link")
            }
            .accessibilityLabel("만든 사람 GitHub, armsone")

            SettingsPanelDescription("NasFinder를 만든 사람의 GitHub입니다.")
        } header: {
            SettingsSectionHeader(title: "만든 사람", systemImage: "person.crop.circle")
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
                } else if theme == .workbench {
                    WorkbenchDecoration(size: geometry.size)
                } else if theme == .skeuomorphism {
                    Circle()
                        .stroke(.white.opacity(0.75), lineWidth: 7)
                        .shadow(color: .black.opacity(0.24), radius: 2, x: 1, y: 2)
                        .padding(ui(18))
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
        case .workbench:
            LinearGradient(
                colors: [
                    Color(red: 0.08, green: 0.12, blue: 0.18),
                    Color(red: 0.025, green: 0.04, blue: 0.065),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .skeuomorphism:
            LinearGradient(
                colors: [
                    Color(red: 0.78, green: 0.78, blue: 0.76),
                    Color(red: 0.98, green: 0.975, blue: 0.96),
                    .white,
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

private struct SettingsIntegrationStep: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: ui(10)) {
            Text(number, format: .number)
                .font(.ui(.caption2).weight(.bold))
                .foregroundStyle(.white)
                .frame(width: ui(22), height: ui(22))
                .background(SkyBreezeTheme.accent, in: Circle())

            Text(text)
                .font(.ui(.subheadline))
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }
}
