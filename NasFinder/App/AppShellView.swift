import SwiftUI

/// 최상위 탐색: 파인더 / 영상 / 도구. 파인더가 기본이며, 세 화면은 한 번 열면 계속 살아 있어
/// 탭을 오가도 파인더의 폴더 위치와 영상 탭의 선택이 그대로 남는다.
enum AppTab: String, CaseIterable, Identifiable {
    case finder = "파인더"
    case video = "영상"
    case tools = "도구"
    var id: String { rawValue }

    /// 기존 원본 InterfaceIcon 팩의 아이콘 이름.
    var iconName: String {
        switch self {
        case .finder: "house"
        case .video: "film"
        case .tools: "arrow.up.arrow.down.square"
        }
    }
}

/// Mac 넓은 창 사이드바의 도구 하위 목적지. 설정도 도구 묶음 안에 둔다.
enum ToolsDestination: String, CaseIterable, Identifiable {
    case transfer = "사진 전송"
    case storage = "저장공간"
    case settings = "설정"
    var id: String { rawValue }

    var iconName: String {
        switch self {
        case .transfer: "arrow.left.arrow.right"
        case .storage: "square.grid.2x2"
        case .settings: "gearshape"
        }
    }
}

extension VideoDestination {
    var iconName: String {
        switch self {
        // 아이콘 팩에서 다른 행과 겹치지 않는 그림: 편집본은 drafts, 완성 영상인 컬렉션은 재생.
        case .make: "video"
        case .basket: "square.and.arrow.down"
        case .drafts: "film.stack"
        case .collection: "play"
        }
    }
}

/// Mac 사이드바의 파인더 행이 파인더에 보내는 요청. 파인더가 자기 상태·확인창·메뉴 동작으로 처리한다.
enum FinderSidebarCommand: Equatable {
    case home, rememberedLocation, open(UUID), photos, phoneHard, googlePhotos, deviceFiles, browser, addConnection
    case editConnection(UUID), deleteConnection(UUID)
    case editGooglePhotos, reconnectGooglePhotos, deleteGooglePhotos
}

/// 같은 행을 다시 눌러도 전달되도록 요청마다 새 id를 둔다.
struct FinderSidebarRequest: Equatable {
    let id = UUID()
    let command: FinderSidebarCommand
}

/// 파인더가 지금 보여 주는 곳. 사이드바 선택 표시에만 쓴다.
enum FinderSidebarLocation: Equatable {
    case home, connection(UUID), photos, phoneHard, googlePhotos, deviceFiles, browser, other
}

private struct UsesShellSidebarKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Mac 넓은 창에서 앱 셸의 하나뿐인 사이드바가 하위 목적지를 맡는지. 그러면 각 화면은 자기 사이드바·
    /// 가로 목적지 막대·같은 목적지 카드를 다시 그리지 않고 현재 작업 내용만 보여 준다.
    var usesShellSidebar: Bool {
        get { self[UsesShellSidebarKey.self] }
        set { self[UsesShellSidebarKey.self] = newValue }
    }
}

/// 사이드바 한 줄: 같은 높이·정렬·선택 표시. 접힌 사이드바에서는 아이콘만 보인다.
struct ShellSidebarRow: View {
    let title: String
    let icon: String
    var tint: Color? = nil
    let isSelected: Bool
    let showsTitle: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PorcelainSidebarItem(title: title, isSelected: isSelected, showsTitle: showsTitle,
                                 minHeight: PorcelainMetrics.shellSidebarRowHeight) {
                InterfaceIcon(systemName: icon, size: PorcelainMetrics.rowIconSize)
                    .foregroundStyle(tint ?? PorcelainMetrics.graphite)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AppShellView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @State private var selectedRaw = AppTab.finder.rawValue
    @AppStorage("appShell.railExpanded.v1") private var railExpanded = false
    @AppStorage("appShell.sidebarCollapsed.v1") private var sidebarCollapsed = false
    @State private var visited: Set<AppTab> = [.finder]
    @State private var showingSettings = false
    @ObservedObject private var router = AppShellRouter.shared

    private var selected: AppTab { AppTab(rawValue: selectedRaw) ?? .finder }
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        GeometryReader { geometry in
            // 창의 실제 폭으로 레이아웃을 정한다(분할 화면·창 크기 조절 포함).
            let usesRail = geometry.size.width >= PorcelainMetrics.workspaceWidth
            Group {
                if usesRail && isRunningOnMac {
                    // Mac 넓은 창: 레일·파인더 사이드바를 겹쳐 두지 않고 사이드바 하나로 모든 하위 목적지를 연다.
                    HStack(spacing: 0) {
                        sidebar(windowWidth: geometry.size.width)
                        Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                        content.environment(\.usesShellSidebar, true)
                    }
                } else if usesRail {
                    HStack(spacing: 0) {
                        rail
                        Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                        content
                    }
                } else {
                    content
                        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .background(PorcelainMetrics.paper.ignoresSafeArea())
        .sheet(isPresented: $showingSettings) {
            NavigationStack {
                AppSettingsView(connectionCount: connectionStore.connections.count)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("닫기") { showingSettings = false } }
                    }
            }
        }
        .onChange(of: selectedRaw, initial: true) { _, _ in visited.insert(selected) }
        // 편집기 레일에서 다른 탭을 눌렀을 때: 편집은 보관된 채 해당 탭으로 이동한다.
        .onChange(of: router.request) { _, tab in
            guard let tab else { return }
            selectedRaw = tab.rawValue
            router.request = nil
        }
    }

    private var content: some View {
        ZStack {
            ConnectionListView().tabLayer(selected == .finder)
            if visited.contains(.video) { VideoHubView().tabLayer(selected == .video) }
            if visited.contains(.tools) { ToolsView(openSettings: { showingSettings = true }).tabLayer(selected == .tools) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    // MARK: Mac 넓은 창: 하나뿐인 사이드바 (파인더·영상·도구 작은 제목 + 하위 목적지)

    private func sidebar(windowWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 브랜드와 접기 단추는 맨 위 한 줄에 둔다. 아래 끝으로 밀어 두지 않는다.
            HStack(spacing: 4) {
                if !sidebarCollapsed {
                    Button { sendFinder(.rememberedLocation) } label: {
                        HStack(spacing: 8) {
                            PorcelainHeaderGlyph(size: 24)
                            PorcelainBrandText()
                        }
                        .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("NasFinder")
                    .accessibilityHint("마지막으로 보던 네트워크 폴더를 엽니다.")
                    Spacer(minLength: 0)
                }
                Button { sidebarCollapsed.toggle() } label: {
                    InterfaceIcon(systemName: sidebarCollapsed ? "chevron.right" : "chevron.left", size: 20)
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: sidebarCollapsed ? .infinity : nil)
                .accessibilityLabel(sidebarCollapsed ? "사이드바 펼치기" : "사이드바 접기")
                .help(sidebarCollapsed ? "사이드바 펼치기" : "사이드바 접기")
            }
            .padding(.leading, sidebarCollapsed ? 0 : 12)
            .padding(.trailing, sidebarCollapsed ? 0 : 4)
            .padding(.top, 6)

            // 짧은 창에서는 사이드바만 스크롤한다.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarHeading("파인더")
                    FinderSidebarSection(isActive: selected == .finder, showsTitles: !sidebarCollapsed, send: sendFinder)
                    sidebarHeading("영상")
                    ForEach(VideoDestination.allCases) { item in
                        ShellSidebarRow(title: item.rawValue, icon: item.iconName,
                                        isSelected: selected == .video && router.videoDestination == item,
                                        showsTitle: !sidebarCollapsed) {
                            router.videoDestination = item
                            selectedRaw = AppTab.video.rawValue
                        }
                    }
                    sidebarHeading("도구")
                    ForEach(ToolsDestination.allCases) { item in
                        ShellSidebarRow(title: item.rawValue, icon: item.iconName,
                                        isSelected: selected == .tools && router.toolsDestination == item,
                                        showsTitle: !sidebarCollapsed) {
                            router.toolsDestination = item
                            selectedRaw = AppTab.tools.rawValue
                        }
                        .keyboardShortcut(item == .settings ? KeyboardShortcut(",", modifiers: .command) : nil)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: sidebarCollapsed ? 64 : PorcelainMetrics.sidebarWidth(for: windowWidth))
        .frame(maxHeight: .infinity, alignment: .top)
        // 배경만 안전 영역 밖까지 늘리고 버튼은 안전 영역 안에 둔다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea())
    }

    @ViewBuilder
    private func sidebarHeading(_ title: String) -> some View {
        if sidebarCollapsed {
            PorcelainMetrics.line.frame(height: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
        } else {
            Text(title)
                .porcelainFont(.meta, weight: .semibold)
                .foregroundStyle(PorcelainMetrics.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
        }
    }

    private func sendFinder(_ command: FinderSidebarCommand) {
        selectedRaw = AppTab.finder.rawValue
        router.finderRequest = FinderSidebarRequest(command: command)
    }

    // MARK: 넓은 화면(iPad): 64pt 아이콘 레일 (펼치면 이름 표시)

    private var rail: some View {
        VStack(spacing: 6) {
            ForEach(AppTab.allCases) { tab in
                Button { selectedRaw = tab.rawValue } label: {
                    HStack(spacing: 10) {
                        InterfaceIcon(systemName: tab.iconName, size: 28)
                        if railExpanded { Text(tab.rawValue).porcelainFont(.tile).lineLimit(1) }
                    }
                    .foregroundStyle(selected == tab ? PorcelainMetrics.accent : PorcelainMetrics.graphite)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: railExpanded ? .leading : .center)
                    .padding(.horizontal, railExpanded ? 12 : 0)
                    .background(selected == tab ? PorcelainMetrics.selected : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
            Spacer(minLength: 8)
            railButton(icon: "gearshape", title: "설정") { showingSettings = true }
            railButton(icon: railExpanded ? "chevron.left" : "chevron.right", title: railExpanded ? "접기" : "펼치기") {
                railExpanded.toggle()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(width: railExpanded ? 168 : 64)
        .frame(maxHeight: .infinity)
        // 배경만 안전 영역 밖까지 늘리고 버튼은 안전 영역 안에 둔다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea())
    }

    private func railButton(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                InterfaceIcon(systemName: icon, size: 24)
                if railExpanded { Text(title).porcelainFont(.tile) }
            }
            .foregroundStyle(PorcelainMetrics.graphite)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: railExpanded ? .leading : .center)
            .padding(.horizontal, railExpanded ? 12 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: 폰: 아래 탭 막대

    private var bottomBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button { selectedRaw = tab.rawValue } label: {
                    VStack(spacing: 2) {
                        InterfaceIcon(systemName: tab.iconName, size: 26)
                        Text(tab.rawValue).porcelainFont(.favorite)
                    }
                    .foregroundStyle(selected == tab ? PorcelainMetrics.accent : PorcelainMetrics.secondary)
                    .frame(maxWidth: .infinity, minHeight: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.rawValue)
                .accessibilityAddTraits(selected == tab ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        // 홈 인디케이터 영역까지 배경만 채우고 버튼은 안전 영역 위에 있다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea(.container, edges: .bottom))
        .overlay(alignment: .top) { PorcelainMetrics.line.frame(height: 0.5) }
    }
}

private extension View {
    /// 선택되지 않은 탭도 트리에 남겨 상태를 보존하되, 보이지 않고 눌리지 않게 한다.
    func tabLayer(_ isActive: Bool) -> some View {
        opacity(isActive ? 1 : 0)
            .allowsHitTesting(isActive)
            .accessibilityHidden(!isActive)
            .zIndex(isActive ? 1 : 0)
    }
}

/// 도구: 기기 간 사진 전송과 저장공간. 설정은 레일/아래쪽 목록에서도 연다.
struct ToolsView: View {
    let openSettings: () -> Void
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @EnvironmentObject private var connectionStore: ConnectionStore
    @ObservedObject private var router = AppShellRouter.shared
    @State private var snapshot = StorageSnapshot.current()
    @ObservedObject private var basket = MaterialBasketStore.shared
    @ObservedObject private var collection = MovieCollectionStore.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    private struct StorageSnapshot {
        let total: Int64
        let available: Int64
        var fraction: Double { total > 0 ? Double(total - min(total, available)) / Double(total) : 0 }
        static func current() -> Self {
            let values = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [
                .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
            return Self(total: values?.volumeTotalCapacity.map(Int64.init) ?? 0,
                        available: max(0, values?.volumeAvailableCapacityForImportantUsage ?? 0))
        }
    }

    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }

    var body: some View {
        NavigationStack {
            if usesShellSidebar {
                // Mac 사이드바가 도구 하위 목적지를 고르므로 여기서는 고른 화면 하나만 보여 준다.
                switch router.toolsDestination {
                case .transfer: PhotoTransferView()
                case .storage: storagePage
                case .settings: AppSettingsView(connectionCount: connectionStore.connections.count)
                }
            } else {
                toolsList
            }
        }
    }

    private var storagePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                storageCard
                if let versionText = AppVersionDisplayPolicy.text() {
                    Text(versionText).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(PorcelainMetrics.paper)
        .navigationTitle("저장공간")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue)
            }
        }
        .onAppear { snapshot = StorageSnapshot.current() }
    }

    private var storageCard: some View {
        PorcelainGroupCard {
            PorcelainRow(
                title: "기기 저장공간",
                subtitle: snapshot.total > 0
                    ? "전체 \(bytes(snapshot.total)) · 사용 가능 \(bytes(snapshot.available))" : "확인 불가"
            ) {
                InterfaceIcon(systemName: "internaldrive", size: PorcelainMetrics.rowIconSize)
            }
            if snapshot.total > 0 {
                ProgressView(value: snapshot.fraction).tint(SkyBreezeTheme.accent)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            PorcelainDivider()
            PorcelainRow(
                title: "재료함 \(basket.items.count)개",
                subtitle: "앱 안 복사본 \(bytes(basket.items.reduce(0) { $0 + ($1.localFilename == nil ? 0 : ($1.byteCount ?? 0)) }))"
            ) {
                InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.rowIconSize)
            }
            PorcelainDivider()
            PorcelainRow(
                title: "컬렉션 \(collection.videos.count)편",
                subtitle: "앱 안 복사본 \(bytes(collection.videos.reduce(0) { $0 + $1.byteCount }))"
            ) {
                InterfaceIcon(systemName: "film.stack", size: PorcelainMetrics.rowIconSize)
            }
        }
    }

    private var toolsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    PorcelainSectionHeader(title: "전송")
                    PorcelainGroupCard {
                        NavigationLink {
                            PhotoTransferView()
                        } label: {
                            PorcelainRow(title: "기기 간 사진 전송",
                                         subtitle: "Live Photos·Motion Photos 함께 보내기",
                                         showsChevron: true) {
                                InterfaceIcon(systemName: "arrow.left.arrow.right", size: PorcelainMetrics.rowIconSize)
                            }
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    PorcelainSectionHeader(title: "저장공간")
                    storageCard
                }
                VStack(alignment: .leading, spacing: 8) {
                    PorcelainSectionHeader(title: "앱")
                    PorcelainGroupCard {
                        Button(action: openSettings) {
                            PorcelainRow(title: "설정", showsChevron: true) {
                                InterfaceIcon(systemName: "gearshape", size: PorcelainMetrics.rowIconSize)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    if let versionText = AppVersionDisplayPolicy.text() {
                        Text(versionText).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                            .padding(.horizontal, 4)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .background(PorcelainMetrics.paper)
        .navigationTitle("도구")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue)
            }
        }
        .onAppear { snapshot = StorageSnapshot.current() }
    }
}
