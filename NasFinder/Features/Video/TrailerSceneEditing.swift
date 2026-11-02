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

    /// 선택한 장면들을 상대 순서를 유지하며 1기준 목표 위치(1...N)로 이동한다. (예: 420번째를 3번째로)
    static func moveScenes(ids: Set<Int>, toOneBasedPosition targetPosition: Int, in scenes: inout [TrailerEditScene]) {
        guard !ids.isEmpty, !scenes.isEmpty else { return }
        let selectedScenes = scenes.filter { ids.contains($0.id) }
        guard !selectedScenes.isEmpty else { return }
        let remainingScenes = scenes.filter { !ids.contains($0.id) }
        let targetIndex = min(remainingScenes.count, max(0, targetPosition - 1))
        var result = remainingScenes
        result.insert(contentsOf: selectedScenes, at: targetIndex)
        scenes = result
    }

    /// 선택된 장면들을 복제한다.
    static func duplicateScenes(ids: Set<Int>, in scenes: inout [TrailerEditScene], nextID: inout Int) -> [Int] {
        guard !ids.isEmpty else { return [] }
        var newIDs: [Int] = []
        var index = 0
        while index < scenes.count {
            let scene = scenes[index]
            if ids.contains(scene.id) {
                var copy = scene
                copy.id = nextID
                copy.excluded = false
                nextID += 1
                newIDs.append(copy.id)
                scenes.insert(copy, at: index + 1)
                index += 2
            } else {
                index += 1
            }
        }
        return newIDs
    }

    /// 선택된 장면들을 삭제한다.
    static func deleteScenes(ids: Set<Int>, in scenes: inout [TrailerEditScene]) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if canDelete(id, in: scenes) {
                delete(id, in: &scenes)
            } else if let at = index(of: id, in: scenes) {
                scenes[at].excluded = true
            }
        }
    }

    static func update(_ id: Int, in scenes: inout [TrailerEditScene], _ change: (inout TrailerEditScene) -> Void) {
        guard let at = index(of: id, in: scenes) else { return }
        change(&scenes[at])
    }

    /// 새로 들어온 소스의 장면. 사진은 기본 길이, 영상은 공통 장면 길이만큼의 하이라이트.
    static func newScene(for source: VideoTrailerSource, id: Int, clipLength: Double) -> TrailerEditScene? {
        if source.isImage {
            return TrailerEditScene(id: id, sourceID: source.id, start: 0,
                length: source.weightedImageLength(clipLength: clipLength))
        }
        guard source.duration > 0 else { return nil }
        let length = VideoTrailerBatchPlan.sceneLength(source, clipLength: clipLength)
        let first = source.plan.proposal(total: length, clipLength: length).first
        return TrailerEditScene(id: id, sourceID: source.id, start: first?.start ?? 0, length: first?.length ?? length)
    }

    /// 장면의 물리적 표시 시간 범위(최소...최대).
    /// 비디오는 min(.2, duration), 시작점 유효 클램프 0...duration-min, max = duration-validStart.
    /// 사진은 1/30...30초. 유효하지 않거나 누락된 소스는 기존 유한 길이를 고정값으로 유지.
    static func sceneDurationBounds(scene: TrailerEditScene, source: VideoTrailerSource?) -> (minimum: Double, maximum: Double) {
        guard let source else {
            let fixed = scene.length.isFinite && scene.length > 0 ? scene.length : 0.2
            return (fixed, fixed)
        }
        if source.isImage {
            return (1.0 / 30.0, 30.0)
        }
        guard source.duration.isFinite, source.duration > 0 else {
            let fixed = scene.length.isFinite && scene.length > 0 ? scene.length : 0.2
            return (fixed, fixed)
        }
        let duration = source.duration
        let minLen = min(0.2, duration)
        let validStart = min(max(0.0, scene.start), max(0.0, duration - minLen))
        let maxLen = max(minLen, duration - validStart)
        return (minLen, maxLen)
    }

    /// 직접 편집 모드에서 포함된 장면들의 물리적 총길이 범위.
    static func manualTotalBounds(scenes: [TrailerEditScene], sources: [VideoTrailerSource]) -> (minimum: Double, maximum: Double) {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var totalMin = 0.0
        var totalMax = 0.0
        for scene in scenes where !scene.excluded {
            let bounds = sceneDurationBounds(scene: scene, source: byID[scene.sourceID])
            totalMin += bounds.minimum
            totalMax += bounds.maximum
        }
        return (totalMin, max(totalMin, totalMax))
    }

    /// 직접 편집 모드에서 총길이 변경 시 기존 장면 길이를 비율에 맞춰 비례 재분배한다.
    /// 제외된 장면은 보존하며, 포함된 장면의 경계(사진 1/30...30초, 영상 소스 잔여 길이)에서
    /// 60단계 이분법 스케일링 후 잔여 분배로 목표 오차까지 정확히 맞춘다.
    static func redistributeManualTotal(
        scenes: inout [TrailerEditScene],
        sources: [VideoTrailerSource],
        targetTotal: Double
    ) {
        guard targetTotal.isFinite, targetTotal > 0 else { return }
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let includedIndices = scenes.indices.filter { !scenes[$0].excluded }
        guard !includedIndices.isEmpty else { return }

        var minBounds: [Int: Double] = [:]
        var maxBounds: [Int: Double] = [:]
        var totalMin = 0.0
        var totalMax = 0.0

        for index in includedIndices {
            let bounds = sceneDurationBounds(scene: scenes[index], source: byID[scenes[index].sourceID])
            minBounds[index] = bounds.minimum
            maxBounds[index] = bounds.maximum
            totalMin += bounds.minimum
            totalMax += bounds.maximum
        }

        let clampedTarget = min(totalMax, max(totalMin, targetTotal))

        var lengths: [Int: Double] = [:]
        for index in includedIndices {
            let minB = minBounds[index]!
            let maxB = maxBounds[index]!
            lengths[index] = min(maxB, max(minB, scenes[index].length))
        }

        func sumForScale(_ s: Double) -> Double {
            var sum = 0.0
            for index in includedIndices {
                let orig = lengths[index]!
                let minB = minBounds[index]!
                let maxB = maxBounds[index]!
                sum += min(maxB, max(minB, orig * s))
            }
            return sum
        }

        var sLow = 0.0
        var sHigh = 1.0
        let currentSum = sumForScale(1.0)
        if currentSum >= clampedTarget {
            sHigh = 1.0
        } else {
            sHigh = 2.0
            while sumForScale(sHigh) < clampedTarget && sHigh < 1_000_000.0 {
                sHigh *= 2.0
            }
        }

        for _ in 0..<60 {
            let mid = (sLow + sHigh) / 2.0
            if sumForScale(mid) < clampedTarget {
                sLow = mid
            } else {
                sHigh = mid
            }
        }

        let bestScale = (sLow + sHigh) / 2.0
        for index in includedIndices {
            let orig = lengths[index]!
            let minB = minBounds[index]!
            let maxB = maxBounds[index]!
            lengths[index] = min(maxB, max(minB, orig * bestScale))
        }

        let targetTolerance = 0.0001
        for _ in 0..<20 {
            let currentTotal = includedIndices.reduce(0.0) { $0 + (lengths[$1] ?? 0.0) }
            let residual = clampedTarget - currentTotal
            if abs(residual) <= targetTolerance { break }

            if residual > 0 {
                let expandable = includedIndices.filter { (lengths[$0] ?? 0.0) < (maxBounds[$0] ?? 0.0) - 0.000001 }
                guard !expandable.isEmpty else { break }
                let share = residual / Double(expandable.count)
                for index in expandable {
                    let cur = lengths[index]!
                    let maxB = maxBounds[index]!
                    lengths[index] = min(maxB, cur + share)
                }
            } else {
                let reducible = includedIndices.filter { (lengths[$0] ?? 0.0) > (minBounds[$0] ?? 0.0) + 0.000001 }
                guard !reducible.isEmpty else { break }
                let share = (-residual) / Double(reducible.count)
                for index in reducible {
                    let cur = lengths[index]!
                    let minB = minBounds[index]!
                    lengths[index] = max(minB, cur - share)
                }
            }
        }

        for index in includedIndices {
            if let len = lengths[index] {
                scenes[index].length = len
                let scene = scenes[index]
                if let source = byID[scene.sourceID], !source.isImage, source.duration > 0 {
                    let minLen = minBounds[index] ?? min(0.2, source.duration)
                    let validStart = min(max(0, scene.start), max(0, source.duration - minLen))
                    scenes[index].start = validStart
                }
            }
        }
    }

    /// 공통 영상 클립 길이 변경을 직접 편집 장면에 명시적으로 적용한다.
    /// 영상은 잔여 길이 내 기준 길이, 사진은 저장된 가중치 비율(1/30...30초)로 재계산된다.
    static func applyExplicitClipLength(
        clipLength: Double,
        scenes: inout [TrailerEditScene],
        sources: inout [VideoTrailerSource]
    ) {
        guard clipLength.isFinite, clipLength > 0 else { return }

        // V1 사진 비율이 있으면 1회 안전하게 마이그레이션
        for i in sources.indices where sources[i].isImage && sources[i].imageDurationPolicyVersion < 2 {
            sources[i].imageDurationRatio = VideoTrailerPhotoQuality.migrateV1ToV2Ratio(sources[i].imageDurationRatio)
            sources[i].imageDurationPolicyVersion = 2
        }

        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in scenes.indices where !scenes[index].excluded {
            let source = byID[scenes[index].sourceID]
            let bounds = sceneDurationBounds(scene: scenes[index], source: source)
            if let source, source.isImage {
                let targetLen = source.weightedImageLength(clipLength: clipLength)
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, targetLen))
            } else if let source, source.duration > 0 {
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, clipLength))
                let minLen = bounds.minimum
                let validStart = min(max(0, scenes[index].start), max(0, source.duration - minLen))
                scenes[index].start = validStart
            }
        }
    }

    /// 스테이징된 소스(최신 URL, 미디어 분석)와 드래프트 소스(순서, 사진 비율 및 정책 버전)를 조화시킨다.
    /// 사용자가 제외한 소스는 되살리지 않고, 드래프트의 순서와 사진 타이밍 스냅샷을 보존한다.
    static func reconcileSources(
        draftSources: [VideoTrailerSource],
        stagedSources: [VideoTrailerSource],
        timingBaseline: [VideoTrailerSource]? = nil
    ) -> [VideoTrailerSource] {
        let byID = Dictionary(stagedSources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let baselineByID = timingBaseline.map { Dictionary($0.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }) }
        var result: [VideoTrailerSource] = []
        for draftSource in draftSources {
            guard var staged = byID[draftSource.id] else { continue }
            staged.isImportant = draftSource.isImportant
            if staged.isImage || draftSource.isImage {
                let shouldPreserveDraft: Bool
                if let baselineByID {
                    if let base = baselineByID[draftSource.id] {
                        shouldPreserveDraft = draftSource.imageDurationRatio != base.imageDurationRatio
                            || draftSource.imageDurationPolicyVersion != base.imageDurationPolicyVersion
                    } else {
                        shouldPreserveDraft = true
                    }
                } else {
                    shouldPreserveDraft = true
                }
                if shouldPreserveDraft {
                    staged.imageDurationRatio = draftSource.imageDurationRatio
                    staged.imageDurationPolicyVersion = draftSource.imageDurationPolicyVersion
                }
            }
            result.append(staged)
        }
        return result
    }

    /// UI 다음 마일스톤을 위한 최소 데이터 연산:
    /// 선택된 장면들이 참조하는 사진 소스의 중요도(isImportant)를 일괄 변경하고,
    /// 해당 사진 장면들의 길이를 weightedImageLength(clipLength:)로 갱신한다.
    /// 비디오/자막/프레이밍은 그대로 보존된다.
    static func setPhotosImportant(
        ids: Set<Int>,
        important: Bool,
        scenes: inout [TrailerEditScene],
        sources: inout [VideoTrailerSource],
        clipLength: Double
    ) {
        guard !ids.isEmpty else { return }

        // ids는 장면 ID다. 장면 ID와 소스 ID가 겹칠 수 있어 소스 ID로는 해석하지 않는다.
        let targetSourceIDs = Set(scenes.filter { ids.contains($0.id) }.map(\.sourceID))

        var changedPhotoSourceIDs: Set<Int> = []
        for index in sources.indices {
            if sources[index].isImage && targetSourceIDs.contains(sources[index].id) {
                sources[index].isImportant = important
                changedPhotoSourceIDs.insert(sources[index].id)
            }
        }

        guard !changedPhotoSourceIDs.isEmpty else { return }

        let photoSourcesByID = Dictionary(sources.filter { changedPhotoSourceIDs.contains($0.id) }.map { ($0.id, $0) },
                                          uniquingKeysWith: { first, _ in first })

        for index in scenes.indices {
            if let photoSource = photoSourcesByID[scenes[index].sourceID] {
                let bounds = sceneDurationBounds(scene: scenes[index], source: photoSource)
                let newLength = photoSource.weightedImageLength(clipLength: clipLength)
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, newLength))
            }
        }
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
            music: music, scenes: scenes, photoRatios: sources.map(\.imageDurationRatio),
            policyVersions: sources.map(\.imageDurationPolicyVersion),
            importances: sources.map(\.isImportant),
            batchCaption: batchCaption)
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
    var policyVersions: [Int] = []
    var importances: [Bool] = []
    var batchCaption: TrailerCaption? = nil
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
    /// 편집본 저장 버튼 하나의 상태: 저장 / 저장 중… / 저장됨 / 저장 실패.
    var isSavingDraft = false
    var isDraftSaved = false
    /// 렌더와 무관하게 지금 편집본을 디스크에 저장한다(끝날 때까지 기다리는 내구성 저장).
    var onSaveDraft: () -> Void = {}
    /// 적용 대기 자막 적용 후 내구성 저장 성공 시 렌더링을 시작한다.
    var onSaveAndExport: () -> Void = {}
    var onCancelWork: () -> Void = {}
    var onRetryRender: () -> Void = {}
    var projectID: UUID?
    /// 적용하지 않은 자막이 있으면 적용/입력 취소를 먼저 묻고, 고른 뒤에 동작을 이어 간다.
    var guarded: (@escaping () -> Void) -> Void = { $0() }
}

// MARK: - 자막 입력 초안

/// 자막 탭의 입력 중인 값. 편집기(부모)가 갖고 있어 회전·영역 전환·장면 전환에도 사라지지 않고,
/// 적용/입력 취소를 고르기 전에는 장면에 들어가지도 버려지지도 않는다.
@MainActor
final class TrailerCaptionDraft: ObservableObject {
    @Published var text = ""
    @Published var position: TrailerCaption.Position = .top
    @Published var fontDesign: TrailerCaption.FontDesign = .standard
    @Published var fontSize: Double = 22
    @Published var colorHex = "#FFFFFF"
    @Published var hasShadow = true
    @Published var column: Int = 0
    @Published var row: Int = 0
    @Published var fontName: String = "pretendard_bold"
    @Published var captionSize: CaptionSize = .normal
    @Published var shadowColorHex: String = "#000000"
    @Published var shadowOpacity: Double = 0.7
    @Published var lineSpacing: Double = 1.0
    @Published var isDirty = false
    /// 이 초안을 불러온 장면.
    @Published private(set) var sceneID: Int?

    func load(_ scene: TrailerEditScene) {
        if let caption = scene.caption {
            text = caption.text
            position = caption.position
            fontDesign = caption.fontDesign
            fontSize = caption.fontSize
            colorHex = caption.colorHex
            hasShadow = caption.hasShadow
            column = caption.column
            row = caption.row
            fontName = caption.fontName
            captionSize = caption.captionSize
            shadowColorHex = caption.shadowColorHex
            shadowOpacity = caption.shadowOpacity
            lineSpacing = caption.lineSpacing
        } else {
            text = ""
            position = .top
            fontDesign = .standard
            fontSize = 22
            colorHex = "#FFFFFF"
            hasShadow = true
            column = 0
            row = 0
            fontName = "pretendard_bold"
            captionSize = .normal
            shadowColorHex = "#000000"
            shadowOpacity = 0.7
            lineSpacing = 1.0
        }
        isDirty = false
        sceneID = scene.id
    }

    /// 빈 문구는 자막 없음이다. 미리보기·내보내기 규칙과 같다.
    var caption: TrailerCaption? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let pos: TrailerCaption.Position
        if row <= 1 { pos = .top }
        else if row == 2 { pos = .center }
        else { pos = .bottom }
        return TrailerCaption(
            text: trimmed,
            position: pos,
            fontDesign: fontDesign,
            fontSize: fontSize,
            colorHex: colorHex,
            hasShadow: hasShadow,
            column: column,
            row: row,
            fontName: fontName,
            captionSize: captionSize,
            shadowColorHex: shadowColorHex,
            shadowOpacity: shadowOpacity,
            lineSpacing: lineSpacing
        )
    }

    /// 불러온 장면에 지금 값을 넣는다.
    func apply(to scenes: inout [TrailerEditScene]?) {
        var batch: TrailerCaption? = nil
        apply(to: &scenes, scope: .current, selectedIDs: [], batchCaption: &batch)
    }

    /// 범위(현재 클립/선택 클립/전체 영상)에 맞춰 자막을 원자적으로 적용한다.
    func apply(
        to scenes: inout [TrailerEditScene]?,
        scope: CaptionApplyScope,
        selectedIDs: Set<Int>,
        batchCaption: inout TrailerCaption?
    ) {
        guard scenes != nil else { isDirty = false; return }
        let value = caption
        switch scope {
        case .current:
            if let id = sceneID, scenes?.contains(where: { $0.id == id }) == true {
                TrailerSceneEditor.update(id, in: &scenes!) { $0.caption = value }
            }
        case .selected:
            let targets = selectedIDs.isEmpty ? (sceneID.map { Set([$0]) } ?? []) : selectedIDs
            for id in targets {
                if scenes?.contains(where: { $0.id == id }) == true {
                    TrailerSceneEditor.update(id, in: &scenes!) { $0.caption = value }
                }
            }
        case .all:
            for index in scenes!.indices {
                scenes![index].caption = value
            }
            batchCaption = value
        }
        isDirty = false
    }

    /// 입력을 버리고 장면에 들어 있는 자막으로 되돌린다.
    func discard(scenes: [TrailerEditScene]?) {
        if let id = sceneID, let scene = scenes?.first(where: { $0.id == id }) {
            load(scene)
        } else {
            isDirty = false
        }
    }
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
                    Image(interfaceSystemName: source.isImage ? "photo" : "film").foregroundStyle(.secondary)
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

/// 반응형 스토리보드 격자 (태블릿/Mac 4열, 폰 3열 기본, 2...6열 조절).
/// 다중 선택, 임의 1기준 위치 이동(420 -> 3), 복제, 삭제 기능 내장.
struct TrailerStoryboardGrid: View {
    let scenes: [TrailerEditScene]
    let sources: [VideoTrailerSource]
    @Binding var selectedID: Int?
    @Binding var selectedIDs: Set<Int>
    @Binding var columnsCount: Int
    var scrollable: Bool = true
    var onSelectSceneForDetail: ((Int) -> Void)? = nil
    var onMoveScenes: ((Set<Int>, Int) -> Void)? = nil
    var onDuplicateScenes: ((Set<Int>) -> Void)? = nil
    var onDeleteScenes: ((Set<Int>) -> Void)? = nil

    @State private var showingMoveSheet = false
    @State private var targetPositionString = "1"
    @State private var localMultiSelectMode = false
    /// 부모가 툴바를 소유할 때(showToolbar == false) 다중 선택 상태를 공유한다.
    var externalMultiSelect: Binding<Bool>? = nil
    var showToolbar: Bool = true

    private var isMultiSelectMode: Bool {
        get { externalMultiSelect?.wrappedValue ?? localMultiSelectMode }
        nonmutating set {
            if let externalMultiSelect { externalMultiSelect.wrappedValue = newValue } else { localMultiSelectMode = newValue }
        }
    }

    init(
        scenes: [TrailerEditScene],
        sources: [VideoTrailerSource],
        selectedID: Binding<Int?>,
        selectedIDs: Binding<Set<Int>>,
        columnsCount: Binding<Int>,
        scrollable: Bool = true,
        showToolbar: Bool = true,
        multiSelect: Binding<Bool>? = nil,
        onSelectSceneForDetail: ((Int) -> Void)? = nil,
        onMoveScenes: ((Set<Int>, Int) -> Void)? = nil,
        onDuplicateScenes: ((Set<Int>) -> Void)? = nil,
        onDeleteScenes: ((Set<Int>) -> Void)? = nil
    ) {
        self.showToolbar = showToolbar
        self.externalMultiSelect = multiSelect
        self.scenes = scenes
        self.sources = sources
        self._selectedID = selectedID
        self._selectedIDs = selectedIDs
        self._columnsCount = columnsCount
        self.scrollable = scrollable
        self.onSelectSceneForDetail = onSelectSceneForDetail
        self.onMoveScenes = onMoveScenes
        self.onDuplicateScenes = onDuplicateScenes
        self.onDeleteScenes = onDeleteScenes
    }

    init(
        scenes: [TrailerEditScene],
        sources: [VideoTrailerSource],
        selectedID: Binding<Int?>,
        selectedIDs: Binding<Set<Int>>,
        columnsCount: Int = 4,
        scrollable: Bool = true,
        onSelectSceneForDetail: ((Int) -> Void)? = nil,
        onMoveScenes: ((Set<Int>, Int) -> Void)? = nil,
        onDuplicateScenes: ((Set<Int>) -> Void)? = nil,
        onDeleteScenes: ((Set<Int>) -> Void)? = nil
    ) {
        self.init(
            scenes: scenes,
            sources: sources,
            selectedID: selectedID,
            selectedIDs: selectedIDs,
            columnsCount: .constant(columnsCount),
            scrollable: scrollable,
            onSelectSceneForDetail: onSelectSceneForDetail,
            onMoveScenes: onMoveScenes,
            onDuplicateScenes: onDuplicateScenes,
            onDeleteScenes: onDeleteScenes
        )
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: min(6, max(2, columnsCount)))
    }

    var body: some View {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        VStack(alignment: .leading, spacing: 8) {
            if showToolbar { toolbarSection }
            if scrollable {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        gridContent(byID: byID)
                            .padding(.vertical, 4)
                    }
                    .onChange(of: selectedID) { _, id in
                        if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                    }
                }
            } else {
                gridContent(byID: byID)
                    .padding(.vertical, 4)
            }
        }
        .sheet(isPresented: $showingMoveSheet) {
            movePositionSheet
        }
    }

    private func gridContent(byID: [Int: VideoTrailerSource]) -> some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                if let source = byID[scene.sourceID] {
                    let isSelected = selectedIDs.contains(scene.id) || selectedID == scene.id
                    Button {
                        handleSceneTap(scene: scene, index: index)
                    } label: {
                        gridCell(index: index, scene: scene, source: source, isSelected: isSelected)
                    }
                    .buttonStyle(.plain)
                    .id(scene.id)
                    .accessibilityLabel("장면 \(index + 1), \(source.name), \(String(format: "%.1f", scene.length))초"
                        + (scene.excluded ? ", 제외됨" : "")
                        + (scene.caption != nil && !scene.caption!.text.isEmpty ? ", 자막 있음" : ""))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
        }
    }

    private var toolbarSection: some View {
        HStack(spacing: 8) {
            if isMultiSelectMode || !selectedIDs.isEmpty {
                Text("\(selectedIDs.count)개 선택됨")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button {
                    selectedIDs = Set(scenes.map(\.id))
                } label: { Text("전체").frame(minHeight: 44) }
                .buttonStyle(.bordered).controlSize(.small)
                Button {
                    selectedIDs.removeAll()
                    isMultiSelectMode = false
                } label: { Text("해제").frame(minHeight: 44) }
                .buttonStyle(.bordered).controlSize(.small)
                if !selectedIDs.isEmpty {
                    Button {
                        if let idx = scenes.firstIndex(where: { selectedIDs.contains($0.id) }) {
                            targetPositionString = "\(idx + 1)"
                        } else {
                            targetPositionString = "1"
                        }
                        showingMoveSheet = true
                    } label: {
                        Label("위치 이동", interfaceSystemImage: "arrow.up.and.down.and.arrow.left.and.right")
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.small)
                    Button {
                        onDuplicateScenes?(selectedIDs)
                    } label: {
                        Label("복제", interfaceSystemImage: "plus.square.on.square").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                    Button(role: .destructive) {
                        onDeleteScenes?(selectedIDs)
                    } label: {
                        Label("삭제", interfaceSystemImage: "trash").frame(minHeight: 44)
                    }
                    .buttonStyle(.bordered).controlSize(.small)
                }
            } else {
                Text("장면 (\(scenes.count))")
                    .font(.subheadline.weight(.semibold))
                Spacer()

                // 격자 열 조절 2...6
                Menu {
                    ForEach(2...6, id: \.self) { c in
                        Button("\(c)열") { columnsCount = c }
                    }
                } label: {
                    HStack(spacing: 2) {
                        Image(interfaceSystemName: "square.grid.2x2", pointSize: 14, tintable: true)
                        Text("\(columnsCount)열")
                    }
                    .font(.caption.weight(.medium))
                    .frame(minHeight: 36)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button {
                    isMultiSelectMode = true
                    if let current = selectedID { selectedIDs.insert(current) }
                } label: {
                    Label("다중 선택", interfaceSystemImage: "checkmark.circle").frame(minHeight: 44)
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
        }
        .padding(.horizontal, 4)
    }

    private func handleSceneTap(scene: TrailerEditScene, index: Int) {
        if isMultiSelectMode {
            if selectedIDs.contains(scene.id) {
                selectedIDs.remove(scene.id)
            } else {
                selectedIDs.insert(scene.id)
            }
            selectedID = scene.id
        } else {
            selectedID = scene.id
            selectedIDs = [scene.id]
            onSelectSceneForDetail?(scene.id)
        }
    }

    private func gridCell(index: Int, scene: TrailerEditScene, source: VideoTrailerSource, isSelected: Bool) -> some View {
        ZStack {
            TrailerSceneThumb(source: source, time: scene.start)
                .aspectRatio(1.25, contentMode: .fill)
                .clipped()
                .opacity(scene.excluded ? 0.35 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(alignment: .topLeading) {
            Text("\(index + 1)")
                .font(.caption2.weight(.bold)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(6)
        }
        .overlay(alignment: .topTrailing) {
            if isMultiSelectMode {
                Image(interfaceSystemName: selectedIDs.contains(scene.id) ? "checkmark.circle.fill" : "circle")
                    .font(.body.weight(.bold))
                    .foregroundStyle(selectedIDs.contains(scene.id) ? PorcelainMetrics.accent : .white)
                    .background(Circle().fill(.black.opacity(0.45)))
                    .padding(6)
            }
        }
        .overlay(alignment: .trailing) {
            if source.isImage && source.isImportant {
                Image(interfaceSystemName: "star.fill", pointSize: 12, tintable: true)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.yellow)
                    .padding(4)
                    .background(.black.opacity(0.65), in: Circle())
                    .padding(6)
                    .accessibilityLabel("중요 사진")
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let caption = scene.caption, !caption.text.isEmpty {
                HStack(spacing: 3) {
                    Image(interfaceSystemName: "captions.bubble.fill")
                    Text(caption.text).lineLimit(1)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.7), in: Capsule())
                .padding(6)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text(String(format: "%.1f초", scene.length))
                .font(.caption2.weight(.medium)).monospacedDigit()
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.65), in: Capsule())
                .padding(6)
        }
        .overlay {
            if scene.excluded {
                Text("제외")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.black.opacity(0.75), in: Capsule())
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(isSelected ? PorcelainMetrics.accent : Color.clear, lineWidth: isSelected ? 3 : 0)
        )
    }

    private var movePositionSheet: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("선택한 \(selectedIDs.count)개 장면을 이동할 1기준 위치 번호를 입력하세요.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Text("목표 위치:")
                        .font(.headline)
                    TextField("1 ~ \(scenes.count)", text: $targetPositionString)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                    Text("번째 (1 ~ \(scenes.count))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            .navigationTitle("장면 위치 이동")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { showingMoveSheet = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("이동") {
                        if let target = Int(targetPositionString.trimmingCharacters(in: .whitespacesAndNewlines)), target >= 1 {
                            onMoveScenes?(selectedIDs, target)
                        }
                        showingMoveSheet = false
                    }
                    .fontWeight(.bold)
                }
            }
        }
        .presentationDetents([.fraction(0.35), .medium])
    }
}

// MARK: - 선택 클립 인스펙터 (클립 탭 전용)

/// 비디오 시작점과 길이를 한 번에 조절할 수 있는 듀얼 썸 레인지 슬라이더
private struct VideoRangeSlider: View {
    @Binding var start: Double
    @Binding var length: Double
    let duration: Double
    var onDragStart: () -> Void = {}

    private let minLength: Double = 0.2
    private let thumbWidth: CGFloat = 20
    private let trackHeight: CGFloat = 24

    private var safeDuration: Double {
        max(duration, minLength)
    }

    private var end: Double {
        min(safeDuration, start + length)
    }

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let availW = max(totalW - thumbWidth * 2, 1)
            let startFrac = safeDuration > 0 ? max(0, min(start / safeDuration, 1)) : 0
            let endFrac = safeDuration > 0 ? max(startFrac, min(end / safeDuration, 1)) : 1

            let startX = startFrac * availW
            let endX = thumbWidth + endFrac * availW

            ZStack(alignment: .leading) {
                // 전체 트랙 (배경)
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: trackHeight)

                // 선택 영역 (틴트)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(0.35))
                    .frame(width: max(endX - startX, thumbWidth), height: trackHeight)
                    .offset(x: startX)

                // 시작 핸들 (좌측)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .frame(width: thumbWidth, height: trackHeight)
                    .overlay(
                        Image(systemName: "chevron.compact.left")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    )
                    .offset(x: startX)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                onDragStart()
                                let curEnd = min(safeDuration, start + length)
                                let newX = max(0, min(g.location.x, availW))
                                let newStart = (newX / availW) * safeDuration
                                let clampedStart = min(newStart, curEnd - minLength)
                                start = max(0, clampedStart)
                                length = max(minLength, curEnd - start)
                            }
                    )
                    .accessibilityLabel("재생 시작 지점")
                    .accessibilityValue(videoTrailerTime(start))
                    .accessibilityAdjustableAction { direction in
                        onDragStart()
                        let curEnd = min(safeDuration, start + length)
                        let step = 0.5
                        switch direction {
                        case .increment:
                            start = min(start + step, curEnd - minLength)
                        case .decrement:
                            start = max(0, start - step)
                        @unknown default:
                            break
                        }
                        length = max(minLength, curEnd - start)
                    }

                // 끝 핸들 (우측)
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: .black.opacity(0.2), radius: 2, x: 0, y: 1)
                    .frame(width: thumbWidth, height: trackHeight)
                    .overlay(
                        Image(systemName: "chevron.compact.right")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.secondary)
                    )
                    .offset(x: endX - thumbWidth)
                    .gesture(
                        DragGesture()
                            .onChanged { g in
                                onDragStart()
                                let newX = max(thumbWidth, min(g.location.x, totalW)) - thumbWidth
                                let newEnd = (newX / availW) * safeDuration
                                let clampedEnd = max(start + minLength, min(safeDuration, newEnd))
                                length = max(minLength, clampedEnd - start)
                            }
                    )
                    .accessibilityLabel("재생 끝 지점")
                    .accessibilityValue(videoTrailerTime(end))
                    .accessibilityAdjustableAction { direction in
                        onDragStart()
                        let step = 0.5
                        switch direction {
                        case .increment:
                            let targetEnd = min(safeDuration, end + step)
                            length = max(minLength, targetEnd - start)
                        case .decrement:
                            let targetEnd = max(start + minLength, end - step)
                            length = max(minLength, targetEnd - start)
                        @unknown default:
                            break
                        }
                    }
            }
        }
        .frame(height: trackHeight)
    }
}

/// '클립' 탭에서 선택한 클립 하나의 시작/끝/길이, 소리, 화면 맞춤 조절.
struct TrailerClipInspectorView: View {
    enum Section {
        case timing
        case audio
        case framing
    }

    let sources: [VideoTrailerSource]
    @Binding var scenes: [TrailerEditScene]?
    @Binding var selectedID: Int?
    var aspectRatio: OutputAspectRatio? = nil
    var section: Section = .timing

    /// 부모가 넘기면 다중 선택으로 인스펙터가 사라져도 기준값이 유지된다.
    var externalBaselines: Binding<[Int: TimingBaseline]>? = nil
    typealias TimingBaseline = (start: Double, length: Double)
    @State private var localBaselines: [Int: TimingBaseline] = [:]

    private var timingBaselines: [Int: TimingBaseline] {
        get { externalBaselines?.wrappedValue ?? localBaselines }
        nonmutating set {
            if let externalBaselines { externalBaselines.wrappedValue = newValue } else { localBaselines = newValue }
        }
    }

    private var selectedIndex: Int? { TrailerSceneEditor.index(of: selectedID, in: scenes ?? []) }

    init(
        sources: [VideoTrailerSource],
        scenes: Binding<[TrailerEditScene]?>,
        selectedID: Binding<Int?>,
        aspectRatio: OutputAspectRatio? = nil,
        section: Section = .timing,
        baselines: Binding<[Int: TimingBaseline]>? = nil
    ) {
        self.sources = sources
        self._scenes = scenes
        self._selectedID = selectedID
        self.aspectRatio = aspectRatio
        self.section = section
        self.externalBaselines = baselines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let index = selectedIndex, let scene = scenes?[index],
               let source = sources.first(where: { $0.id == scene.sourceID }) {
                switch section {
                case .timing:
                    // 간결한 헤더 (장면 순서 및 포함/제외 토글)
                    HStack {
                        Text("장면 \(index + 1) / \(scenes?.count ?? 0) · \(source.isImage ? "사진" : "영상")" + (scene.excluded ? " · 제외됨" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            set { $0.excluded.toggle() }
                        } label: {
                            Label(scene.excluded ? "포함" : "제외", systemImage: scene.excluded ? "eye" : "eye.slash")
                                .font(.system(size: 13, weight: .medium))
                                .frame(minHeight: 36)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    // 트리밍 / 길이 조절
                    if source.isImage {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("표시 시간 \(String(format: "%.1f", scene.length))초")
                                .font(.subheadline).monospacedDigit()

                            let hasBaseline = timingBaselines[scene.id] != nil
                            let isChanged = hasBaseline && abs((timingBaselines[scene.id]?.length ?? scene.length) - scene.length) > 0.001

                            HStack(spacing: 8) {
                                Button {
                                    if let base = timingBaselines[scene.id] {
                                        set { $0.length = base.length }
                                    }
                                } label: {
                                    Image(systemName: "arrow.counterclockwise.circle")
                                        .font(.system(size: 20))
                                }
                                .disabled(!isChanged)
                                .accessibilityLabel("원래 시간으로 재설정")

                                Slider(
                                    value: Binding(get: { scene.length }, set: { val in set { $0.length = val } }),
                                    in: (1.0 / 30.0)...30,
                                    onEditingChanged: { editing in
                                        if editing {
                                            captureBaselineIfNeeded(for: scene)
                                        }
                                    }
                                )
                                .accessibilityLabel("사진 표시 시간")
                            }
                        }
                    } else {
                        let duration = (source.duration.isFinite && source.duration > 0) ? source.duration : 0.4
                        let safeDuration = max(duration, 0.2)
                        let end = min(safeDuration, scene.start + scene.length)

                        let hasBaseline = timingBaselines[scene.id] != nil
                        let isChanged: Bool = {
                            guard let base = timingBaselines[scene.id] else { return false }
                            return abs(base.start - scene.start) > 0.001 || abs(base.length - scene.length) > 0.001
                        }()

                        VStack(alignment: .leading, spacing: 6) {
                            Text("구간 \(videoTrailerTime(scene.start)) ~ \(videoTrailerTime(end)) (\(String(format: "%.1f", scene.length))초) / 전체 \(videoTrailerTime(safeDuration))")
                                .font(.subheadline).monospacedDigit()

                            HStack(spacing: 8) {
                                Button {
                                    if let base = timingBaselines[scene.id] {
                                        set {
                                            $0.start = base.start
                                            $0.length = base.length
                                        }
                                    }
                                } label: {
                                    Image(systemName: "arrow.counterclockwise.circle")
                                        .font(.system(size: 20))
                                }
                                .disabled(!isChanged)
                                .accessibilityLabel("원래 타이밍으로 재설정")

                                VideoRangeSlider(
                                    start: Binding(
                                        get: { scene.start },
                                        set: { val in set { $0.start = val } }
                                    ),
                                    length: Binding(
                                        get: { scene.length },
                                        set: { val in set { $0.length = val } }
                                    ),
                                    duration: safeDuration,
                                    onDragStart: {
                                        captureBaselineIfNeeded(for: scene)
                                    }
                                )
                            }
                        }
                    }

                case .audio:
                    // 소리 조절 (비디오만: 사진인 경우 뷰를 렌더하지 않음)
                    if !source.isImage {
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("이 장면의 원본 소리 끄기", isOn: Binding(get: { scene.muted }, set: { val in set { $0.muted = val } }))
                                .font(.system(size: 14))

                            if !scene.muted {
                                HStack {
                                    Text("원본 소리 음량 \(Int((scene.volume * 100).rounded()))%")
                                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                    Spacer()
                                }
                                Slider(value: Binding(get: { scene.volume }, set: { val in set { $0.volume = val } }), in: 0...1)
                                    .accessibilityLabel("원본 소리 음량")
                            }
                        }
                    }

                case .framing:
                    // 화면 맞춤 및 위치
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("화면 안에 맞추기(여백 생김)", isOn: Binding(get: { scene.fitsFrame }, set: { val in set { $0.fitsFrame = val } }))
                            .font(.system(size: 14))

                        if !scene.fitsFrame {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("좌우 위치 \(Int((scene.offsetX * 100).rounded()))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Slider(value: Binding(get: { scene.offsetX }, set: { val in set { $0.offsetX = val } }), in: -1...1)

                                Text("상하 위치 \(Int((scene.offsetY * 100).rounded()))")
                                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                Slider(value: Binding(get: { scene.offsetY }, set: { val in set { $0.offsetY = val } }), in: -1...1)

                                if scene.offsetX != 0 || scene.offsetY != 0 {
                                    Button("가운데로") {
                                        set { $0.offsetX = 0; $0.offsetY = 0 }
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
            } else {
                Text("장면 목록에서 클립을 선택하면 상세 조절이 나타납니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(PorcelainMetrics.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(PorcelainMetrics.line, lineWidth: 0.5))
    }

    private func captureBaselineIfNeeded(for scene: TrailerEditScene) {
        if timingBaselines[scene.id] == nil {
            timingBaselines[scene.id] = (start: scene.start, length: scene.length)
        }
    }

    private func set(_ change: @escaping (inout TrailerEditScene) -> Void) {
        guard let id = selectedID else { return }
        TrailerSceneEditor.update(id, in: &scenes!, change)
    }
}

// MARK: - 선택 장면 상세

private enum TrailerInspectorTab: String, CaseIterable, Identifiable {
    case scene = "장면", caption = "자막", sound = "소리", picture = "화면"
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
    var chrome: TrailerEditorChrome
    /// 전체 화면 비율. nil이면 원본(현재 순서의 첫 영상 비율)이며, 내보내기와 같은 규칙으로 계산한다.
    var aspectRatio: OutputAspectRatio? = nil
    /// 자막 입력 초안. 편집기가 갖고 있어 이 화면이 다시 만들어져도 그대로다.
    @ObservedObject var captionDraft: TrailerCaptionDraft
    @State private var tab = TrailerInspectorTab.scene
    /// 영상을 화면에 채울 때 어느 방향으로 잘리는지. 그 방향의 위치만 고를 수 있다.
    @State private var videoRoom: (key: String, horizontal: Bool, vertical: Bool)?

    private var selectedIndex: Int? { TrailerSceneEditor.index(of: selectedID, in: scenes ?? []) }

    /// 머리글과 탭은 고정이고, 탭의 값들만 따로 스크롤된다.
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if scenes == nil {
                // 준비가 끝나면 편집기가 장면 목록을 만든다. 그 사이 안내 문구나 버튼은 두지 않는다.
                Spacer(minLength: 0)
            } else if let index = selectedIndex, let scene = scenes?[index],
                      let source = sources.first(where: { $0.id == scene.sourceID }) {
                header(index: index, scene: scene, source: source)
                Picker("", selection: Binding(get: { tab }, set: { next in
                    guard next != tab else { return }
                    // 자막 탭을 떠날 때 적용하지 않은 입력이 있으면 먼저 묻는다.
                    if tab == .caption { chrome.guarded { tab = next } } else { tab = next }
                })) {
                    ForEach(TrailerInspectorTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        switch tab {
                        case .scene: sceneTab(scene: scene, source: source)
                        case .caption: captionTab(scene: scene, source: source)
                        case .sound: soundTab(scene: scene, source: source)
                        case .picture: pictureTab(scene: scene, source: source)
                        }
                        arrangement(scene: scene)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
                .scrollDismissesKeyboard(.interactively)
            } else {
                Text("장면 목록에서 장면을 고르세요.").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
                       in: (1.0 / 30.0)...30)
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

    private func applyCaptionDraft() {
        captionDraft.apply(to: &scenes)
    }

    private func revertCaptionDraft() {
        captionDraft.discard(scenes: scenes)
    }

    private func batchApplyCaptionStyle() {
        guard var editScenes = scenes else { return }
        for index in editScenes.indices {
            if let existing = editScenes[index].caption {
                var updated = existing
                updated.position = captionDraft.position
                updated.fontDesign = captionDraft.fontDesign
                updated.fontSize = captionDraft.fontSize
                updated.colorHex = captionDraft.colorHex
                updated.hasShadow = captionDraft.hasShadow
                editScenes[index].caption = updated
            }
        }
        var updatedScenes: [TrailerEditScene]? = editScenes
        captionDraft.apply(to: &updatedScenes)
        scenes = updatedScenes
    }

    /// 입력 초안 값 하나를 바꾸고 "적용하지 않은 입력"으로 표시하는 바인딩.
    private func draftBinding<Value>(_ keyPath: ReferenceWritableKeyPath<TrailerCaptionDraft, Value>) -> Binding<Value> {
        Binding(get: { captionDraft[keyPath: keyPath] },
                set: { captionDraft[keyPath: keyPath] = $0; captionDraft.isDirty = true })
    }

    private func colorFromHex(_ hexString: String) -> Color {
        let hex = hexString.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: Double
        switch hex.count {
        case 6:
            r = Double((int >> 16) & 0xFF) / 255.0
            g = Double((int >> 8) & 0xFF) / 255.0
            b = Double(int & 0xFF) / 255.0
        default:
            r = 1.0; g = 1.0; b = 1.0
        }
        return Color(red: r, green: g, blue: b)
    }

    @ViewBuilder
    private func captionTab(scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("자막 문구").font(.caption).foregroundStyle(.secondary)
                TextField("이 장면에 표시할 문구를 입력하세요", text: draftBinding(\.text))
                .textFieldStyle(.roundedBorder)
            }

            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("위치").font(.caption).foregroundStyle(.secondary)
                    Picker("위치", selection: draftBinding(\.position)) {
                        ForEach(TrailerCaption.Position.allCases) { pos in
                            Text(pos.rawValue).tag(pos)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("글꼴").font(.caption).foregroundStyle(.secondary)
                    Picker("글꼴", selection: draftBinding(\.fontDesign)) {
                        ForEach(TrailerCaption.FontDesign.allCases) { font in
                            Text(font.rawValue).tag(font)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("글자 크기").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(captionDraft.fontSize))pt").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Slider(value: draftBinding(\.fontSize), in: 14...36, step: 1)
            }

            HStack(spacing: 12) {
                Text("글자 색상").font(.caption).foregroundStyle(.secondary)
                let colorPresets = [
                    ("#FFFFFF", "흰색"),
                    ("#FFE600", "노랑"),
                    ("#00F0FF", "하늘"),
                    ("#FF3B30", "빨강"),
                    ("#000000", "검정")
                ]
                ForEach(colorPresets, id: \.0) { hex, name in
                    Button {
                        captionDraft.colorHex = hex
                        captionDraft.isDirty = true
                    } label: {
                        Circle()
                            .fill(colorFromHex(hex))
                            .frame(width: 26, height: 26)
                            .overlay(Circle().stroke(captionDraft.colorHex == hex ? PorcelainMetrics.accent : Color.gray.opacity(0.4), lineWidth: captionDraft.colorHex == hex ? 3 : 1))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(name)
                }
                Spacer()
                Toggle("그림자", isOn: draftBinding(\.hasShadow))
                .font(.caption)
            }

            Divider()

            HStack(spacing: 8) {
                Button("적용", action: applyCaptionDraft)
                    .buttonStyle(.borderedProminent)
                    .disabled(!captionDraft.isDirty)

                Button("취소", action: revertCaptionDraft)
                    .buttonStyle(.bordered)
                    .disabled(!captionDraft.isDirty)

                Spacer()

                Button("전체 일괄 스타일 적용") {
                    batchApplyCaptionStyle()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                if scene.caption != nil {
                    Button("자막 삭제", role: .destructive) {
                        set { $0.caption = nil }
                        var cleared = scene
                        cleared.caption = nil
                        captionDraft.load(cleared)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .onAppear {
            // 적용·취소하지 않은 입력은 그대로 둔다. 장면 전환·영역 전환은 편집기의 확인을 먼저 거친다.
            if captionDraft.sceneID != scene.id, !captionDraft.isDirty { captionDraft.load(scene) }
        }
        .onChange(of: scene.id) { _, _ in
            if !captionDraft.isDirty { captionDraft.load(scene) }
        }
        .onChange(of: scene.caption) { _, _ in
            // 되돌리기·일괄 적용처럼 밖에서 바뀐 자막을 입력칸에 반영한다(입력 중이면 건드리지 않는다).
            if !captionDraft.isDirty { captionDraft.load(scene) }
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

    /// 위치 이동·복제·삭제는 스토리보드 선택 도구줄에만 있다. 여기에는 그 줄에 없는 포함/제외만 둔다.
    private func arrangement(scene: TrailerEditScene) -> some View {
        Button { set { $0.excluded.toggle() } } label: {
            Label(scene.excluded ? "포함" : "제외", interfaceSystemImage: scene.excluded ? "eye" : "eye.slash")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}
