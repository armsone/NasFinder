import AVFoundation
import SwiftUI
import UIKit

// MARK: - 장면 편집 연산

/// 장면 목록을 고치는 순수 연산. 화면과 저장이 같은 규칙을 쓰도록 한곳에 둔다.
enum TrailerSceneEditor {
    static func index(of id: Int?, in scenes: [TrailerEditScene]) -> Int? {
        guard let id else { return nil }
        return scenes.firstIndex { $0.id == id }
    }

    static func move(_ id: Int, by offset: Int, in scenes: inout [TrailerEditScene]) {
        guard let from = index(of: id, in: scenes) else { return }
        let to = from + offset
        guard scenes.indices.contains(to) else { return }
        scenes.swapAt(from, to)
    }

    static func duplicate(_ id: Int, in scenes: inout [TrailerEditScene], nextID: inout Int) -> Int? {
        guard let at = index(of: id, in: scenes) else { return nil }
        var copy = scenes[at]
        copy.id = nextID
        copy.excluded = false
        nextID += 1
        scenes.insert(copy, at: at + 1)
        return copy.id
    }

    /// 같은 소스의 다른 장면이 남아 있을 때만 지울 수 있다. 마지막 장면은 제외로만 뺀다.
    static func canDelete(_ id: Int, in scenes: [TrailerEditScene]) -> Bool {
        guard let at = index(of: id, in: scenes) else { return false }
        return scenes.contains { $0.sourceID == scenes[at].sourceID && $0.id != id }
    }

    static func delete(_ id: Int, in scenes: inout [TrailerEditScene]) {
        guard canDelete(id, in: scenes), let at = index(of: id, in: scenes) else { return }
        scenes.remove(at: at)
    }

    static func update(_ id: Int, in scenes: inout [TrailerEditScene], _ change: (inout TrailerEditScene) -> Void) {
        guard let at = index(of: id, in: scenes) else { return }
        change(&scenes[at])
    }

    /// 새로 들어온 소스의 장면. 사진은 기본 길이, 영상은 공통 장면 길이만큼의 하이라이트.
    static func newScene(for source: VideoTrailerSource, id: Int, clipLength: Double) -> TrailerEditScene? {
        if source.isImage {
            return TrailerEditScene(id: id, sourceID: source.id, start: 0, length: max(0.5, clipLength * source.imageDurationRatio))
        }
        guard source.duration > 0 else { return nil }
        let length = VideoTrailerBatchPlan.sceneLength(source, clipLength: clipLength)
        let first = source.plan.proposal(total: length, clipLength: length).first
        return TrailerEditScene(id: id, sourceID: source.id, start: first?.start ?? 0, length: first?.length ?? length)
    }
}

extension TrailerSettingsDraft {
    /// 새로 스테이징된 소스만 목록 끝에 붙인다. 사용자가 뺀 소스는 `knownIDs` 덕에 되살아나지 않는다.
    mutating func absorbNewSources(_ staged: [VideoTrailerSource]) -> Bool {
        let fresh = staged.filter { !knownIDs.contains($0.id) }
        guard !fresh.isEmpty else { return false }
        for source in fresh {
            sources.append(source)
            knownIDs.insert(source.id)
            if scenes != nil, let scene = TrailerSceneEditor.newScene(for: source, id: nextSceneID, clipLength: clipLength) {
                scenes?.append(scene)
                nextSceneID += 1
            }
        }
        return true
    }

    mutating func beginSceneEditing(mode: VideoTrailerMode) {
        guard scenes == nil else { return }
        let seeded = TrailerPreparedPlan.seedEdits(mode: mode, sources: sources, total: total, clipLength: clipLength)
        scenes = seeded
        nextSceneID = (seeded.map(\.id).max() ?? 0) + 1
    }

    /// 되돌리기 항목 비교용 가벼운 서명.
    var signature: TrailerDraftSignature {
        TrailerDraftSignature(
            sourceIDs: sources.map(\.id), total: total, clipLength: clipLength, aspect: aspectRatio?.rawValue,
            music: music, scenes: scenes, photoRatios: sources.map(\.imageDurationRatio))
    }
}

struct TrailerDraftSignature: Equatable {
    var sourceIDs: [Int]
    var total: Double
    var clipLength: Double
    var aspect: String?
    var music: TrailerMusicSelection?
    var scenes: [TrailerEditScene]?
    var photoRatios: [Double]
}

// MARK: - 되돌리기 / 다시 실행

/// 이번 편집 중의 변경 이력. 앱을 다시 켜면 비워지고, 프로젝트 자체는 디스크에 남는다.
@MainActor
final class TrailerEditHistory: ObservableObject {
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    private var past: [TrailerSettingsDraft] = []
    private var future: [TrailerSettingsDraft] = []
    private var lastCommitted: TrailerSettingsDraft?
    private var lastChange = Date.distantPast
    private var applying = false

    /// 슬라이더를 끄는 동안의 연속 변경은 한 단계로 묶는다.
    func observe(_ draft: TrailerSettingsDraft) {
        defer { lastCommitted = draft }
        if applying { applying = false; return }
        guard let previous = lastCommitted, previous.signature != draft.signature else { return }
        if Date().timeIntervalSince(lastChange) > 0.8 || past.isEmpty {
            past.append(previous)
            if past.count > 200 { past.removeFirst() }
        }
        lastChange = Date()
        future.removeAll()
        refresh()
    }

    func reset(to draft: TrailerSettingsDraft?) {
        past.removeAll(); future.removeAll(); lastCommitted = draft; refresh()
    }

    func undo(current: TrailerSettingsDraft) -> TrailerSettingsDraft? {
        guard let previous = past.popLast() else { return nil }
        future.append(current)
        applying = true
        lastChange = .distantPast
        refresh()
        return previous
    }

    func redo(current: TrailerSettingsDraft) -> TrailerSettingsDraft? {
        guard let next = future.popLast() else { return nil }
        past.append(current)
        applying = true
        lastChange = .distantPast
        refresh()
        return next
    }

    private func refresh() { canUndo = !past.isEmpty; canRedo = !future.isEmpty }
}

// MARK: - 편집기 가장자리(헤더·상태) 값

struct TrailerEditorChrome {
    var title = "영상 편집"
    var showsAdd = false
    var onAdd: () -> Void = {}
    var showsDetailToggle = false
    var onDetail: () -> Void = {}
    var canUndo = false
    var canRedo = false
    var onUndo: () -> Void = {}
    var onRedo: () -> Void = {}
    var saveLabel = ""
    var saveFailed = false
    var onRetrySave: () -> Void = {}
    var onCancelWork: () -> Void = {}
    var onRetryRender: () -> Void = {}
    var projectID: UUID?
}

// MARK: - 장면 목록

private struct TrailerSceneThumb: View {
    let source: VideoTrailerSource
    let time: Double
    @State private var image: UIImage?

    var body: some View {
        Color(uiColor: .tertiarySystemFill)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: source.isImage ? "photo" : "film").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: "\(source.id)-\(Int(time * 2))") {
                if source.isImage {
                    image = await trailerThumbnailImage(at: source.url, maxPixelSize: 200)
                } else {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: 200, height: 200)
                    if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                        image = UIImage(cgImage: frame.image)
                    }
                }
            }
    }
}

/// 직접 편집 중인 장면을 순서대로 보여 주는 가로 목록. 눌러서 고르면 상세에 그 장면이 나온다.
struct TrailerSceneStrip: View {
    let scenes: [TrailerEditScene]
    let sources: [VideoTrailerSource]
    @Binding var selectedID: Int?

    var body: some View {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                        if let source = byID[scene.sourceID] {
                            Button { selectedID = scene.id } label: {
                                TrailerSceneThumb(source: source, time: scene.start)
                                    .frame(width: 72, height: 72)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    .overlay(alignment: .topLeading) {
                                        Text("\(index + 1)").font(.caption2.weight(.bold)).monospacedDigit()
                                            .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.65), in: Capsule()).padding(4)
                                    }
                                    .overlay(alignment: .bottomTrailing) {
                                        Text(String(format: "%.1f초", scene.length)).font(.caption2).monospacedDigit()
                                            .foregroundStyle(.white).padding(.horizontal, 4)
                                            .background(.black.opacity(0.65), in: Capsule()).padding(4)
                                    }
                                    .opacity(scene.excluded ? 0.35 : 1)
                                    .overlay {
                                        if scene.excluded {
                                            Text("제외").font(.caption.weight(.semibold)).foregroundStyle(.white)
                                                .padding(.horizontal, 6).background(.black.opacity(0.7), in: Capsule())
                                        }
                                    }
                                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(PorcelainMetrics.accent, lineWidth: selectedID == scene.id ? 3 : 0))
                            }
                            .buttonStyle(.plain)
                            .id(scene.id)
                            .accessibilityLabel("장면 \(index + 1), \(source.name), \(String(format: "%.1f", scene.length))초"
                                                + (scene.excluded ? ", 제외됨" : ""))
                            .accessibilityAddTraits(selectedID == scene.id ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: selectedID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

// MARK: - 선택 장면 상세

private enum TrailerInspectorTab: String, CaseIterable, Identifiable {
    case scene = "장면", sound = "소리", picture = "화면"
    var id: String { rawValue }
}

/// 선택한 장면 하나의 이름, 장면/소리/화면. 전역 음악·화면 비율은 편집기 설정에 따로 있다.
struct TrailerSceneInspector: View {
    let mode: VideoTrailerMode
    let sources: [VideoTrailerSource]
    @Binding var scenes: [TrailerEditScene]?
    @Binding var nextSceneID: Int
    @Binding var selectedID: Int?
    let clipLength: Double
    let beginEditing: () -> Void
    var chrome: TrailerEditorChrome
    /// 전체 화면 비율. nil이면 원본(현재 순서의 첫 영상 비율)이며, 내보내기와 같은 규칙으로 계산한다.
    var aspectRatio: OutputAspectRatio? = nil
    @State private var tab = TrailerInspectorTab.scene
    /// 영상을 화면에 채울 때 어느 방향으로 잘리는지. 그 방향의 위치만 고를 수 있다.
    @State private var videoRoom: (key: String, horizontal: Bool, vertical: Bool)?

    private var selectedIndex: Int? { TrailerSceneEditor.index(of: selectedID, in: scenes ?? []) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("선택한 장면").font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: chrome.onUndo) { Image(systemName: "arrow.uturn.backward") }
                    .disabled(!chrome.canUndo).accessibilityLabel("되돌리기")
                Button(action: chrome.onRedo) { Image(systemName: "arrow.uturn.forward") }
                    .disabled(!chrome.canRedo).accessibilityLabel("다시 실행")
            }
            if scenes == nil {
                Text("지금은 자동 추천 장면을 쓰고 있어요. 장면별로 자르거나 순서를 바꾸려면 직접 편집을 시작하세요. 시작해도 사진은 하나도 빠지지 않고, 담기지 못한 영상은 \"제외\"로 표시돼요.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("장면 직접 편집 시작", action: beginEditing).buttonStyle(.borderedProminent)
            } else if let index = selectedIndex, let scene = scenes?[index],
                      let source = sources.first(where: { $0.id == scene.sourceID }) {
                header(index: index, scene: scene, source: source)
                Picker("", selection: $tab) {
                    ForEach(TrailerInspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch tab {
                case .scene: sceneTab(scene: scene, source: source)
                case .sound: soundTab(scene: scene, source: source)
                case .picture: pictureTab(scene: scene, source: source)
                }
                arrangement(index: index, scene: scene)
            } else {
                Text("위 장면 목록에서 장면을 고르세요.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func header(index: Int, scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(source.name).font(.headline).lineLimit(1).truncationMode(.middle)
            Text("장면 \(index + 1) / \(scenes?.count ?? 0) · \(source.isImage ? "사진" : "영상")" + (scene.excluded ? " · 제외됨" : ""))
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func set(_ change: @escaping (inout TrailerEditScene) -> Void) {
        guard let id = selectedID else { return }
        TrailerSceneEditor.update(id, in: &scenes!, change)
    }

    @ViewBuilder
    private func sceneTab(scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        if source.isImage {
            VStack(alignment: .leading, spacing: 6) {
                Text("사진 표시 시간 \(String(format: "%.1f", scene.length))초").font(.subheadline).monospacedDigit()
                Slider(value: Binding(get: { scene.length }, set: { value in set { $0.length = value } }),
                       in: 0.5...30, step: 0.5)
                    .accessibilityLabel("사진 표시 시간")
            }
        } else {
            let duration = max(source.duration, 0.4)
            let end = min(duration, scene.start + scene.length)
            VStack(alignment: .leading, spacing: 6) {
                Text("시작 \(videoTrailerTime(scene.start)) · 끝 \(videoTrailerTime(end)) · 길이 \(String(format: "%.1f", scene.length))초")
                    .font(.subheadline).monospacedDigit()
                Text("시작").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { min(scene.start, duration - 0.2) }, set: { value in
                    set {
                        let currentEnd = min(duration, $0.start + $0.length)
                        $0.start = min(value, currentEnd - 0.2)
                        $0.length = max(0.2, currentEnd - $0.start)
                    }
                }), in: 0...(duration - 0.2)).accessibilityLabel("시작 지점")
                Text("끝").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { end }, set: { value in
                    set { $0.length = max(0.2, min(duration, value) - $0.start) }
                }), in: 0.2...duration).accessibilityLabel("끝 지점")
            }
        }
    }

    @ViewBuilder
    private func soundTab(scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        if source.isImage {
            Text("사진에는 원본 소리가 없어요.").font(.caption).foregroundStyle(.secondary)
        } else {
            Toggle("이 장면의 원본 소리 끄기", isOn: Binding(get: { scene.muted }, set: { value in set { $0.muted = value } }))
            VStack(alignment: .leading, spacing: 2) {
                Text("원본 소리 음량 \(Int((scene.volume * 100).rounded()))%").font(.subheadline).monospacedDigit()
                Slider(value: Binding(get: { scene.volume }, set: { value in set { $0.volume = value } }), in: 0...1)
                    .accessibilityLabel("원본 소리 음량")
            }
            .disabled(scene.muted)
            Text("끄기는 이 장면의 소리를 완전히 빼고, 음량은 소리를 남긴 채 크기만 조절해요. 배경음악 음량은 전체 설정의 \"음악\"에서 따로 정해요.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pictureTab(scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        if source.isImage {
            Toggle("사진 전체를 화면 안에 맞추기(여백 생김)", isOn: Binding(get: { scene.fitsFrame }, set: { value in set { $0.fitsFrame = value } }))
            if !scene.fitsFrame {
                VStack(alignment: .leading, spacing: 2) {
                    Text("좌우 위치 \(Int((scene.offsetX * 100).rounded()))").font(.subheadline).monospacedDigit()
                    Slider(value: Binding(get: { scene.offsetX }, set: { value in set { $0.offsetX = value } }), in: -1...1)
                        .accessibilityLabel("사진 좌우 위치")
                    Text("상하 위치 \(Int((scene.offsetY * 100).rounded()))").font(.subheadline).monospacedDigit()
                    Slider(value: Binding(get: { scene.offsetY }, set: { value in set { $0.offsetY = value } }), in: -1...1)
                        .accessibilityLabel("사진 상하 위치")
                    if scene.offsetX != 0 || scene.offsetY != 0 {
                        Button("가운데로") { set { $0.offsetX = 0; $0.offsetY = 0 } }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Text(scene.hasCustomFraming
                 ? "고른 구성 그대로 그려요. 자동 확대 효과는 쓰지 않아요."
                 : "기본은 화면을 채우며 천천히 확대돼요. 위치를 옮기거나 전체 맞춤을 고르면 그 상태로 고정돼요. 위치는 사진이 화면보다 클 때 넘치는 쪽으로만 움직여요.")
                .font(.caption).foregroundStyle(.secondary)
        } else {
            let key = videoRoomKey(for: source)
            VStack(alignment: .leading, spacing: 8) {
                Toggle("화면 안에 맞추기(여백 생김)", isOn: Binding(get: { scene.fitsFrame }, set: { value in set { $0.fitsFrame = value } }))
                if !scene.fitsFrame {
                    if let room = videoRoom, room.key == key {
                        if room.horizontal || room.vertical {
                            VStack(alignment: .leading, spacing: 2) {
                                if room.horizontal {
                                    Text("좌우 위치 \(Int((scene.offsetX * 100).rounded()))").font(.subheadline).monospacedDigit()
                                    Slider(value: Binding(get: { scene.offsetX }, set: { value in set { $0.offsetX = value } }), in: -1...1)
                                        .accessibilityLabel("영상 좌우 위치")
                                }
                                if room.vertical {
                                    Text("상하 위치 \(Int((scene.offsetY * 100).rounded()))").font(.subheadline).monospacedDigit()
                                    Slider(value: Binding(get: { scene.offsetY }, set: { value in set { $0.offsetY = value } }), in: -1...1)
                                        .accessibilityLabel("영상 상하 위치")
                                }
                                if scene.offsetX != 0 || scene.offsetY != 0 {
                                    Button("가운데로") { set { $0.offsetX = 0; $0.offsetY = 0 } }.buttonStyle(.bordered).controlSize(.small)
                                }
                            }
                        } else {
                            Text("이 영상은 화면 비율과 같아 잘리는 부분이 없어요. 옮길 위치가 없습니다.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("영상 크기를 확인하는 중…").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text("끄면 화면을 가득 채우고 넘치는 부분을 잘라요. 기본은 가운데이고, 위치는 잘리는 쪽으로만 움직여요. 전체 화면 비율은 전체 설정의 \"화면 모양\"에서 바꿔요.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .task(id: key) { await measureVideoRoom(for: source, key: key) }
        }
    }

    /// 내보내기의 원본 비율 기준과 같은 영상: 현재 순서에서 빠지지 않은 첫 영상.
    private var referenceVideo: VideoTrailerSource? {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return (scenes ?? []).lazy.filter { !$0.excluded }.compactMap { byID[$0.sourceID] }
            .first { !$0.isImage && $0.duration > 0 }
    }

    private func videoRoomKey(for source: VideoTrailerSource) -> String {
        "\(source.id)|\(source.url.path)|\(aspectRatio?.rawValue ?? "original:\(referenceVideo?.id ?? -1)")"
    }

    /// 영상과 전체 화면의 실제 크기로 채울 때 잘리는 방향을 잰다. 크기를 못 읽으면 두 방향 모두 열어 둔다
    /// (렌더러가 실제로 넘치는 범위로 다시 제한한다).
    private func measureVideoRoom(for source: VideoTrailerSource, key: String) async {
        guard let size = try? await trailerOrientedVideoSize(url: source.url) else {
            if !Task.isCancelled { videoRoom = (key, true, true) }
            return
        }
        let render: CGSize
        if let aspectRatio {
            render = aspectRatio.renderSize
        } else if let reference = referenceVideo, reference.id != source.id,
                  let referenceSize = try? await trailerOrientedVideoSize(url: reference.url) {
            render = OutputAspectRatio.renderSize(for: referenceSize)
        } else {
            render = OutputAspectRatio.renderSize(for: size)
        }
        guard !Task.isCancelled else { return }
        let overflow = TrailerOutputRenderer.fillOverflow(orientedSize: size, renderSize: render)
        // 짝수 픽셀 맞춤에서 생기는 몇 픽셀은 옮길 자리가 아니다.
        videoRoom = (key, overflow.width > 8, overflow.height > 8)
    }

    private func arrangement(index: Int, scene: TrailerEditScene) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { move(-1) } label: { Label("앞으로", systemImage: "arrow.left") }
                    .disabled(index == 0)
                Button { move(1) } label: { Label("뒤로", systemImage: "arrow.right") }
                    .disabled(index + 1 >= (scenes?.count ?? 0))
            }
            HStack(spacing: 6) {
                Button { duplicate() } label: { Label("복제", systemImage: "plus.square.on.square") }
                Button { set { $0.excluded.toggle() } } label: {
                    Label(scene.excluded ? "포함" : "제외", systemImage: scene.excluded ? "eye" : "eye.slash")
                }
                if TrailerSceneEditor.canDelete(scene.id, in: scenes ?? []) {
                    Button(role: .destructive) { remove() } label: { Label("삭제", systemImage: "trash") }
                }
            }
        }
        .buttonStyle(.bordered).controlSize(.small)
    }

    private func move(_ offset: Int) {
        guard let id = selectedID else { return }
        TrailerSceneEditor.move(id, by: offset, in: &scenes!)
    }

    private func duplicate() {
        guard let id = selectedID else { return }
        var next = nextSceneID
        if let newID = TrailerSceneEditor.duplicate(id, in: &scenes!, nextID: &next) { selectedID = newID }
        nextSceneID = next
    }

    private func remove() {
        guard let id = selectedID, let at = selectedIndex else { return }
        TrailerSceneEditor.delete(id, in: &scenes!)
        selectedID = scenes?[min(at, (scenes?.count ?? 1) - 1)].id
    }
}
