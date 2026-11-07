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

    /// 음악 비트 온셋에 맞춰 사진 장면들의 길이를 미세 조절한다.
    /// 영상 컷, 시작 위치, 자막, 프레이밍, 순서는 100% 보존된다.
    @discardableResult
    static func syncPhotoScenesToBeatOnsets(
        scenes: inout [TrailerEditScene],
        sources: [VideoTrailerSource],
        beatOnsets: [Double],
        musicDuration: Double,
        introOffset: Double = 0,
        repeatMusic: Bool = true,
        maxBudget: Double? = nil
    ) -> (adjustedCount: Int, averageShift: Double, unalignedCount: Int) {
        guard !scenes.isEmpty, !beatOnsets.isEmpty, musicDuration > 0 else {
            return (0, 0.0, 0)
        }

        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var timelineCursor = max(0.0, introOffset)
        var adjustedCount = 0
        var unalignedCount = 0
        var totalShift = 0.0

        for index in scenes.indices {
            let scene = scenes[index]
            guard !scene.excluded else { continue }
            guard let source = byID[scene.sourceID] else { continue }

            if !source.isImage {
                // 영상 컷/길이는 원본 의도 및 소리 싱크를 위해 100% 보존
                timelineCursor += max(0.001, scene.length)
                continue
            }

            // 사진 장면의 경우: 현재 목표 전환 시점 (타임라인 상에서 사진이 끝나는 시점)
            let bounds = sceneDurationBounds(scene: scene, source: source)
            let currentLen = scene.length
            let targetTransitionTime = timelineCursor + currentLen

            // 타임라인 상의 비트 후보군 생성 (음악 반복 여부 반영)
            var candidateBeats: [Double] = []
            if repeatMusic {
                let currentLoop = Int(max(0.0, targetTransitionTime) / musicDuration)
                for loop in max(0, currentLoop - 1)...(currentLoop + 2) {
                    let loopBase = Double(loop) * musicDuration
                    for b in beatOnsets {
                        candidateBeats.append(loopBase + b)
                    }
                }
            } else {
                // single policy: 음악이 한 번만 재생되므로 음악 길이 이내의 비트만 매칭
                if timelineCursor < musicDuration {
                    for b in beatOnsets where b >= timelineCursor && b <= musicDuration {
                        candidateBeats.append(b)
                    }
                }
            }

            // fitMusic의 마지막 예산끝 이후 후보는 적용되지 않도록 제한
            if let maxBudget {
                candidateBeats = candidateBeats.filter { $0 <= maxBudget }
            }

            // 사진이 가질 수 있는 최소/최대 길이 범위 안의 비트들 중 targetTransitionTime과 가장 가까운 비트 탐색
            let minAllowed = max(bounds.minimum, 0.8)
            let maxAllowed = min(bounds.maximum, 15.0)

            var bestBeat: Double? = nil
            var smallestDiff: Double = .greatestFiniteMagnitude

            for beatTime in candidateBeats {
                let candidateLen = beatTime - timelineCursor
                guard candidateLen >= minAllowed && candidateLen <= maxAllowed else { continue }
                let diff = abs(beatTime - targetTransitionTime)
                if diff < smallestDiff {
                    smallestDiff = diff
                    bestBeat = beatTime
                }
            }

            // 1.8초 이내의 가장 가까운 비트가 유효하면 사진 길이를 비트 전환 시점에 맞춤
            if let bestBeat, smallestDiff <= 1.8 {
                let newLen = bestBeat - timelineCursor
                let shift = abs(newLen - currentLen)
                if shift > 0.02 {
                    scenes[index].length = newLen
                    adjustedCount += 1
                    totalShift += shift
                }
                timelineCursor += scenes[index].length
            } else {
                unalignedCount += 1
                timelineCursor += currentLen
            }
        }

        let avgShift = adjustedCount > 0 ? totalShift / Double(adjustedCount) : 0.0
        return (adjustedCount, avgShift, unalignedCount)
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
            batchCaption: batchCaption,
            introCard: introCard,
            outroCard: outroCard)
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
    var introCard: TrailerTitleCard = TrailerTitleCard()
    var outroCard: TrailerTitleCard = TrailerTitleCard()
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

    /// 현재 서체 설정만 담은 견본. 시작/마지막 화면 카드의 실시간 미리보기가 쓴다.
    var styleSample: TrailerCaption {
        TrailerCaption(
            text: "Aa", position: .center, fontDesign: fontDesign, fontSize: fontSize, colorHex: colorHex,
            hasShadow: hasShadow, column: column, row: row, fontName: fontName, captionSize: captionSize,
            shadowColorHex: shadowColorHex, shadowOpacity: shadowOpacity, lineSpacing: lineSpacing
        )
    }

    /// 글자가 있는 본편 자막에 현재 서체만 입히고 문구·위치는 그대로 둔다.
    /// 카드는 본편 자막 서체를 따르므로 카드 화면에서 고른 스타일은 이렇게 반영된다.
    func applyStyleOnly(to scenes: inout [TrailerEditScene]?) {
        guard scenes != nil else { isDirty = false; return }
        let sample = styleSample
        for index in scenes!.indices {
            guard var c = scenes![index].caption,
                  !c.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            c.fontDesign = sample.fontDesign; c.fontSize = sample.fontSize; c.colorHex = sample.colorHex
            c.hasShadow = sample.hasShadow; c.fontName = sample.fontName; c.captionSize = sample.captionSize
            c.shadowColorHex = sample.shadowColorHex; c.shadowOpacity = sample.shadowOpacity
            c.lineSpacing = sample.lineSpacing
            scenes![index].caption = c
        }
        isDirty = false
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
        case .startScreen, .endScreen:
            // 화면 카드는 편집기가 따로 저장한다. 본편 문구는 건드리지 않는다.
            break
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
    var maxPixel: CGFloat = 200
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
            .task(id: "\(source.id)-\(Int(time * 2))-\(Int(maxPixel))") {
                if source.isImage {
                    image = await trailerThumbnailImage(at: source.url, maxPixelSize: maxPixel)
                } else {
                    let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
                    generator.appliesPreferredTrackTransform = true
                    generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
                    if let frame = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)) {
                        image = UIImage(cgImage: frame.image)
                    }
                }
            }
    }
}

/// 미리보기 플레이어(`RemotePreviewView`)와 타임라인 필름스트립을 잇는 다리. 위치는 플레이어가 쓰고,
/// 탐색은 플레이어의 기존 seek 경로(재생/일시 정지 상태는 건드리지 않음)를 부른다.
@MainActor
final class TrailerTimelineBridge: ObservableObject {
    @Published var currentSeconds = 0.0
    @Published var durationSeconds = 0.0
    @Published var isPlaying = false
    @Published var hasPlayer = false
    var seekHandler: ((Double) -> Void)?
    var playHandler: (() -> Void)?
    var pauseHandler: (() -> Void)?
    /// 핸들러를 건 플레이어 세션. 이전 세션의 늦은 정리가 새 세션의 핸들러를 지우지 못하게 한다.
    var owner: UUID?
    private var lastToggleDate = Date.distantPast
#if targetEnvironment(macCatalyst)
    @Published var masterVolume: Float = 1.0
#endif

    /// 재생 중이면 멈추고, 멈춰 있으면 지금 위치에서 재생한다(타임라인 클릭 재생과 같은 경로).
    func togglePlayback() {
        guard hasPlayer else { return }
        let now = Date()
        guard now.timeIntervalSince(lastToggleDate) >= 0.15 else { return }
        lastToggleDate = now
        if isPlaying { pauseHandler?() } else { playHandler?() }
    }

    /// 이미 재생 중이면 아무것도 하지 않는다. 멈춘 영상만 지금 위치에서 재생을 시작한다.
    func playIfPaused() {
        guard hasPlayer, !isPlaying else { return }
        playHandler?()
    }

    func seek(toSeconds seconds: Double) {
        guard hasPlayer, durationSeconds > 0 else { return }
        seekHandler?(min(max(seconds, 0), durationSeconds))
    }

    func seek(toFraction fraction: Double) {
        guard hasPlayer, durationSeconds > 0 else { return }
        seekHandler?(min(max(fraction, 0), 1) * durationSeconds)
    }

    func detach(ifOwner token: UUID) {
        guard owner == token else { return }
        owner = nil
        seekHandler = nil
        playHandler = nil
        pauseHandler = nil
        hasPlayer = false
    }
}

struct TrailerTimelineSegment: Identifiable, Equatable {
    enum Kind { case intro, clip, outro }
    let id: String
    let kind: Kind
    /// 편집 장면 id. 자동 구성이나 시작/마지막 화면은 nil.
    let sceneID: Int?
    let sourceID: Int?
    let start: Double
    let length: Double
    /// 이 장면의 원본 소리를 넣지 않는다(내보내기와 같은 규칙으로 음악 자동 조절에서 빠진다).
    var muted = false
    /// 이 장면의 화면 구성. 내보내기와 같이 계획 장면 값(음악 맞춤 반복 포함)을 따른다.
    var fitsFrame = false
    var offsetX = 0.0
    var offsetY = 0.0

    /// 사진 내보내기와 같은 규칙: 직접 정한 구성이 있을 때만 고정 구성, 없으면 자동 효과(nil).
    var framing: VideoTrailerImageClip.Framing? {
        (fitsFrame || offsetX != 0 || offsetY != 0)
            ? .init(fitsFrame: fitsFrame, offsetX: offsetX, offsetY: offsetY) : nil
    }
}

/// 미리보기 패널 안의 연속 필름스트립. 구간 폭은 길이에 비례하고, 켜진 시작/마지막 화면도 포함한다.
/// 완성 영상이 있으면 플레이헤드가 재생 위치를 따라가며 가로로 끌거나 눌러 탐색하고, 없으면 선택한 장면에 고정된다.
struct TrailerTimelineFilmstrip: View {
    let segments: [TrailerTimelineSegment]
    let sources: [VideoTrailerSource]
    let selectedSceneID: Int?
    @ObservedObject var bridge: TrailerTimelineBridge
    var onSelectScene: (Int) -> Void

    /// Mac 호버 탐색 상태. 호버를 시작할 때의 위치를 기억해 두었다가 클릭 없이 벗어나면 되돌린다.
    @State private var hoverOrigin: Double?
    @State private var hoverCommitted = false
    @State private var isDragging = false
    @State private var lastHoverSeek = Date.distantPast
    @State private var pendingHoverSeek: Task<Void, Never>?

    private var total: Double { max(0.001, segments.reduce(0) { $0 + max(0.05, $1.length) }) }
    private var clipCount: Int { segments.filter { $0.kind == .clip }.count }

    private func weight(_ segment: TrailerTimelineSegment) -> Double { max(0.05, segment.length) / total }

    private func segmentIndex(atFraction fraction: Double) -> Int? {
        var acc = 0.0
        for (i, segment) in segments.enumerated() {
            acc += weight(segment)
            if fraction < acc || i == segments.count - 1 { return i }
        }
        return nil
    }

    private var playheadFraction: Double? {
        if bridge.hasPlayer, bridge.durationSeconds > 0 {
            return min(max(bridge.currentSeconds / bridge.durationSeconds, 0), 1)
        }
        guard let selectedSceneID,
              let index = segments.firstIndex(where: { $0.sceneID == selectedSceneID }) else { return nil }
        let before = segments[..<index].reduce(0.0) { $0 + weight($1) }
        return before + weight(segments[index]) / 2
    }

    private var currentLabel: String? {
        guard let fraction = playheadFraction, let index = segmentIndex(atFraction: min(fraction, 0.999999)) else { return nil }
        switch segments[index].kind {
        case .intro: return "시작 화면"
        case .outro: return "마지막 화면"
        case .clip:
            let number = segments[...index].filter { $0.kind == .clip }.count
            return "\(number)/\(clipCount)"
        }
    }

    var body: some View {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                HStack(spacing: 0) {
                    ForEach(segments) { segment in
                        segmentView(segment, source: segment.sourceID.flatMap { byID[$0] })
                            .frame(width: max(1, width * weight(segment)))
                    }
                }
                .frame(width: width, height: proxy.size.height, alignment: .leading)
                .clipped()
                .allowsHitTesting(false)

                if let fraction = playheadFraction {
                    Rectangle().fill(.white)
                        .frame(width: 2, height: proxy.size.height)
                        .shadow(color: .black.opacity(0.7), radius: 1.5)
                        .offset(x: min(max(fraction * width - 1, 0), width - 2))
                        .allowsHitTesting(false)
                }
                if let label = currentLabel {
                    Text(label).font(.caption2.weight(.bold)).monospacedDigit()
                        .foregroundStyle(.white).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.black.opacity(0.7), in: Capsule()).padding(4)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: proxy.size.height)
            .contentShape(Rectangle())
            // SwiftUI의 onContinuousHover/DragGesture는 Catalyst 합성 뷰 위에서 이벤트를 받지 못해,
            // 실제 UIKit 뷰의 hover/press 인식기로 마우스 이벤트를 직접 받는다.
            .overlay {
                TrailerTimelineNativeInput(
                    onHover: { hoverScrub(fraction: $0) },
                    onHoverEnd: { endHover() },
                    onPress: { fraction in
                        guard bridge.hasPlayer else { return }
                        isDragging = true
                        commitHover()
                        bridge.seek(toFraction: fraction)
                    },
                    onDrag: { fraction in
                        guard bridge.hasPlayer else { return }
                        bridge.seek(toFraction: fraction)
                    },
                    onRelease: { fraction, moved in
                        defer { isDragging = false }
                        if bridge.hasPlayer {
                            commitHover()
                            bridge.seek(toFraction: fraction)
                            // 거의 움직이지 않은 클릭이면 눌린 바로 그 위치에서 재생한다. 끌기는 위치만 옮긴다.
                            if !moved { bridge.playIfPaused() }
                        } else if let index = segmentIndex(atFraction: fraction), let id = segments[index].sceneID {
                            onSelectScene(id)
                        }
                    }
                )
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement()
        .accessibilityLabel("타임라인")
        .accessibilityValue(currentLabel ?? "")
    }

    /// 호버 탐색 확정: 대기 중인 호버 이동을 버리고 되돌리기를 막는다. 클릭과 호버 종료가 겹쳐도 클릭 위치가 남는다.
    private func commitHover() {
        pendingHoverSeek?.cancel()
        pendingHoverSeek = nil
        hoverCommitted = true
    }

    /// 멈춘 영상 위에서만 위치를 따라간다(자동 재생 없음). 이동은 약 12Hz로 줄이고 마지막 위치는 뒤따라 보낸다.
    private func hoverScrub(fraction rawFraction: Double) {
        guard bridge.hasPlayer, !bridge.isPlaying, !isDragging else { return }
        if hoverOrigin == nil {
            hoverOrigin = bridge.currentSeconds
            hoverCommitted = false
        }
        let fraction = min(max(rawFraction, 0), 1)
        let interval = 0.08
        let elapsed = Date().timeIntervalSince(lastHoverSeek)
        pendingHoverSeek?.cancel()
        if elapsed >= interval {
            lastHoverSeek = Date()
            bridge.seek(toFraction: fraction)
        } else {
            pendingHoverSeek = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(Int((interval - elapsed) * 1000) + 1))
                guard !Task.isCancelled, !hoverCommitted, !bridge.isPlaying else { return }
                lastHoverSeek = Date()
                bridge.seek(toFraction: fraction)
            }
        }
    }

    private func endHover() {
        pendingHoverSeek?.cancel()
        pendingHoverSeek = nil
        defer { hoverOrigin = nil; hoverCommitted = false }
        // 클릭·끌기로 확정했거나 재생이 시작됐다면 그 위치를 유지하고, 아니면 호버 전 위치로 돌아간다.
        guard let origin = hoverOrigin, !hoverCommitted, !isDragging, bridge.hasPlayer, !bridge.isPlaying,
              bridge.durationSeconds > 0 else { return }
        bridge.seek(toFraction: origin / bridge.durationSeconds)
    }

    @ViewBuilder
    private func segmentView(_ segment: TrailerTimelineSegment, source: VideoTrailerSource?) -> some View {
        ZStack {
            switch segment.kind {
            case .intro, .outro:
                Color(white: 0.16)
                Text(segment.kind == .intro ? "시작" : "마지막")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1).minimumScaleFactor(0.5).padding(.horizontal, 2)
            case .clip:
                if let source {
                    TrailerSceneThumb(source: source, time: segment.start)
                } else {
                    Color(uiColor: .tertiarySystemFill)
                }
            }
        }
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.6)).frame(width: 1) }
    }
}

/// 필름스트립 위의 실제 UIKit 입력 뷰. hover(마우스 이동)와 눌러서 끌기/클릭을 0...1 비율로 알려 준다.
struct TrailerTimelineNativeInput: UIViewRepresentable {
    var onHover: (Double) -> Void
    var onHoverEnd: () -> Void
    var onPress: (Double) -> Void
    var onDrag: (Double) -> Void
    var onRelease: (Double, Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isMultipleTouchEnabled = false
        let hover = UIHoverGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.hovered(_:)))
        let press = UILongPressGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pressed(_:)))
        press.minimumPressDuration = 0
        press.allowableMovement = .greatestFiniteMagnitude
        press.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                   NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        press.delegate = context.coordinator
        view.addGestureRecognizer(hover)
        view.addGestureRecognizer(press)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.parent = self }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: TrailerTimelineNativeInput
        private var pressStart: CGPoint?
        private var moved = false
        init(_ parent: TrailerTimelineNativeInput) { self.parent = parent }

        private func fraction(_ recognizer: UIGestureRecognizer) -> Double {
            guard let view = recognizer.view, view.bounds.width > 0 else { return 0 }
            return min(max(Double(recognizer.location(in: view).x / view.bounds.width), 0), 1)
        }

        func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func hovered(_ recognizer: UIHoverGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed: parent.onHover(fraction(recognizer))
            case .ended, .cancelled, .failed: parent.onHoverEnd()
            default: break
            }
        }

        @objc func pressed(_ recognizer: UILongPressGestureRecognizer) {
            let point = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                pressStart = point
                moved = false
                parent.onPress(fraction(recognizer))
            case .changed:
                if let start = pressStart, hypot(point.x - start.x, point.y - start.y) >= 4 { moved = true }
                parent.onDrag(fraction(recognizer))
            case .ended:
                parent.onRelease(fraction(recognizer), moved)
                pressStart = nil
            case .cancelled, .failed:
                parent.onRelease(fraction(recognizer), true)
                pressStart = nil
            default: break
            }
        }
    }
}

/// Mac 편집기 왼쪽 클립 목록의 표시 방식. 선택은 `@AppStorage`로 저장한다.
enum TrailerClipListMode: String, CaseIterable, Identifiable {
    case detail, thumbnail, poster
    var id: String { rawValue }
    var title: String {
        switch self {
        case .detail: "자세히"
        case .thumbnail: "썸네일"
        case .poster: "포스터"
        }
    }
    var isGrid: Bool { self != .detail }
}

/// Mac 편집기 왼쪽의 유일한 클립 브라우저(자세히·썸네일·포스터). 줄을 누르면 편집 대상이 되고,
/// 자막·구간 편집은 오른쪽 인스펙터 하나가 맡으므로 여기서는 펼치지 않는다.
/// `markedIDs`가 있으면 다중 선택 중이라 표시된 클립에 체크를 그린다.
/// 재생 위치나 호버는 이 목록의 선택을 바꾸지 않는다. 선택은 `onSelect`로만 바뀐다.
/// 모든 모드가 Lazy 컨테이너라 400개 이상도 보이는 줄만 만든다.
struct TrailerClipListView: View {
    let scenes: [TrailerEditScene]
    let sources: [VideoTrailerSource]
    let selectedID: Int?
    var mode: TrailerClipListMode = .detail
    var markedIDs: Set<Int>? = nil
    var columnCount: Int? = nil
    let onSelect: (Int) -> Void
    /// false면 자체 세로 스크롤 없이 지연 내용만 그려, 바깥 ScrollView(폰 단일 스크롤) 안에 놓인다.
    var scrolls: Bool = true

    @ViewBuilder
    private func content(_ byID: [Int: VideoTrailerSource]) -> some View {
        switch mode {
        case .detail: detailRows(byID)
        case .thumbnail: grid(byID, minimum: 84, thumbHeight: 60, pixel: 240, showsName: false)
        case .poster: grid(byID, minimum: 150, thumbHeight: 190, pixel: 480, showsName: true)
        }
    }

    var body: some View {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if scrolls {
            ScrollViewReader { proxy in
                ScrollView {
                    content(byID)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .onChange(of: selectedID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: mode.isGrid ? .center : .top) } }
                }
                .onChange(of: mode) { _, _ in
                    if let selectedID { proxy.scrollTo(selectedID, anchor: .center) }
                }
            }
        } else {
            content(byID)
        }
    }

    private func summary(_ scene: TrailerEditScene, _ source: VideoTrailerSource) -> String {
        (source.isImage ? "사진" : "영상") + " · " + String(format: "%.1f초", scene.length)
            + (scene.excluded ? " · 제외됨" : "") + (scene.caption == nil ? "" : " · 자막")
    }

    private func label(_ index: Int, _ scene: TrailerEditScene, _ source: VideoTrailerSource) -> String {
        "클립 \(index + 1), \(source.name), \(String(format: "%.1f", scene.length))초" + (scene.excluded ? ", 제외됨" : "")
    }

    private func markBadge(_ marked: Bool) -> some View {
        Image(systemName: marked ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(marked ? PorcelainMetrics.accent : Color.secondary)
            .background(Circle().fill(Color.white.opacity(0.7)))
            .accessibilityLabel(marked ? "선택됨" : "선택 안 됨")
    }

    private func detailRows(_ byID: [Int: VideoTrailerSource]) -> some View {
        LazyVStack(alignment: .leading, spacing: 6) {
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                if let source = byID[scene.sourceID] {
                    let isSelected = selectedID == scene.id
                    VStack(alignment: .leading, spacing: 8) {
                        Button { onSelect(scene.id) } label: {
                            HStack(spacing: 10) {
                                if let markedIDs { markBadge(markedIDs.contains(scene.id)) }
                                TrailerSceneThumb(source: source, time: scene.start)
                                    .frame(width: 64, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .opacity(scene.excluded ? 0.35 : 1)
                                Text("\(index + 1)")
                                    .font(.system(size: 13, weight: .bold).monospacedDigit())
                                    .frame(minWidth: 22, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(source.name)
                                        .font(.system(size: 13, weight: .medium))
                                        .lineLimit(1).truncationMode(.middle)
                                    Text(summary(scene, source))
                                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(6)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(label(index, scene, source))
                        .accessibilityAddTraits(isSelected ? .isSelected : [])
                    }
                    .background(isSelected ? PorcelainMetrics.accent.opacity(0.08) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? PorcelainMetrics.accent : PorcelainMetrics.line, lineWidth: isSelected ? 1.5 : 0.5))
                    .id(scene.id)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func grid(_ byID: [Int: VideoTrailerSource], minimum: CGFloat, thumbHeight: CGFloat,
                      pixel: CGFloat, showsName: Bool) -> some View {
        let gridColumns: [GridItem] = columnCount.map {
            Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: min(6, max(2, $0)))
        } ?? [GridItem(.adaptive(minimum: minimum), spacing: 8, alignment: .top)]
        return LazyVGrid(columns: gridColumns, spacing: 8) {
            ForEach(Array(scenes.enumerated()), id: \.element.id) { index, scene in
                if let source = byID[scene.sourceID] {
                    let isSelected = selectedID == scene.id
                    Button { onSelect(scene.id) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Color.clear
                                .frame(height: thumbHeight)
                                .overlay {
                                    TrailerSceneThumb(source: source, time: scene.start, maxPixel: pixel)
                                        .opacity(scene.excluded ? 0.35 : 1)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(alignment: .topTrailing) {
                                    if let markedIDs { markBadge(markedIDs.contains(scene.id)).padding(4) }
                                }
                                .overlay(alignment: .topLeading) {
                                    Text("\(index + 1)")
                                        .font(.system(size: 11, weight: .bold).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Color.black.opacity(0.6), in: Capsule())
                                        .padding(4)
                                }
                                .overlay(alignment: .bottomTrailing) {
                                    Text(String(format: "%.1f초", scene.length))
                                        .font(.system(size: 10).monospacedDigit())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Color.black.opacity(0.6), in: Capsule())
                                        .padding(4)
                                }
                            if showsName {
                                Text(source.name).font(.system(size: 12, weight: .medium))
                                    .lineLimit(1).truncationMode(.middle)
                                Text(summary(scene, source)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .padding(4)
                        .background(isSelected ? PorcelainMetrics.accent.opacity(0.08) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isSelected ? PorcelainMetrics.accent : Color.clear, lineWidth: 1.5))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(label(index, scene, source))
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                    .id(scene.id)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

/// 좌우 두 칸 사이의 끌 수 있는 구분선. 끌기 시작 때의 비율에서 총 폭 기준으로 계산해 손을 따라 흔들리지 않고,
/// 더블클릭하면 기본 비율로 돌아간다. 비율 저장은 호출한 쪽의 바인딩이 맡는다.
struct TrailerSplitHandle: View {
    @Binding var ratio: Double
    /// 두 칸이 나누어 쓰는 폭(구분선 폭 제외). 끌어도 변하지 않는 값이어야 한다.
    let totalWidth: CGFloat
    let range: ClosedRange<Double>
    let defaultRatio: Double
    @State private var startRatio: Double?

    var body: some View {
        Color.clear
            .frame(width: 12)
            .overlay(Capsule().fill(PorcelainMetrics.line).frame(width: 4, height: 40))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ratio = min(max(defaultRatio, range.lowerBound), range.upperBound) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let start = startRatio ?? ratio
                        if startRatio == nil { startRatio = ratio }
                        ratio = min(max(start + Double(value.translation.width / totalWidth), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startRatio = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("왼쪽 창과 오른쪽 창 경계")
            .accessibilityAdjustableAction { direction in
                let step = 0.05
                ratio = min(max(ratio + (direction == .increment ? step : -step), range.lowerBound), range.upperBound)
            }
    }
}

/// 위아래 두 칸 사이의 경계. 끌면 위 칸의 비율이 바뀌고, 두 번 누르면 기본 비율로 돌아간다.
struct TrailerVerticalSplitHandle: View {
    @Binding var ratio: Double
    /// 두 칸이 나누어 쓰는 높이(구분선 높이 제외). 끌어도 변하지 않는 값이어야 한다.
    let totalHeight: CGFloat
    let range: ClosedRange<Double>
    let defaultRatio: Double
    @State private var startRatio: Double?

    var body: some View {
        Color.clear
            .frame(height: 12)
            .overlay(Capsule().fill(PorcelainMetrics.line).frame(width: 40, height: 4))
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { ratio = min(max(defaultRatio, range.lowerBound), range.upperBound) }
            .gesture(
                DragGesture(minimumDistance: 2, coordinateSpace: .global)
                    .onChanged { value in
                        guard totalHeight > 0 else { return }
                        let start = startRatio ?? ratio
                        if startRatio == nil { startRatio = ratio }
                        ratio = min(max(start + Double(value.translation.height / totalHeight), range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in startRatio = nil }
            )
            .accessibilityElement()
            .accessibilityLabel("클립과 설정 경계")
            .accessibilityAdjustableAction { direction in
                ratio = min(max(ratio + (direction == .increment ? 0.05 : -0.05), range.lowerBound), range.upperBound)
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

// MARK: - 렌더 전 초안 재생

/// 완성 영상이 없을 때 사진·영상·타이틀 카드로 초안을 재생하기 위한 입력.
struct TrailerDraftPreviewInput {
    var segments: [TrailerTimelineSegment]
    var sources: [VideoTrailerSource]
    var captions: [String: TrailerCaption]
    var introCard: TrailerTitleCard
    var outroCard: TrailerTitleCard
    var introBackground: UIImage?
    var outroBackground: UIImage?
    var bodyTypography: TrailerCaption?
    var selectedSceneID: Int?
    /// 배경음악. nil이면 음악 없이 재생한다.
    var music: TrailerMusicSelection?

    /// 음악 배치·음량이 달라질 때만 바뀌는 키. 시계 재생은 이 키와 무관하다.
    var musicKey: String {
        guard let music else { return "none" }
        let layout = segments.map { "\($0.id):\($0.length):\($0.start):\($0.muted)" }.joined(separator: ",")
        return "\(music.recordID)|\(music.url.path)|\(music.policy.rawValue)|\(music.fitCount)|\(music.autoDuck)|\(music.level)|\(layout)"
    }

    /// 타임라인 필름스트립과 같은 가중치(최소 0.05초)로 센 전체 길이.
    var totalDuration: Double { segments.reduce(0) { $0 + max(0.05, $1.length) } }

    func location(at seconds: Double) -> (index: Int, offset: Double)? {
        var acc = 0.0
        for (index, segment) in segments.enumerated() {
            let length = max(0.05, segment.length)
            if seconds < acc + length || index == segments.count - 1 {
                return (index, min(max(seconds - acc, 0), length))
            }
            acc += length
        }
        return nil
    }

    func startSeconds(ofScene id: Int) -> Double? {
        var acc = 0.0
        for segment in segments {
            if segment.sceneID == id { return acc }
            acc += max(0.05, segment.length)
        }
        return nil
    }
}

/// 미리보기 자산(사진 썸네일, 타이틀 카드, 비디오 컴포지션, 메타데이터)을 프로젝트 단위로 유지하는 바운디드 캐시.
/// 인라인과 전체화면 전환, 그리고 탐색 중에 미리보기가 재생성되어도 준비 상태를 유지한다.
@MainActor
final class TrailerDraftPreviewCache {
    static let shared = TrailerDraftPreviewCache()

    private let photoCache = NSCache<NSString, UIImage>()
    private let cardCache = NSCache<NSString, UIImage>()
    private var videoCompositions: [String: AVVideoComposition] = [:]
    private var videoCompositionKeys: [String] = []
    private var videoSizes: [String: CGSize] = [:]
    private var videoSizeKeys: [String] = []
    private var preparedSignatures: [String] = []

    init() {
        photoCache.countLimit = 64
        cardCache.countLimit = 16
    }

    func photo(for sourceID: Int, url: URL) -> UIImage? {
        photoCache.object(forKey: "\(sourceID)|\(url.absoluteString)" as NSString)
    }

    func setPhoto(_ image: UIImage, for sourceID: Int, url: URL) {
        photoCache.setObject(image, forKey: "\(sourceID)|\(url.absoluteString)" as NSString)
    }

    func card(for key: String) -> UIImage? {
        cardCache.object(forKey: key as NSString)
    }

    func setCard(_ image: UIImage, for key: String) {
        cardCache.setObject(image, forKey: key as NSString)
    }

    func videoSize(for url: URL) -> CGSize? {
        videoSizes[url.absoluteString]
    }

    func setVideoSize(_ size: CGSize, for url: URL) {
        let key = url.absoluteString
        if videoSizes[key] == nil {
            videoSizeKeys.append(key)
            if videoSizeKeys.count > 64 {
                let old = videoSizeKeys.removeFirst()
                videoSizes.removeValue(forKey: old)
            }
        }
        videoSizes[key] = size
    }

    func videoComposition(for key: String) -> AVVideoComposition? {
        videoCompositions[key]
    }

    func setVideoComposition(_ composition: AVVideoComposition, for key: String) {
        if videoCompositions[key] == nil {
            videoCompositionKeys.append(key)
            if videoCompositionKeys.count > 64 {
                let old = videoCompositionKeys.removeFirst()
                videoCompositions.removeValue(forKey: old)
            }
        }
        videoCompositions[key] = composition
    }

    func isPrepared(signature: String) -> Bool {
        preparedSignatures.contains(signature)
    }

    func markPrepared(signature: String) {
        if let idx = preparedSignatures.firstIndex(of: signature) {
            preparedSignatures.remove(at: idx)
        }
        preparedSignatures.append(signature)
        if preparedSignatures.count > 32 {
            preparedSignatures.removeFirst()
        }
    }
}

/// 영상 구간을 시계에 맞춰 재생하는 AVPlayer 보조. 시계가 기준이고, 플레이어는 잘라낸 원본 위치로 따라간다.
@MainActor
final class TrailerDraftVideoDriver: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var isPreparingLayout = false
    @Published private(set) var isBuffering = false
    var isPreparingMedia: Bool { isBuffering }
    private var segmentID: String?

    private var layoutGeneration = 0
    private var itemGeneration = 0
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?

    init() {
        player.actionAtItemEnd = .pause
        setupPlayerObservation()
    }

    deinit {
        timeControlObservation?.invalidate()
        itemStatusObservation?.invalidate()
    }

    private func setupPlayerObservation() {
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            self?.scheduleReadinessEvaluation()
        }
    }

    private func attachItemObservation(_ item: AVPlayerItem, generation: Int) {
        itemStatusObservation?.invalidate()
        itemStatusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self, weak item] observedItem, _ in
            guard let self, let item, observedItem === item else { return }
            self.scheduleReadinessEvaluation(expectedItem: item, generation: generation)
        }
    }

    private func teardownItemObservation() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
    }

    private func scheduleReadinessEvaluation(expectedItem: AVPlayerItem? = nil, generation: Int? = nil) {
        if Thread.isMainThread {
            updateReadiness(expectedItem: expectedItem, generation: generation)
        } else {
            Task { @MainActor [weak self] in
                self?.updateReadiness(expectedItem: expectedItem, generation: generation)
            }
        }
    }

    @MainActor
    private func updateReadiness(expectedItem: AVPlayerItem? = nil, generation: Int? = nil) {
        if let generation, generation != itemGeneration { return }
        guard segmentID != nil, let currentItem = player.currentItem else {
            if isBuffering { isBuffering = false }
            return
        }
        if let expectedItem, currentItem !== expectedItem { return }

        // Failed video must not endlessly spin.
        if currentItem.status == .failed || currentItem.error != nil || player.error != nil {
            if isBuffering { isBuffering = false }
            return
        }

        switch currentItem.status {
        case .unknown:
            if !isBuffering { isBuffering = true }
        case .readyToPlay:
            let buffering = (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
            if isBuffering != buffering { isBuffering = buffering }
        case .failed:
            if isBuffering { isBuffering = false }
        @unknown default:
            if isBuffering { isBuffering = false }
        }
    }

    /// 영상 구간의 화면 구성(채우기/맞추기/위치)과 미리보기 화면 크기.
    struct Layout: Equatable {
        var fitsFrame: Bool
        var offsetX: Double
        var offsetY: Double
        var renderSize: CGSize
    }

    static func compositionKey(url: URL, layout: Layout) -> String {
        "\(url.absoluteString)|\(layout.fitsFrame)|\(layout.offsetX)|\(layout.offsetY)|\(Int(layout.renderSize.width))x\(Int(layout.renderSize.height))"
    }

    @discardableResult
    static func prepareComposition(url: URL, layout: Layout) async -> AVVideoComposition? {
        let key = compositionKey(url: url, layout: layout)
        if let existing = TrailerDraftPreviewCache.shared.videoComposition(for: key) {
            return existing
        }
        let asset = AVURLAsset(url: url)
        guard let track = try? await asset.loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize),
              let transform = try? await track.load(.preferredTransform),
              let duration = try? await asset.load(.duration),
              natural.width > 0, natural.height > 0, !Task.isCancelled else { return nil }
        let scale = min(1, 960 / max(layout.renderSize.width, layout.renderSize.height))
        let size = CGSize(width: max(4, (layout.renderSize.width * scale).rounded()),
                          height: max(4, (layout.renderSize.height * scale).rounded()))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(layout.fitsFrame
            ? TrailerOutputRenderer.aspectFitTransform(naturalSize: natural, preferredTransform: transform, renderSize: size)
            : TrailerOutputRenderer.aspectFillTransform(naturalSize: natural, preferredTransform: transform, renderSize: size,
                                                        offsetX: layout.offsetX, offsetY: layout.offsetY), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        instruction.backgroundColor = UIColor.black.cgColor
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1, timescale: 30)
        composition.instructions = [instruction]
        guard !Task.isCancelled else { return nil }
        TrailerDraftPreviewCache.shared.setVideoComposition(composition, for: key)
        return composition
    }

    private var layoutKey: Layout?
    private var layoutTask: Task<Void, Never>?

    func sync(segment: TrailerTimelineSegment?, url: URL?, offset: Double, playing: Bool, layout: Layout) {
        guard let segment, segment.kind == .clip, let url else { stop(); return }
        let target = max(0, segment.start + offset)
        if segmentID != segment.id {
            segmentID = segment.id
            layoutKey = nil
            layoutTask?.cancel()
            layoutGeneration += 1
            itemGeneration += 1
            let gen = itemGeneration
            let item = AVPlayerItem(url: url)
            attachItemObservation(item, generation: gen)
            player.replaceCurrentItem(with: item)
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            scheduleReadinessEvaluation(expectedItem: item, generation: gen)
        } else if !playing || abs(player.currentTime().seconds - target) > 0.3 {
            player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            scheduleReadinessEvaluation(expectedItem: player.currentItem, generation: itemGeneration)
        }
        applyLayout(layout, for: url)
        if playing {
            if player.timeControlStatus == .paused { player.play() }
        } else {
            player.pause()
        }
        scheduleReadinessEvaluation(expectedItem: player.currentItem, generation: itemGeneration)
    }

    /// 내보내기와 같은 `aspectFit/aspectFillTransform`을 항목의 비디오 합성에 걸어 일시정지·재생 모두에 반영한다.
    /// 항목과 재생 위치는 바꾸지 않는다.
    private func applyLayout(_ layout: Layout, for url: URL? = nil) {
        guard layout != layoutKey, let item = player.currentItem else { return }
        layoutKey = layout
        if let url, let cached = TrailerDraftPreviewCache.shared.videoComposition(for: Self.compositionKey(url: url, layout: layout)) {
            item.videoComposition = cached
            isPreparingLayout = false
            if player.rate == 0 {
                player.seek(to: player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            }
            return
        }
        layoutTask?.cancel()
        layoutGeneration += 1
        let generation = layoutGeneration
        isPreparingLayout = true
        layoutTask = Task { [weak self, weak item] in
            defer {
                if let self, self.layoutGeneration == generation {
                    self.isPreparingLayout = false
                }
            }
            guard let item else { return }
            let asset = item.asset
            guard let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let natural = try? await track.load(.naturalSize),
                  let transform = try? await track.load(.preferredTransform),
                  let duration = try? await asset.load(.duration),
                  natural.width > 0, natural.height > 0, !Task.isCancelled else { return }
            let scale = min(1, 960 / max(layout.renderSize.width, layout.renderSize.height))
            let size = CGSize(width: max(4, (layout.renderSize.width * scale).rounded()),
                              height: max(4, (layout.renderSize.height * scale).rounded()))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            layer.setTransform(layout.fitsFrame
                ? TrailerOutputRenderer.aspectFitTransform(naturalSize: natural, preferredTransform: transform, renderSize: size)
                : TrailerOutputRenderer.aspectFillTransform(naturalSize: natural, preferredTransform: transform, renderSize: size,
                                                            offsetX: layout.offsetX, offsetY: layout.offsetY), at: .zero)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
            instruction.layerInstructions = [layer]
            instruction.backgroundColor = UIColor.black.cgColor
            let composition = AVMutableVideoComposition()
            composition.renderSize = size
            composition.frameDuration = CMTime(value: 1, timescale: 30)
            composition.instructions = [instruction]
            if let url {
                TrailerDraftPreviewCache.shared.setVideoComposition(composition, for: Self.compositionKey(url: url, layout: layout))
            }
            guard let self, !Task.isCancelled, self.layoutGeneration == generation, self.player.currentItem === item else { return }
            item.videoComposition = composition
            // 일시정지 중에도 보이는 프레임을 새 구성으로 다시 그린다(같은 위치).
            if self.player.rate == 0 {
                self.player.seek(to: self.player.currentTime(), toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: { _ in })
            }
        }
    }

    func stop() {
        player.pause()
        layoutGeneration += 1
        itemGeneration += 1
        layoutTask?.cancel()
        layoutTask = nil
        isPreparingLayout = false
        isBuffering = false
        teardownItemObservation()
        guard segmentID != nil else { return }
        segmentID = nil
        layoutKey = nil
        player.replaceCurrentItem(with: nil)
    }
}

/// 초안 배경음악 재생. 내보내기와 같은 `TrailerMusicMix`로 음악을 깔고 자동 조절을 계산한 합성 항목을
/// 만들어 두고, 미리보기 시계(재생 위치·재생 여부)를 그대로 따라간다.
@MainActor
final class TrailerDraftMusicDriver: ObservableObject {
    let player = AVPlayer()
    @Published private(set) var failure: String?
    private var ready = false
    private var duration = 0.0
    private var envelopes: [Int: AudioActivityEnvelope] = [:]
    private var measured: Set<Int> = []
    private var currentMusicKey: String?
    private var prepareTask: Task<Void, Never>?
    private var prepareGeneration = 0
    private var heldAsset: AVURLAsset?

    init() { player.actionAtItemEnd = .pause }

    /// 입력이 바뀔 때마다 호출한다(`.task(id:)`가 이전 호출을 취소한다).
    func prepare(_ input: TrailerDraftPreviewInput) async {
        guard let music = input.music else {
            stop()
            return
        }
        let key = input.musicKey
        if currentMusicKey == key && ready && player.currentItem != nil {
            return
        }
        if let existing = prepareTask, currentMusicKey == key {
            await existing.value
            return
        }

        prepareTask?.cancel()
        currentMusicKey = key
        ready = false
        player.pause()
        player.replaceCurrentItem(with: nil)
        failure = nil

        let task = Task { [weak self] in
            // 음량 슬라이더를 끄는 동안 매번 다시 만들지 않도록 잠깐 모은다.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            do {
                let asset = AVURLAsset(url: music.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
                guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                      try await track.load(.isDecodable) else { throw TrailerMusicError.unreadable }
                let range = try await track.load(.timeRange)
                try TrailerMusic.validate(duration: range.duration.seconds)

                // 소리가 나는 영상 장면의 세기를 한 번만 잰다. 못 잰 영상은 내보내기처럼 계속 들리는 것으로 본다.
                let videoIDs = Set(input.segments.compactMap { $0.kind == .clip && !$0.muted ? $0.sourceID : nil })
                guard let self else { return }
                for source in input.sources where !source.isImage && videoIDs.contains(source.id) && !self.measured.contains(source.id) {
                    self.envelopes[source.id] = try? await AudioAnalysisService.activityEnvelope(url: source.url)
                    try Task.checkCancellation()
                    self.measured.insert(source.id)
                }

                var originalSound: [TrailerMusicDucking.Clip] = []
                var outputStart = 0.0
                let byID = Dictionary(input.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                for segment in input.segments {
                    if segment.kind == .clip, !segment.muted, let id = segment.sourceID, let source = byID[id], !source.isImage {
                        originalSound.append(.init(outputStart: outputStart, sourceStart: segment.start,
                                                   length: segment.length, envelope: self.envelopes[id]))
                    }
                    outputStart += segment.length
                }

                let composition = AVMutableComposition()
                guard outputStart > 0,
                      let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                else { throw TrailerMusicError.unreadable }
                let placed = try TrailerMusicMix.insertPieces(
                    into: musicTrack, source: track, range: range,
                    total: CMTime(seconds: outputStart, preferredTimescale: 600), policy: music.policy)
                let built = TrailerMusicMix.audioMix(for: musicTrack, selection: music, originalSound: originalSound,
                                                     musicEnd: placed.end.seconds)
                try Task.checkCancellation()
                let item = AVPlayerItem(asset: composition)
                item.audioMix = built.mix
                guard !Task.isCancelled, self.currentMusicKey == key else { return }
                self.heldAsset = asset
                self.duration = placed.end.seconds
                self.player.replaceCurrentItem(with: item)
                self.ready = true
            } catch is CancellationError {
                return
            } catch let error as TrailerMusicError {
                guard let self, !Task.isCancelled, self.currentMusicKey == key else { return }
                self.failure = error.errorDescription
            } catch {
                guard let self, !Task.isCancelled, self.currentMusicKey == key else { return }
                self.failure = TrailerMusicError.unreadable.errorDescription
            }
        }
        prepareGeneration += 1
        let generation = prepareGeneration
        prepareTask = task
        await task.value
        if prepareGeneration == generation {
            prepareTask = nil
        }
    }

    func sync(seconds: Double, playing: Bool) {
        guard ready else { return }
        // 음악이 먼저 끝났거나(음악 한 번) 영상이 끝에 닿으면 소리를 멈춘다.
        guard seconds < duration - 0.02 else { player.pause(); return }
        let drift = abs(player.currentTime().seconds - seconds)
        if playing {
            if player.timeControlStatus == .paused || drift > 0.3 {
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
            if player.timeControlStatus == .paused {
                SharedMediaAudioSession.activatePlayback()
                player.play()
            }
        } else {
            player.pause()
            if drift > 0.05 {
                player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            }
        }
    }

    func stop() {
        prepareTask?.cancel()
        prepareTask = nil
        currentMusicKey = nil
        player.pause()
        ready = false
        player.replaceCurrentItem(with: nil)
    }
}

/// 사진·영상·타이틀 카드로 된 초안을 시계로 재생하는 미리보기. 브리지에 같은 재생/탐색 핸들러를 걸어
/// 항상 보이는 재생 버튼과 타임라인 호버·클릭 탐색이 완성 영상 없이도 동작한다.
struct TrailerDraftPreviewPlayer: View {
    let input: TrailerDraftPreviewInput
    let aspectRatio: OutputAspectRatio?
    @ObservedObject var bridge: TrailerTimelineBridge

    @State private var currentPhoto: (sourceID: Int, image: UIImage)?
    @State private var photoCacheRevision = 0
    @State private var cardImage: UIImage?
    @State private var originalVideoSize: (url: URL, size: CGSize)?
    @StateObject private var video = TrailerDraftVideoDriver()
    @StateObject private var music = TrailerDraftMusicDriver()
    @State private var isPreparingProject = false
    @State private var preparationProgress: Double?
    @State private var preparationGeneration = 0
    @State private var activePreparationSignature: String?
    @State private var failedAssetCount = 0
#if targetEnvironment(macCatalyst)
    @State private var draftVolumeHUD: Float?
    @State private var draftVolumeDismissTask: Task<Void, Never>?
#endif

    private var isPreparingPreview: Bool {
        isPreparingProject && (preparationProgress != nil)
    }

    private var currentVideoSource: VideoTrailerSource? {
        guard let id = currentSegment?.sourceID, currentSegment?.kind == .clip else { return nil }
        return input.sources.first { $0.id == id && !$0.isImage }
    }

    private func syncVideo() {
        let segment = currentSegment
        video.sync(segment: segment, url: currentVideoSource?.url,
                   offset: location?.offset ?? 0, playing: bridge.isPlaying,
                   layout: .init(fitsFrame: segment?.fitsFrame ?? false, offsetX: segment?.offsetX ?? 0,
                                 offsetY: segment?.offsetY ?? 0, renderSize: renderSize))
#if targetEnvironment(macCatalyst)
        video.player.volume = bridge.masterVolume
#endif
    }

    /// 사진 한 장면을 내보내기와 같은 카메라 계획으로 그린다. 직접 정한 구성이 없으면 자동 확대 효과의 해당 시점.
    @ViewBuilder
    private func photoView(_ photo: UIImage, segment: TrailerTimelineSegment) -> some View {
        GeometryReader { proxy in
            let length = max(0.05, segment.length)
            let plan = VideoTrailerImageClip.fallbackCameraMotionPlan(
                imageSize: photo.size, duration: length, renderSize: renderSize,
                sourceIdentity: input.sources.first { $0.id == segment.sourceID }?.name,
                framing: segment.framing)
            let sample = plan.sample(at: (location?.offset ?? 0) / length, in: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(uiImage: photo).resizable()
                    .frame(width: sample.drawSize.width, height: sample.drawSize.height)
                    .offset(x: sample.drawOrigin.x, y: sample.drawOrigin.y)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
    }

    private var videoLayoutKey: String {
        guard let segment = currentSegment else { return "none" }
        return "\(segment.id)|\(segment.fitsFrame)|\(segment.offsetX)|\(segment.offsetY)|\(Int(renderSize.width))x\(Int(renderSize.height))"
    }

    private var location: (index: Int, offset: Double)? { input.location(at: bridge.currentSeconds) }
    private var currentSegment: TrailerTimelineSegment? { location.map { input.segments[$0.index] } }

    private var originalVideoURL: URL? {
        input.sources.first { !$0.isImage }?.url
    }

    private var renderSize: CGSize {
        if let aspectRatio { return aspectRatio.renderSize }
        if let originalVideoURL {
            if let originalVideoSize, originalVideoSize.url == originalVideoURL {
                return OutputAspectRatio.renderSize(for: originalVideoSize.size)
            }
            if let cachedSize = TrailerDraftPreviewCache.shared.videoSize(for: originalVideoURL) {
                return OutputAspectRatio.renderSize(for: cachedSize)
            }
        } else if let firstID = input.segments.compactMap(\.sourceID).first,
                  let image = (currentPhoto?.sourceID == firstID ? currentPhoto?.image : nil) ?? (input.sources.first(where: { $0.id == firstID })?.url).flatMap({ TrailerDraftPreviewCache.shared.photo(for: firstID, url: $0) }) {
            return OutputAspectRatio.renderSize(for: image.size)
        }
        return OutputAspectRatio.landscape16x9.renderSize
    }

    private var attachKey: String {
        "\(input.segments.map { "\($0.id):\($0.length)" }.joined(separator: ","))"
    }

    private var frameKey: String {
        guard let segment = currentSegment else { return "none" }
        switch segment.kind {
        case .intro:
            return "intro|\(segment.id)|\(cardKey(isIntro: true, card: input.introCard, renderSize: renderSize))"
        case .outro:
            return "outro|\(segment.id)|\(cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize))"
        case .clip:
            return "clip|\(segment.id)|\(segment.sourceID ?? -1)|\(segment.start)|\(segment.length)"
        }
    }

    private static func encodeCard(_ card: TrailerTitleCard) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(card), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(card.isEnabled)|\(card.title)|\(card.subtitle)|\(card.duration)|\(card.usesFirstOrLastImage)|\(card.backgroundSourceID ?? -1)|\(card.usesBodyTypography)"
    }

    private static func encodeCaption(_ caption: TrailerCaption?) -> String {
        guard let caption else { return "none" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(caption), let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "\(caption.text)|\(caption.position.rawValue)|\(caption.fontDesign.rawValue)|\(caption.fontSize)|\(caption.colorHex)"
    }

    private var projectSourcesKey: String {
        input.sources.map { "\($0.id):\($0.url.absoluteString)" }.joined(separator: ";")
    }

    private func backgroundKey(isIntro: Bool, card: TrailerTitleCard) -> String {
        if let bgID = card.backgroundSourceID {
            let urlStr = input.sources.first(where: { $0.id == bgID })?.url.absoluteString ?? ""
            return "bgID:\(bgID):\(urlStr)"
        } else if card.usesFirstOrLastImage {
            if isIntro {
                let firstClipSourceID = input.segments.first(where: { $0.kind == .clip })?.sourceID ?? input.sources.first?.id
                let urlStr = input.sources.first(where: { $0.id == firstClipSourceID })?.url.absoluteString ?? ""
                return "introFirst:\(firstClipSourceID ?? -1):\(urlStr)"
            } else {
                let lastClipSourceID = input.segments.last(where: { $0.kind == .clip })?.sourceID ?? input.sources.last?.id
                let urlStr = input.sources.first(where: { $0.id == lastClipSourceID })?.url.absoluteString ?? ""
                return "outroLast:\(lastClipSourceID ?? -1):\(urlStr)"
            }
        } else {
            return "solidColor"
        }
    }

    private func cardKey(isIntro: Bool, card: TrailerTitleCard, renderSize: CGSize) -> String {
        let cardJSON = Self.encodeCard(card)
        let bodyJSON = Self.encodeCaption(input.bodyTypography)
        let bg = backgroundKey(isIntro: isIntro, card: card)
        return "\(projectSourcesKey)|\(isIntro)|\(bg)|\(cardJSON)|\(bodyJSON)|\(Int(renderSize.width))x\(Int(renderSize.height))"
    }

    var body: some View {
        Color.black
            .aspectRatio(renderSize.width / max(1, renderSize.height), contentMode: .fit)
            .overlay {
                if let segment = currentSegment {
                    ZStack {
                        switch segment.kind {
                        case .intro, .outro:
                            let isIntro = segment.kind == .intro
                            let card = isIntro ? input.introCard : input.outroCard
                            let key = cardKey(isIntro: isIntro, card: card, renderSize: renderSize)
                            if let cardImg = cardImage ?? TrailerDraftPreviewCache.shared.card(for: key) {
                                Image(uiImage: cardImg).resizable().scaledToFit()
                            }
                        case .clip:
                            if currentVideoSource != nil {
#if targetEnvironment(macCatalyst)
                                SharedVideoPlayerSurface(
                                    player: video.player,
                                    videoGravity: .resizeAspect,
                                    onScrollVolume: { dy in
                                        handleDraftVolumeScroll(delta: dy)
                                    }
                                )
#else
                                SharedVideoPlayerSurface(player: video.player, videoGravity: .resizeAspect)
#endif
                            } else if let id = segment.sourceID,
                                      let photo = (currentPhoto?.sourceID == id ? currentPhoto?.image : nil) ?? (input.sources.first(where: { $0.id == id })?.url).flatMap({ TrailerDraftPreviewCache.shared.photo(for: id, url: $0) }) {
                                photoView(photo, segment: segment)
                            } else {
                                Image(systemName: "photo").font(.system(size: 36)).foregroundStyle(.white.opacity(0.6))
                            }
                            if let caption = input.captions[segment.id] { CaptionOverlayView(caption: caption) }
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                bridge.togglePlayback()
            }
            .task(id: projectPreparationKey) {
                await performProjectPreparation(signature: projectPreparationKey)
            }
            .task(id: originalVideoURL) {
                guard let url = originalVideoURL else { return }
                if let cached = TrailerDraftPreviewCache.shared.videoSize(for: url) {
                    originalVideoSize = (url, cached)
                    return
                }
                guard let size = try? await trailerOrientedVideoSize(url: url),
                      size.width > 0, size.height > 0, !Task.isCancelled else { return }
                TrailerDraftPreviewCache.shared.setVideoSize(size, for: url)
                originalVideoSize = (url, size)
            }
            .task(id: frameKey) {
                await loadFrame()
            }
            .task(id: attachKey) { await runClock() }
            .task(id: input.musicKey) {
                await music.prepare(input)
                // 준비가 끝난 시점의 재생 위치로 바로 이어 붙는다(재생 중에 음악을 바꾼 경우).
                music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
#if targetEnvironment(macCatalyst)
                music.player.volume = bridge.masterVolume
#endif
            }
            .onChange(of: bridge.currentSeconds) { _, _ in syncVideo(); music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying) }
            .onChange(of: videoLayoutKey) { _, _ in syncVideo() }
            .onChange(of: bridge.isPlaying) { _, _ in syncVideo(); music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying) }
            .overlay(alignment: .center) {
#if targetEnvironment(macCatalyst)
                if let volume = draftVolumeHUD {
                    volumeHUD(volume)
                        .transition(.scale.combined(with: .opacity))
                }
#endif
                if isPreparingPreview, let progress = preparationProgress {
                    VStack(spacing: 8) {
                        Text("미리보기 준비 중…")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white)
                        ProgressView(value: progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 140)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.75)))
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                if let failure = music.failure {
                    Text("배경음악을 미리 들을 수 없어요 · \(failure)")
                        .font(.caption).foregroundStyle(.white)
                        .padding(6).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(8)
                }
            }
            .onDisappear { video.stop(); music.stop() }
            .onChange(of: input.selectedSceneID) { _, id in
                guard !bridge.isPlaying, let id, let start = input.startSeconds(ofScene: id) else { return }
                bridge.currentSeconds = start
            }
    }

    private var projectPreparationKey: String {
        let segKey = input.segments.map { "\($0.id):\($0.sourceID ?? -1):\($0.start):\($0.length):\($0.fitsFrame):\($0.offsetX):\($0.offsetY)" }.joined(separator: ";")
        let introKey = cardKey(isIntro: true, card: input.introCard, renderSize: renderSize)
        let outroKey = cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize)
        return "\(segKey)|\(projectSourcesKey)|\(input.musicKey)|\(introKey)|\(outroKey)|\(Int(renderSize.width))x\(Int(renderSize.height))"
    }

    private func performProjectPreparation(signature: String) async {
        guard !TrailerDraftPreviewCache.shared.isPrepared(signature: signature) else {
            isPreparingProject = false
            preparationProgress = nil
            return
        }

        preparationGeneration += 1
        let generation = preparationGeneration
        activePreparationSignature = signature

        defer {
            if preparationGeneration == generation {
                isPreparingProject = false
                preparationProgress = nil
                activePreparationSignature = nil
            }
        }

        var totalSteps = 0
        let refVideoURL = originalVideoURL
        if let refVideoURL, TrailerDraftPreviewCache.shared.videoSize(for: refVideoURL) == nil {
            totalSteps += 1
        }
        if input.music != nil {
            totalSteps += 1
        }
        let introNeeded = input.segments.contains { $0.kind == .intro }
        let introKey = cardKey(isIntro: true, card: input.introCard, renderSize: renderSize)
        if introNeeded, TrailerDraftPreviewCache.shared.card(for: introKey) == nil {
            totalSteps += 1
        }
        let outroNeeded = input.segments.contains { $0.kind == .outro }
        let outroKey = cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize)
        if outroNeeded, TrailerDraftPreviewCache.shared.card(for: outroKey) == nil {
            totalSteps += 1
        }

        let photoSegments = input.segments.filter { $0.kind == .clip }
        let byID = Dictionary(input.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pendingPhotos: [(Int, URL)] = []
        for seg in photoSegments {
            if let id = seg.sourceID, let src = byID[id], src.isImage {
                if TrailerDraftPreviewCache.shared.photo(for: src.id, url: src.url) == nil,
                   !pendingPhotos.contains(where: { $0.0 == src.id }) {
                    pendingPhotos.append((src.id, src.url))
                }
            }
        }
        totalSteps += pendingPhotos.count

        var pendingVideoLayouts: [(URL, TrailerDraftVideoDriver.Layout)] = []
        for seg in photoSegments {
            if let id = seg.sourceID, let src = byID[id], !src.isImage {
                let layout = TrailerDraftVideoDriver.Layout(fitsFrame: seg.fitsFrame, offsetX: seg.offsetX, offsetY: seg.offsetY, renderSize: renderSize)
                let key = TrailerDraftVideoDriver.compositionKey(url: src.url, layout: layout)
                if TrailerDraftPreviewCache.shared.videoComposition(for: key) == nil,
                   !pendingVideoLayouts.contains(where: { $0.0 == src.url && $0.1 == layout }) {
                    pendingVideoLayouts.append((src.url, layout))
                }
            }
        }
        totalSteps += pendingVideoLayouts.count

        if totalSteps == 0 {
            TrailerDraftPreviewCache.shared.markPrepared(signature: signature)
            isPreparingProject = false
            preparationProgress = nil
            return
        }

        isPreparingProject = true
        preparationProgress = 0.0
        var completed = 0
        var failedAssets = 0

        func stepDone() {
            completed += 1
            if preparationGeneration == generation && activePreparationSignature == signature {
                preparationProgress = min(1.0, Double(completed) / Double(max(1, totalSteps)))
            }
        }

        if let refVideoURL, TrailerDraftPreviewCache.shared.videoSize(for: refVideoURL) == nil {
            if let size = try? await trailerOrientedVideoSize(url: refVideoURL), size.width > 0, size.height > 0 {
                TrailerDraftPreviewCache.shared.setVideoSize(size, for: refVideoURL)
                if preparationGeneration == generation && activePreparationSignature == signature {
                    originalVideoSize = (refVideoURL, size)
                }
            } else {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        if introNeeded, TrailerDraftPreviewCache.shared.card(for: introKey) == nil {
            let scale = min(1, 960 / max(renderSize.width, renderSize.height))
            let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
            if let img = TrailerTitleCardRenderer.renderCardImage(
                card: input.introCard,
                sourceImage: input.introCard.usesFirstOrLastImage ? input.introBackground : nil,
                renderSize: size,
                bodyTypography: input.introCard.usesBodyTypography ? input.bodyTypography : nil
            ) {
                TrailerDraftPreviewCache.shared.setCard(img, for: introKey)
                if preparationGeneration == generation && activePreparationSignature == signature && currentSegment?.kind == .intro {
                    cardImage = img
                }
            } else {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        if outroNeeded, TrailerDraftPreviewCache.shared.card(for: outroKey) == nil {
            let scale = min(1, 960 / max(renderSize.width, renderSize.height))
            let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
            if let img = TrailerTitleCardRenderer.renderCardImage(
                card: input.outroCard,
                sourceImage: input.outroCard.usesFirstOrLastImage ? input.outroBackground : nil,
                renderSize: size,
                bodyTypography: input.outroCard.usesBodyTypography ? input.bodyTypography : nil
            ) {
                TrailerDraftPreviewCache.shared.setCard(img, for: outroKey)
                if preparationGeneration == generation && activePreparationSignature == signature && currentSegment?.kind == .outro {
                    cardImage = img
                }
            } else {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        for (sourceID, url) in pendingPhotos {
            if let img = await trailerThumbnailImage(at: url, maxPixelSize: 1280) {
                TrailerDraftPreviewCache.shared.setPhoto(img, for: sourceID, url: url)
                if preparationGeneration == generation && activePreparationSignature == signature {
                    photoCacheRevision += 1
                    if currentSegment?.sourceID == sourceID {
                        currentPhoto = (sourceID, img)
                    }
                }
            } else {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        for (url, layout) in pendingVideoLayouts {
            let comp = await TrailerDraftVideoDriver.prepareComposition(url: url, layout: layout)
            if comp == nil {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        if input.music != nil {
            await music.prepare(input)
            if preparationGeneration == generation && activePreparationSignature == signature {
                music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
#if targetEnvironment(macCatalyst)
                music.player.volume = bridge.masterVolume
#endif
            }
            if music.failure != nil {
                failedAssets += 1
            }
            guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
            stepDone()
        }

        guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
        if failedAssets == 0 {
            TrailerDraftPreviewCache.shared.markPrepared(signature: signature)
        }
        failedAssetCount = failedAssets
        isPreparingProject = false
        preparationProgress = nil
    }

    private func loadFrame() async {
        guard let segment = currentSegment else {
            cardImage = nil
            currentPhoto = nil
            return
        }
        switch segment.kind {
        case .intro, .outro:
            currentPhoto = nil
            let isIntro = segment.kind == .intro
            let card = isIntro ? input.introCard : input.outroCard
            let key = cardKey(isIntro: isIntro, card: card, renderSize: renderSize)
            if let cached = TrailerDraftPreviewCache.shared.card(for: key) {
                cardImage = cached
            } else {
                let scale = min(1, 960 / max(renderSize.width, renderSize.height))
                let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
                let rendered = TrailerTitleCardRenderer.renderCardImage(
                    card: card,
                    sourceImage: card.usesFirstOrLastImage ? (isIntro ? input.introBackground : input.outroBackground) : nil,
                    renderSize: size,
                    bodyTypography: card.usesBodyTypography ? input.bodyTypography : nil
                )
                if let rendered {
                    TrailerDraftPreviewCache.shared.setCard(rendered, for: key)
                }
                cardImage = rendered
            }
        case .clip:
            cardImage = nil
            guard let id = segment.sourceID,
                  let source = input.sources.first(where: { $0.id == id }), source.isImage else {
                currentPhoto = nil
                return
            }
            if currentPhoto?.sourceID == id { return }
            if let cached = TrailerDraftPreviewCache.shared.photo(for: id, url: source.url) {
                currentPhoto = (id, cached)
            } else if let image = await trailerThumbnailImage(at: source.url, maxPixelSize: 1280), !Task.isCancelled {
                TrailerDraftPreviewCache.shared.setPhoto(image, for: id, url: source.url)
                if !Task.isCancelled, currentSegment?.sourceID == id {
                    currentPhoto = (id, image)
                }
            }
        }
    }

    private func runClock() async {
        let total = input.totalDuration
        guard total > 0 else { return }
        let token = UUID()
        bridge.owner = token
        bridge.seekHandler = { [weak bridge] seconds in bridge?.currentSeconds = min(max(seconds, 0), total) }
        bridge.pauseHandler = { [weak bridge] in bridge?.isPlaying = false }
        bridge.playHandler = { [weak bridge] in
            guard let bridge else { return }
            if bridge.currentSeconds >= total - 0.01 { bridge.currentSeconds = 0 }
            bridge.isPlaying = true
        }
        bridge.durationSeconds = total
        let preservedTime = bridge.currentSeconds
        let wasPlaying = bridge.isPlaying
        if preservedTime <= 0 || preservedTime > total {
            let start = input.selectedSceneID.flatMap { input.startSeconds(ofScene: $0) } ?? 0
            bridge.currentSeconds = min(max(start, 0), total)
        }
        bridge.isPlaying = wasPlaying
        bridge.hasPlayer = true
        // The selected clip can already be at this time. In that case no change
        // handler runs, so attach its video before waiting for playback.
        syncVideo()
        music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
#if targetEnvironment(macCatalyst)
        video.player.volume = bridge.masterVolume
        music.player.volume = bridge.masterVolume
#endif
        var last = Date()
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(33))
            let now = Date()
            defer { last = now }
            guard bridge.isPlaying else { continue }
            let next = bridge.currentSeconds + now.timeIntervalSince(last)
            if next >= total {
                bridge.currentSeconds = total
                bridge.isPlaying = false
            } else {
                bridge.currentSeconds = next
            }
        }
        bridge.detach(ifOwner: token)
    }

#if targetEnvironment(macCatalyst)
    private func handleDraftVolumeScroll(delta: CGFloat) {
        let current = bridge.masterVolume
        let gain: Float = 1.0 / 360.0
        let target = min(max(current + Float(delta) * gain, 0), 1)
        bridge.masterVolume = target
        video.player.volume = target
        music.player.volume = target
        draftVolumeDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.12)) {
            draftVolumeHUD = target
        }
        draftVolumeDismissTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                draftVolumeHUD = nil
            }
        }
    }

    @ViewBuilder
    private func volumeHUD(_ volume: Float) -> some View {
        HStack(spacing: 9) {
            Image(interfaceSystemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit()
        }
        .font(.system(size: 17, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .allowsHitTesting(false)
    }
#endif
}
