import SwiftUI
import UniformTypeIdentifiers

/// 영상 탭의 목적지. 용어: 편집본 = 이어서 편집할 수 있는 프로젝트, 컬렉션 = 재생 가능한 완성 영상 파일.
/// `.basket`(재료함)은 작업대로 합쳐졌다. 저장 키·옛 경로를 쓰는 곳이 깨지지 않도록 값은 남기고,
/// 화면에는 나열하지 않으며 선택되면 작업대로 보낸다(`AppShellRouter.videoDestination`).
enum VideoDestination: String, CaseIterable, Identifiable {
    case make = "영상 제작"
    case basket = "재료함"
    case drafts = "편집본"
    case collection = "컬렉션"
    var id: String { rawValue }
    /// 사이드바·가로 막대·홈에 보이는 목적지. 재료함은 작업대와 같은 곳이라 중복 메뉴로 보이지 않는다.
    static var allCases: [VideoDestination] { [.make, .drafts, .collection] }
    /// 화면에 보이는 이름. rawValue는 사이드바 순서 저장 키라 바꾸지 않는다.
    var title: String { self == .basket ? "작업대" : rawValue }
}

struct VideoHubView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @ObservedObject private var router = AppShellRouter.shared
    @ObservedObject private var shareIntents = ShareIntentCoordinator.shared
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue = AppThemePreference.light.rawValue
    @State private var resumingDraft: TrailerDraftEntry?
    @State private var notice: String?
    /// 허브 스택에 올린 화면. 사이드바/가로 막대로 목적지를 바꾸면 비워서 이전 목적지의 화면이 새 루트를 덮지 않게 한다.
    @State private var isPickingMedia = false
    @State private var isPickingMusicMedia = false
    @State private var isAddingFromLibrary = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mac 넓은 창에서는 사이드바가 하위 목적지를 고르므로 가로 막대를 겹쳐 두지 않는다.
                if !usesShellSidebar { destinationPicker }
                Group {
                    switch destination {
                    case .make: makeDestination
                    case .basket: makeDestination
                    case .drafts:
                        TrailerDraftManagerView { entry in resumingDraft = entry }
                    case .collection: MovieCollectionView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PorcelainMetrics.paper)
            .navigationTitle(usesShellSidebar ? destination.title : "영상")
            .navigationBarTitleDisplayMode(.inline)
            .phoneRootHeader("영상", enabled: PhoneRootHeaderPolicy.isEnabled(usesShellSidebar: usesShellSidebar)) {
                ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue, isBadgeStyle: false, isRunningOnMac: false)
            }
            // 길게 누른 뒤로가기는 홈으로 간다. 고르던 항목은 맥락별 선택 세션이 보관한다.
            .environment(\.returnToDashboard) { router.request = .home }
            .navigationDestination(isPresented: $isPickingMedia) { LocalPhotoLibraryView(initialMode: .trailer) }
            .navigationDestination(isPresented: $isPickingMusicMedia) { LocalPhotoLibraryView(initialMode: .mediaMusic) }
            .navigationDestination(isPresented: $isAddingFromLibrary) { LocalPhotoLibraryView() }
            .onChange(of: router.videoDestination) { _, _ in
                // 홈에서 고르기 화면을 함께 요청한 이동이면 요청 처리가 그 화면을 연다.
                guard router.videoPickRequest == nil else { return }
                isPickingMedia = false
                isPickingMusicMedia = false
                isAddingFromLibrary = false
            }
        }
        .trailerEditorCover(item: $resumingDraft) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
                .environmentObject(inboxStore)
        }
        .alert("영상 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert("공유로 받은 항목", isPresented: Binding(get: { shareIntents.notice != nil }, set: { if !$0 { shareIntents.notice = nil } })) {
            Button("확인", role: .cancel) { shareIntents.notice = nil }
        } message: { Text(shareIntents.notice ?? "") }
        .onAppear {
            shareIntents.refresh()
            resumeRequestedDraft(router.resumeDraftRequest)
            openRequestedPicker(router.videoPickRequest)
        }
        .onChange(of: router.resumeDraftRequest) { _, id in resumeRequestedDraft(id) }
        .onChange(of: router.videoPickRequest) { _, mode in openRequestedPicker(mode) }
    }

    /// 홈의 "예고편 보기"·"뮤직비디오"가 요청한 미디어 고르기를 연다. 선택 세션은 맥락별로 이미 유지되므로 새로 만들거나 비우지 않는다.
    private func openRequestedPicker(_ mode: VideoTrailerMode?) {
        guard let mode else { return }
        router.videoPickRequest = nil
        // 같은 갱신에서 도착하는 목적지 변경(이전 고르기 화면 닫기)이 끝난 다음에 연다.
        Task { @MainActor in
            await Task.yield()
            isAddingFromLibrary = false
            switch mode {
            case .trailer:
                isPickingMusicMedia = false
                isPickingMedia = true
            case .mediaMusic:
                isPickingMedia = false
                isPickingMusicMedia = true
            }
        }
    }

    /// 홈에서 고른 편집본을 이미 저장된 편집본 목록에서 찾아 연다. 목록에 없으면 편집본 화면에 그대로 둔다.
    private func resumeRequestedDraft(_ id: UUID?) {
        guard let id else { return }
        router.resumeDraftRequest = nil
        if let entry = draftStore.entries.first(where: { $0.id == id }) { resumingDraft = entry }
    }

    // MARK: 목적지 선택

    /// 폰 가로 막대와 Mac 사이드바가 같은 선택을 쓴다.
    private var destination: VideoDestination {
        get { router.videoDestination }
        nonmutating set { router.videoDestination = newValue }
    }

    private var destinationPicker: some View {
        HStack(spacing: 0) {
            ForEach(VideoDestination.allCases) { item in
                Button { destination = item } label: {
                    VStack(spacing: 2) {
                        Text(item.title)
                            .porcelainFont(.tile)
                            .foregroundStyle(destination == item ? PorcelainMetrics.accent : PorcelainMetrics.secondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Capsule().fill(destination == item ? PorcelainMetrics.accent : .clear).frame(height: 3)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(destination == item ? .isSelected : [])
            }
        }
        .padding(.horizontal, 8)
        .background(PorcelainMetrics.paper)
        .overlay(alignment: .bottom) { PorcelainMetrics.line.frame(height: 0.5) }
    }

    // MARK: 영상 제작

    private var makeDestination: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("새 영상을 만들 때만 편집본이 생깁니다. 작업대의 포켓은 그대로 남습니다.")
                    .porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary)
                PorcelainGroupCard {
                    Button { router.request = .workbench } label: {
                        PorcelainRow(
                            title: "작업대에서 시작",
                            subtitle: "포켓에 담아 둔 사진·영상으로 제작합니다 (시작할 때 원본을 가져옵니다)",
                            subtitleLineLimit: 2, showsChevron: true
                        ) { InterfaceIcon(systemName: "tray.2", size: PorcelainMetrics.rowIconSize) } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    PorcelainDivider()
                    Button { isPickingMedia = true } label: {
                        PorcelainRow(
                            title: "미디어 고르기",
                            subtitle: "내 미디어·폰하드·NAS 등에서 골라 바로 제작하거나 작업대에 담습니다",
                            subtitleLineLimit: 2, showsChevron: true
                        ) { InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.rowIconSize) } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    PorcelainDivider()
                    Button { isPickingMusicMedia = true } label: {
                        PorcelainRow(
                            title: "뮤직비디오",
                            subtitle: "고른 사진·영상을 음악에 맞춰 이어 붙입니다",
                            subtitleLineLimit: 2, showsChevron: true
                        ) { InterfaceIcon(systemName: "music.note", size: PorcelainMetrics.rowIconSize) } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

}

