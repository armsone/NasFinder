import SwiftUI
import UniformTypeIdentifiers

/// 영상 탭의 네 목적지. 용어: 편집본 = 이어서 편집할 수 있는 프로젝트, 컬렉션 = 재생 가능한 완성 영상 파일.
enum VideoDestination: String, CaseIterable, Identifiable {
    case make = "영상 제작"
    case basket = "재료함"
    case drafts = "편집본"
    case collection = "컬렉션"
    var id: String { rawValue }
}

/// 재료함 항목에서 연결 서비스를 만든다. 폰하드는 로컬 서비스, 나머지는 저장된 연결과 로그인 정보를 쓴다.
@MainActor
func materialService(for item: MaterialItem, connectionStore: ConnectionStore) -> (any RemoteFileService)? {
    guard let connectionID = item.connectionID else { return nil }
    if connectionID == LocalInboxFileService.connectionID { return LocalInboxFileService() }
    if case .granted(let access) = DeviceFolderBookmark.restore(), access.connectionID == connectionID {
        // 기기 파일은 기억한 폴더 권한을 다시 열 수 있고 항목의 연결 ID와 일치할 때만 받는다. 권한은 받기 작업이 끝나면 닫힌다.
        return DeviceFolderFileService(access: access)
    }
    guard let connection = connectionStore.connections.first(where: { $0.id == connectionID }),
          let credential = try? connectionStore.credential(for: connection) else { return nil }
    return RemoteFileServiceFactory.make(connection: connection, credential: credential)
}

struct VideoHubView: View {
    @EnvironmentObject private var connectionStore: ConnectionStore
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @ObservedObject private var basket = MaterialBasketStore.shared
    @ObservedObject private var draftStore = TrailerDraftStore.shared
    @ObservedObject private var router = AppShellRouter.shared
    @Environment(\.usesShellSidebar) private var usesShellSidebar
    @State private var selected: Set<UUID> = []
    @State private var editor: HubEditorPresentation?
    @State private var resumingDraft: TrailerDraftEntry?
    @State private var notice: String?
    @State private var isImportingFiles = false

    private struct HubEditorPresentation: Identifiable {
        let id = UUID()
        let items: [RemoteFileItem]
        let service: LocalPhotoLibraryFileService
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Mac 넓은 창에서는 사이드바가 하위 목적지를 고르므로 가로 막대를 겹쳐 두지 않는다.
                if !usesShellSidebar { destinationPicker }
                Group {
                    switch destination {
                    case .make: makeDestination
                    case .basket: basketDestination
                    case .drafts:
                        TrailerDraftManagerView { entry in resumingDraft = entry }
                    case .collection: MovieCollectionView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(PorcelainMetrics.paper)
            .navigationTitle(usesShellSidebar ? destination.rawValue : "영상")
            .navigationBarTitleDisplayMode(.inline)
        }
        .fullScreenCover(item: $editor) { presentation in
            VideoTrailerView(items: presentation.items, service: presentation.service, mode: .trailer,
                             keepsSelectionOrder: true)
                .environmentObject(inboxStore)
        }
        .fullScreenCover(item: $resumingDraft) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
                .environmentObject(inboxStore)
        }
        .alert("알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
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
                        Text(item.rawValue)
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
                Text("새 영상을 만들 때만 편집본이 생깁니다. 재료함은 그대로 남습니다.")
                    .porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary)
                PorcelainGroupCard {
                    Button { start(from: basket.readyItems.map(\.id)) } label: {
                        PorcelainRow(
                            title: "재료함으로 시작",
                            subtitle: basket.readyItems.isEmpty
                                ? "바로 쓸 수 있는 재료가 없습니다"
                                : "바로 쓸 수 있는 재료 \(basket.readyItems.count)개 · 전체 \(basket.items.count)개",
                            showsChevron: true
                        ) { InterfaceIcon(systemName: "film", size: PorcelainMetrics.rowIconSize) } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                    .disabled(basket.readyItems.isEmpty)
                    PorcelainDivider()
                    NavigationLink {
                        LocalPhotoLibraryView(initialMode: .trailer)
                    } label: {
                        PorcelainRow(
                            title: "미디어 고르기",
                            subtitle: "사진·영상·폰하드·NAS에서 골라 바로 제작합니다",
                            subtitleLineLimit: 2, showsChevron: true
                        ) { InterfaceIcon(systemName: "photo.on.rectangle.angled", size: PorcelainMetrics.rowIconSize) } trailing: { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: 재료함

    private var basketDestination: some View {
        VStack(spacing: 0) {
            if basket.items.isEmpty {
                PorcelainStateView(
                    systemImage: "photo.on.rectangle.angled",
                    title: "재료함이 비어 있습니다",
                    message: "폴더·폰하드·내 사진에서 \"재료함에 담기\"를 누르거나 아래 + 로 파일을 추가하세요.")
            } else {
                List {
                    ForEach(basket.items) { item in
                        MaterialRow(item: item, isSelected: selected.contains(item.id),
                                    progress: basket.progress[item.id],
                                    toggle: { toggle(item.id) },
                                    retry: { retry(item) },
                                    exclude: {
                                        // 인덱스에 기록된 경우에만 선택도 푼다. 실패하면 목록·선택·파일을 그대로 둔다.
                                        if basket.remove([item.id]) {
                                            selected.remove(item.id)
                                        } else {
                                            notice = basket.persistenceError ?? "재료함에서 빼지 못했습니다. 다시 시도해 주세요."
                                        }
                                    })
                            .listRowBackground(PorcelainMetrics.card)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            basketBar
        }
        .fileImporter(isPresented: $isImportingFiles, allowedContentTypes: [.image, .movie],
                      allowsMultipleSelection: true) { result in importFiles(result) }
    }

    private var basketBar: some View {
        VStack(spacing: 8) {
            if let message = basket.persistenceError {
                Text(message).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.danger)
            }
            HStack(spacing: 8) {
                Menu {
                    NavigationLink("내 사진·영상에서 추가") { LocalPhotoLibraryView() }
                    Button("기기 파일에서 추가") { isImportingFiles = true }
                    Button("받아야 하는 재료 모두 받기") { acquireAll() }
                } label: {
                    InterfaceToolbarIcon(systemName: "plus")
                }
                .accessibilityLabel("재료 추가")
                Text("선택 \(selected.count)개 · 전체 \(basket.items.count)개")
                    .porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary).monospacedDigit()
                Spacer()
                Button("선택으로 영상 제작") { start(from: Array(selected)) }
                    .buttonStyle(PorcelainProminentButtonStyle())
                    .disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(PorcelainMetrics.card)
        .overlay(alignment: .top) { PorcelainMetrics.line.frame(height: 0.5) }
    }

    private func toggle(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    private func retry(_ item: MaterialItem) {
        if item.connectionID == nil {
            // 원격 연결이 없는 항목은 이 항목만 다시 받을 출처가 없다. 사실대로 알리고 제외는 사용자가 정한다.
            notice = item.sourceKind == .googlePhotos
                ? "Google 포토 선택 세션은 가져오기가 끝나면 닫혀서 이 항목만 다시 받을 수 없습니다. Google 포토 가져오기 화면에서 다시 선택하거나, 이 항목을 제외해 주세요."
                : "이 항목은 다시 받을 출처 정보가 없습니다. 원본 파일을 다시 담거나 제외해 주세요."
            return
        }
        guard let service = materialService(for: item, connectionStore: connectionStore) else {
            notice = "이 재료의 연결이 삭제되었거나 로그인 정보가 없어 받을 수 없습니다. 제외하거나 연결을 다시 추가해 주세요."
            return
        }
        basket.acquire(item.id, service: service)
    }

    private func acquireAll() {
        for item in basket.items where item.availability != .localReady && item.connectionID != nil { retry(item) }
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result else { return }
        Task { @MainActor in
            // 복사본을 검증하고 인덱스에 기록한 것만 담긴 것으로 센다. 보안 범위 접근은 addValidated가 연다.
            var duplicates = 0
            var failures: [String] = []
            for url in urls {
                let type = UTType(filenameExtension: url.pathExtension)
                let isVideo = type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true
                switch await basket.addValidated(url: url, name: url.lastPathComponent, isVideo: isVideo,
                                                 sourceKey: "file:\(url.standardizedFileURL.path)", kind: .systemFile) {
                case .added: break
                case .duplicate: duplicates += 1
                case .failed(let reason): failures.append("\(url.lastPathComponent): \(reason)")
                }
            }
            var parts: [String] = []
            if duplicates > 0 { parts.append("이미 담긴 파일 \(duplicates)개는 건너뛰었습니다.") }
            if !failures.isEmpty { parts.append("담지 못한 파일 \(failures.count)개: " + failures.joined(separator: ", ")) }
            if !parts.isEmpty { notice = parts.joined(separator: "\n") }
        }
    }

    // MARK: 제작 시작

    /// 확정한 재료로 독립된 편집 프로젝트를 시작한다. 재료함은 비우지 않고, 편집기는 자기 사본을 만든다.
    private func start(from ids: [UUID]) {
        let chosen = basket.items.filter { ids.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let notReady = chosen.filter { basket.fileURL(for: $0) == nil || $0.availability != .localReady }
        guard notReady.isEmpty else {
            notice = "\(notReady.count)개 재료가 아직 이 기기에 없습니다. 재료함에서 받기를 마치거나 제외한 뒤 다시 시작해 주세요. 받은 재료는 그대로 유지됩니다."
            destination = .basket
            return
        }
        var entries: [(item: RemoteFileItem, url: URL)] = []
        for item in chosen {
            guard let url = basket.fileURL(for: item) else { continue }
            let remote = RemoteFileItem(
                connectionID: LocalPhotoLibraryFileService.connectionID, path: url.path, name: item.name,
                kind: .file, size: item.byteCount, modifiedAt: nil,
                contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
            entries.append((remote, url))
        }
        let items = entries.map(\.item).filter(\.isTrailerEligible)
        guard !items.isEmpty else { return }
        editor = HubEditorPresentation(items: items, service: LocalPhotoLibraryFileService(entries: entries))
    }
}

private struct MaterialRow: View {
    let item: MaterialItem
    let isSelected: Bool
    let progress: Double?
    let toggle: () -> Void
    let retry: () -> Void
    let exclude: () -> Void

    private var statusText: String {
        switch item.availability {
        case .localReady: "이 기기에 준비됨"
        case .needsDownload: progress == nil ? "받아야 함 (네트워크 필요)" : "받는 중"
        case .unavailable: item.failureMessage.map { "사용 불가 · \($0)" } ?? "사용 불가"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.secondary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isSelected ? "선택됨" : "선택")
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).porcelainFont(.tile).foregroundStyle(PorcelainMetrics.graphite).lineLimit(1)
                Text("\(item.sourceKind.rawValue) · \(item.isVideo ? "영상" : "사진")"
                     + (item.byteCount.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                    .porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                Text(statusText).porcelainFont(.meta)
                    .foregroundStyle(item.availability == .unavailable ? PorcelainMetrics.danger : PorcelainMetrics.secondary)
                    .lineLimit(2)
                if let progress { ProgressView(value: progress) }
            }
            Spacer(minLength: 0)
            Menu {
                if item.availability != .localReady && progress == nil { Button("다시 받기", action: retry) }
                Button("재료함에서 제외", role: .destructive, action: exclude)
            } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44)
            }
            .accessibilityLabel("재료 메뉴")
        }
    }
}
