import SwiftUI

struct AppSettingsView: View {
    let connectionCount: Int
    @ObservedObject private var screenAwakeController = ScreenAwakeController.shared
    @AppStorage(InterfaceIconStyle.storageKey) private var iconStyleRawValue = ""
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue
    #if targetEnvironment(macCatalyst)
    @ObservedObject private var updateManager = MacDirectUpdateManager.shared
    #endif

    private var themeRefresh = ThemeRefresh()

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

    private enum Pane: String, CaseIterable, Identifiable {
        case appearance = "화면·테마"
        case storage = "저장공간·연동"
        case update = "업데이트"
        case info = "앱 정보"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .appearance: return "paintpalette"
            case .storage: return "photo.stack"
            case .update: return "arrow.down.circle"
            case .info: return "info.circle"
            }
        }
    }

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selectedPane: Pane = .appearance

    private var panes: [Pane] {
        #if targetEnvironment(macCatalyst)
        Pane.allCases
        #else
        Pane.allCases.filter { $0 != .update }
        #endif
    }

    /// 실제 사용 가능한 너비로 판단한다. 좁은 Mac 창이나 분할 화면에서는 단일 목록으로 돌아간다.
    private func isWide(width: CGFloat) -> Bool {
        (isRunningOnMac || horizontalSizeClass == .regular) && width >= ui(560)
    }

    var body: some View {
        let _ = themeRefresh.theme
        let palette = selectedTheme.palette
        GeometryReader { proxy in
            if isWide(width: proxy.size.width) {
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(panes) { pane in
                            Button {
                                selectedPane = pane
                            } label: {
                                Label(pane.rawValue, systemImage: pane.icon)
                                    .font(PorcelainTypeface.font(size: 14, weight: .medium))
                                    .foregroundStyle(selectedPane == pane ? palette.onAccent : palette.text)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 8)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(selectedPane == pane ? palette.solidAction : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(12)
                    .frame(width: ui(220))
                    .background(palette.surface)
                    Rectangle().fill(palette.border).frame(width: 1)
                    settingsList(palette: palette, only: selectedPane)
                        .frame(maxWidth: ui(800))
                        .frame(maxWidth: .infinity)
                }
            } else {
                settingsList(palette: palette, only: nil)
            }
        }
        .background(SkyBreezeBackground())
        .navigationTitle("설정")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(selectedTheme.isDark ? .dark : .light, for: .navigationBar)
        .tint(palette.accent)
    }

    private func settingsList(palette: AppThemePalette, only pane: Pane?) -> some View {
        List {
            if pane == nil || pane == .appearance {
                themePaletteSection
                    .listRowBackground(palette.surface)
                interfaceIconStyleSection
                    .listRowBackground(palette.surface)
                AppIconPickerSection(compact: true)
                    .listRowBackground(palette.surface)
                screenAwakeSection
                    .listRowBackground(palette.surface)
            }
            if pane == nil || pane == .storage {
                filesAppIntegrationSection
                    .listRowBackground(palette.surface)
                storageMaintenanceSection
                    .listRowBackground(palette.surface)
            }
            #if targetEnvironment(macCatalyst)
            if pane == nil || pane == .update {
                macUpdateSection
                    .listRowBackground(palette.surface)
            }
            #endif
            if pane == nil || pane == .info {
                openSourceSection
                    .listRowBackground(palette.surface)
                creatorSection
                    .listRowBackground(palette.surface)
            }
        }
        .environment(\.defaultMinListRowHeight, MacUIScale.minListRowHeight)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
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
            .frame(height: ui(216))
            .listRowInsets(
                EdgeInsets(top: ui(10), leading: ui(12), bottom: ui(10), trailing: ui(12))
            )

            SettingsPanelDescription(
                "모든 테마는 같은 배치와 글꼴을 쓰고 색만 바뀝니다. 아이콘 스타일과 앱 아이콘은 그대로 유지됩니다."
            )

        } header: {
            SettingsSectionHeader(title: "병기스타일 테마", systemImage: "paintpalette")
        }
    }

    private var interfaceIconStyleSection: some View {
        let current = InterfaceIconStyle.resolved(iconStyleRawValue, theme: selectedTheme)
        return Section {
            // 승인 보드 06: 스타일마다 한 행(선택 표시 · 이름 · 설명 · 샘플 아이콘). 6개 테마 공통.
            ForEach(InterfaceIconStyle.allCases) { style in
                interfaceIconStyleRow(style, isSelected: current == style)
            }

            SettingsPanelDescription(
                "화면 테마·앱 아이콘과 따로 저장됩니다. 사진·영상·폴더 썸네일은 항상 실제 이미지를 보여 줍니다."
            )
        } header: {
            SettingsSectionHeader(title: "아이콘 스타일", systemImage: "square.grid.2x2")
        }
    }

    private func interfaceIconStyleRow(_ style: InterfaceIconStyle, isSelected: Bool) -> some View {
        Button {
            iconStyleRawValue = style.rawValue
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? PorcelainMetrics.accent : Color.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(style.title)
                        .porcelainFont(.tile)
                        .foregroundStyle(PorcelainMetrics.graphite)
                    Text(Self.interfaceIconStyleDescription(style))
                        .porcelainFont(.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                HStack(spacing: 8) {
                    ForEach([ThemeIconID.nas, .photos, .settings], id: \.self) { id in
                        ThemeIcon(id, style: style)
                            .frame(width: 30, height: 30)
                    }
                }
                .accessibilityHidden(true)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(style.title) 아이콘")
        .accessibilityValue(isSelected ? "선택됨" : "선택 안 됨")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private static func interfaceIconStyleDescription(_ style: InterfaceIconStyle) -> String {
        switch style {
        case .simple: "간결한 선으로 구성된 라인 스타일"
        case .solid: "명확하고 단단한 면의 플랫 스타일"
        case .dimension: "부드러운 입체감의 모던 스타일"
        case .realistic: "실제 질감을 표현한 현실적인 스타일"
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
                    ByungkiThemeGlyph(theme: theme, size: ui(18), tintColor: themePreviewForeground(theme))
                    Spacer(minLength: 0)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.ui(.caption))
                    }
                }
                .foregroundStyle(themePreviewForeground(theme))

                Spacer(minLength: 0)

                Text(theme.title)
                    .font(.ui(.caption).weight(.medium))
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
        theme.palette.text
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

/// 테마 카드 미리보기: 그 테마의 바탕·표면·채운 단추 색만 보여 준다(장식 없음).
private struct ThemePreviewBackground: View {
    let theme: AppThemePreference

    var body: some View {
        let palette = theme.palette
        ZStack(alignment: .bottomTrailing) {
            palette.background
            RoundedRectangle(cornerRadius: ui(6), style: .continuous)
                .fill(palette.solidAction)
                .frame(width: ui(28), height: ui(14))
                .padding(ui(9))
        }
        .overlay {
            RoundedRectangle(cornerRadius: ui(12))
                .stroke(palette.border, lineWidth: 0.5)
        }
    }
}

private struct SettingsIntegrationStep: View {
    let number: Int
    let text: String
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        HStack(alignment: .top, spacing: ui(10)) {
            Text(number, format: .number)
                .font(.ui(.caption2).weight(.bold))
                .foregroundStyle(PorcelainMetrics.onAccent)
                .frame(width: ui(22), height: ui(22))
                .background(PorcelainMetrics.solidAction, in: Circle())

            Text(text)
                .porcelainFont(.tile, weight: .regular)
                .foregroundStyle(PorcelainMetrics.graphite)
        }
        .accessibilityElement(children: .combine)
    }
}
