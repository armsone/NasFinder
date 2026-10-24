import Photos
import SwiftUI

/// 작업대에서 미디어 전송 화면으로 넘길 때 사용자가 고른 포켓을 기억하는 키(앱 설정 저장소, 이 기기 전용).
enum WorkbenchSelectionKey {
    static let transferPocket = "workbench.transferPocketID.v1"
}

// MARK: - 실행 진행·결정 패널

/// 영상 제작·미디어 전송 실행의 진행 상황과 '가능한 것만 계속할지' 결정을 보여 주는 덮개.
/// 시트가 아니라 내용 위의 패널이라 이어서 열리는 편집기·보내기 화면과 충돌하지 않는다.
struct WorkbenchRunPanel: View {
    @ObservedObject var run: WorkbenchRun
    let title: String
    private var themeRefresh = ThemeRefresh()

    init(run: WorkbenchRun, title: String) {
        self.run = run
        self.title = title
    }

    var body: some View {
        let _ = themeRefresh.theme
        switch run.phase {
        case .planning, .materializing, .decision, .failed:
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                    .onTapGesture {}
                panel
                    .padding(ui(18))
                    .frame(maxWidth: ui(520))
                    .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: ui(14), style: .continuous))
                    .shadow(radius: 12)
                    .padding(ui(16))
            }
            .accessibilityElement(children: .contain)
        case .idle, .ready:
            EmptyView()
        }
    }

    @ViewBuilder
    private var panel: some View {
        switch run.phase {
        case .planning:
            progress(heading: "\(title) · 폴더와 항목 확인 중",
                     detail: run.masksNames ? nil : run.currentName, fraction: nil)
        case .materializing:
            progress(heading: "\(title) · 원본 가져오는 중 \(min(run.completed + 1, max(run.total, 1)))/\(run.total)",
                     detail: run.masksNames ? nil : run.currentName, fraction: run.itemProgress)
        case .decision:
            decision
        case .failed(let message):
            VStack(alignment: .leading, spacing: ui(10)) {
                Text("\(title)을(를) 시작하지 못했습니다").font(.ui(.headline))
                Text(message).font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.secondary)
                problemList
                Text("포켓의 항목은 그대로 남아 있습니다.").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                Button("닫기") { run.cancel() }.buttonStyle(PorcelainProminentButtonStyle())
            }
        case .idle, .ready:
            EmptyView()
        }
    }

    private func progress(heading: String, detail: String?, fraction: Double?) -> some View {
        VStack(alignment: .leading, spacing: ui(10)) {
            Text(heading).font(.ui(.headline))
            if let detail { Text(detail).font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.secondary).lineLimit(2) }
            if let fraction { ProgressView(value: fraction) } else { ProgressView() }
            Button("취소") { run.cancel() }
                .buttonStyle(.bordered)
                .accessibilityHint("진행을 멈추고 이번에 가져온 임시 파일만 지웁니다. 포켓의 항목은 그대로입니다.")
        }
    }

    private var decision: some View {
        let usable = run.decisionAfterFetch ? run.productionClips.count : run.planCount
        return VStack(alignment: .leading, spacing: ui(10)) {
            Text("모든 항목을 쓸 수는 없습니다").font(.ui(.headline))
            Text("가능한 \(usable)개로 계속하면 나머지는 이번 \(title)에서 빠집니다. 빠진 항목은 포켓에 그대로 남아 있습니다.")
                .font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.secondary)
            problemList
            HStack {
                Button("취소") { run.cancel() }.buttonStyle(.bordered)
                Spacer(minLength: 0)
                Button("가능한 \(usable)개로 계속") { run.continueWithAvailable() }
                    .buttonStyle(PorcelainProminentButtonStyle())
                    .disabled(usable == 0)
            }
        }
    }

    private var problemList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ui(6)) {
                ForEach(run.problems.prefix(12)) { problem in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: ui(6)) {
                            Text(run.masksNames ? "항목" : problem.name).font(.ui(.footnote).weight(.semibold)).lineLimit(1)
                            if problem.needsRelink {
                                Text("다시 연결 필요").font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.warn)
                            }
                        }
                        Text(problem.reason).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.danger)
                    }
                }
                if run.problems.count > 12 {
                    Text("그 밖에 \(run.problems.count - 12)개 항목에 문제가 있습니다.").font(.ui(.caption))
                        .foregroundStyle(PorcelainMetrics.secondary)
                }
                ForEach(Array(run.skippedNotices.prefix(8).enumerated()), id: \.offset) { _, notice in
                    Text(notice).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: ui(220))
    }
}

// MARK: - 항목 행

/// 사진 보관함 항목의 작은 썸네일. 기기 안 캐시만 쓰고 iCloud 원본을 내려받지 않는다.
private struct WorkbenchAssetThumbnail: View {
    let identifier: String
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(interfaceSystemName: "photo").foregroundStyle(PorcelainMetrics.secondary)
            }
        }
        .frame(width: ui(44), height: ui(44))
        .clipShape(RoundedRectangle(cornerRadius: ui(8), style: .continuous))
        .task(id: identifier) { image = await Self.load(identifier) }
    }

    private static func load(_ identifier: String) async -> UIImage? {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else { return nil }
        return await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .fastFormat
            options.isNetworkAccessAllowed = false
            options.isSynchronous = false
            var resumed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 132, height: 132), contentMode: .aspectFill, options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}

struct WorkbenchEntryRow: View {
    let entry: WorkbenchEntry
    var isSelected: Bool? = nil
    var toggle: (() -> Void)? = nil
    let remove: () -> Void
    var relink: (() -> Void)? = nil
    /// 포켓이 공개일 때만 항목 자신의 공개 범위를 바꿀 수 있다.
    var setPrivate: ((Bool) -> Void)? = nil

    private var detail: String {
        var parts = [entry.sourceLabel, entry.mediaKind.title]
        if let size = entry.byteCount { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: ui(10)) {
            if let isSelected, let toggle {
                Button(action: toggle) {
                    Image(interfaceSystemName: isSelected ? "checkmark.circle.fill" : "circle", pointSize: ui(22))
                        .font(.system(size: ui(22)))
                        .foregroundStyle(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.secondary)
                        .frame(width: ui(36), height: ui(44))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSelected ? "선택됨" : "선택")
            }
            if entry.kind == .photoAsset, let identifier = entry.assetIdentifier {
                WorkbenchAssetThumbnail(identifier: identifier)
            } else {
                Image(interfaceSystemName: entry.mediaKind.systemImage)
                    .frame(width: ui(44), height: ui(44))
                    .foregroundStyle(PorcelainMetrics.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: ui(4)) {
                    Text(entry.name).font(.ui(.subheadline)).foregroundStyle(PorcelainMetrics.graphite).lineLimit(1)
                    if entry.isPrivate == true {
                        Image(interfaceSystemName: "eye.slash", pointSize: 11).font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.secondary)
                            .accessibilityLabel("비공개")
                    }
                }
                Text(detail).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary).lineLimit(1)
                if let reason = entry.relinkReason {
                    Text("다시 연결 필요 · \(reason)").font(.ui(.caption)).foregroundStyle(PorcelainMetrics.warn).lineLimit(3)
                }
            }
            Spacer(minLength: 0)
            Menu {
                if entry.relinkReason != nil, let relink { Button("다시 연결 방법", action: relink) }
                if let setPrivate {
                    if entry.isPrivate == true {
                        Button("공개로 전환", interfaceSystemImage: "eye") { setPrivate(false) }
                    } else {
                        Button("비공개로 전환", interfaceSystemImage: "eye.slash") { setPrivate(true) }
                    }
                }
                Button("포켓에서 빼기", role: .destructive, action: remove)
            } label: {
                Image(interfaceSystemName: "ellipsis.circle").frame(width: ui(44), height: ui(44))
            }
            .accessibilityLabel("\(entry.name) 메뉴")
        }
        .accessibilityElement(children: .contain)
    }
}

// MARK: - 포켓 화면

private struct WorkbenchEditorPresentation: Identifiable {
    let id = UUID()
    let items: [RemoteFileItem]
    let service: LocalPhotoLibraryFileService
    let mode: VideoTrailerMode
    let originPrivate: Bool
}

/// 포켓 하나: 순서가 있는 참조 목록. 영상 제작·미디어 전송은 선택한 항목(없으면 전체)을 이 순서대로 쓰고,
/// 원본은 시작을 누른 그 순간에만 가져온다.
struct WorkbenchPocketView: View {
    let pocketID: UUID
    @ObservedObject private var store = WorkbenchStore.shared
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var run = WorkbenchRun(purpose: .production)
    @State private var selected: Set<UUID> = []
    @State private var editMode: EditMode = .inactive
    @State private var editor: WorkbenchEditorPresentation?
    @State private var productionMode: VideoTrailerMode = .trailer
    @State private var isGooglePresented = false
    @State private var isFinderPresented = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isClearConfirmationPresented = false
    @State private var isDeleteConfirmationPresented = false
    @State private var isPublicConfirmationPresented = false
    @State private var relinkGuidance: WorkbenchEntry?
    @State private var notice: String?
    private var themeRefresh = ThemeRefresh()

    init(pocketID: UUID) { self.pocketID = pocketID }

    private var pocket: WorkbenchPocket? { store.pocket(pocketID) }

    var body: some View {
        let _ = themeRefresh.theme
        Group {
            if let pocket {
                content(pocket)
            } else {
                PorcelainStateView(systemImage: "nf.pocket", title: "포켓을 찾을 수 없습니다", message: "삭제되었거나 비워진 포켓입니다.")
            }
        }
        .background(PorcelainMetrics.paper)
        .navigationTitle(pocket?.name ?? "포켓")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                WorkbenchAddSourceControls(pocketID: pocket == nil ? nil : pocketID, layout: .menu,
                                           openGoogle: { isGooglePresented = true }, openFinder: { isFinderPresented = true })
                moreMenu
            }
        }
        .overlay { WorkbenchRunPanel(run: run, title: productionMode == .mediaMusic ? "뮤직비디오" : "영상 제작") }
        .environment(\.editMode, $editMode)
        .navigationDestination(isPresented: $isGooglePresented) { WorkbenchGooglePhotosPage(pocketID: pocketID) }
        .navigationDestination(isPresented: $isFinderPresented) { WorkbenchFinderSourcePage(pocketID: pocketID) }
        .trailerEditorCover(item: $editor, onDismiss: { run.finish() }) { presentation in
            VideoTrailerView(items: presentation.items, service: presentation.service, mode: presentation.mode,
                             keepsSelectionOrder: true, originPrivate: presentation.originPrivate)
                .environmentObject(inboxStore)
        }
        .onChange(of: run.phase) { _, phase in
            guard phase == .ready, editor == nil else { return }
            let clips = run.productionClips
            guard !clips.isEmpty else { run.finish(); return }
            editor = WorkbenchEditorPresentation(items: clips.map(\.item), service: run.productionService(), mode: productionMode, originPrivate: run.originPrivate)
        }
        .onChange(of: store.pockets) { _, _ in
            // 지워진 항목의 선택은 풀어 둔다.
            let ids = Set(pocket?.entries.map(\.id) ?? [])
            selected.formIntersection(ids)
        }
        .alert("포켓 이름 바꾸기", isPresented: $isRenaming) {
            TextField("포켓 이름", text: $renameText)
            Button("취소", role: .cancel) {}
            Button("바꾸기") { rename() }
        }
        .confirmationDialog("이 포켓의 항목을 모두 뺄까요?", isPresented: $isClearConfirmationPresented, titleVisibility: .visible) {
            Button("모두 비우기", role: .destructive) { clear() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("포켓에서 참조 \(pocket?.entries.count ?? 0)개만 지웁니다. 사진·영상 원본과 앱에 있던 기존 복사본은 지워지지 않습니다.")
        }
        .confirmationDialog("이 포켓을 공개로 바꿀까요?", isPresented: $isPublicConfirmationPresented, titleVisibility: .visible) {
            Button("공개로 전환") { setPrivate(false) }
            Button("취소", role: .cancel) {}
        } message: {
            Text("일반 모드에서도 이 포켓과 안의 항목이 보이게 됩니다.")
        }
        .confirmationDialog("포켓을 삭제할까요?", isPresented: $isDeleteConfirmationPresented, titleVisibility: .visible) {
            Button("포켓 삭제", role: .destructive) { deletePocket() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("'\(pocket?.name ?? "")' 포켓과 안의 참조 \(pocket?.entries.count ?? 0)개만 지웁니다. 원본과 기존 복사본은 지워지지 않습니다.")
        }
        .alert("다시 연결", isPresented: Binding(get: { relinkGuidance != nil }, set: { if !$0 { relinkGuidance = nil } })) {
            if relinkGuidance?.kind == .googlePhoto {
                Button("Google 포토에서 다시 선택") { relinkGuidance = nil; isGooglePresented = true }
            }
            Button("확인", role: .cancel) { relinkGuidance = nil }
        } message: { Text(relinkGuidance.map(Self.guidance(for:)) ?? "") }
        .alert("작업대 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
    }

    // MARK: 내용

    @ViewBuilder
    private func content(_ pocket: WorkbenchPocket) -> some View {
        VStack(spacing: 0) {
            if let message = store.persistenceError {
                Text(message).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.danger)
                    .padding(ui(10)).frame(maxWidth: .infinity, alignment: .leading)
            }
            if pocket.entries.isEmpty {
                PorcelainStateView(
                    systemImage: "nf.pocket", title: "비어 있는 포켓입니다",
                    message: "담기에서 파일이나 폴더를 골라 이 포켓에 담으세요. 원본은 그대로 보관됩니다.")
            } else {
                List {
                    ForEach(pocket.entries) { entry in
                        WorkbenchEntryRow(
                            entry: entry, isSelected: selected.contains(entry.id), toggle: { toggle(entry.id) },
                            remove: { remove(entry) }, relink: { relinkGuidance = entry },
                            setPrivate: pocket.isPrivate == true ? nil : { flag in setEntryPrivate(entry, flag) })
                            .listRowBackground(PorcelainMetrics.card)
                    }
                    .onMove { source, destination in
                        if case .failure(let error) = store.moveEntries(in: pocketID, from: source, to: destination) {
                            notice = error.localizedDescription
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            bottomBar(pocket)
        }
    }

    private func bottomBar(_ pocket: WorkbenchPocket) -> some View {
        let targetCount = selected.isEmpty ? pocket.entries.count : selected.count
        return VStack(spacing: ui(8)) {
            Text("항목 \(pocket.entries.count)개 · 선택 \(selected.count)개" + (selected.isEmpty ? " (선택이 없으면 전체 사용)" : ""))
                .font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary).monospacedDigit()
            HStack(spacing: ui(8)) {
                Button("영상 제작") { startProduction(pocket, mode: .trailer) }
                    .buttonStyle(PorcelainProminentButtonStyle())
                    .accessibilityHint("\(targetCount)개를 순서대로 가져와 영상 편집을 시작합니다.")
                Button("미디어 전송") { startTransfer() }
                    .buttonStyle(.bordered)
                    .accessibilityHint("이 포켓을 보낼 목록으로 열어 QR로 다른 폰에 보냅니다.")
            }
            .disabled(pocket.entries.isEmpty || run.isBusy)
        }
        .padding(.horizontal, ui(12)).padding(.vertical, ui(8))
        .frame(maxWidth: .infinity)
        .background(PorcelainMetrics.card)
        .overlay(alignment: .top) { PorcelainMetrics.line.frame(height: 0.5) }
    }

    private var moreMenu: some View {
        Menu {
            Button("이름 바꾸기", interfaceSystemImage: "pencil") { renameText = pocket?.name ?? ""; isRenaming = true }
            if let pocket {
                if pocket.isPrivate == true {
                    Button("공개로 전환", interfaceSystemImage: "eye") { isPublicConfirmationPresented = true }
                } else {
                    Button("비공개로 전환", interfaceSystemImage: "eye.slash") { setPrivate(true) }
                }
            }
            Button(editMode == .active ? "순서 편집 끝" : "순서 편집", interfaceSystemImage: "arrow.up.arrow.down") {
                editMode = editMode == .active ? .inactive : .active
            }
            if let pocket, !pocket.entries.isEmpty {
                Button(selected.count == pocket.entries.count ? "선택 해제" : "전체 선택", interfaceSystemImage: "checkmark.circle") {
                    selected = selected.count == pocket.entries.count ? [] : Set(pocket.entries.map(\.id))
                }
                Button("뮤직비디오로 제작", interfaceSystemImage: "music.note") { startProduction(pocket, mode: .mediaMusic) }
                    .disabled(run.isBusy)
                Button("모두 비우기", interfaceSystemImage: "xmark.bin", role: .destructive) { isClearConfirmationPresented = true }
            }
            Button("포켓 삭제", interfaceSystemImage: "trash", role: .destructive) { isDeleteConfirmationPresented = true }
        } label: {
            InterfaceToolbarIcon(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("포켓 메뉴")
    }

    // MARK: 동작

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func remove(_ entry: WorkbenchEntry) {
        switch store.removeEntries([entry.id], from: pocketID) {
        case .success: selected.remove(entry.id)
        case .failure(let error): notice = error.localizedDescription
        }
    }

    private func rename() {
        if case .failure(let error) = store.renamePocket(pocketID, to: renameText) { notice = error.localizedDescription }
    }

    private func setEntryPrivate(_ entry: WorkbenchEntry, _ isPrivate: Bool) {
        if case .failure(let error) = store.setEntryPrivate(entry.id, in: pocketID, isPrivate) { notice = error.localizedDescription }
        // 일반 모드에서 항목을 비공개로 바꾸면 곧바로 목록에서 사라지므로 그 항목의 선택도 푼다.
        if isPrivate && !PrivacyMode.shared.isActive { selected.remove(entry.id) }
    }

    private func setPrivate(_ isPrivate: Bool) {
        if case .failure(let error) = store.setPocketPrivate(pocketID, isPrivate) { notice = error.localizedDescription }
        // 일반 모드에서 비공개로 바꾸면 이 포켓은 즉시 숨겨지므로 화면을 닫는다.
        if isPrivate && !PrivacyMode.shared.isActive { dismiss() }
    }

    private func clear() {
        switch store.clearPocket(pocketID) {
        case .success: selected = []
        case .failure(let error): notice = error.localizedDescription
        }
    }

    private func deletePocket() {
        switch store.removePocket(pocketID) {
        case .success: dismiss()
        case .failure(let error): notice = error.localizedDescription
        }
    }

    private func targets(_ pocket: WorkbenchPocket) -> [WorkbenchEntry] {
        selected.isEmpty ? pocket.entries : pocket.entries.filter { selected.contains($0.id) }
    }

    private func startProduction(_ pocket: WorkbenchPocket, mode: VideoTrailerMode) {
        productionMode = mode
        run.start(entries: targets(pocket), connectionStore: connectionStore, inputPrivate: pocket.isPrivate == true)
    }

    private func startTransfer() {
        UserDefaults.standard.set(pocketID.uuidString, forKey: WorkbenchSelectionKey.transferPocket)
        AppShellRouter.shared.openWorkbenchTransfer(pocketID: pocketID, entryIDs: selected.isEmpty ? nil : selected)
    }

    static func guidance(for entry: WorkbenchEntry) -> String {
        let base = entry.relinkReason.map { "\($0)\n\n" } ?? ""
        switch entry.kind {
        case .remote:
            return base + "연결이 저장된 목록에 있고 로그인되어 있는지, 원본이 같은 위치에 있는지 확인하세요. 파인더에서 같은 파일을 다시 \"작업대에 담기\" 하면 이 항목이 다시 연결됩니다."
        case .photoAsset:
            return base + "설정에서 사진 접근을 허용하거나, 사진 보관함에서 같은 사진을 이 포켓에 다시 담아 주세요."
        case .fileBookmark:
            return base + "+ 메뉴의 \"파일·폴더\"에서 같은 파일을 다시 고르면 이 항목이 다시 연결됩니다."
        case .googlePhoto:
            return base + "Google 포토에서 같은 항목을 다시 선택하면 영속 항목 ID가 같은 이 항목에 새 선택 세션이 연결됩니다."
        case .sharedStaging:
            return base + "공유로 받은 파일이 앱에서 정리되었습니다. 같은 파일을 다시 공유해 주세요."
        case .legacyCopy:
            return base + "예전 영상 재료의 복사본을 찾을 수 없습니다. 원본에서 다시 담아 주세요."
        }
    }
}

// MARK: - 작업대 홈 (포켓 목록)

struct WorkbenchView: View {
    @ObservedObject private var store = WorkbenchStore.shared
    @ObservedObject private var shareIntents = ShareIntentCoordinator.shared
    @State private var path: [UUID] = []
    @State private var isCreating = false
    @State private var newName = ""
    @State private var renaming: WorkbenchPocket?
    @State private var renameText = ""
    @State private var deleting: WorkbenchPocket?
    @State private var makingPublic: WorkbenchPocket?
    @State private var shareRequest: WorkbenchAddRequest?
    @State private var notice: String?
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @AppStorage(AppThemePreference.storageKey) private var selectedThemeRawValue = AppThemePreference.light.rawValue
    private var themeRefresh = ThemeRefresh()
    /// 넓은 창 오른쪽 패널에 넣을 때 셸이 넘기는 닫기 동작. 있으면 뿌리에서 시스템 막대 대신
    /// 좁은 한 줄 머리글(제목·담은 수·새 포켓·닫기)을 쓴다. 전체 화면 작업대는 nil이라 그대로다.
    private let embeddedClose: (() -> Void)?

    init(embeddedClose: (() -> Void)? = nil) {
        self.embeddedClose = embeddedClose
    }

    var body: some View {
        let _ = themeRefresh.theme
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if store.isReadOnly { readOnlyBanner }
                else if let message = store.persistenceError {
                    Text(message).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.danger)
                        .padding(ui(10)).frame(maxWidth: .infinity, alignment: .leading)
                }
                if !unreferencedShares.isEmpty { shareBanner }
                if store.pockets.isEmpty && !store.isReadOnly {
                    PorcelainStateView(
                        systemImage: "tray.2", title: "작업대가 비어 있습니다",
                        message: "포켓을 만들어 영상 제작이나 미디어 전송에 쓸 파일을 담으세요. 원본은 그대로 보관됩니다.")
                } else {
                    pocketList
                }
            }
            .background(PorcelainMetrics.paper)
            .navigationTitle("작업대")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; isCreating = true } label: { InterfaceToolbarIcon(systemName: "plus") }
                        .disabled(store.isReadOnly)
                        .accessibilityLabel("새 포켓")
                }
            }
            .phoneRootHeader("작업대", enabled: PhoneRootHeaderPolicy.isEnabled(usesShellSidebar: usesShellSidebar)) {
                Button { newName = ""; isCreating = true } label: { InterfaceToolbarIcon(systemName: "plus") }
                    .disabled(store.isReadOnly)
                    .accessibilityLabel("새 포켓")
                ByungkiThemeControlButton(selectedThemeRawValue: $selectedThemeRawValue, isBadgeStyle: false, isRunningOnMac: false)
            }
            .toolbar(embeddedClose != nil ? .hidden : .automatic, for: .navigationBar)
            .safeAreaInset(edge: .top, spacing: 0) {
                if let embeddedClose { embeddedHeader(close: embeddedClose) }
            }
            .navigationDestination(for: UUID.self) { WorkbenchPocketView(pocketID: $0) }
        }
        .workbenchAddSheet($shareRequest)
        .alert("새 포켓", isPresented: $isCreating) {
            TextField("포켓 이름", text: $newName)
            Button("취소", role: .cancel) {}
            Button("만들기") { create() }
        }
        .alert("포켓 이름 바꾸기", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("포켓 이름", text: $renameText)
            Button("취소", role: .cancel) { renaming = nil }
            Button("바꾸기") { rename() }
        }
        .confirmationDialog("이 포켓을 공개로 바꿀까요?", isPresented: Binding(get: { makingPublic != nil }, set: { if !$0 { makingPublic = nil } }),
                            titleVisibility: .visible) {
            Button("공개로 전환") {
                if let pocket = makingPublic,
                   case .failure(let error) = store.setPocketPrivate(pocket.id, false) { notice = error.localizedDescription }
                makingPublic = nil
            }
            Button("취소", role: .cancel) { makingPublic = nil }
        } message: {
            Text("일반 모드에서도 이 포켓과 안의 항목이 보이게 됩니다.")
        }
        .confirmationDialog("포켓을 삭제할까요?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("포켓 삭제", role: .destructive) { delete() }
            Button("취소", role: .cancel) { deleting = nil }
        } message: {
            Text("'\(deleting?.name ?? "")' 포켓과 안의 참조 \(deleting?.entries.count ?? 0)개만 지웁니다. 사진·영상 원본과 앱에 있던 기존 복사본은 지워지지 않습니다.")
        }
        .alert("작업대 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert("공유로 받은 항목", isPresented: Binding(get: { shareIntents.notice != nil }, set: { if !$0 { shareIntents.notice = nil } })) {
            Button("확인", role: .cancel) { shareIntents.notice = nil }
        } message: { Text(shareIntents.notice ?? "") }
        .onAppear { shareIntents.refresh() }
    }

    /// 오른쪽 패널 뿌리 머리글. 좁은 패널에서 시스템 막대가 제목을 자르고 + 단추를 길게 늘이던 것을 대신한다.
    private func embeddedHeader(close: @escaping () -> Void) -> some View {
        let count = store.pockets.reduce(0) { $0 + $1.entries.count }
        return HStack(spacing: 8) {
            InterfaceIcon(systemName: AppTab.workbench.iconName, size: 20)
                .accessibilityHidden(true)
            Text("작업대")
                .porcelainFont(.section)
                .foregroundStyle(PorcelainMetrics.graphite)
                .lineLimit(1)
                .fixedSize()
                .accessibilityAddTraits(.isHeader)
            Text("담은 항목 \(count)개")
                .porcelainFont(.meta)
                .monospacedDigit()
                .foregroundStyle(PorcelainMetrics.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Button { newName = ""; isCreating = true } label: {
                InterfaceIcon(systemName: "plus", size: 18, fitsBitmap: true)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(store.isReadOnly)
            .accessibilityLabel("새 포켓")
            .help("새 포켓")
            Button(action: close) {
                Image(interfaceSystemName: "xmark", pointSize: 13)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(PorcelainMetrics.secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
            .accessibilityLabel("작업대 닫기")
            .help("작업대 닫기")
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, minHeight: 44)
        .background(PorcelainMetrics.sidebar)
        .overlay(alignment: .bottom) { PorcelainMetrics.line.frame(height: 0.5) }
    }

    private var pocketList: some View {
        List {
            Section {
                ForEach(store.pockets) { pocket in
                    NavigationLink(value: pocket.id) {
                        HStack(spacing: ui(10)) {
                            InterfaceIcon(systemName: "nf.pocket", size: PorcelainMetrics.rowIconSize).frame(width: ui(30))
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: ui(4)) {
                                    Text(pocket.name).font(.ui(.body)).foregroundStyle(PorcelainMetrics.graphite)
                                    if pocket.isPrivate == true {
                                        Image(interfaceSystemName: "eye.slash", pointSize: 12).font(.ui(.caption))
                                            .foregroundStyle(PorcelainMetrics.secondary)
                                            .accessibilityLabel("비공개")
                                    }
                                }
                                Text(summary(pocket)).font(.ui(.caption)).foregroundStyle(PorcelainMetrics.secondary)
                            }
                        }
                    }
                    .listRowBackground(PorcelainMetrics.card)
                    .contextMenu {
                        Button("이름 바꾸기", interfaceSystemImage: "pencil") { renameText = pocket.name; renaming = pocket }
                        if pocket.isPrivate == true {
                            Button("공개로 전환", interfaceSystemImage: "eye") { makingPublic = pocket }
                        } else {
                            Button("비공개로 전환", interfaceSystemImage: "eye.slash") {
                                if case .failure(let error) = store.setPocketPrivate(pocket.id, true) { notice = error.localizedDescription }
                            }
                        }
                        Button("포켓 삭제", interfaceSystemImage: "trash", role: .destructive) { deleting = pocket }
                    }
                    .swipeActions {
                        Button("삭제", role: .destructive) { deleting = pocket }
                        Button("이름") { renameText = pocket.name; renaming = pocket }.tint(PorcelainMetrics.accent)
                    }
                }
            } footer: {
                Text("작업대는 파일·폴더의 위치만 기록합니다. 영상 제작이나 미디어 전송을 시작할 때에만 원본을 가져옵니다.")
                    .font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.secondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private func summary(_ pocket: WorkbenchPocket) -> String {
        let relink = pocket.entries.filter { $0.relinkReason != nil }.count
        return "항목 \(pocket.entries.count)개" + (relink > 0 ? " · 다시 연결 필요 \(relink)개" : "")
    }

    private var readOnlyBanner: some View {
        VStack(alignment: .leading, spacing: ui(6)) {
            Text(store.persistenceError ?? "작업대 기록을 읽지 못했습니다.").font(.ui(.footnote)).foregroundStyle(PorcelainMetrics.danger)
            HStack(spacing: ui(12)) {
                Button("다시 읽기") { store.reload() }
                Button("기록 보관하고 새로 시작", role: .destructive) {
                    if !store.startFreshKeepingUnreadable() { notice = store.persistenceError }
                }
            }.font(.ui(.footnote))
        }
        .padding(ui(12)).frame(maxWidth: .infinity, alignment: .leading)
        .background(PorcelainMetrics.sidebar)
    }

    // MARK: 공유로 받은 항목

    /// 공유 확장이 앱 그룹에 둔 항목 중 아직 어느 포켓도 참조하지 않은 것.
    private struct ShareGroup: Identifiable {
        let batch: ShareIntentBatch
        let items: [ShareIntentItem]
        var id: UUID { batch.id }
    }

    private var unreferencedShares: [ShareGroup] {
        let referenced = Set(store.storedPockets.flatMap(\.entries).compactMap(\.stagedItemID))
        return shareIntents.pendingMaterialBatches.compactMap { batch in
            let items = batch.items.filter { !referenced.contains($0.id) }
            return items.isEmpty ? nil : ShareGroup(batch: batch, items: items)
        }
    }

    private var shareBanner: some View {
        let groups = unreferencedShares
        let count = groups.reduce(0) { $0 + $1.items.count }
        return VStack(alignment: .leading, spacing: ui(6)) {
            Text("공유로 받은 \(count)개가 아직 포켓에 담기지 않았습니다.")
                .font(.ui(.footnote).weight(.semibold)).foregroundStyle(PorcelainMetrics.graphite)
            ForEach(groups.flatMap { $0.items }.filter { $0.lastError != nil }.prefix(3)) { item in
                Text("\(item.originalFilename): \(item.lastError ?? "")")
                    .font(.ui(.caption2)).foregroundStyle(PorcelainMetrics.danger).lineLimit(2)
            }
            HStack(spacing: ui(12)) {
                Button("포켓에 담기") {
                    let entries = groups.flatMap { group in
                        group.items.map { WorkbenchEntryFactory.entry(stagedBatch: group.batch.id, item: $0) }
                    }
                    shareRequest = WorkbenchAddRequest(
                        title: "공유로 받은 항목 \(entries.count)개", entries: entries,
                        notices: groups.flatMap { $0.batch.skippedReasons })
                }
                Menu("대기 항목 버리기") {
                    ForEach(groups) { group in
                        Button("공유 \(group.items.count)개 버리기", role: .destructive) {
                            shareIntents.discardPending(batchID: group.batch.id)
                        }
                    }
                }
            }.font(.ui(.footnote))
        }
        .padding(ui(12)).frame(maxWidth: .infinity, alignment: .leading)
        .background(PorcelainMetrics.sidebar)
    }

    // MARK: 동작

    private func create() {
        switch store.createPocket(named: newName) {
        case .success(let id): path = [id]
        case .failure(let error): notice = error.localizedDescription
        }
    }

    private func rename() {
        guard let pocket = renaming else { return }
        renaming = nil
        if case .failure(let error) = store.renamePocket(pocket.id, to: renameText) { notice = error.localizedDescription }
    }

    private func delete() {
        guard let pocket = deleting else { return }
        deleting = nil
        if case .failure(let error) = store.removePocket(pocket.id) { notice = error.localizedDescription }
    }
}
