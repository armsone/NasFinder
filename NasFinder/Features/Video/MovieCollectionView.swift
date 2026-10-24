import AVKit
import SwiftUI
import UniformTypeIdentifiers

/// 컬렉션 목적지: 세로 포스터 격자. 고정 + 직접 정한 순서, 이름·포스터 변경, 압축, 공유, 제거.
struct MovieCollectionView: View {
    @ObservedObject private var store = MovieCollectionStore.shared
    @State private var isImporting = false
    @State private var pendingImport: [URL] = []
    @State private var playing: CollectedVideo?
    @State private var renaming: CollectedVideo?
    @State private var renameText = ""
    @State private var posterTarget: CollectedVideo?
    @State private var compressTarget: CollectedVideo?
    @State private var removeTarget: CollectedVideo?
    @State private var isWorking = false
    @State private var workTask: Task<Void, Never>?
    @State private var reselectTarget: CollectedVideo?
    @State private var convertTarget: CollectedVideo?
    @ObservedObject private var drafts = TrailerDraftStore.shared
    @ObservedObject private var projects = TrailerProjectStore.shared
    @State private var openingEntry: TrailerDraftEntry?
    @State private var newClip: ClipEditorPresentation?
    @State private var notice: String?

    private struct ClipEditorPresentation: Identifiable {
        let id = UUID()
        let items: [RemoteFileItem]
        let service: LocalPhotoLibraryFileService
        var originPrivate = false
    }

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 160), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(store.videos.count)편").porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                Spacer()
                Button { isImporting = true } label: {
                    Label("영상 가져오기", interfaceSystemImage: "nf.import").porcelainFont(.tile)
                }
                .frame(minHeight: 44)
            }
            .padding(.horizontal, 16)
            if store.videos.isEmpty {
                PorcelainStateView(
                    systemImage: "photo.stack", title: "컬렉션이 비어 있습니다",
                    message: "완성한 영상을 컬렉션에 추가하거나 + 영상 가져오기로 파일을 가져오세요.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(store.ordered) { video in poster(video) }
                    }
                    .padding(16)
                }
            }
            if let message = store.errorMessage {
                Text(message).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.danger).padding(8)
            }
        }
        .task { await store.refreshReferences() }
        .overlay {
            if isWorking {
                VStack(spacing: 10) {
                    ProgressView("처리 중…")
                    Button("취소", role: .cancel) { workTask?.cancel() }.buttonStyle(.bordered)
                }
                .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .fileImporter(isPresented: Binding(get: { reselectTarget != nil }, set: { if !$0 { reselectTarget = nil } }),
                      allowedContentTypes: [.movie], allowsMultipleSelection: false) { result in
            guard let target = reselectTarget else { return }
            reselectTarget = nil
            if case .success(let urls) = result, let url = urls.first {
                Task { if await store.reselectReference(target.id, to: url) { notice = "원본을 다시 연결했습니다." } }
            }
        }
        .confirmationDialog("앱 안에 복사본을 만들까요?", isPresented: Binding(get: { convertTarget != nil }, set: { if !$0 { convertTarget = nil } }),
                            titleVisibility: .visible) {
            Button("복사본 만들고 전환") {
                guard let target = convertTarget else { return }
                convertTarget = nil
                isWorking = true
                workTask = Task { _ = await store.convertToCopy(target.id); isWorking = false }
            }
            Button("취소", role: .cancel) { convertTarget = nil }
        } message: {
            Text("원본은 그대로 두고 앱 안에 복사본을 만든 뒤, 복사가 확인되면 이 항목이 복사본을 쓰도록 바뀝니다. 앱 저장 공간을 차지합니다.")
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.movie], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { pendingImport = urls }
        }
        .sheet(isPresented: Binding(get: { !pendingImport.isEmpty }, set: { if !$0 { pendingImport = [] } })) {
            CollectionImportSheet(urls: pendingImport) { pendingImport = [] }
        }
        .fullScreenCover(item: $playing) { video in
            CollectionPlayerView(url: store.playbackURL(video) ?? store.videoURL(video), title: video.title) { playing = nil }
        }
        .sheet(item: $posterTarget) { video in CollectionPosterPicker(video: video) }
        .trailerEditorCover(item: $openingEntry) { entry in
            VideoTrailerView(items: entry.items, service: entry.service, mode: entry.mode, resuming: entry)
        }
        .trailerEditorCover(item: $newClip) { presentation in
            VideoTrailerView(items: presentation.items, service: presentation.service, mode: .trailer,
                             keepsSelectionOrder: true, originPrivate: presentation.originPrivate)
        }
        .alert("컬렉션 알림", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("확인", role: .cancel) { notice = nil }
        } message: { Text(notice ?? "") }
        .alert("이름 변경", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("제목", text: $renameText)
            Button("취소", role: .cancel) { renaming = nil }
            Button("저장") { if let id = renaming?.id { store.rename(id, to: renameText) }; renaming = nil }
        }
        .confirmationDialog("앱 안의 복사본을 압축합니다", isPresented: Binding(get: { compressTarget != nil }, set: { if !$0 { compressTarget = nil } }),
                            titleVisibility: .visible) {
            ForEach(CollectionCompressionOption.allCases) { option in
                Button(option.title) {
                    guard let target = compressTarget else { return }
                    compressTarget = nil
                    isWorking = true
                    workTask = Task { _ = await store.compress(target.id, option: option); isWorking = false }
                }
            }
            Button("취소", role: .cancel) { compressTarget = nil }
        } message: {
            Text(compressTarget?.isReference == true
                 ? "원본 파일은 바뀌지 않습니다. 앱 안에 압축본을 새로 만들고, 더 작아지고 재생이 확인될 때만 이 항목이 압축본을 쓰도록 바뀝니다."
                 : "압축본을 새 파일로 만들고, 더 작아지고 재생이 확인될 때만 교체합니다. 실패하거나 취소하면 기존 영상이 그대로 남습니다.")
        }
        .confirmationDialog("컬렉션에서 제거할까요?", isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
                            titleVisibility: .visible) {
            Button(removeTarget?.isReference == true ? "컬렉션 목록에서만 제거" : "앱 안의 복사본 제거", role: .destructive) {
                if let id = removeTarget?.id { store.remove(id) }
                removeTarget = nil
            }
            Button("취소", role: .cancel) { removeTarget = nil }
        } message: {
            Text(removeTarget?.isReference == true
                 ? "연결 기록만 지워집니다. 원본 파일과 편집본은 지워지지 않습니다."
                 : "컬렉션의 복사본만 지워집니다. 편집본과 외부 원본 파일은 지워지지 않습니다.")
        }
    }

    /// 컬렉션 영상을 만든 편집본을 연다. 편집본을 지워도 컬렉션 영상은 남고, 반대도 마찬가지다.
    private func openProject(_ id: UUID) {
        if let entry = drafts.entries.first(where: { $0.id == id }) {
            openingEntry = entry
        } else if let record = projects.records[id], PrivacyMode.isVisible(record.isPrivate) {
            openingEntry = TrailerDraftStore.entry(from: record)
        } else {
            notice = "이 영상을 만든 편집본이 지워졌거나 지금 다른 화면에서 편집 중입니다. 컬렉션 영상은 그대로 남아 있습니다."
        }
    }

    /// 가져온 영상은 복사본 한 개를 클립으로 쓰는 새 편집으로 시작한다. 컬렉션 파일은 바뀌지 않는다.
    private func startClip(from video: CollectedVideo) {
        guard let url = store.playbackURL(video) else {
            notice = store.state(of: video).message ?? "영상을 열 수 없습니다."
            return
        }
        let item = RemoteFileItem(
            connectionID: LocalPhotoLibraryFileService.connectionID, path: url.path, name: video.title + ".mp4",
            kind: .file, size: video.byteCount, modifiedAt: nil,
            contentTypeIdentifier: UTType(filenameExtension: url.pathExtension)?.identifier)
        newClip = ClipEditorPresentation(items: [item], service: LocalPhotoLibraryFileService(entries: [(item, url)]),
                                         originPrivate: video.isPrivate == true)
    }

    private func poster(_ video: CollectedVideo) -> some View {
        Button {
            if store.playbackURL(video) != nil { playing = video }
            else {
                notice = (store.state(of: video).message ?? "영상을 열 수 없습니다.")
                Task { await store.refreshReferences(ids: [video.id]) }
            }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Color.clear
                        .aspectRatio(2.0 / 3.0, contentMode: .fit)
                        .overlay { PosterImage(url: store.posterURL(video)) }
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: PorcelainMetrics.coverCorner, style: .continuous))
                    if video.isPrivate == true {
                        Image(interfaceSystemName: "eye.slash", pointSize: 12).font(.caption).padding(5)
                            .foregroundStyle(PorcelainMetrics.onAccent)
                            .background(PorcelainMetrics.graphite, in: Circle()).padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .accessibilityLabel("비공개")
                    }
                    if video.isPinned {
                        Image(interfaceSystemName: "pin.fill", pointSize: 12).font(.caption).padding(5)
                            .foregroundStyle(PorcelainMetrics.onAccent)
                            .background(PorcelainMetrics.accent, in: Circle()).padding(4)
                    }
                }
                Text(video.title).porcelainFont(.tile).foregroundStyle(PorcelainMetrics.graphite).lineLimit(2)
                Text(Duration.seconds(video.duration).formatted(.time(pattern: .minuteSecond))
                     + " · " + ByteCountFormatter.string(fromByteCount: video.byteCount, countStyle: .file)
                     + (video.isReference ? " · 원본 참조" : ""))
                    .porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary)
                if let problem = store.state(of: video).message {
                    Text(problem).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.danger).lineLimit(3)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if video.isImported {
                Button("이 영상으로 새 편집 시작", interfaceSystemImage: "film") { startClip(from: video) }
            } else if let projectID = video.sourceProjectID,
                      let project = TrailerProjectStore.shared.records[projectID], PrivacyMode.isVisible(project.isPrivate) {
                // 이 영상을 만든 편집본이 실제로 남아 있을 때만 보여 준다. 지워진 편집본을 가리키는 가짜 동작은 만들지 않는다.
                Button("만든 편집본 열기", interfaceSystemImage: "square.and.pencil") { openProject(projectID) }
            }
            Button("이름 변경", interfaceSystemImage: "pencil") { renameText = video.title; renaming = video }
            if video.isPrivate == true {
                Button("공개로 전환", interfaceSystemImage: "eye") { store.setPrivate(video.id, false) }
            } else {
                Button("비공개로 전환", interfaceSystemImage: "eye.slash") { store.setPrivate(video.id, true) }
            }
            Button(video.isPinned ? "고정 해제" : "고정", interfaceSystemImage: "pin") { store.togglePin(video.id) }
            Button("앞으로 이동", interfaceSystemImage: "arrow.up") { store.move(video.id, by: -1) }
            Button("뒤로 이동", interfaceSystemImage: "arrow.down") { store.move(video.id, by: 1) }
            Button("포스터 선택", interfaceSystemImage: "photo") { posterTarget = video }
            if video.isReference {
                Button("연결 다시 확인", interfaceSystemImage: "arrow.clockwise") { Task { await store.refreshReferences(ids: [video.id]) } }
                Button("원본 다시 선택", interfaceSystemImage: "folder") { reselectTarget = video }
                Button("앱 안에 복사본 만들기", interfaceSystemImage: "doc.on.doc") { convertTarget = video }
            }
            Button(video.isReference ? "압축본 만들기" : "파일 압축", interfaceSystemImage: "arrow.down.right.and.arrow.up.left") { compressTarget = video }
                .disabled(store.playbackURL(video) == nil)
            if let shareURL = store.playbackURL(video) {
                ShareLink(item: shareURL) { Label("공유", interfaceSystemImage: "square.and.arrow.up") }
            }
            Button(video.isReference ? "컬렉션 목록에서 제거" : "컬렉션에서 제거", interfaceSystemImage: "trash", role: .destructive) { removeTarget = video }
        }
        .accessibilityLabel(video.title)
        .accessibilityAction(named: "앞으로 이동") { store.move(video.id, by: -1) }
        .accessibilityAction(named: "뒤로 이동") { store.move(video.id, by: 1) }
    }
}

private struct PosterImage: View {
    let url: URL
    var body: some View {
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFill()
        } else {
            Rectangle().fill(PorcelainMetrics.line)
        }
    }
}

private struct CollectionPlayerView: View {
    let url: URL
    let title: String
    let onClose: () -> Void
    @State private var player: AVPlayer?

    var body: some View {
        NavigationStack {
            VideoPlayer(player: player)
                .background(Color.black.ignoresSafeArea())
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기", action: onClose) } }
                .onAppear { player = AVPlayer(url: url); player?.play() }
                .onDisappear { player?.pause() }
        }
    }
}

/// 가져오기 확인: 크기를 보여 주고 앱 안 복사(기본) 또는 원본 참조를 고른다.
/// 참조는 사용자가 직접 고른 파일의 보안 범위 북마크를 저장하는 방식이라 이 파일 선택 경로에서만 제공한다.
/// NAS·Google 포토·브라우저 출처는 이 화면의 선택 대상이 아니므로 참조 선택지를 내지 않는다.
private struct CollectionImportSheet: View {
    let urls: [URL]
    let onDone: () -> Void
    @State private var isWorking = false
    @State private var asReference = false
    @State private var failures: [String] = []
    @State private var finished = false

    private var totalBytes: Int64 {
        urls.reduce(0) { total, url in
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(urls.count)개 영상 · \(ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file))")
                    .porcelainFont(.section)
                Picker("가져오는 방식", selection: $asReference) {
                    Text("앱 안에 복사").tag(false)
                    Text("원본 위치 참조").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(isWorking || finished)
                Text(asReference
                     ? "복사하지 않고 선택한 원본 위치를 기억합니다. 저장 공간은 쓰지 않지만 원본이 이동·삭제되거나 저장 장치가 빠지면 재생할 수 없고, 그때는 다시 연결해야 합니다. 앱은 원본을 바꾸거나 지우지 않습니다."
                     : "앱 안에 복사본을 만들어 컬렉션에 추가합니다. 위 용량만큼 앱 저장 공간을 씁니다. 원본은 바뀌지 않고, 가져온 영상은 새 제작에서 클립 한 개로만 쓸 수 있습니다.")
                    .porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary)
                if !failures.isEmpty {
                    Text("추가하지 못한 영상\n" + failures.joined(separator: "\n"))
                        .porcelainFont(.meta).foregroundStyle(PorcelainMetrics.danger)
                }
                Button(finished ? "닫기" : (isWorking ? "처리 중…" : (asReference ? "참조로 추가" : "복사해서 추가"))) {
                    if finished { onDone(); return }
                    isWorking = true
                    Task {
                        var failed: [String] = []
                        for url in urls {
                            let title = url.deletingPathExtension().lastPathComponent
                            let added = await MovieCollectionStore.shared.add(
                                from: url, title: title, isImported: true, asReference: asReference)
                            if added == nil {
                                failed.append("\(url.lastPathComponent): \(MovieCollectionStore.shared.errorMessage ?? "알 수 없는 오류")")
                            }
                        }
                        isWorking = false
                        if failed.isEmpty { onDone() } else { failures = failed; finished = true }
                    }
                }
                .buttonStyle(PorcelainProminentButtonStyle())
                .disabled(isWorking)
                Spacer()
            }
            .padding(16)
            .background(PorcelainMetrics.paper)
            .navigationTitle("영상 가져오기")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소", action: onDone).disabled(isWorking) } }
        }
        .presentationDetents([.medium])
    }
}

/// 추천 썸네일 후보 중에서 고른다. 다시 만들면 다른 위치의 장면으로 새 후보가 나온다. 개수 제한은 없다.
private struct CollectionPosterPicker: View {
    let video: CollectedVideo
    @Environment(\.dismiss) private var dismiss
    @State private var candidates: [PosterCandidate] = []
    @State private var isLoading = true
    @State private var generation = 0

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading { ProgressView().padding(40) }
                if !isLoading && candidates.isEmpty {
                    Text("후보 장면을 만들지 못했습니다. 영상을 열 수 있는지 확인해 주세요.")
                        .porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary).padding(24)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 10)], spacing: 10) {
                    ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                        Button {
                            MovieCollectionStore.shared.setPoster(video.id, data: candidate.data)
                            dismiss()
                        } label: {
                            if let image = UIImage(data: candidate.data) {
                                Image(uiImage: image).resizable().aspectRatio(2.0 / 3.0, contentMode: .fill)
                                    .frame(maxWidth: .infinity)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(alignment: .topLeading) {
                                        if index == 0 {
                                            Text("추천").font(.caption2.bold()).padding(4)
                                                .background(PorcelainMetrics.accent, in: Capsule())
                                                .foregroundStyle(PorcelainMetrics.onAccent).padding(4)
                                        }
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(Duration.seconds(candidate.time).formatted(.time(pattern: .minuteSecond)))
                                            .font(.caption2.monospacedDigit()).padding(3)
                                            .background(.black.opacity(0.55), in: Capsule())
                                            .foregroundStyle(.white).padding(4)
                                    }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                Text("선명도·밝기·해상도로 점수를 매긴 추천 썸네일입니다. 직접 고른 장면이 포스터가 됩니다.")
                    .porcelainFont(.meta).foregroundStyle(PorcelainMetrics.secondary).padding(.horizontal, 16)
            }
            .background(PorcelainMetrics.paper)
            .navigationTitle("추천 썸네일")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("다시 만들기", interfaceSystemImage: "arrow.clockwise") { generation += 1; Task { await load() } }
                        .disabled(isLoading)
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        isLoading = true
        candidates = await MovieCollectionStore.shared.posterCandidates(for: video, generation: generation)
        isLoading = false
    }
}

/// 내보낸 영상 확인: 제목과 포스터를 확인하고 컬렉션에 등록한다. 완성되어 재생 가능한 파일만 등록된다.
struct CollectionAddSheet: View {
    let videoURL: URL
    let suggestedTitle: String
    var sourceProjectID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var posters: [PosterCandidate] = []
    @State private var generation = 0
    @State private var isLoadingPosters = false
    @State private var selectedPoster = 0
    @State private var isWorking = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                TextField("제목", text: $title).textFieldStyle(.roundedBorder)
                HStack {
                    Text("추천 썸네일").porcelainFont(.section)
                    Spacer()
                    Button("다시 만들기", interfaceSystemImage: "arrow.clockwise") { generation += 1; Task { await loadPosters() } }
                        .disabled(isLoadingPosters)
                }
                ScrollView(.horizontal) {
                    HStack {
                        ForEach(Array(posters.enumerated()), id: \.element.id) { index, candidate in
                            Button { selectedPoster = index } label: {
                                if let image = UIImage(data: candidate.data) {
                                    Image(uiImage: image).resizable().aspectRatio(2.0 / 3.0, contentMode: .fill)
                                        .frame(width: 80, height: 120)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                        .overlay(RoundedRectangle(cornerRadius: 6)
                                            .stroke(PorcelainMetrics.accent, lineWidth: selectedPoster == index ? 3 : 0))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                Text("이 기기의 컬렉션에 복사본이 저장됩니다. 편집본은 그대로 남습니다.")
                    .porcelainFont(.body).foregroundStyle(PorcelainMetrics.secondary)
                Button(isWorking ? "추가 중…" : "컬렉션에 추가") {
                    isWorking = true
                    Task {
                        let poster = posters.indices.contains(selectedPoster) ? posters[selectedPoster].data : nil
                        let result = await MovieCollectionStore.shared.add(
                            from: videoURL, title: title.isEmpty ? suggestedTitle : title,
                            posterData: poster, sourceProjectID: sourceProjectID, isImported: false)
                        isWorking = false
                        if let result {
                            if let sourceProjectID {
                                // 프로젝트 작업 줄에 세운다. 실패는 그 편집본의 저장 상태로 남는다.
                                Task { await TrailerProjectStore.shared.linkCollectionVideo(result.id, to: sourceProjectID) }
                            }
                            dismiss()
                        }
                    }
                }
                .buttonStyle(PorcelainProminentButtonStyle())
                .disabled(isWorking)
                if let message = MovieCollectionStore.shared.errorMessage {
                    Text(message).porcelainFont(.meta).foregroundStyle(PorcelainMetrics.danger)
                }
                Spacer()
            }
            .padding(16)
            .background(PorcelainMetrics.paper)
            .navigationTitle("컬렉션에 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
            .task {
                title = suggestedTitle
                await loadPosters()
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func loadPosters() async {
        isLoadingPosters = true
        defer { isLoadingPosters = false }
        let seconds = (try? await AVURLAsset(url: videoURL).load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else { return }
        posters = await PosterCandidateGenerator.candidates(url: videoURL, duration: seconds, generation: generation, count: 6)
        selectedPoster = 0
    }
}
