import SwiftUI
import UniformTypeIdentifiers

/// 최상위 탐색: 홈 / 작업대 / 파인더 / 영상 / 도구. 아이폰은 아래 막대(감상·영상 만들기·도구 세 탭, 홈은 감상 안 입구,
/// 작업대는 머리글 단추와 시트), iPad·Mac 넓은 창은 사이드바로 같은 뿌리를 연다. iPad 세로·좁은 창은 아이콘 레일이다.
/// 작업대는 파인더·영상·도구 묶음에 속하지 않는 독립 메뉴로 홈 바로 아래에 둔다.
/// 파인더가 아이폰 밖의 기본이며, 화면은 한 번 열면 계속 살아 있어 탭을 오가도 파인더의 폴더 위치와 영상 탭의 선택이 그대로 남는다.
/// 홈은 기존 파인더 개요(즐겨찾기 선반·파일 열기·저장된 연결)를 같은 호스트에서 홈 뿌리로 보여 주고,
/// 최근 위치·기록은 자동으로 올리지 않는다. 어느 폭에서도 라벨과 목적지는 같다.
enum AppTab: String, CaseIterable, Identifiable {
    case home = "홈"
    case workbench = "작업대"
    case finder = "파인더"
    case video = "영상"
    case tools = "도구"
    var id: String { rawValue }

    /// 아래 막대(좁은 창)에 보이는 탭: 감상 / 영상 만들기 / 도구 세 개.
    /// 홈은 감상 안의 입구(소스 목록)로 접히고, 작업대는 맨 위 머리글 단추와 기존 시트로 연다.
    /// 다섯 rawValue와 예전 요청(`.home`·`.workbench`)은 그대로 받는다.
    static let rootTabs: [AppTab] = [.finder, .video, .tools]

    /// 화면에 보이는 이름(Jarvis 셸). rawValue는 기존 탭 식별 값이라 바꾸지 않는다.
    /// 파인더는 '감상', 영상은 '영상 만들기'로 보인다. 아래 막대는 좁아서 영상만 짧게 쓴다.
    var title: String {
        switch self {
        case .finder: "감상"
        case .video: "영상 만들기"
        default: rawValue
        }
    }

    var shortTitle: String { self == .video ? "영상" : title }

    /// 기존 원본 InterfaceIcon 팩의 아이콘 이름. 감상은 연결 목록(connections)·NAS·앱 로고와 겹치지 않게 재생 그림을 쓴다.
    var iconName: String {
        switch self {
        case .home: "house"
        case .workbench: "tray.2"
        case .finder: "play.circle"
        case .video: "film"
        case .tools: "arrow.up.arrow.down.square"
        }
    }

}

/// 넓은 창(Mac·iPad) 사이드바의 도구 하위 목적지. 설정도 도구 묶음 안에 둔다.
enum ToolsDestination: String, CaseIterable, Identifiable {
    case transfer = "사진 전송"
    case selection = "사진 선별"
    case storage = "저장공간"
    case settings = "설정"
    var id: String { rawValue }

    /// 화면에 보이는 이름. rawValue는 사이드바 순서 저장 키라 바꾸지 않는다.
    var title: String { self == .transfer ? "미디어 전송" : rawValue }

    var iconName: String {
        switch self {
        case .transfer: "arrow.left.arrow.right"
        case .selection: "nf.photo_selection"
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
                    launchRow(title: AppTab.workbench.rawValue, icon: AppTab.workbench.iconName) {
                        router.request = .workbench
                    }
                case .video:
                    let ids = sidebarOrder.ordered(.video, current: VideoDestination.allCases.map(\.rawValue))
                    // 컬렉션은 홈에서 즐겨찾기 바로 아래 입구(HomeCollectionEntry)로 열어 여기서는 뺀다.
                    // 영상 탭·사이드바의 목적지 목록은 그대로다.
                    let items = ids.compactMap(VideoDestination.init(rawValue:)).filter { $0 != .collection }
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        if index > 0 { PorcelainDivider() }
                        launchRow(title: item.title, icon: item.iconName) {
                            router.videoDestination = item
                            router.request = .video
                        }
                    }
                case .tools:
                    let ids = sidebarOrder.ordered(.tools, current: ToolsDestination.allCases.map(\.rawValue))
                    let items = ids.compactMap(ToolsDestination.init(rawValue:))
                    ForEach(Array(items.enumerated()), id: \.element) { index, item in
                        if index > 0 { PorcelainDivider() }
                        launchRow(title: item.title, icon: item.iconName) {
                            router.toolsDestination = item
                            router.request = .tools
                        }
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

/// 홈(Mac·iPad·iPhone)의 즐겨찾기 바로 아래에 두는 작은 컬렉션 입구. 영상 탭·사이드바와 같은 라우터 값으로
/// 컬렉션을 열고, 개수는 지금 모드에서 보이는 컬렉션만 센다.
struct HomeCollectionEntry: View {
    @ObservedObject private var router = AppShellRouter.shared
    @ObservedObject private var collection = MovieCollectionStore.shared

    var body: some View {
        let title = "\(VideoDestination.collection.title) \(collection.videos.count)편"
        PorcelainGroupCard {
            Button {
                router.videoDestination = .collection
                router.request = .video
            } label: {
                PorcelainInlineAction(title: title) {
                    InterfaceIcon(systemName: VideoDestination.collection.iconName, size: 24)
                }
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
        }
    }
}

/// 사이드바의 파인더 행이 파인더에 보내는 요청. 파인더가 자기 상태·확인창·메뉴 동작으로 처리한다.
enum FinderSidebarCommand: Equatable {
    case home, rememberedLocation, open(UUID), photos, phoneHard, favorites, googlePhotos, deviceFiles, browser, addConnection
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
    var tint: Color? = nil
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
                .foregroundStyle(tint ?? PorcelainMetrics.graphite)
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
    @AppStorage("appShell.sidebarCollapsed.v1") private var sidebarCollapsed = false
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
    /// 도구 탭을 길게 눌러 프라이버시 모드를 바꾼 직후, 손을 뗄 때 일어나는 탭(도구 열기)을 한 번 건너뛴다.
    @State private var toolsLongPressFired = false
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
            let usesSidebar = geometry.size.width >= PorcelainMetrics.workspaceWidth
                || (Self.isPadIdiom && geometry.size.width >= Self.padRailMinimumWidth)
            // iPad 세로·좁은 창: 사이드바를 아이콘 레일로 고정하고 작업대는 겹쳐 띄운다(펼친 사이드바가 내용을 누르지 않게).
            let compactRail = Self.usesCompactRail(size: geometry.size)
            let current = selected
            Group {
                if usesSidebar {
                    // Mac·iPad 넓은 창(Jarvis 셸): 왼쪽 소스·이동 사이드바, 가운데 실제 브라우저·플레이어,
                    // 오른쪽 기존 작업대. 가운데가 좁아지면 작업대는 가운데 위에 겹쳐 뜬다.
                    let collapsed = compactRail || sidebarCollapsed
                    let sidebarWidth = collapsed ? 64 : PorcelainMetrics.sidebarWidth(for: geometry.size.width)
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
                        if workbenchPanelOpen, docksPanel {
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
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onChange(of: usesSidebar, initial: true) { _, wide in
                usesWideLayout = wide
                // 넓은 창이 되면 작업대는 오른쪽 패널이 맡으므로 시트는 내린다.
                if wide { workbenchSheetPresented = false }
            }
        }
        // 모드가 바뀌면 화면 트리를 새로 만든다: 열린 시트·선택·탐색 스택·검색어가 비워져 숨겨진 내용이 남지 않는다.
        .id(privacy.epoch)
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
    }

    /// 파인더 인스턴스는 하나뿐이다(연결 목록·확인창·Google 포토·받은 파일 처리를 한 곳이 맡는다).
    /// 홈도 같은 인스턴스의 기존 개요(즐겨찾기·파일 열기·저장된 연결)를 홈 뿌리 모드로 보여 주므로 같은 처리를 두 번 하지 않는다.
    /// 홈으로 들어오거나 홈을 다시 누르면 그 인스턴스가 입구 화면으로 돌아온다.
    private func content(current: AppTab) -> some View {
        ZStack {
            ConnectionListView(
                splitsPhoneHome: true,
                showsHomeRoot: current == .home,
                homeResetToken: homeResetToken,
                openFinderTab: { selectedRaw = AppTab.finder.rawValue }
            )
            .tabLayer(current == .finder || current == .home)
            if visited.contains(.workbench) { WorkbenchView().tabLayer(current == .workbench) }
            if visited.contains(.video) { VideoHubView().tabLayer(current == .video) }
            if visited.contains(.tools) { ToolsView().tabLayer(current == .tools) }
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

    // MARK: Mac·iPad 넓은 창: 하나뿐인 사이드바 (고정 홈 + 파인더·영상·도구 작은 제목 + 하위 목적지)

    /// `collapsed`: 아이콘만 보이는 레일. `compactRail`: iPad 세로·좁은 창이라 접기 단추가 겹쳐 펼치는 사이드바를 여닫는다.
    private func sidebar(windowWidth: CGFloat, current: AppTab, collapsed: Bool, compactRail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 브랜드와 접기 단추는 맨 위 한 줄에 둔다. 아래 끝으로 밀어 두지 않는다.
            HStack(spacing: 4) {
                if !collapsed {
                    brandLogo
                    Spacer(minLength: 0)
                }
                Button { toggleSidebar(compactRail: compactRail) } label: {
                    // 접힘 상태와 상관없이 같은 꺾쇠 모양이고 방향만 바뀐다(펼치면 왼쪽, 접으면 오른쪽).
                    Image(interfaceSystemName: collapsed ? "chevron.right" : "chevron.left", pointSize: 17)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(PorcelainMetrics.secondary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .frame(maxWidth: collapsed ? .infinity : nil)
                .accessibilityLabel(collapsed ? "사이드바 펼치기" : "사이드바 접기")
                .help(collapsed ? "사이드바 펼치기" : "사이드바 접기")
            }
            .padding(.leading, collapsed ? 0 : 12)
            .padding(.trailing, collapsed ? 0 : 4)
            .padding(.top, 6)

            // 짧은 창에서는 사이드바만 스크롤한다.
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    // 홈은 묶음 밖에 고정한다: 기능 입구만 있는 뿌리라 파인더 소스 순서와 섞이지 않는다.
                    ShellSidebarRow(title: AppTab.home.rawValue, icon: AppTab.home.iconName,
                                    isSelected: current == .home, showsTitle: !collapsed) {
                        select(.home)
                    }
                    .padding(.top, 8)
                    // 감상: 파인더의 지금 위치(폴더·보기 방식)로 돌아간다. 연결 목록은 아래 소스 묶음에 있다.
                    ShellSidebarRow(title: AppTab.finder.title, icon: AppTab.finder.iconName,
                                    isSelected: current == .finder, showsTitle: !collapsed) {
                        select(.finder)
                    }
                    .accessibilityHint("보던 폴더와 보기 방식으로 돌아갑니다.")
                    // 작업대는 오른쪽 패널로 열고 닫는다. 숫자는 지금 보이는 포켓에 담긴 참조 수다.
                    ShellSidebarRow(title: AppTab.workbench.rawValue, icon: AppTab.workbench.iconName,
                                    isSelected: isWorkbenchPanelVisible, showsTitle: !collapsed,
                                    badge: "\(workbenchEntryCount)") {
                        railExpanded = false
                        setWorkbenchPanelVisible(!isWorkbenchPanelVisible)
                    }
                    .accessibilityValue(isWorkbenchPanelVisible ? "열림, 담은 항목 \(workbenchEntryCount)개" : "닫힘, 담은 항목 \(workbenchEntryCount)개")
                    .accessibilityHint("오른쪽 작업대를 열거나 닫습니다.")
                    sidebarHeading("소스", collapsed: collapsed)
                    FinderSidebarSection(isActive: current == .finder, showsTitles: !collapsed, send: sendFinder)
                    sidebarHeading(AppTab.video.title, collapsed: collapsed)
                    // 묶음 안 순서는 이 기기에만 저장한다. 선택 표시는 목적지 값으로 하므로 순서가 바뀌어도 그대로다.
                    SidebarReorderGroup(group: .video, currentIDs: VideoDestination.allCases.map(\.rawValue)) { orderedIDs in
                        ForEach(orderedIDs, id: \.self) { id in
                            if let item = VideoDestination(rawValue: id) {
                                ShellSidebarRow(title: item.title, icon: item.iconName,
                                                isSelected: current == .video && router.videoDestination == item,
                                                showsTitle: !collapsed, isReorderable: true) {
                                    router.videoDestination = item
                                    selectedRaw = AppTab.video.rawValue
                                }
                                .sidebarReorderable(group: .video, itemID: id,
                                                    currentIDs: VideoDestination.allCases.map(\.rawValue),
                                                    showsGrip: !collapsed)
                            }
                        }
                    }
                    sidebarHeading("도구", collapsed: collapsed, togglesPrivacy: true)
                    SidebarReorderGroup(group: .tools, currentIDs: ToolsDestination.allCases.map(\.rawValue)) { orderedIDs in
                        ForEach(orderedIDs, id: \.self) { id in
                            if let item = ToolsDestination(rawValue: id) {
                                ShellSidebarRow(title: item.title, icon: item.iconName,
                                                isSelected: current == .tools && router.toolsDestination == item,
                                                showsTitle: !collapsed, isReorderable: true,
                                                shortcut: item == .settings ? KeyboardShortcut(",", modifiers: .command) : nil) {
                                    router.toolsDestination = item
                                    selectedRaw = AppTab.tools.rawValue
                                }
                                .sidebarReorderable(group: .tools, itemID: id,
                                                    currentIDs: ToolsDestination.allCases.map(\.rawValue),
                                                    showsGrip: !collapsed)
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
        }
        .frame(width: collapsed ? 64 : PorcelainMetrics.sidebarWidth(for: windowWidth))
        .frame(maxHeight: .infinity, alignment: .top)
        // 배경만 안전 영역 밖까지 늘리고 버튼은 안전 영역 안에 둔다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea())
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
        if tab == .workbench { showWorkbench(); return }
        if tab == .home, selected == .home { homeResetToken += 1 }
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
        if usesWideLayout {
            setWorkbenchPanelVisible(true)
        } else {
            workbenchSheetPresented = true
        }
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

    /// 좁은 창(아이폰 세로·폰 크기 iPad 창)은 감상·영상 만들기·도구 세 개다. 홈은 감상 안의 입구다.
    private func bottomBar(current: AppTab) -> some View {
        HStack(spacing: 0) {
            ForEach(AppTab.rootTabs) { tab in
                // 감상 탭은 홈 입구와 파인더 위치를 함께 맡는다.
                let isActive = tab == .finder ? (current == .finder || current == .home) : current == tab
                Button {
                    if tab == .tools, toolsLongPressFired { toolsLongPressFired = false; return }
                    if tab == .finder { selectWatch() } else { select(tab) }
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
                .modifier(PrivacyToolsLongPress(enabled: tab == .tools, fired: $toolsLongPressFired))
            }
        }
        .padding(.horizontal, 8)
        // 홈 인디케이터 영역까지 배경만 채우고 버튼은 안전 영역 위에 있다.
        .background(PorcelainMetrics.sidebar.ignoresSafeArea(.container, edges: .bottom))
        .overlay(alignment: .top) { PorcelainMetrics.line.frame(height: 0.5) }
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

/// 도구: 기기 간 사진 전송과 저장공간. 설정은 레일/아래쪽 목록에서도 연다.
struct ToolsView: View {
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @EnvironmentObject private var connectionStore: ConnectionStore
    @ObservedObject private var router = AppShellRouter.shared
    @State private var snapshot = StorageSnapshot.current()
    @State private var pushedDestination: ToolsDestination?
    @ObservedObject private var workbench = WorkbenchStore.shared
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
                // 스택을 목적지별로 새로 만들어, 이전 도구가 올려 둔 화면(받기 QR 등)이 새 목적지를 덮은 채 남아
                // 도구 행이 눌러도 아무 일도 없는 것처럼 보이는 일이 없게 한다.
                switch router.toolsDestination {
                case .transfer: PhotoTransferView()
                case .selection: PhotoSelectionView()
                case .storage: storagePage
                case .settings: AppSettingsView(connectionCount: connectionStore.connections.count)
                }
            } else {
                toolsList
                    .navigationDestination(item: $pushedDestination) { destination in
                        switch destination {
                        case .transfer: PhotoTransferView()
                        case .selection: PhotoSelectionView()
                        case .storage: storagePage
                        case .settings: AppSettingsView(connectionCount: connectionStore.connections.count)
                        }
                    }
            }
        }
        .id(usesShellSidebar ? router.toolsDestination.rawValue : "list")
        .onChange(of: router.toolsPushRequest) { _, destination in consumePushRequest(destination) }
        .onAppear { consumePushRequest(router.toolsPushRequest) }
    }

    private func consumePushRequest(_ destination: ToolsDestination?) {
        guard let destination else { return }
        if !usesShellSidebar { pushedDestination = destination }
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
            PorcelainDivider()
            PorcelainRow(
                title: "컬렉션 \(collection.videos.count)편",
                subtitle: "앱 안 복사본 \(bytes(collection.videos.reduce(0) { $0 + $1.byteCount }))"
            ) {
                InterfaceIcon(systemName: "nf.collection", size: PorcelainMetrics.rowIconSize)
            }
        }
    }

    private var toolsList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    PorcelainSectionHeader(title: "미디어")
                    PorcelainGroupCard {
                        NavigationLink {
                            PhotoSelectionView()
                        } label: {
                            PorcelainRow(title: "사진 선별",
                                         subtitle: "비슷한 사진을 묶고 몇 장이 적당한지 추천",
                                         showsChevron: true) {
                                InterfaceIcon(systemName: "nf.photo_selection", size: PorcelainMetrics.rowIconSize)
                            }
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
                        PorcelainDivider()
                        NavigationLink {
                            PhotoTransferView()
                        } label: {
                            PorcelainRow(title: "미디어 전송",
                                         subtitle: "미디어·Live Photos·Motion Photos 기기 간 전송",
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
                        // 설정도 다른 도구 목적지처럼 이 스택으로 push한다(시트로 따로 열지 않는다).
                        NavigationLink {
                            AppSettingsView(connectionCount: connectionStore.connections.count)
                        } label: {
                            PorcelainRow(title: "설정", showsChevron: true) {
                                InterfaceIcon(systemName: "gearshape", size: PorcelainMetrics.rowIconSize)
                            }
                        }
                        .buttonStyle(.plain)
                        .navigationLinkIndicatorVisibility(.hidden)
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
        .phoneRootHeader("도구", enabled: usesPhoneRootHeader) {
            ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue, isBadgeStyle: false, isRunningOnMac: false)
        }
        .onAppear { snapshot = StorageSnapshot.current() }
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
        #if targetEnvironment(macCatalyst)
        false
        #else
        !usesShellSidebar && !ProcessInfo.processInfo.isiOSAppOnMac
        #endif
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

    /// 지금 보이는 항목의 ID를 기본 순서(연결 → 내 사진·영상 → 폰하드 → 즐겨찾기 → Google 포토 → 기기 파일 → Browser)로.
    /// 즐겨찾기는 나중에 생긴 ID라 저장된 순서가 있으면 꼬리에 붙고(`SidebarOrderPolicy.normalized`) 기존 순서는 바뀌지 않는다.
    static func current(connectionIDs: [UUID], showsGooglePhotos: Bool) -> [String] {
        connectionIDs.map(\.uuidString)
            + [photos, phoneHard, favorites] + (showsGooglePhotos ? [googlePhotos] : []) + [deviceFiles, browser]
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
