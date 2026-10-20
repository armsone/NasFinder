import SwiftUI
import UniformTypeIdentifiers

// MARK: - 현재 프로젝트로 보내는 출처 연결

/// 편집기 안의 파인더·사진·폰하드 화면이 "현재 프로젝트에 추가"를 누를 때 항목을 넘기는 통로.
/// 값이 있으면 그 화면은 새 편집기를 따로 띄우지 않고 이 프로젝트로 항목을 보낸다.
struct TrailerProjectSink: @unchecked Sendable {
    let add: ([RemoteFileItem], any RemoteFileService) -> Void
}

private struct TrailerProjectSinkKey: EnvironmentKey {
    static let defaultValue: TrailerProjectSink? = nil
}

extension EnvironmentValues {
    var trailerProjectSink: TrailerProjectSink? {
        get { self[TrailerProjectSinkKey.self] }
        set { self[TrailerProjectSinkKey.self] = newValue }
    }
}

private struct EmbedsInTrailerPanelKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 편집기의 재료 파인더 패널 안에서 그려지는지. 패널 제목이 있으므로 파인더는 브랜드 머리글을 숨긴다.
    var embedsInTrailerPanel: Bool {
        get { self[EmbedsInTrailerPanelKey.self] }
        set { self[EmbedsInTrailerPanelKey.self] = newValue }
    }
}

/// 프로젝트 안에서는 출처 화면이 새 편집기를 덮어 띄우지 않도록 막는다.
func trailerCoverBinding(_ base: Binding<VideoTrailerSelection?>, sink: TrailerProjectSink?) -> Binding<VideoTrailerSelection?> {
    sink == nil ? base : .constant(nil)
}

extension View {
    /// 편집 프로젝트 안에서 열린 출처 화면이 새 편집기 대신 이 프로젝트로 항목을 보내게 한다.
    func routesTrailerSelection(
        _ selection: Binding<VideoTrailerSelection?>, service: @escaping () -> any RemoteFileService,
        sink: TrailerProjectSink?
    ) -> some View {
        onChange(of: selection.wrappedValue?.id) { _, id in
            guard id != nil, let sink, let picked = selection.wrappedValue else { return }
            sink.add(picked.items, service())
            selection.wrappedValue = nil
        }
    }
}

// MARK: - 폭 단계

enum TrailerWorkspaceTier: Equatable {
    /// 1280pt 이상: 레일 + 파인더 + 편집기 + 선택 장면 상세
    case wide
    /// 920–1279pt: 레일 + 파인더 + 편집기, 상세는 아래쪽 패널
    case medium
    /// 760–919pt: 레일 + 편집기, 파인더·상세는 겹쳐 뜨는 패널
    case compact
    /// 760pt 미만: 폰 집중 화면
    case phone

    init(width: CGFloat) {
        switch width {
        case 1280...: self = .wide
        case 920...: self = .medium
        case 760...: self = .compact
        default: self = .phone
        }
    }

    var hasRail: Bool { self != .phone }
    var dockedFinder: Bool { self == .wide || self == .medium }
}

// MARK: - 레일

struct TrailerWorkspaceRail: View {
    let finderActive: Bool
    let detailActive: Bool
    let showsDetail: Bool
    let toggleFinder: () -> Void
    let toggleDetail: () -> Void
    let openSettings: () -> Void
    let leave: (AppTab?) -> Void

    var body: some View {
        VStack(spacing: 6) {
            railButton("영상 편집", icon: "film", active: true) {}
            railButton("파인더", icon: "house", active: finderActive, action: toggleFinder)
            if showsDetail { railButton("장면 상세", icon: "slider.horizontal.3", active: detailActive, action: toggleDetail) }
            railButton("영상 목록", icon: "film.stack", active: false) { leave(.video) }
            railButton("도구", icon: "arrow.up.arrow.down.square", active: false) { leave(.tools) }
            // 설정·나가기도 같은 위쪽 묶음에 둔다. 창 아래 끝으로 밀어 떨어뜨리지 않는다.
            PorcelainMetrics.line.frame(height: 0.5).padding(.horizontal, 6).padding(.vertical, 2)
            railButton("설정", icon: "gearshape", active: false, action: openSettings)
            railButton("나가기", icon: "chevron.left", active: false) { leave(nil) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(width: 64)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(PorcelainMetrics.sidebar.ignoresSafeArea(.container, edges: .vertical))
        .overlay(alignment: .trailing) { PorcelainMetrics.line.frame(width: 0.5).ignoresSafeArea(.container, edges: .vertical) }
    }

    private func railButton(_ title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            InterfaceIcon(systemName: icon, size: 26)
                .foregroundStyle(active ? PorcelainMetrics.accent : PorcelainMetrics.graphite)
                .frame(maxWidth: .infinity, minHeight: 48)
                .background(active ? PorcelainMetrics.selected : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

// MARK: - 파인더 패널

/// 실제 파인더(저장된 연결·폰하드·내 사진·기기 파일)를 그대로 올린 패널. 가짜 목록은 없다.
/// 재료함에 준비된 파일은 맨 위에서 바로 현재 프로젝트에 추가할 수 있다.
struct TrailerFinderPanel: View {
    let sink: TrailerProjectSink
    let projectName: String
    let isOverlay: Bool
    let close: () -> Void
    @ObservedObject private var basket = MaterialBasketStore.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("재료 파인더").font(.subheadline.weight(.semibold))
                    Text("고른 항목은 \"현재 프로젝트에 추가\"로 \(projectName)에 들어가요")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if isOverlay {
                    Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title3) }
                        .accessibilityLabel("파인더 닫기")
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            if !basket.readyItems.isEmpty {
                Button(action: addBasket) {
                    Label("재료함 \(basket.readyItems.count)개를 현재 프로젝트에 추가", systemImage: "photo.on.rectangle.angled")
                        .font(.caption.weight(.semibold)).frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.bordered).padding(.horizontal, 12).padding(.bottom, 6)
            }
            Divider()
            ConnectionListView()
                .environment(\.trailerProjectSink, sink)
                .environment(\.embedsInTrailerPanel, true)
        }
        .background(PorcelainMetrics.paper)
    }

    /// 재료함의 준비된 파일을 프로젝트로 보낸다. 재료함 자체는 비우지 않고 편집기는 자기 사본을 만든다.
    private func addBasket() {
        var entries: [(item: RemoteFileItem, url: URL)] = []
        for item in basket.readyItems {
            guard let url = basket.fileURL(for: item) else { continue }
            let remote = RemoteFileItem(
                connectionID: LocalPhotoLibraryFileService.connectionID, path: url.path, name: item.name,
                kind: .file, size: item.byteCount, modifiedAt: nil,
                contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
            entries.append((remote, url))
        }
        let items = entries.map(\.item).filter(\.isTrailerEligible)
        guard !items.isEmpty else { return }
        sink.add(items, LocalPhotoLibraryFileService(entries: entries))
    }
}

// MARK: - 작업 공간

/// 폭에 따라 레일·파인더·편집기·상세를 배치한다. 편집기와 파인더는 각각 트리의 고정된 자리에
/// 한 번만 두고 프레임만 바꾸므로, 폭이 바뀌어도 편집기의 플레이어·선택·파인더의 탐색 위치가 유지된다.
struct TrailerWorkspace<Editor: View, Finder: View, Detail: View>: View {
    let finderOpenRequest: Int
    /// 항목을 추가한 뒤 겹쳐 뜬 파인더를 닫아 편집기가 보이게 한다. 도킹된 파인더는 그대로 둔다.
    let finderCloseRequest: Int
    let editor: (TrailerWorkspaceTier) -> Editor
    let finder: (Bool, @escaping () -> Void) -> Finder
    let detail: (TrailerWorkspaceTier) -> Detail
    let openSettings: () -> Void
    let leave: (AppTab?) -> Void

    @State private var finderShown = true
    @State private var detailShown = false
    @State private var finderLoaded = false
    @State private var lastRequest = 0

    var body: some View {
        GeometryReader { geometry in
            let tier = TrailerWorkspaceTier(width: geometry.size.width)
            let railWidth: CGFloat = tier.hasRail ? 64 : 0
            let finderWidth = min(380, max(300, geometry.size.width * 0.27))
            let dockedVisible = tier.dockedFinder && finderShown
            let overlayVisible = !tier.dockedFinder && finderShown
            let detailSide = tier == .wide
            let detailBottom = tier == .medium
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    if tier.hasRail {
                        TrailerWorkspaceRail(
                            finderActive: finderShown, detailActive: detailShown, showsDetail: tier == .compact,
                            toggleFinder: { finderShown.toggle() }, toggleDetail: { detailShown.toggle() },
                            openSettings: openSettings, leave: leave)
                    }
                    if dockedVisible { Color.clear.frame(width: finderWidth) }
                    VStack(spacing: 0) {
                        editor(tier).frame(maxWidth: .infinity, maxHeight: .infinity)
                        if detailBottom {
                            Divider()
                            ScrollView { detail(tier).padding(12) }.frame(height: min(260, geometry.size.height * 0.34))
                                .background(PorcelainMetrics.paper)
                        }
                    }
                    if detailSide {
                        Rectangle().fill(PorcelainMetrics.line).frame(width: 0.5)
                        ScrollView { detail(tier).padding(12) }.frame(width: 320)
                            .background(PorcelainMetrics.paper)
                    }
                }
                // 파인더는 한 번 만들면 계속 둔다. 도킹/겹침/숨김은 위치와 투명도만 바꾼다.
                if finderLoaded {
                    let visible = dockedVisible || overlayVisible
                    let width = tier == .phone ? geometry.size.width : (tier.dockedFinder ? finderWidth : min(400, geometry.size.width - railWidth))
                    finder(!tier.dockedFinder, { finderShown = false })
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .background(PorcelainMetrics.paper.ignoresSafeArea(.container, edges: .vertical))
                        .overlay(alignment: .trailing) { PorcelainMetrics.line.frame(width: 0.5) }
                        .shadow(color: .black.opacity(tier.dockedFinder ? 0 : 0.18), radius: 10, x: 2)
                        .offset(x: railWidth)
                        .opacity(visible ? 1 : 0)
                        .allowsHitTesting(visible)
                        .accessibilityHidden(!visible)
                        .zIndex(2)
                }
                if tier == .compact, detailShown {
                    ScrollView { detail(tier).padding(12) }
                        .frame(width: min(360, geometry.size.width - railWidth))
                        .background(PorcelainMetrics.paper)
                        .overlay(alignment: .leading) { PorcelainMetrics.line.frame(width: 0.5) }
                        .shadow(color: .black.opacity(0.18), radius: 10, x: -2)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .zIndex(3)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .onAppear {
                // 넓은 단계에서는 처음부터 열고, 좁은 단계에서는 사용자가 열기 전까지 닫아 둔다.
                if !tier.dockedFinder { finderShown = false }
                finderLoaded = tier.dockedFinder
            }
            .onChange(of: finderShown) { _, shown in if shown { finderLoaded = true } }
            .onChange(of: finderOpenRequest) { _, request in
                guard request != lastRequest else { return }
                lastRequest = request
                finderLoaded = true
                finderShown = true
            }
            .onChange(of: finderCloseRequest) { _, _ in
                if !tier.dockedFinder { finderShown = false }
            }
            .onChange(of: tier) { old, new in
                // 단계가 바뀌어도 파인더는 그대로이고, 겹침으로 바뀔 때만 닫아 편집기를 가리지 않는다.
                if old.dockedFinder != new.dockedFinder { finderShown = new.dockedFinder }
                if new != .compact { detailShown = false }
                if new.dockedFinder { finderLoaded = true }
            }
        }
    }
}

// MARK: - 앱 셸 이동 요청

/// 편집기 레일에서 다른 탭으로 나갈 때 앱 셸에 알린다. Mac 넓은 창의 하나뿐인 사이드바도
/// 이 통로로 파인더에 이동을 요청하고, 파인더·영상·도구의 현재 위치를 읽어 선택 표시를 한다.
@MainActor
final class AppShellRouter: ObservableObject {
    static let shared = AppShellRouter()
    @Published var request: AppTab?
    @Published var finderRequest: FinderSidebarRequest?
    @Published var finderLocation: FinderSidebarLocation = .home
    @Published var googlePhotosConnected = false
    @Published var googlePhotosDisconnecting = false
    @Published var videoDestination: VideoDestination = .make
    @Published var toolsDestination: ToolsDestination = .storage
}
