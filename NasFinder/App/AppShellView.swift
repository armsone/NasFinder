import SwiftUI
import UniformTypeIdentifiers
import Combine

/// 최상위 탐색: 홈 / 작업대 / 파인더 / 영상 / 도구. 아이폰은 아래 막대(감상·영상 만들기·도구 세 탭, 홈은 감상 안 입구,
/// 작업대는 머리글 단추와 시트), iPad·Mac 넓은 창은 사이드바로 같은 뿌리를 연다. iPad 세로·좁은 창은 아이콘 레일이다.
/// 작업대는 파인더·영상·도구 묶음에 속하지 않는 독립 메뉴로 홈 바로 아래에 둔다.
/// 파인더가 아이폰 밖의 기본이며, 화면은 한 번 열면 계속 살아 있어 탭을 오가도 파인더의 폴더 위치와 영상 탭의 선택이 그대로 남는다.
/// 홈은 기존 파인더 개요(즐겨찾기 선반·파일 열기·저장된 연결)를 같은 호스트에서 홈 뿌리로 보여 주고,
/// 최근 위치·기록은 자동으로 올리지 않는다. 어느 폭에서도 라벨과 목적지는 같다.
@MainActor
final class HomeTaskProgress: ObservableObject {
    static let shared = HomeTaskProgress()

    struct Snapshot: Equatable {
        let title: String
        let detail: String
        let progress: Double?
        let isPrivate: Bool
    }

    struct Entry: Identifiable {
        let id: String
        let hostID: UUID?
        let snapshot: Snapshot
        let open: () -> Void
    }

    @Published private var entries: [String: Entry] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]

    public var visibleEntries: [Entry] {
        entries.values
            .filter { PrivacyMode.isVisible($0.snapshot.isPrivate) }
            .sorted { $0.id < $1.id }
    }

    func hasActivity(_ hostID: UUID) -> Bool {
        entries.values.contains { $0.hostID == hostID }
    }

    func watch(
        id: String,
        hostID: UUID? = nil,
        changes: AnyPublisher<Void, Never>,
        snapshot: @escaping () -> Snapshot?,
        open: @escaping () -> Void
    ) {
        let refresh = { [weak self] in
            guard let self else {
                return
            }
            if let snap = snapshot() {
                self.entries[id] = Entry(id: id, hostID: hostID, snapshot: snap, open: open)
            } else {
                if self.entries[id] != nil {
                    self.entries.removeValue(forKey: id)
                }
            }
        }

        subscriptions[id] = changes
            .receive(on: RunLoop.main)
            .sink { _ in
                refresh()
            }

        refresh()
    }

    func remove(_ id: String) {
        subscriptions.removeValue(forKey: id)?.cancel()
        entries.removeValue(forKey: id)
    }
}

struct HomeTaskSection: View {
    @ObservedObject private var bridge = HomeTaskProgress.shared
    @ObservedObject private var privacy = PrivacyMode.shared

    var body: some View {
        let visible = bridge.visibleEntries
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                PorcelainSectionHeader(title: "진행 중인 작업")
                PorcelainGroupCard {
                    ForEach(visible) { entry in
                        if entry.id != visible.first?.id {
                            PorcelainDivider()
                        }
                        Button {
                            entry.open()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(entry.snapshot.title)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(PorcelainMetrics.graphite)
                                    Text(entry.snapshot.detail)
                                        .font(.system(size: 13))
                                        .foregroundStyle(PorcelainMetrics.secondary)
                                    if let progress = entry.snapshot.progress {
                                        ProgressView(value: max(0.0, min(1.0, progress)))
                                            .progressViewStyle(.linear)
                                            .padding(.top, 2)
                                    }
                                }
                                Spacer()
                                InterfaceIcon(systemName: "chevron.right", size: PorcelainMetrics.rowIconSize)
                                    .foregroundStyle(PorcelainMetrics.secondary)
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

private struct ShellToolActiveKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

private struct ShellToolHostIDKey: EnvironmentKey {
    static let defaultValue: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!
}

private struct ShellToolHostPrivateKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var shellToolActive: Bool {
        get { self[ShellToolActiveKey.self] }
        set { self[ShellToolActiveKey.self] = newValue }
    }

    var shellToolHostID: UUID {
        get { self[ShellToolHostIDKey.self] }
        set { self[ShellToolHostIDKey.self] = newValue }
    }

    var shellToolHostPrivate: Bool {
        get { self[ShellToolHostPrivateKey.self] }
        set { self[ShellToolHostPrivateKey.self] = newValue }
    }
}

extension Binding where Value == Bool {
    func shellPresentation(_ active: Bool) -> Binding<Bool> {
        Binding<Bool>(
            get: { active && wrappedValue },
            set: { if active { wrappedValue = $0 } }
        )
    }
}

enum AppTab: String, CaseIterable, Identifiable {
    case home = "홈"
    case workbench = "작업대"
    case finder = "파인더"
    case video = "영상"
    case tools = "도구"
    case settings = "설정"
    var id: String { rawValue }

    /// 아래 막대(좁은 창)에 보이는 탭: 도구 / 파인더 / 홈 / 영상 / 설정 다섯 개.
    static let rootTabs: [AppTab] = [.tools, .finder, .home, .video, .settings]

    /// 화면에 보이는 이름(Jarvis 셸). rawValue는 기존 탭 식별 값이라 바꾸지 않는다.
    var title: String {
        switch self {
        case .home: "홈"
        case .workbench: "작업대"
        case .finder: "파인더"
        case .video: "만들기"
        case .tools: "도구"
        case .settings: "설정"
        }
    }

    var shortTitle: String { title }

    /// 기존 원본 InterfaceIcon 팩의 아이콘 이름. 감상은 연결 목록(connections)·NAS·앱 로고와 겹치지 않게 재생 그림을 쓴다.
    var iconName: String {
        switch self {
        case .home: "house"
        case .workbench: "tray.2"
        case .finder: "folder"
        case .video: "film"
        case .tools: "arrow.up.arrow.down.square"
        case .settings: "gearshape"
        }
    }

}

/// 넓은 창(Mac·iPad) 사이드바의 도구 하위 목적지. 설정도 도구 묶음 안에 둔다.
enum ToolsDestination: String, CaseIterable, Identifiable {
    case hub = "도구 모음"
    case selection = "사진 선별"
    case transfer = "사진 전송"
    case superThumbnail = "수퍼 썸네일"
    case thumbnailCache = "썸네일 캐시"
    case storage = "저장공간"
    case settings = "설정"

    var id: String { rawValue }

    static var allCases: [ToolsDestination] {
        [.selection, .transfer, .superThumbnail, .thumbnailCache]
    }

    /// 화면에 보이는 이름. rawValue는 사이드바 순서 저장 키라 바꾸지 않는다.
    var title: String {
        self == .transfer ? "미디어 전송" : rawValue
    }

    var iconName: String {
        switch self {
        case .hub: "square.grid.2x2"
        case .transfer: "arrow.left.arrow.right"
        case .selection: "nf.photo_selection"
        case .superThumbnail: "nf.super_thumbnail"
        case .thumbnailCache: "nf.thumbnail_cache"
        case .storage: "nf.storage"
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
        case .collection: "nf.collection"
        }
    }
}

/// 홈의 영상·도구 구역(Mac·iPad·iPhone): 사이드바와 같은 목적지·이름·아이콘·저장된 순서로 같은 라우터 값을 바꿔 연다.
struct HomeLaunchSection: View {
    enum Kind { case workbench, video, tools }
    let kind: Kind
    @ObservedObject private var router = AppShellRouter.shared
    @ObservedObject private var sidebarOrder = SidebarOrderStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PorcelainSectionHeader(title: kind == .workbench ? AppTab.workbench.title : kind == .video ? AppTab.video.title : AppTab.tools.title)
            PorcelainGroupCard {
                switch kind {
                case .workbench:
                    launchRow(title: AppTab.workbench.title, icon: AppTab.workbench.iconName) {
                        router.request = .workbench
                    }
                case .video:
                    launchRow(title: AppTab.video.title, icon: AppTab.video.iconName) {
                        router.videoHubResetToken += 1
                        router.videoDestination = .make
                        router.request = .video
                    }
                case .tools:
                    launchRow(title: AppTab.finder.title, icon: AppTab.finder.iconName) {
                        router.finderRequest = FinderSidebarRequest(command: .home)
                        router.request = .finder
                    }
                    PorcelainDivider()
                    launchRow(title: AppTab.tools.title, icon: AppTab.tools.iconName) {
                        router.toolsDestination = .hub
                        router.toolsPushRequest = nil
                        router.request = .tools
                    }
                    PorcelainDivider()
                    launchRow(title: AppTab.settings.title, icon: AppTab.settings.iconName) {
                        router.request = .settings
                    }
                }
            }
        }
    }

    private func launchRow(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PorcelainInlineAction(title: title) { InterfaceIcon(systemName: icon, size: 24) }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

/// 사이드바의 파인더 행이 파인더에 보내는 요청. 파인더가 자기 상태·확인창·메뉴 동작으로 처리한다.
enum FinderSidebarCommand: Equatable {
    case home, rememberedLocation, open(UUID), photos, phoneHard, favorites, googlePhotos, deviceFiles, browser, addConnection, chooseNetwork
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
    case home, connection(UUID), photos, phoneHard, favorites, googlePhotos, deviceFiles, browser, other
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

    /// 아래 막대 레이아웃에서 앱 셸이 넣어 주는 작업대 입구. 있으면 뿌리 머리글 오른쪽에 작업대 단추가 보인다.
    var shellWorkbenchEntry: ShellWorkbenchEntry? {
        get { self[ShellWorkbenchEntryKey.self] }
        set { self[ShellWorkbenchEntryKey.self] = newValue }
    }
}

/// 좁은 창의 작업대 열기 동작(기존 작업대 시트를 연다).
struct ShellWorkbenchEntry {
    let open: () -> Void
}

private struct ShellWorkbenchEntryKey: EnvironmentKey {
    static var defaultValue: ShellWorkbenchEntry? { nil }
}

/// 뿌리 머리글의 작업대 단추. 앱 셸이 입구를 넣어 준 좁은 창에서만 보인다.
/// 숫자는 `WorkbenchStore.pockets`(일반 모드는 비공개 포켓·항목을 뺀 목록)에 담긴 참조 수다.
struct ShellWorkbenchToolbarButton: View {
    @Environment(\.shellWorkbenchEntry) private var entry
    @ObservedObject private var workbench = WorkbenchStore.shared

    var body: some View {
        if let entry {
            let count = workbench.pockets.reduce(0) { $0 + $1.entries.count }
            Button(action: entry.open) {
                InterfaceToolbarIcon(systemName: AppTab.workbench.iconName)
                    .overlay(alignment: .topTrailing) {
                        if count > 0 {
                            Text("\(min(count, 99))")
                                .porcelainFont(.badge)
                                .monospacedDigit()
                                .foregroundStyle(PorcelainMetrics.onAccent)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(PorcelainMetrics.solidAction, in: Capsule())
                                .offset(x: -3, y: 5)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .accessibilityLabel("작업대, 담은 항목 \(count)개")
            .accessibilityIdentifier("shell.toolbar.workbench")
        }
    }
}

/// 사이드바 한 줄: 같은 높이·정렬·선택 표시. 접힌 사이드바에서는 아이콘만 보인다.
struct ShellSidebarRow: View {
    let title: String
    let icon: String
    let isSelected: Bool
    let showsTitle: Bool
    /// 순서를 끌어 바꾸는 행. Button은 Mac Catalyst에서 누름을 먼저 잡아 시스템 끌기가 시작되지 않으므로,
    /// 이런 행은 예고편 소스 썸네일처럼 Button 없이 탭 제스처로 열고 끌기는 바깥 `.onDrag`가 맡는다.
    var isReorderable = false
    var shortcut: KeyboardShortcut? = nil
    /// 이름 오른쪽의 작은 개수 표시(작업대 담은 항목 수 등). 접힌 사이드바에서는 숨긴다.
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        if isReorderable {
            item
                .contentShape(Rectangle())
                .onTapGesture(perform: action)
                .background {
                    // 단축키는 Button에만 붙으므로 화면에 보이지 않는 Button이 맡는다.
                    if let shortcut {
                        Button("", action: action)
                            .keyboardShortcut(shortcut)
                            .opacity(0)
                            .frame(width: 0, height: 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(title)
                .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction(.default, action)
        } else {
            Button(action: action) { item }
                .buttonStyle(.plain)
                .accessibilityLabel(title)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    private var item: some View {
        PorcelainSidebarItem(title: title, isSelected: isSelected, showsTitle: showsTitle,
                             minHeight: PorcelainMetrics.shellSidebarRowHeight) {
            InterfaceIcon(systemName: icon, size: PorcelainMetrics.rowIconSize)
                .foregroundStyle(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.graphite)
        }
        .overlay(alignment: .trailing) {
            if showsTitle, let badge {
                Text(badge)
                    .porcelainFont(.badge)
                    .monospacedDigit()
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(PorcelainMetrics.card, in: Capsule())
                    .overlay(Capsule().stroke(PorcelainMetrics.line, lineWidth: 0.5))
                    .padding(.trailing, 10)
                    .accessibilityHidden(true)
            }
        }
    }
}

struct AppShellView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @EnvironmentObject private var favoriteStore: FavoriteStore
    @EnvironmentObject private var browserFavoritesStore: BrowserFavoritesStore
    @EnvironmentObject private var webHardServerController: WebHardServerController
    @State private var selectedRaw = AppShellView.initialTab.rawValue
    /// 전체 작업대로 들어오기 직전의 대표 뿌리 탭(메모리에만 보관). 작업대 뿌리의 뒤로 가기가 쓴다.
    @State private var workbenchReturnRaw = AppTab.home.rawValue
    @State private var shellIcon = AppIconChoice.current(alternateIconName: UIApplication.shared.alternateIconName)
    @AppStorage("appShell.sidebarCollapsed.v1") private var sidebarCollapsed = false
    /// 사용자가 끌어 정한 사이드바 너비. 0이면 실제 라벨 기준 자동 너비.
    @AppStorage("appShell.sidebarWidth.v1") private var sidebarUserWidth: Double = 0
    @State private var sidebarDragStartWidth: CGFloat?
    /// 넓은 창(Mac·iPad 가로) 오른쪽 작업대 패널을 펼쳐 둘지. 이 기기에만 저장한다.
    @AppStorage("appShell.workbenchPanelOpen.v2") private var workbenchPanelOpen = true
    /// 좁은 창(폰·iPad 세로 분할)에서 작업대를 아래에서 올라오는 시트로 연다.
    @State private var workbenchSheetPresented = false
    /// 가운데가 좁아 작업대가 겹쳐 뜨는 넓은 창(아이폰 가로·iPad 세로 등)에서만 쓰는 이번 실행의 열림 상태.
    /// 겹치는 패널은 저장된 열림 값으로 자동으로 뜨지 않아 브라우저를 가리지 않는다.
    @State private var workbenchOverlayShown = false
    @State private var panelDocks = true
    @State private var usesWideLayout = false
    /// iPad 세로·좁은 분할 창의 아이콘 레일을 잠시 펼쳐 내용 위에 겹쳐 보여 주는지. 내용 폭은 줄이지 않는다.
    @State private var railExpanded = false
    /// 감상 안에서 마지막으로 보던 뿌리(홈 입구 또는 파인더 위치). 다른 탭에서 감상으로 돌아올 때 쓴다.
    @State private var lastWatchRaw = AppShellView.initialTab.rawValue
    @ObservedObject private var workbench = WorkbenchStore.shared
    @State private var visited: Set<AppTab> = [AppShellView.initialTab]
    /// 이미 홈일 때 홈을 다시 누른 횟수. 파인더 호스트가 입구 화면으로 돌아오는 신호로만 쓴다.
    @State private var homeResetToken = 0
    @State private var logoPressTask: Task<Void, Never>?
    @State private var logoLongPressFired = false
    /// 설정 탭을 길게 눌러 프라이버시 모드를 바꾼 직후, 손을 뗄 때 일어나는 탭(설정 열기)을 한 번 건너뛴다.
    @State private var settingsLongPressFired = false
    @State private var railPopoverTab: AppTab?
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue = AppThemePreference.light.rawValue
    @ObservedObject private var privacy = PrivacyMode.shared
    @ObservedObject private var router = AppShellRouter.shared
    @ObservedObject private var sidebarOrder = SidebarOrderStore.shared

    /// 앱을 새로 실행하면 모든 기기에서 항상 홈이다. 이전 위치·상세·플레이어를 복원해 먼저 보여 주지 않는다.
    private static var initialTab: AppTab { .home }

    private var selected: AppTab { AppTab(rawValue: selectedRaw) ?? .finder }
    private var themeRefresh = ThemeRefresh()

    var body: some View {
        let _ = themeRefresh.theme
        GeometryReader { geometry in
            // 창의 실제 폭으로 레이아웃을 정한다(분할 화면·창 크기 조절 포함).
            // iPad는 좁은 분할 창(반 화면 등)에서도 아래 막대 대신 아이콘 레일을 쓴다. 폰 크기 창(1/3·Slide Over)만 아래 막대다.
            let usesSidebar = Self.isPadIdiom || isRunningOnMac
            // iPad 세로·좁은 창: 사이드바를 아이콘 레일로 고정하고 작업대는 겹쳐 띄운다(펼친 사이드바가 내용을 누르지 않게).
            let compactRail = Self.usesCompactRail(size: geometry.size)
                || (isRunningOnMac && geometry.size.width < PorcelainMetrics.workspaceWidth)
            let current = selected
            VStack(spacing: 0) {
            globalHeader(showBrand: !usesSidebar)
            Group {
                if usesSidebar {
                    // Mac·iPad 넓은 창(Jarvis 셸): 왼쪽 소스·이동 사이드바, 가운데 실제 브라우저·플레이어,
                    // 오른쪽 기존 작업대. 가운데가 좁아지면 작업대는 가운데 위에 겹쳐 뜬다.
                    let collapsed = compactRail || sidebarCollapsed
                    let sidebarWidth = collapsed ? 64 : resolvedSidebarWidth(windowWidth: geometry.size.width)
                    let panelWidth = Self.workbenchPanelWidth(for: geometry.size.width)
                    let docksPanel = !compactRail && geometry.size.width - sidebarWidth - panelWidth >= ui(480)
                    HStack(spacing: 0) {
                        sidebar(windowWidth: geometry.size.width, current: current, collapsed: collapsed, compactRail: compactRail)
                        Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                        content(current: current).environment(\.usesShellSidebar, true)
                            .overlay(alignment: .trailing) {
                                if workbenchOverlayShown, !docksPanel {
                                    workbenchPanel(width: panelWidth)
                                        .shadow(color: .black.opacity(0.28), radius: 14, x: -2)
                                        .transition(.move(edge: .trailing))
                                }
                            }
                        if workbenchPanelOpen, docksPanel, current != .workbench {
                            Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                            workbenchPanel(width: panelWidth)
                                .transition(.move(edge: .trailing))
                        }
                    }
                    .overlay(alignment: .leading) {
                        // 레일을 펼치면 이름이 보이는 사이드바가 내용 위에 겹친다. 바깥을 누르면 접힌다.
                        if compactRail, railExpanded {
                            ZStack(alignment: .leading) {
                                Color.black.opacity(0.18)
                                    .ignoresSafeArea()
                                    .onTapGesture { railExpanded = false }
                                    .accessibilityHidden(true)
                                sidebar(windowWidth: geometry.size.width, current: current, collapsed: false, compactRail: true)
                                    .shadow(color: .black.opacity(0.28), radius: 14, x: 2)
                            }
                            .transition(.move(edge: .leading))
                        }
                    }
                    .onChange(of: docksPanel, initial: true) { _, docks in panelDocks = docks }
                    .onChange(of: compactRail) { _, rail in if !rail { railExpanded = false } }
                } else {
                    // 탭 막대는 inset이 아니라 실제 레이아웃 영역으로 둔다. safeAreaInset은 UIKit이 호스팅하는
                    // push 목적지(미디어 고르기 등)에 전달되지 않아 그 화면의 하단 푸터가 막대 아래로 밀렸다.
                    // 작업대 입구는 뿌리 화면 머리글 오른쪽 단추가 맡는다(아래 막대에는 없다).
                    VStack(spacing: 0) {
                        content(current: current)
                            .environment(\.shellWorkbenchEntry, ShellWorkbenchEntry { workbenchSheetPresented = true })
                        bottomBar(current: current)
                    }
                }
            }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: usesSidebar, initial: true) { _, wide in
                usesWideLayout = wide
                // 넓은 창이 되면 작업대는 오른쪽 패널이 맡으므로 시트는 내린다.
                if wide { workbenchSheetPresented = false }
            }
        }
        // 모드가 바뀌면 화면 트리를 새로 만든다: 열린 시트·선택·탐색 스택·검색어가 비워져 숨겨진 내용이 남지 않는다.
        .background(PorcelainMetrics.paper.ignoresSafeArea())
        .sheet(isPresented: $workbenchSheetPresented) {
            WorkbenchView()
                .environmentObject(connectionStore)
                .environmentObject(inboxStore)
                .environmentObject(favoriteStore)
                .environmentObject(browserFavoritesStore)
                .environmentObject(webHardServerController)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .onChange(of: selectedRaw, initial: true) { _, _ in visited.insert(selected) }
        .onChange(of: privacy.epoch) { _, _ in
            router.hostedEditor?.close()
            router.finderRequest = nil
            router.toolsPushRequest = nil
            inboxStore.resetTransientPresentation()
            workbenchSheetPresented = false
            // 겹쳐 뜬 작업대·펼친 레일은 이번 실행의 임시 화면이라 모드가 바뀌면 내린다. 고정 패널은 새 트리에서
            // WorkbenchStore.pockets(일반 모드는 비공개 포켓·항목을 뺀 목록)로 다시 그려진다.
            workbenchOverlayShown = false
            railExpanded = false
            homeResetToken += 1
        }
        // 편집기 레일에서 다른 탭을 눌렀을 때: 편집은 보관된 채 해당 탭으로 이동한다.
        // 예전 작업대 탭 요청(.workbench)은 넓은 창에서 오른쪽 작업대를, 좁은 창에서 작업대 시트를 연다.
        .onChange(of: router.request) { _, tab in
            guard let tab else { return }
            router.request = nil
            if tab == .workbench {
                showWorkbench()
            } else {
                workbenchSheetPresented = false
                selectedRaw = tab.rawValue
            }
        }
        // 공유로 들어온 파일은 파인더(폰하드)에서 열린다. 홈에 있으면 파인더 탭으로 옮겨 사용자가 볼 수 있게 한다.
        .onChange(of: inboxStore.shouldPresentInbox) { _, presented in
            if presented { workbenchSheetPresented = false }
            if presented, selected == .home { selectedRaw = AppTab.finder.rawValue }
        }
        .onChange(of: selectedRaw) { _, _ in
            // 사이드바로 다른 곳을 열면 올라와 있던 편집기는 보관된 채 내려간다(편집기가 스스로 편집 세션을 보관한다).
            router.hostedEditor?.close()
            // 겹쳐 뜬 작업대는 다른 곳으로 이동하면 내려 새 화면을 가리지 않는다(고정된 오른쪽 작업대는 그대로).
            workbenchOverlayShown = false
            railExpanded = false
            if selected == .home || selected == .finder { lastWatchRaw = selectedRaw }
        }
        .onChange(of: router.videoDestination) { _, _ in router.hostedEditor?.close(); railExpanded = false }
        .onChange(of: router.toolsDestination) { _, _ in router.hostedEditor?.close(); railExpanded = false }
        .onChange(of: router.finderRequest) { _, request in
            if request != nil { router.hostedEditor?.close(); railExpanded = false }
        }
        .onAppear {
            #if DEBUG
            applyCaptureRouteIfRequested()
            #endif
        }
    }

    /// 파인더 인스턴스는 하나뿐이다(연결 목록·확인창·Google 포토·받은 파일 처리를 한 곳이 맡는다).
    /// 홈도 같은 인스턴스의 기존 개요(즐겨찾기·파일 열기·저장된 연결)를 홈 뿌리 모드로 보여 주므로 같은 처리를 두 번 하지 않는다.
    /// 홈으로 들어오거나 홈을 다시 누르면 그 인스턴스가 입구 화면으로 돌아온다.
    #if DEBUG
    private func applyCaptureRouteIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flagIndex = arguments.firstIndex(of: "--nf-capture-route"),
              arguments.indices.contains(flagIndex + 1) else { return }
        let route = arguments[flagIndex + 1]
        Task { @MainActor in
            await Task.yield()
            switch route {
            case "root_home.default": select(.home)
            case "root_finder.default": select(.finder)
            case "root_create.default": select(.video)
            case "root_tools.default": select(.tools)
            case "root_settings.default": select(.settings)
            case "favorites.list": sendFinder(.favorites)
            case "inbox.list": sendFinder(.phoneHard)
            case "local_photo_library.photos": sendFinder(.photos)
            case "web_browser.default": sendFinder(.browser)
            case "add_connection.new": sendFinder(.addConnection)
            case "workbench.default": showWorkbench()
            case "thumbnail_cache.default": router.openTools(.thumbnailCache)
            case "super_thumbnail.setup": router.openTools(.superThumbnail)
            case "photo_transfer.mode_select": router.openTools(.transfer)
            case "photo_selection.default": router.openTools(.selection)
            case "create.drafts_inline":
                router.videoDestination = .drafts
                router.request = .video
            default: return
            }
            let screen = UIScreen.main
            print("NF_CAPTURE route=\(route) theme=\(selectedThemeRawValue) icon=\(shellIcon.rawValue) privacy=\(privacy.isActive) scale=\(screen.scale) nativeScale=\(screen.nativeScale) nativeBounds=\(NSCoder.string(for: screen.nativeBounds)) contentSize=\(UIApplication.shared.preferredContentSizeCategory.rawValue) locale=\(Locale.current.identifier)")
        }
    }
    #endif

    private func content(current: AppTab) -> some View {
        ZStack {
            ConnectionListView(
                splitsPhoneHome: true,
                showsHomeRoot: current == .home,
                homeResetToken: homeResetToken,
                openFinderTab: { selectedRaw = AppTab.finder.rawValue }
            )
            .id(privacy.epoch)
            .tabLayer(current == .finder || current == .home)
            if visited.contains(.workbench) {
                WorkbenchView(rootBack: {
                    selectedRaw = AppTab(rawValue: workbenchReturnRaw).map { $0 == .workbench ? AppTab.home.rawValue : $0.rawValue } ?? AppTab.home.rawValue
                })
                    .id(privacy.epoch)
                    .environment(\.workbenchTabActive, current == .workbench)
                    .tabLayer(current == .workbench)
            }
            if visited.contains(.video) {
                VideoHubView()
                    .id(privacy.epoch)
                    .tabLayer(current == .video)
            }
            if visited.contains(.tools) {
                ToolsView()
                    .environment(\.shellToolActive, current == .tools)
                    .tabLayer(current == .tools)
            }
            if visited.contains(.settings) {
                NavigationStack {
                    AppSettingsView(connectionCount: connectionStore.connections.count)
                        .toolbar(.hidden, for: .navigationBar)
                }
                .id(privacy.epoch)
                .tabLayer(current == .settings)
            }
            // Mac: 영상 편집기는 전체 화면 커버 대신 이 내용 영역 위에 올라와 왼쪽 사이드바가 계속 보인다.
            if let hosted = router.hostedEditor {
                hosted.view
                    .id(hosted.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(PorcelainMetrics.paper.ignoresSafeArea())
                    .zIndex(10)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func globalHeader(showBrand: Bool) -> some View {
        HStack(spacing: 12) {
            if showBrand {
                HStack(spacing: 8) {
                    Image(shellIcon.previewAssetName)
                        .resizable()
                        .frame(width: 24, height: 24)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    PorcelainBrandText()
                }
            }
            Spacer()
            ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue)
            Button {
                router.request = .workbench
            } label: {
                InterfaceIcon(systemName: "tray.2", size: 18)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("작업대")
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .background(PorcelainMetrics.paper.ignoresSafeArea(edges: .top))
        .onReceive(NotificationCenter.default.publisher(for: AppIconChoice.didChangeNotification)) { _ in
            shellIcon = AppIconChoice.current(alternateIconName: UIApplication.shared.alternateIconName)
        }
    }

    // MARK: Mac·iPad 넓은 창: 하나뿐인 사이드바 (고정 홈 + 파인더·영상·도구 작은 제목 + 하위 목적지)

    /// 접힌 레일의 루트 행에 붙는 팝오버 열림 상태. 펼친 사이드바에서는 항상 닫힘.
    private func railPopoverBinding(_ tab: AppTab, collapsed: Bool) -> Binding<Bool> {
        Binding(get: { collapsed && railPopoverTab == tab },
                set: { if !$0 && railPopoverTab == tab { railPopoverTab = nil } })
    }

    private func railPopoverContent<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) { content() }
                .padding(8)
        }
        .frame(minWidth: 240, idealWidth: 260, maxWidth: 300, maxHeight: 420)
    }

    @ViewBuilder
    private func videoSidebarChildren(current: AppTab, showsTitle: Bool) -> some View {
        ShellSidebarRow(title: "미디어 고르기", icon: "photo.on.rectangle.angled",
                        isSelected: current == .video && router.videoHubChild == .mediaPicker,
                        showsTitle: showsTitle) {
            router.openVideoPicker(.trailer)
        }
        .accessibilityHint("영상 만들기용 미디어 고르기 화면을 엽니다.")
        ShellSidebarRow(title: AppTab.workbench.rawValue, icon: AppTab.workbench.iconName,
                        isSelected: current == .workbench, showsTitle: showsTitle,
                        badge: "\(workbenchEntryCount)") {
            select(.workbench)
        }
        .accessibilityValue(current == .workbench ? "선택됨, 담은 항목 \(workbenchEntryCount)개" : "담은 항목 \(workbenchEntryCount)개")
        .accessibilityHint("작업대 화면으로 이동합니다.")
        ShellSidebarRow(title: "편집본 전체", icon: "film.stack",
                        isSelected: current == .video && router.videoHubChild == .draftManager,
                        showsTitle: showsTitle) {
            router.openVideoDraftManager()
        }
        .accessibilityHint("저장된 편집본 전체 목록을 엽니다.")
    }

    @ViewBuilder
    private func toolsSidebarChildren(current: AppTab) -> some View {
        let ids = ToolsDestination.allCases.filter { $0 != .settings && $0 != .storage }.map(\.rawValue)
        SidebarReorderGroup(group: .tools, currentIDs: ids) { orderedIDs in
            ForEach(orderedIDs, id: \.self) { id in
                if let item = ToolsDestination(rawValue: id) {
                    ShellSidebarRow(title: item.title, icon: item.iconName,
                                    isSelected: current == .tools && router.toolsDestination == item,
                                    showsTitle: true, isReorderable: true) {
                        router.toolsDestination = item
                        selectedRaw = AppTab.tools.rawValue
                    }
                    .sidebarReorderable(group: .tools, itemID: id, currentIDs: ids, showsGrip: true)
                }
            }
        }
    }

    /// `collapsed`: 아이콘만 보이는 레일. `compactRail`: iPad 세로·좁은 창이라 접기 단추가 겹쳐 펼치는 사이드바를 여닫는다.
    private func sidebar(windowWidth: CGFloat, current: AppTab, collapsed: Bool, compactRail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 펼침: 앱 아이콘·브랜드·접기 단추를 맨 위 고정 한 줄에. 접힘: 아이콘 아래에 펼치기 단추.
            let appIcon = Image(shellIcon.previewAssetName)
                .resizable()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .accessibilityHidden(true)
            let toggleButton = Button { toggleSidebar(compactRail: compactRail) } label: {
                Image(interfaceSystemName: collapsed ? "arrow.right" : "arrow.left", pointSize: 24, tintable: true)
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(collapsed ? "사이드바 펼치기" : "사이드바 접기")
            .help(collapsed ? "사이드바 펼치기" : "사이드바 접기")
            if collapsed {
                VStack(spacing: 2) {
                    appIcon
                    toggleButton
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 6)
            } else {
                HStack(spacing: 8) {
                    appIcon
                        .fixedSize()
                        .layoutPriority(2)
                    PorcelainBrandText(allowsTruncation: true)
                        .layoutPriority(0)
                    Spacer(minLength: 0)
                    toggleButton
                        .fixedSize()
                        .layoutPriority(2)
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .padding(.top, 6)
            }

            // 펼친 사이드바는 다섯 루트와 활성 하위 목록을 한 목록으로 이어 스크롤한다. 접힌 레일은 루트 다섯만 보인다.
            ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                // 1. 홈
                ShellSidebarRow(title: AppTab.home.rawValue, icon: AppTab.home.iconName,
                                isSelected: current == .home, showsTitle: !collapsed) {
                    select(.home)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)

                // 2. 파인더
                ShellSidebarRow(title: AppTab.finder.title, icon: AppTab.finder.iconName,
                                isSelected: current == .finder, showsTitle: !collapsed) {
                    select(.finder)
                    if collapsed { railPopoverTab = .finder }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHint("파인더 모음화면을 엽니다.")
                .popover(isPresented: railPopoverBinding(.finder, collapsed: collapsed), arrowEdge: .trailing) {
                    railPopoverContent {
                        FinderSidebarSection(isActive: true, showsTitles: true, send: sendFinder)
                    }
                }
                if current == .finder && !collapsed {
                    ShellSidebarChildren {
                        FinderSidebarSection(isActive: true, showsTitles: true, send: sendFinder)
                    }
                }

                // 3. 만들기 (비디오/작업대)
                ShellSidebarRow(title: AppTab.video.title, icon: AppTab.video.iconName,
                                isSelected: current == .video || current == .workbench, showsTitle: !collapsed) {
                    select(.video)
                    if collapsed { railPopoverTab = .video }
                }
                .fixedSize(horizontal: false, vertical: true)
                .popover(isPresented: railPopoverBinding(.video, collapsed: collapsed), arrowEdge: .trailing) {
                    railPopoverContent { videoSidebarChildren(current: current, showsTitle: true) }
                }
                if (current == .video || current == .workbench) && !collapsed {
                    ShellSidebarChildren {
                        videoSidebarChildren(current: current, showsTitle: true)
                    }
                }

                // 4. 도구 (.settings, .storage 제외)
                ShellSidebarRow(title: AppTab.tools.title, icon: AppTab.tools.iconName,
                                isSelected: current == .tools, showsTitle: !collapsed) {
                    select(.tools)
                    if collapsed { railPopoverTab = .tools }
                }
                .fixedSize(horizontal: false, vertical: true)
                .popover(isPresented: railPopoverBinding(.tools, collapsed: collapsed), arrowEdge: .trailing) {
                    railPopoverContent { toolsSidebarChildren(current: current) }
                }
                if current == .tools && !collapsed {
                    ShellSidebarChildren {
                        toolsSidebarChildren(current: current)
                    }
                }

                // 5. 설정 (자체 루트, PrivacyToolsLongPress 활성화, Cmd+, 단축키)
                ShellSidebarRow(title: AppTab.settings.title, icon: AppTab.settings.iconName,
                                isSelected: current == .settings,
                                showsTitle: !collapsed,
                                shortcut: KeyboardShortcut(",", modifiers: .command)) {
                    if settingsLongPressFired {
                        settingsLongPressFired = false
                        return
                    }
                    select(.settings)
                }
                .fixedSize(horizontal: false, vertical: true)
                .modifier(PrivacyToolsLongPress(enabled: true, fired: $settingsLongPressFired))

            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(width: collapsed ? 64 : resolvedSidebarWidth(windowWidth: windowWidth))
        .overlay(alignment: .trailing) {
            if !collapsed && !compactRail { sidebarResizeHandle(windowWidth: windowWidth) }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // 배경만 안전 영역 밖까지 늘리고 버튼은 안전 영역 안에 둔다.
        .id(privacy.epoch)
        .background(PorcelainMetrics.sidebar.ignoresSafeArea())
    }

    private func sidebarLimits(windowWidth: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let contentMin: CGFloat = windowWidth >= 480 ? 240 : 120
        let upper = max(1, min(windowWidth * 0.5, windowWidth - contentMin))
        return (min(max(180, sidebarHeaderWidth()), upper), upper)
    }

    /// 머리글(패딩+로고24+브랜드+접기 단추48)이 잘리지 않는 실측 최소 너비. 글자 크기 설정을 따른다.
    private func sidebarHeaderWidth() -> CGFloat {
        let brand = UIFontMetrics(forTextStyle: .title3)
            .scaledFont(for: PorcelainTypeface.uiFont(size: 22, weight: .bold))
        let brandName = privacy.isActive ? PrivacyMode.brandName : "NasFinder"
        let nameWidth = ceil((brandName as NSString).size(withAttributes: [.font: brand]).width)
        return 12 + 24 + 8 + nameWidth + 8 + 48 + 4
    }

    /// 현재 루트·하위 라벨과 머리글(로고+브랜드+접기 단추)이 들어가는 최소 너비. 글자 크기 설정을 따른다.
    private func autoSidebarWidth() -> CGFloat {
        // 선택 행은 semibold이므로 가장 넓은 폭 기준으로 semibold로 잰다.
        let tile = UIFontMetrics(forTextStyle: .subheadline)
            .scaledFont(for: PorcelainTypeface.uiFont(size: 14, weight: .semibold))
        func textWidth(_ text: String, _ font: UIFont) -> CGFloat {
            ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
        let defaults = UserDefaults.standard
        var googleLabels: [String] = []
        if !defaults.bool(forKey: "googlePhotos.networkHidden.v1") {
            let custom = (defaults.string(forKey: "googlePhotos.networkName.v1") ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            googleLabels = [custom.isEmpty ? "Google 포토" : custom]
        }
        let labels = connectionStore.connections.map { $0.name }
            + ToolsDestination.allCases.map { $0.title }
            + ["미디어 고르기", AppTab.workbench.rawValue, "편집본 전체"]
            + [AppTab.home.rawValue, AppTab.finder.title, AppTab.video.title,
               AppTab.tools.title, AppTab.settings.title, AppTab.workbench.rawValue]
            + ["연결 추가·관리", "내 미디어", "폰하드", "즐겨찾기", "기기 파일", "브라우저"]
            + googleLabels
        // 패딩 12 + 루트 아이콘 26 + 간격 10 + 들여쓰기 24 + 배지·메뉴 버튼 여유 36
        let rows = (labels.map { textWidth($0, tile) }.max() ?? 0) + 12 + 26 + 10 + 24 + 36
        return max(rows, sidebarHeaderWidth())
    }

    private func resolvedSidebarWidth(windowWidth: CGFloat) -> CGFloat {
        let limits = sidebarLimits(windowWidth: windowWidth)
        let wanted = sidebarUserWidth > 0 ? CGFloat(sidebarUserWidth) : autoSidebarWidth() + 8
        return min(max(wanted, limits.min), limits.max).rounded()
    }

    private func sidebarResizeHandle(windowWidth: CGFloat) -> some View {
        let limits = sidebarLimits(windowWidth: windowWidth)
        func set(_ width: CGFloat) { sidebarUserWidth = Double(min(max(width, limits.min), limits.max).rounded()) }
        return Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            .hoverEffect(.highlight)
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = sidebarDragStartWidth ?? resolvedSidebarWidth(windowWidth: windowWidth)
                        sidebarDragStartWidth = start
                        set(start + value.translation.width)
                    }
                    .onEnded { _ in sidebarDragStartWidth = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("사이드바 너비")
            .accessibilityAdjustableAction { direction in
                let current = resolvedSidebarWidth(windowWidth: windowWidth)
                switch direction {
                case .increment: set(current + 16)
                case .decrement: set(current - 16)
                @unknown default: break
                }
            }
    }

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// 로고(Mac·iPad 사이드바). 짧게 한 번 누르면 홈, 0.6초 이상 길게 누르면 마지막으로 보던 네트워크 폴더를 연다.
    /// 길게 누른 뒤 손을 떼도 홈 클릭은 따로 일어나지 않는다. 아이폰은 아래 막대에 홈 탭이 있고 로고를 두지 않는다.
    @ViewBuilder
    private var brandLogo: some View {
        let label = HStack(spacing: 8) {
            PorcelainHeaderGlyph(size: 24)
            PorcelainBrandText()
        }
        .fixedSize(horizontal: true, vertical: false)
        label
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in beginLogoPress() }
                    .onEnded { value in endLogoPress(moved: hypot(value.translation.width, value.translation.height)) }
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel(privacy.isActive ? PrivacyMode.brandName : "NasFinder")
            .accessibilityHint(privacy.isActive
                ? "누르면 프라이버시 모드를 끄고 홈으로 갑니다."
                : "누르면 홈으로 가고, 길게 누르면 마지막으로 보던 네트워크 폴더를 엽니다.")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { if privacy.isActive { PrivacyModeFeedback.exitToHome() } else { select(.home) } }
            .accessibilityAction(named: "마지막 네트워크 폴더 열기") { if !privacy.isActive { sendFinder(.rememberedLocation) } }
    }

    @ViewBuilder
    private func sidebarHeading(_ title: String, collapsed: Bool, togglesPrivacy: Bool = false) -> some View {
        if collapsed {
            PorcelainMetrics.line.frame(height: 0.5)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .accessibilityHidden(true)
        } else if togglesPrivacy {
            // 도구 묶음 제목을 길게 누르면 프라이버시 모드가 바뀐다. 짧게 누르는 동작은 없다.
            Text(title)
                .porcelainFont(.meta, weight: .semibold)
                .foregroundStyle(PorcelainMetrics.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 14)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onLongPressGesture(minimumDuration: 0.7) { PrivacyModeFeedback.toggle() }
                .accessibilityAddTraits(.isHeader)
                .accessibilityAction(named: PrivacyModeFeedback.actionTitle) { PrivacyModeFeedback.toggle() }
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

    /// 탭 선택. 이미 홈인데 홈을 다시 누르면 홈 뿌리(입구)로 돌아오게 신호만 올린다.
    /// 작업대는 가운데 화면을 바꾸지 않고 오른쪽 패널(넓은 창) 또는 시트(좁은 창)로 연다.
    private func select(_ tab: AppTab) {
        if tab == .workbench {
            showWorkbench()
            return
        }
        if tab == .tools {
            router.toolsDestination = .hub
            router.toolsPushRequest = nil
        }
        if tab == .finder {
            sendFinder(.home)
        } else if tab == .video {
            router.videoHubResetToken += 1
            router.videoDestination = .make
        } else if tab == .home, selected == .home {
            homeResetToken += 1
        }
        selectedRaw = tab.rawValue
    }

    /// 아래 막대의 감상 탭. 다른 탭에서 오면 감상에서 보던 곳(홈 입구 또는 파인더 위치)으로 돌아가고,
    /// 감상 안에서 다시 누르면 소스 목록이 있는 홈 입구로 돌아온다(홈에서 다시 누르면 기존처럼 입구로 되돌린다).
    private func selectWatch() {
        switch selected {
        case .home, .finder: select(.home)
        default: selectedRaw = AppTab(rawValue: lastWatchRaw) == .finder ? AppTab.finder.rawValue : AppTab.home.rawValue
        }
    }

    private func toggleSidebar(compactRail: Bool) {
        if compactRail {
            withAnimation(.easeInOut(duration: 0.18)) { railExpanded.toggle() }
        } else {
            sidebarCollapsed.toggle()
        }
    }

    private static var isPadIdiom: Bool {
        #if targetEnvironment(macCatalyst)
        false
        #else
        UIDevice.current.userInterfaceIdiom == .pad && !ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    /// iPad에서 레일을 쓰는 가장 좁은 창 폭. 이보다 좁은 창(1/3 분할·Slide Over)은 폰과 같은 아래 막대를 쓴다.
    private static let padRailMinimumWidth: CGFloat = 500

    /// iPad 세로 또는 1000pt보다 좁은 창이면 사이드바를 레일로 고정하고 작업대를 겹쳐 띄운다.
    static func usesCompactRail(size: CGSize) -> Bool {
        isPadIdiom && (size.width < size.height || size.width < 1000)
    }

    private func showWorkbench() {
        workbenchSheetPresented = false
        railExpanded = false
        if selected != .workbench {
            workbenchReturnRaw = selectedRaw
        }
        selectedRaw = AppTab.workbench.rawValue
    }
    private var isWorkbenchPanelVisible: Bool {
        panelDocks ? workbenchPanelOpen : workbenchOverlayShown
    }

    /// 고정된 오른쪽 작업대는 열림 상태를 기억하고, 겹쳐 뜨는 작업대는 이번 실행에서만 연다.
    private func setWorkbenchPanelVisible(_ visible: Bool) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if panelDocks { workbenchPanelOpen = visible } else { workbenchOverlayShown = visible }
        }
    }

    /// 지금 모드에서 보이는 포켓에 담긴 참조 수(비공개는 프라이버시 모드에서만 센다).
    private var workbenchEntryCount: Int {
        workbench.pockets.reduce(0) { $0 + $1.entries.count }
    }

    static func workbenchPanelWidth(for windowWidth: CGFloat) -> CGFloat {
        min(ui(340), max(ui(280), (windowWidth * 0.3).rounded()))
    }

    // MARK: 넓은 창 오른쪽 작업대 (기존 WorkbenchView를 그대로 쓴다)

    private func workbenchPanel(width: CGFloat) -> some View {
        // 제목·담은 수·새 포켓·닫기는 WorkbenchView 뿌리의 좁은 한 줄 머리글이 맡는다(시스템 막대는 패널에서 숨김).
        VStack(spacing: 0) {
            WorkbenchView(embeddedClose: { setWorkbenchPanelVisible(false) })
                .id(privacy.epoch)
                .environment(\.usesShellSidebar, true)
        }
        .frame(width: width)
        .frame(maxHeight: .infinity)
        .background(PorcelainMetrics.paper)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("작업대")
    }

    private func beginLogoPress() {
        // 프라이버시 모드에서는 길게 누르기(마지막 폴더 열기)를 두지 않는다: 한 번 누르면 모드를 끄고 홈으로 간다.
        guard !privacy.isActive, logoPressTask == nil else { return }
        logoLongPressFired = false
        logoPressTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            logoLongPressFired = true
            sendFinder(.rememberedLocation)
        }
    }

    private func endLogoPress(moved: CGFloat) {
        logoPressTask?.cancel()
        logoPressTask = nil
        defer { logoLongPressFired = false }
        guard !logoLongPressFired, moved < 10 else { return }
        if privacy.isActive { PrivacyModeFeedback.exitToHome() } else { select(.home) }
    }

    private func sendFinder(_ command: FinderSidebarCommand) {
        selectedRaw = AppTab.finder.rawValue
        router.finderRequest = FinderSidebarRequest(command: command)
    }

    // MARK: 폰: 아래 탭 막대

    /// 좁은 창(아이폰 세로·폰 크기 iPad 창) 다섯 개 탭 막대.
    private func bottomBar(current: AppTab) -> some View {
        HStack(spacing: 0) {
            ForEach(AppTab.rootTabs) {
 tab in
                let isActive = current == tab || (tab == .video && current == .workbench)
                Button {
                    if tab == .settings, settingsLongPressFired { settingsLongPressFired = false; return }
                    select(tab)
                } label: {
                    VStack(spacing: 2) {
                        InterfaceIcon(systemName: tab.iconName, size: 26)
                        Text(tab.title).porcelainFont(.favorite)
                    }
                    .foregroundStyle(isActive ? PorcelainMetrics.accent : PorcelainMetrics.secondary)
                    .frame(maxWidth: .infinity, minHeight: 49)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityAddTraits(isActive ? .isSelected : [])
                .modifier(PrivacyToolsLongPress(enabled: tab == .settings, fired: $settingsLongPressFired))
            }
        }
        .padding(.horizontal, 8)
        // 홈 인디케이터 영역까지 배경만 채우고 버튼은 안전 영역 위에 있다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea(.container, edges: .bottom))
        .overlay(alignment: .top) {
 PorcelainMetrics.line.frame(height: 0.5) }
    }
}

/// 프라이버시 모드 전환 + 알림. 길게 누르기·접근성 동작·설정 스위치가 모두 이 길로 바꾼다.
@MainActor
enum PrivacyModeFeedback {
    static var actionTitle: String { PrivacyMode.shared.isActive ? "프라이버시 모드 끄기" : "프라이버시 모드 켜기" }

    static func toggle() {
        PrivacyMode.shared.toggle()
        let message = PrivacyMode.shared.isActive ? "프라이버시 모드를 켰습니다" : "프라이버시 모드를 껐습니다"
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: message)
    }
}

extension PrivacyModeFeedback {
    /// 프라이버시 모드에서 로고를 한 번 누르면: 모드를 끄고 홈으로 가며 머리글 글자는 NasFinder로 돌아온다.
    static func exitToHome() {
        PrivacyMode.shared.setActive(false)
        AppShellRouter.shared.request = .home
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        UIAccessibility.post(notification: .announcement, argument: "프라이버시 모드를 껐습니다")
    }
}

/// 도구 탭을 길게 누르면 모드가 바뀐다. 짧게 누르는 동작(도구 열기)은 그대로이고, 길게 누른 뒤 손을 뗄 때의 탭은 건너뛴다.
private struct PrivacyToolsLongPress: ViewModifier {
    let enabled: Bool
    @Binding var fired: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.7).onEnded { _ in
                        fired = true
                        PrivacyModeFeedback.toggle()
                        Task { try? await Task.sleep(for: .seconds(1.5)); fired = false }
                    }
                )
                .accessibilityAction(named: PrivacyModeFeedback.actionTitle) { PrivacyModeFeedback.toggle() }
        } else {
            content
        }
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

private extension View {
    /// 도구 호스트는 독립 NavigationStack 뿌리라 자동 뒤로가기가 없다. 도구 목록으로 돌아가는 보이는 뒤로가기를 단다.
    /// 호스트는 파괴하지 않고 목적지만 `.hub`로 돌리므로 진행 중인 작업과 세션은 그대로 유지된다.
    /// 더 깊이 push된 화면은 자기 자동 뒤로가기를 쓴다(이 툴바는 뿌리에만 붙는다).
    func toolsHostBackBar(action: @escaping () -> Void) -> some View {
        toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: action) {
                        Label("뒤로", systemImage: "chevron.backward")
                    }
                    .accessibilityLabel("도구로 돌아가기")
                }
            }
    }
}

/// 도구: 기기 간 사진 전송과 저장공간. 설정은 레일/아래쪽 목록에서도 연다.
struct ToolsView: View {
    @Environment(\.shellToolActive) private var shellToolActive
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @EnvironmentObject private var connectionStore: ConnectionStore
    @ObservedObject private var router = AppShellRouter.shared
    @ObservedObject private var privacy = PrivacyMode.shared
    @ObservedObject private var bridge = HomeTaskProgress.shared
    @State private var snapshot = StorageSnapshot.current()
    @ObservedObject private var workbench = WorkbenchStore.shared
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue =
        AppThemePreference.light.rawValue

    struct ToolHost: Identifiable {
        let id: UUID
        let destination: ToolsDestination
        let epoch: Int
        let isPrivate: Bool
    }

    @State private var hosts: [ToolHost] = []
    @State private var activeHostID: UUID?

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
        ZStack {
            ForEach(hosts.filter { $0.id == activeHostID || $0.destination == .transfer || $0.destination == .superThumbnail }) { host in
                NavigationStack {
                    switch host.destination {
                    case .hub: toolsList.toolbar(.hidden, for: .navigationBar)
                    case .transfer: PhotoTransferView().toolsHostBackBar { router.toolsDestination = .hub }
                    case .selection: PhotoSelectionView().toolsHostBackBar { router.toolsDestination = .hub }
                    case .superThumbnail: SuperThumbnailView().toolsHostBackBar { router.toolsDestination = .hub }
                    case .thumbnailCache:
                        ThumbnailCacheSettingsView { _ in }.toolsHostBackBar { router.toolsDestination = .hub }
                    case .storage: storagePage
                    case .settings: AppSettingsView(connectionCount: connectionStore.connections.count)
                    }
                }
                .environment(\.shellToolHostID, host.id)
                .environment(\.shellToolHostPrivate, host.isPrivate)
                .environment(\.shellToolActive, shellToolActive && activeHostID == host.id && PrivacyMode.isVisible(host.isPrivate))
                .tabLayer(activeHostID == host.id && PrivacyMode.isVisible(host.isPrivate))
            }
        }
        .onChange(of: router.toolsDestination, initial: true) { _, destination in
            activate(destination, requestedHostID: router.toolsHostRequest)
        }
        .onChange(of: router.toolsHostRequest) { _, requested in
            if let requested {
                if let target = hosts.first(where: { $0.id == requested }) {
                    activate(target.destination, requestedHostID: requested)
                }
            }
        }
        .onChange(of: router.toolsPushRequest) { _, destination in consumePushRequest(destination) }
        .onChange(of: privacy.epoch) { _, _ in
            hosts = hosts.filter { bridge.hasActivity($0.id) }
            activeHostID = nil
            router.toolsHostRequest = nil
            router.toolsDestination = .hub
            activate(.hub)
        }
        .onAppear {
            consumePushRequest(router.toolsPushRequest)
            activate(router.toolsDestination, requestedHostID: router.toolsHostRequest)
        }
    }

    private func activate(_ destination: ToolsDestination, requestedHostID: UUID? = nil) {
        if let requestedHostID {
            if let existing = hosts.first(where: { $0.id == requestedHostID }) {
                if PrivacyMode.isVisible(existing.isPrivate) {
                    activeHostID = existing.id
                    router.toolsDestination = existing.destination
                }
            }
            return
        }

        if let currentID = activeHostID, let current = hosts.first(where: { $0.id == currentID }),
           current.destination == destination, PrivacyMode.isVisible(current.isPrivate) {
            return
        }

        if let match = hosts.first(where: { $0.destination == destination && $0.epoch == privacy.epoch && PrivacyMode.isVisible($0.isPrivate) }) {
            activeHostID = match.id
            return
        }

        let newHost = ToolHost(
            id: UUID(),
            destination: destination,
            epoch: privacy.epoch,
            isPrivate: privacy.isActive
        )
        hosts.append(newHost)
        activeHostID = newHost.id
    }

    private func consumePushRequest(_ destination: ToolsDestination?) {
        guard let destination else {
            return
        }
        let requested = router.toolsHostRequest
        router.toolsDestination = destination
        activate(destination, requestedHostID: requested)
        router.toolsHostRequest = nil
        router.toolsPushRequest = nil
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
                InterfaceIcon(systemName: "nf.storage", size: PorcelainMetrics.rowIconSize)
            }
            if snapshot.total > 0 {
                ProgressView(value: snapshot.fraction).tint(SkyBreezeTheme.accent)
                    .padding(.horizontal, 12).padding(.bottom, 10)
            }
            PorcelainDivider()
            PorcelainRow(
                title: "작업대 포켓 \(workbench.pockets.count)개 · 참조 \(workbench.pockets.reduce(0) { $0 + $1.entries.count })개",
                subtitle: "위치만 기록 · 예전 영상 재료 복사본 \(bytes(MaterialBasketStore.shared.legacyCopyByteCount))"
            ) {
                InterfaceIcon(systemName: "tray.2", size: PorcelainMetrics.rowIconSize)
            }
        }
    }

    private var toolsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    PorcelainSectionHeader(title: "도구")
                    PorcelainGroupCard {
                        ForEach(Array(ToolsDestination.allCases.enumerated()), id: \.element.id) { index, destination in
                            if index > 0 {
                                PorcelainDivider()
                            }
                            Button {
                                router.toolsDestination = destination
                            } label: {
                                PorcelainRow(
                                    title: destination.title,
                                    showsChevron: true
                                ) {
                                    InterfaceIcon(systemName: destination.iconName, size: PorcelainMetrics.rowIconSize)
                                }
                            }
                            .buttonStyle(.plain)
                        }
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
    }

    private var usesPhoneRootHeader: Bool { PhoneRootHeaderPolicy.isEnabled(usesShellSidebar: usesShellSidebar) }
}

// MARK: - 아이폰 뿌리 화면 머리글과 홈

/// 아이폰 뿌리(홈·파인더) 맨 위 한 줄: 화면 제목과 오른쪽 버튼. 시스템 막대 대신 앱 소유 머리글을 쓴다.
struct PhoneRootHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 0) {
            Text(title)
                .porcelainFont(.bigTitle)
                .foregroundStyle(PorcelainMetrics.graphite)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            HStack(spacing: 0) {
                ShellWorkbenchToolbarButton()
                trailing()
            }
                .fixedSize()
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 52)
        // 배경만 상태 막대·Dynamic Island 뒤까지 늘리고, 제목·버튼은 시스템 안전 영역 안에 둔다.
        .background(PorcelainMetrics.paper.ignoresSafeArea(.container, edges: .top))
    }
}

enum PhoneRootHeaderPolicy {
    /// 사이드바가 없는 폭(아이폰·좁은 iPad 창)에서만 앱 소유 머리글을 쓴다. Mac은 항상 시스템 막대.
    static func isEnabled(usesShellSidebar: Bool) -> Bool {
        false
    }
}
extension View {
    /// 아이폰 폭의 뿌리 화면 머리글을 통일한다: 시스템 막대를 숨기고 왼쪽 제목 + 오른쪽 `[주 행동][테마]` 한 줄.
    /// 하위 화면은 자기 시스템 막대(뒤로)를 그대로 쓰며, 사이드바가 있는 넓은 창과 Mac에서는 아무것도 바꾸지 않는다.
    func phoneRootHeader<Trailing: View>(
        _ title: String, enabled: Bool, @ViewBuilder trailing: @escaping () -> Trailing
    ) -> some View {
        self
            .toolbar(enabled ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if enabled { PhoneRootHeader(title: title, trailing: trailing) }
            }
    }
}

// MARK: - 사이드바 묶음 안 순서 바꾸기 (Mac·iPad 전용, 이 기기에만 저장)

/// 사이드바 묶음. 순서 바꾸기는 같은 묶음 안에서만 된다.
enum SidebarGroup: String, Hashable, CaseIterable {
    case finder, video, tools
    /// 이 기기에만 쓰는 순서 기본 설정 키(클라우드 동기화 없음).
    var storageKey: String { "appShell.sidebarOrder.\(rawValue).v1" }
}

/// 파인더 묶음의 고정 메뉴 ID. 저장된 연결은 연결 UUID 문자열을 ID로 쓴다. 홈 행은 고정이라 순서에 넣지 않는다.
enum SidebarFinderItemID {
    static let photos = "photos"
    static let phoneHard = "phoneHard"
    static let favorites = "favorites"
    static let googlePhotos = "googlePhotos"
    static let deviceFiles = "deviceFiles"
    static let browser = "browser"
    static let manageConnections = "manageConnections"

    /// 지금 보이는 항목의 ID를 기본 순서(즐겨찾기 → 내 미디어 → 폰하드 → 기기 파일 → 연결 → Google 포토 → 연결 추가·관리 → Browser)로.
    /// 저장된 순서가 있으면 그대로 두고 새 ID만 꼬리에 붙는다(`SidebarOrderPolicy.normalized`).
    static func current(connectionIDs: [UUID], showsGooglePhotos: Bool) -> [String] {
        [favorites, photos, phoneHard, deviceFiles] + connectionIDs.map(\.uuidString)
            + (showsGooglePhotos ? [googlePhotos] : []) + [manageConnections, browser]
    }
}

/// 저장된 순서를 지금 있는 항목에 맞추는 순수 규칙. 입출력이 없어 그대로 검증할 수 있다.
enum SidebarOrderPolicy {
    /// 사라진 ID는 지우고, 중복은 한 번만 두고, 새 ID는 지금 순서대로 꼬리에 붙인다. 나머지 순서는 그대로다.
    static func normalized(stored: [String], current: [String]) -> [String] {
        let valid = Set(current)
        var seen = Set<String>()
        var result: [String] = []
        for id in stored where valid.contains(id) && seen.insert(id).inserted { result.append(id) }
        for id in current where seen.insert(id).inserted { result.append(id) }
        return result
    }

    /// `dragged`를 `target` 자리로 옮긴다(앞에서 뒤로면 target 뒤, 뒤에서 앞으로면 target 앞).
    static func moving(_ order: [String], _ dragged: String, over target: String) -> [String] {
        guard dragged != target,
              let from = order.firstIndex(of: dragged),
              let to = order.firstIndex(of: target) else { return order }
        var result = order
        result.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        return result
    }

    static func moving(_ order: [String], _ id: String, by offset: Int) -> [String] {
        guard let from = order.firstIndex(of: id) else { return order }
        let to = from + offset
        guard order.indices.contains(to) else { return order }
        return moving(order, id, over: order[to])
    }
}

/// 사이드바 묶음별 순서. 순서는 기기 로컬 UserDefaults에만 쓴다.
@MainActor
final class SidebarOrderStore: ObservableObject {
    static let shared = SidebarOrderStore()

    @Published private(set) var stored: [SidebarGroup: [String]] = [:]
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        for group in SidebarGroup.allCases {
            if let text = defaults.string(forKey: group.storageKey),
               let data = text.data(using: .utf8),
               let ids = try? JSONDecoder().decode([String].self, from: data) {
                stored[group] = ids
            }
        }
    }

    /// 저장된 순서가 없으면 지금 순서 그대로다.
    func ordered(_ group: SidebarGroup, current: [String]) -> [String] {
        SidebarOrderPolicy.normalized(stored: stored[group] ?? [], current: current)
    }

    private func commit(_ group: SidebarGroup, _ order: [String]) {
        stored[group] = order
        if let data = try? JSONEncoder().encode(order), let text = String(data: data, encoding: .utf8) {
            defaults.set(text, forKey: group.storageKey)
        }
    }

    /// 같은 묶음 안에서 위/아래로 `offset`칸. 손잡이 끌기·오른쪽 메뉴·손쉬운 사용이 모두 이 길로 저장한다.
    func moveStep(group: SidebarGroup, id: String, by offset: Int, current: [String], animated: Bool = false) {
        let order = ordered(group, current: current)
        let moved = SidebarOrderPolicy.moving(order, id, by: offset)
        guard moved != order else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.12)) { commit(group, moved) }
        } else {
            commit(group, moved)
        }
    }
}

/// 사이드바 한 묶음의 행 배치.
struct SidebarReorderGroup<Content: View>: View {
    let group: SidebarGroup
    let currentIDs: [String]
    let content: ([String]) -> Content
    @ObservedObject private var store = SidebarOrderStore.shared

    init(group: SidebarGroup, currentIDs: [String], @ViewBuilder content: @escaping ([String]) -> Content) {
        self.group = group
        self.currentIDs = currentIDs
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SidebarReorderMetrics.rowSpacing) {
            content(store.ordered(group, current: currentIDs))
        }
    }
}

enum SidebarReorderMetrics {
    static let rowSpacing: CGFloat = 2
    static let gripWidth: CGFloat = 20
}

extension View {
    /// 사이드바 행을 같은 묶음 안에서 행 전체를 끌어 순서를 바꾼다(왼쪽 손잡이 없음).
    /// Mac은 포인터로 바로 끌고, 아이폰·아이패드는 행을 잠깐 누른 채 끈다. 짧게 누르면 그대로 이동한다.
    /// 시스템 끌어놓기(NSItemProvider·DropDelegate)는 쓰지 않는다: 제스처가 포인터 이동만큼 행을 따라 움직이고,
    /// 행 높이를 넘을 때마다 저장 순서를 한 칸씩 바꾼다. 행 탭·메뉴와 제스처가 겹치지 않는다.
    /// `showsGrip`은 예전 호출부와의 호환용으로 남겨 둔 값이며 더 이상 아무것도 그리지 않는다.
    func sidebarReorderable(group: SidebarGroup, itemID: String, currentIDs: [String], showsGrip: Bool = true) -> some View {
        modifier(SidebarReorderModifier(group: group, itemID: itemID, currentIDs: currentIDs))
    }
}

private struct SidebarReorderModifier: ViewModifier {
    let group: SidebarGroup
    let itemID: String
    let currentIDs: [String]
    @ObservedObject private var store = SidebarOrderStore.shared
    @State private var rowHeight: CGFloat = PorcelainMetrics.shellSidebarRowHeight
    /// 끌기 시작 때의 순서 위치. nil이면 끌고 있지 않다.
    @State private var startIndex: Int?
    @State private var pointerShift: CGFloat = 0

    private var isRunningOnMac: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #else
        ProcessInfo.processInfo.isiOSAppOnMac
        #endif
    }

    func body(content: Content) -> some View {
        let order = store.ordered(group, current: currentIDs)
        let index = order.firstIndex(of: itemID) ?? 0
        let stride = rowHeight + SidebarReorderMetrics.rowSpacing
        let dragging = startIndex != nil
        let row = content
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { rowHeight = proxy.size.height }
                        .onChange(of: proxy.size.height) { _, height in rowHeight = height }
                }
            }
            // 끄는 동안 행이 들려 보이고 놓일 자리가 윤곽으로 표시된다. 다른 행은 한 칸씩 비켜 준다.
            .overlay {
                if dragging {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(PorcelainMetrics.accent, lineWidth: 1.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(dragging ? 0.18 : 0), radius: dragging ? 6 : 0, y: dragging ? 2 : 0)
            // 행은 저장 순서 자리에서 포인터가 움직인 만큼 더 따라간다.
            .offset(y: dragging ? pointerShift - CGFloat(index - (startIndex ?? index)) * stride : 0)
            .zIndex(dragging ? 1 : 0)
            .opacity(dragging ? 0.9 : 1)
            .simultaneousGesture(reorderGesture(index: index, stride: stride))
            .accessibilityIdentifier("sidebar.\(group.rawValue).\(itemID)")
        pointerMenu(row, order: order)
            // 설정 행을 움직이지 않고 길게 누르면 바로 전환한다. 이동한 경우에는 끌기에 양보한다.
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.7, maximumDistance: 8)
                    .onEnded { _ in PrivacyModeFeedback.toggle() },
                including: group == .tools && itemID == ToolsDestination.settings.rawValue ? .all : .none
            )
            .accessibilityAction(named: "위로 이동") {
                store.moveStep(group: group, id: itemID, by: -1, current: currentIDs)
            }
            .accessibilityAction(named: "아래로 이동") {
                store.moveStep(group: group, id: itemID, by: 1, current: currentIDs)
            }
    }

    /// 터치의 시스템 컨텍스트 메뉴가 행 끌기·설정 길게 누르기를 가로채지 않도록 포인터에서만 제공한다.
    @ViewBuilder
    private func pointerMenu<Row: View>(_ row: Row, order: [String]) -> some View {
        if isRunningOnMac {
            row.contextMenu {
                Section("순서") {
                    Button("위로 이동", interfaceSystemImage: "arrow.up") {
                        store.moveStep(group: group, id: itemID, by: -1, current: currentIDs)
                    }
                    .disabled(order.first == itemID)
                    Button("아래로 이동", interfaceSystemImage: "arrow.down") {
                        store.moveStep(group: group, id: itemID, by: 1, current: currentIDs)
                    }
                    .disabled(order.last == itemID)
                }
                // 키보드·포인터로도 모드를 바꿀 수 있게 설정 행의 메뉴에 둔다(설정 화면에도 같은 스위치가 있다).
                if group == .tools && itemID == ToolsDestination.settings.rawValue {
                    Section("프라이버시") {
                        Button(PrivacyModeFeedback.actionTitle, interfaceSystemImage: "eye.slash") { PrivacyModeFeedback.toggle() }
                    }
                }
            }
        } else {
            row
        }
    }

    /// Mac: 4pt 넘게 움직이면 바로 끌기. 터치: 0.3초 눌러 잡은 뒤에만 끌기(그 전의 세로 움직임은 스크롤에 양보).
    private func reorderGesture(index: Int, stride: CGFloat) -> AnyGesture<Void> {
        if isRunningOnMac {
            return AnyGesture(
                DragGesture(minimumDistance: 4, coordinateSpace: .global)
                    .onChanged { value in dragChanged(value.translation.height, index: index, stride: stride) }
                    .onEnded { _ in dragEnded() }
                    .map { _ in () }
            )
        }
        return AnyGesture(
            LongPressGesture(minimumDuration: 0.3)
                .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
                .onChanged { value in
                    if case .second(true, let drag?) = value {
                        dragChanged(drag.translation.height, index: index, stride: stride)
                    }
                }
                .onEnded { _ in dragEnded() }
                .map { _ in () }
        )
    }

    private func dragChanged(_ translation: CGFloat, index: Int, stride: CGFloat) {
        let start = startIndex ?? index
        if startIndex == nil {
            startIndex = start
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        pointerShift = translation
        let count = store.ordered(group, current: currentIDs).count
        let target = min(max(start + Int((pointerShift / stride).rounded()), 0), count - 1)
        let current = store.ordered(group, current: currentIDs).firstIndex(of: itemID) ?? target
        if target != current {
            store.moveStep(group: group, id: itemID, by: target - current,
                           current: currentIDs, animated: true)
        }
    }

    private func dragEnded() {
        withAnimation(.easeOut(duration: 0.12)) {
            startIndex = nil
            pointerShift = 0
        }
    }
}
