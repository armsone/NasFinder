import AVFoundation
import CryptoKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
        // 직접 옮긴 장면은 순서 의도만 표시한다(시간은 계속 자동). 밀려난 이웃은 값이 그대로라 표시를 바꾸지 않는다.
        scenes[to].manual.insert(.order)
    }

    static func duplicate(_ id: Int, in scenes: inout [TrailerEditScene], nextID: inout Int) -> Int? {
        guard let at = index(of: id, in: scenes) else { return nil }
        var copy = scenes[at]
        copy.id = nextID
        copy.excluded = false
        copy.budgetExcluded = false
        // 사용자가 만든 복제본: 포함·순서 의도만 표시하고 원래 장면의 표시는 그대로 이어받는다(시간을 괜히 고정하지 않는다).
        copy.manual.formUnion([.order, .exclusion])
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
        // 순서가 실제로 바뀔 때만 옮긴 장면을 보호한다. 제자리 이동은 아무것도 바꾸지 않는다.
        guard result.map(\.id) != scenes.map(\.id) else { return }
        for index in result.indices where ids.contains(result[index].id) { result[index].manual.insert(.order) }
        scenes = result
    }

    /// 소스 순서(촬영순·추가순·랜덤)를 실제 장면 타임라인에 적용한다.
    /// 각 소스 내부의 다중 구간은 시작 시각(start) 오름차순(동률이면 기존 상대 순서)으로 정렬하며 보호 구간·트리밍·제외·예산 제외·자막 설정은 그대로 보존한다.
    static func reorderScenesBySourceOrder(scenes: [TrailerEditScene], sourceIDs: [Int]) -> [TrailerEditScene] {
        guard !scenes.isEmpty, !sourceIDs.isEmpty else { return scenes }
        var buckets: [Int: [(offset: Int, scene: TrailerEditScene)]] = [:]
        for (offset, scene) in scenes.enumerated() {
            buckets[scene.sourceID, default: []].append((offset, scene))
        }
        func sortedScenes(_ group: [(offset: Int, scene: TrailerEditScene)]) -> [TrailerEditScene] {
            group.sorted { lhs, rhs in
                if lhs.scene.start != rhs.scene.start {
                    return lhs.scene.start < rhs.scene.start
                }
                return lhs.offset < rhs.offset
            }.map(\.scene)
        }
        var seenSources = Set<Int>()
        var reordered: [TrailerEditScene] = []
        reordered.reserveCapacity(scenes.count)
        for sourceID in sourceIDs where seenSources.insert(sourceID).inserted {
            if let group = buckets[sourceID] {
                reordered.append(contentsOf: sortedScenes(group))
            }
        }
        for scene in scenes where seenSources.insert(scene.sourceID).inserted {
            if let group = buckets[scene.sourceID] {
                reordered.append(contentsOf: sortedScenes(group))
            }
        }
        // 사용자가 고른 순서로 자리가 바뀐 장면은 순서 의도를 표시한다. 자리가 그대로인 장면은 값을 바꾸지 않는다.
        if reordered.count == scenes.count {
            for index in reordered.indices where reordered[index].id != scenes[index].id {
                reordered[index].manual.insert(.order)
            }
        }
        return reordered
    }

    /// 직접 편집한 흔적(시간·소리·화면 구성·자막·순서·포함/제외, 또는 전체 보호)이 하나라도 있으면 장면 목록이 곧 최종 계획이다.
    /// 미리보기와 내보내기가 같은 목록을 그대로 쓰므로 음악 길이 맞춤의 두 번째 맞춤(`VideoTrailerBatchPlan.fitted`의 반복·꼬리 자르기)이
    /// 사용자가 고친 장면을 다시 정하거나 반복하거나 빼지 못한다. 길이는 목록을 만드는 쪽(`fitScenesToBudget` 등)이 정하고 렌더는 그 결과 그대로 만든다.
    /// 제외된 장면도 센다(사용자가 뺀 의도가 목록에 이미 들어 있다). 예산이 뺀 장면(`budgetExcluded`만 있는 순수 자동)은 직접 편집이 아니다.
    /// 모든 장면이 순수 자동이면 false: 원래의 음악 길이 맞춤 반복 규칙이 그대로 의도된 동작이다.
    static func keepsManualScenesAsIs(_ scenes: [TrailerEditScene]?) -> Bool {
        guard let scenes else { return false }
        return scenes.contains { !$0.isPureAutomatic }
    }

    /// 포함된 시간 고정 장면의 길이 합(유한하지 않은 길이는 0).
    static func protectedIncludedTotal(_ scenes: [TrailerEditScene]) -> Double {
        scenes.filter { !$0.excluded && $0.timingProtected }
            .reduce(0.0) { $0 + ($1.length.isFinite ? max(0, $1.length) : 0) / outputRate($1) }
    }

    // MARK: 출력 시간표 (배속·디졸브·카드)

    /// 장면의 출력 배속(합성기와 같은 규칙: 0.25...4 밖이면 1).
    static func outputRate(_ scene: TrailerEditScene) -> Double {
        let rate = scene.adjustments?.rate ?? 1
        return rate.isFinite && rate >= 0.25 && rate <= 4 ? rate : 1
    }

    /// 포함된 장면 사이(그리고 마지막 장면과 마지막 화면 사이)에서 실제로 겹치는 길이의 합.
    /// 미리보기·내보내기 합성기와 같은 시간표 팩토리가 겹침을 자른다(삼중 겹침 금지, 이웃 길이 안). 겹친 구간은 출력에서 한 번만 센다.
    static func bodyOverlapTotal(_ scenes: [TrailerEditScene], outroLength: Double = 0) -> Double {
        var inputs: [TrailerClipInput] = []
        for scene in scenes where !scene.excluded && scene.length.isFinite && scene.length > 0.0001 {
            inputs.append(TrailerClipInput(sceneID: inputs.count, sourceID: scene.sourceID, sourceStart: max(0, scene.start),
                                           sourceLength: scene.length, rate: outputRate(scene),
                                           requestedOutgoingOverlap: scene.adjustments?.transition?.dissolveDuration ?? 0))
        }
        guard !inputs.isEmpty, inputs.contains(where: { $0.requestedOutgoingOverlap > 0 }) else { return 0 }
        if outroLength.isFinite, outroLength > 0.0001 {
            inputs.append(TrailerClipInput(sceneID: inputs.count, sourceID: -2, sourceStart: 0, sourceLength: outroLength))
        }
        guard let maps = try? TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs) else { return 0 }
        return maps.reduce(0.0) { $0 + $1.outgoingOverlap }
    }

    /// 포함 장면의 출력 길이 합(배속 반영) 빼기 겹침. 카드는 뺀 본편 길이이며 최종 길이는 여기에 카드 길이를 더한다.
    static func outputBodyDuration(_ scenes: [TrailerEditScene], outroLength: Double = 0) -> Double {
        let raw = scenes.filter { !$0.excluded }.reduce(0.0) {
            $0 + ($1.length.isFinite ? max(0, $1.length) : 0) / outputRate($1)
        }
        return max(0, raw - bodyOverlapTotal(scenes, outroLength: outroLength))
    }

    /// 계획 장면(`VideoTrailerScene`) 목록의 본편 출력 길이(배속 반영, 겹침은 한 번만 뺌). 미리보기·내보내기와 같은 시간표 팩토리를 쓴다.
    static func outputBodyDuration(planned: [VideoTrailerScene], outroLength: Double = 0) -> Double {
        let valid = planned.filter { $0.length.isFinite && $0.length > 0.0001 }
        var inputs = valid.enumerated().map { index, scene in
            TrailerClipInput(sceneID: index, sourceID: scene.sourceID, sourceStart: max(0, scene.start), sourceLength: scene.length,
                             rate: scene.adjustments?.rate ?? 1,
                             requestedOutgoingOverlap: scene.adjustments?.transition?.dissolveDuration ?? 0)
        }
        let raw = valid.reduce(0.0) { $0 + $1.outputLength }
        guard !inputs.isEmpty, inputs.contains(where: { $0.requestedOutgoingOverlap > 0 }) else { return raw }
        if outroLength.isFinite, outroLength > 0.0001 {
            inputs.append(TrailerClipInput(sceneID: inputs.count, sourceID: -2, sourceStart: 0, sourceLength: outroLength))
        }
        guard let maps = try? TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs) else { return raw }
        return max(0, raw - maps.reduce(0.0) { $0 + $1.outgoingOverlap })
    }

    /// 포함 장면 중 가장 이른 순서의 장면부터 센 출력 시작 시각(겹침 반영). 합성기와 같은 팩토리를 쓴다.
    static func outputStarts(_ scenes: [TrailerEditScene]) -> [Int: Double] {
        let included = scenes.filter { !$0.excluded && $0.length.isFinite && $0.length > 0.0001 }
        let inputs = included.enumerated().map { index, scene in
            TrailerClipInput(sceneID: index, sourceID: scene.sourceID, sourceStart: max(0, scene.start), sourceLength: scene.length,
                             rate: outputRate(scene), requestedOutgoingOverlap: scene.adjustments?.transition?.dissolveDuration ?? 0)
        }
        guard let maps = try? TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs) else { return [:] }
        var result: [Int: Double] = [:]
        for (scene, map) in zip(included, maps) { result[scene.id] = map.outputStart }
        return result
    }

    /// 음악 길이 맞춤의 실제 영상 길이(카드 포함). 목록이 최종 계획이면(`keepsManualScenesAsIs`) 포함 장면 길이 합 + 카드가 곧 길이다.
    /// 음악보다 짧아도 길어도 그 값이며 음악 예산(`fitted`)보다 길거나 짧다고 주장하지 않는다. 그 밖에는 음악 예산 그대로다.
    static func effectiveFitDuration(fitted: Double, scenes: [TrailerEditScene]?, cardsDuration: Double, outroLength: Double = 0) -> Double {
        let cards = cardsDuration.isFinite ? max(0, cardsDuration) : 0
        guard let scenes, keepsManualScenesAsIs(scenes) else { return fitted }
        let actual = outputBodyDuration(scenes, outroLength: outroLength)
        return actual > 0 ? actual + cards : fitted
    }

    /// 지정한 장면 중 포함된 장면의 보호 상태를 센다. 추천이 바꿀 수 있는 장면(`eligible`)과 이미 보호된 장면(`protected`).
    static func automationCounts(ids: Set<Int>, in scenes: [TrailerEditScene]) -> (eligible: Int, protected: Int, excluded: Int) {
        var eligible = 0, locked = 0, excluded = 0
        for scene in scenes where ids.contains(scene.id) {
            if scene.excluded { excluded += 1 } else if scene.timingProtected { locked += 1 } else { eligible += 1 }
        }
        return (eligible, locked, excluded)
    }

    /// 사용자가 직접 고른 장면의 전체 보호를 켜거나 끈다(잠금/잠금 해제). 바뀐 장면 수를 돌려준다.
    /// 잠금은 `automationProtected`를 켠다. 해제는 그 표시와 시간·순서·제외 표시를 지우되, 이미 가진 자막·소리·화면 구성 값은
    /// 계속 직접 편집한 내용으로 남긴다(값은 바꾸지 않는다).
    @discardableResult
    static func setAutomationProtected(_ isProtected: Bool, ids: Set<Int>, in scenes: inout [TrailerEditScene]) -> Int {
        var changed = 0
        for index in scenes.indices where ids.contains(scenes[index].id) {
            let before = scenes[index]
            if isProtected {
                scenes[index].automationProtected = true
            } else {
                var content: TrailerManualFields = before.manual.intersection(.content)
                if before.automationProtected {
                    if before.caption != nil { content.insert(.caption) }
                    if before.muted || before.volume != 1 { content.insert(.audio) }
                    if before.hasCustomFraming { content.insert(.framing) }
                }
                scenes[index].automationProtected = false
                scenes[index].manual = content
            }
            if scenes[index] != before { changed += 1 }
        }
        return changed
    }

    /// `ids` 밖의 장면은 잠시 전부 보호된 것으로 두고 `body`를 실행한 뒤, 그 장면들을 `body` 전의 값·표시 그대로 되돌린다.
    /// 길이·예산 맞춤 같은 전체 연산이 선택한 장면 밖의 장면을 값이든 표시든 바꾸지 못하게 한다(선택 안의 장면 결과만 남는다).
    /// `body`는 장면을 지우거나 id를 바꾸거나 순서를 바꾸지 않아야 한다.
    static func freezing(except ids: Set<Int>, in scenes: inout [TrailerEditScene], _ body: (inout [TrailerEditScene]) -> Void) {
        let originals = Dictionary(scenes.filter { !ids.contains($0.id) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in scenes.indices where originals[scenes[index].id] != nil { scenes[index].automationProtected = true }
        body(&scenes)
        for index in scenes.indices {
            if let original = originals[scenes[index].id] { scenes[index] = original }
        }
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
                copy.budgetExcluded = false
                copy.manual.formUnion([.order, .exclusion])
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
                scenes[at].budgetExcluded = false
                scenes[at].manual.insert(.exclusion)
            }
        }
    }

    /// 두 장면 값을 비교해 실제로 바뀐 필드만 돌려준다(시간: start/length/동작 구간, 소리: muted/volume, 화면 구성: fit/offset,
    /// 자막, 제외: excluded). 예산 제외 표시만 달라진 것은 사용자의 편집이 아니므로 세지 않는다.
    static func changedManualFields(from before: TrailerEditScene, to after: TrailerEditScene) -> TrailerManualFields {
        var fields: TrailerManualFields = []
        if before.start != after.start || before.length != after.length
            || before.actionStart != after.actionStart || before.actionEnd != after.actionEnd { fields.insert(.timing) }
        if before.muted != after.muted || before.volume != after.volume { fields.insert(.audio) }
        if before.fitsFrame != after.fitsFrame || before.offsetX != after.offsetX || before.offsetY != after.offsetY { fields.insert(.framing) }
        if before.caption != after.caption { fields.insert(.caption) }
        // 고급 편집: 배속·디졸브는 값만 보존한다(시간 창 전체를 고정하는 `.timing`은 직접 트림·분할만 켠다).
        // 색상·키프레임은 화면 구성, 자막 큐는 자막을 직접 고친 것이다. 직접 놓은 큐·키프레임 구간은 `protectedSpan` 앵커로 지켜진다.
        let oldAdjust = before.adjustments ?? TrailerClipAdjustments(), newAdjust = after.adjustments ?? TrailerClipAdjustments()
        if oldAdjust.rate != newAdjust.rate || oldAdjust.transition != newAdjust.transition { fields.insert(.adjust) }
        if oldAdjust.color != newAdjust.color || oldAdjust.keyframes != newAdjust.keyframes { fields.insert(.framing) }
        if oldAdjust.cues != newAdjust.cues || oldAdjust.suppressions != newAdjust.suppressions { fields.insert(.caption) }
        if before.excluded != after.excluded { fields.insert(.exclusion) }
        return fields
    }

    /// 인스펙터·자막 등 직접 고치는 모든 경로가 쓰는 한 장면 변경. 값이 실제로 바뀐 필드만 직접 편집으로 표시한다
    /// (자막만 고치면 자막, 음량이면 소리 등). 전체 보호(`automationProtected`)는 켜지 않으므로 나머지 시간은 계속 자동이다.
    /// 호출한 변경이 보호·표시를 스스로 정했다면(되돌리기·잠금 해제 등) 그 값을 따른다.
    static func update(_ id: Int, in scenes: inout [TrailerEditScene], _ change: (inout TrailerEditScene) -> Void) {
        guard let at = index(of: id, in: scenes) else { return }
        let before = scenes[at]
        change(&scenes[at])
        guard scenes[at].automationProtected == before.automationProtected, scenes[at].manual == before.manual else { return }
        let fields = changedManualFields(from: before, to: scenes[at])
        scenes[at].manual.formUnion(fields)
        if fields.contains(.exclusion) { scenes[at].budgetExcluded = false }
    }

    /// 자동 생성된 자막 큐를 한 장면에 병합한다. 직접 고친 큐·지운 구간(tombstone)은 그 시점의 최신 값 그대로 지키고,
    /// 건드리지 않은 이전 자동 큐는 새 결과로 바뀐다. 사용자가 편집한 것이 아니므로 `manual` 표시는 켜지 않는다(자막 보호로 승격하지 않는다).
    /// 장면이 사라졌으면 false.
    @discardableResult
    static func mergeGeneratedCues(_ generated: [TrailerTimedCaptionCue], intoSceneID id: Int, in scenes: inout [TrailerEditScene]) -> Bool {
        guard let at = index(of: id, in: scenes) else { return false }
        var value = scenes[at].adjustments ?? TrailerClipAdjustments()
        value.cues = TrailerTimedCaptionCue.merge(existingCues: value.cues, newGeneratedCues: generated, suppressions: value.suppressions)
        scenes[at].adjustments = value == TrailerClipAdjustments() ? nil : value
        return true
    }

    /// 직접 트림: 장면의 원본 시작 위치와 길이를 `start`/`length`로 바꾼다. 영상은 원본 안(0...원본 길이)이며 최소 길이 이상이어야 하고,
    /// 사진은 표시 시간(길이)만 바뀐다(`start`는 쓰지 않는다). 유한하지 않거나 범위를 벗어나거나 실제로 바뀌는 게 없으면 false이고 장면은 그대로다.
    /// 사용자가 직접 고른 창이므로 동작 보호 구간은 지우고 시간만 직접 편집으로 표시한다. 원본 미디어는 바꾸지 않는다.
    @discardableResult
    static func trim(_ id: Int, start: Double, length: Double, source: VideoTrailerSource?,
                     in scenes: inout [TrailerEditScene]) -> Bool {
        guard let at = index(of: id, in: scenes), let source, source.id == scenes[at].sourceID,
              start.isFinite, length.isFinite, length > 0 else { return false }
        let scene = scenes[at]
        let eps = 1e-9
        // 동작 보호 구간은 직접 트림을 막지 못한다. 그 구간 없이 계산한 범위를 쓴다.
        var probe = scene
        probe.actionStart = nil
        probe.actionEnd = nil
        probe.adjustments = nil
        let bounds = sceneDurationBounds(scene: probe, source: source)
        if source.isImage {
            guard length >= bounds.minimum - eps, length <= bounds.maximum + eps else { return false }
            let clamped = min(bounds.maximum, max(bounds.minimum, length))
            guard abs(clamped - scene.length) > eps else { return false }
            scenes[at].length = clamped
            scenes[at].manual.insert(.timing)
            return true
        }
        let duration = source.duration
        guard duration.isFinite, duration > 0,
              start >= -eps, length >= bounds.minimum - eps, start + length <= duration + eps else { return false }
        let newLength = min(length, duration)
        let newStart = min(max(0, start), max(0, duration - newLength))
        guard abs(newStart - scene.start) > eps || abs(newLength - scene.length) > eps else { return false }
        scenes[at].start = newStart
        scenes[at].length = newLength
        scenes[at].actionStart = nil
        scenes[at].actionEnd = nil
        scenes[at].manual.insert(.timing)
        return true
    }

    /// 장면을 장면 안 시각 `atLocalTime`(장면 시작 기준 초, 영상은 원본 시간)에서 둘로 나눈다. 앞 조각은 원래 id를 지키고 뒤 조각은 바로 뒤에
    /// 새 id로 들어간다. 영상은 원본 구간을 둘로, 사진은 표시 시간을 둘로 나누며 각 조각은 기존 최소 길이(영상 `min(0.2, 원본)`, 사진 1/30초) 이상이어야 한다.
    /// 소스·자막·소리·프레이밍·제외와 기존 직접 편집 표시는 두 조각이 그대로 갖고, 동작 보호 구간은 지우며, 두 조각 모두 시간을 직접 정한 것으로 표시한다. 속도 모델은 없다.
    /// 새 id는 `nextID`부터 `scenes`에 없는 첫 값이다. 거절하면 nil이고 `scenes`와 `nextID`는 그대로다.
    @discardableResult
    static func split(_ id: Int, atLocalTime time: Double, source: VideoTrailerSource?,
                      in scenes: inout [TrailerEditScene], nextID: inout Int) -> Int? {
        guard let at = index(of: id, in: scenes), let source, source.id == scenes[at].sourceID,
              time.isFinite, scenes[at].length.isFinite, scenes[at].length > 0 else { return nil }
        let scene = scenes[at]
        let eps = 1e-9
        var probe = scene
        probe.actionStart = nil
        probe.actionEnd = nil
        probe.adjustments = nil
        let minimum = sceneDurationBounds(scene: probe, source: source).minimum
        guard time >= minimum - eps, scene.length - time >= minimum - eps else { return nil }
        if !source.isImage {
            let duration = source.duration
            guard duration.isFinite, duration > 0, scene.start.isFinite, scene.start >= -eps,
                  scene.start + scene.length <= duration + eps else { return nil }
        }
        var newID = max(1, nextID)
        let used = Set(scenes.map(\.id))
        while used.contains(newID) { newID += 1 }
        var first = scene
        var second = scene
        second.id = newID
        first.length = time
        second.length = scene.length - time
        if !source.isImage {
            second.start = scene.start + time
            first.actionStart = nil
            first.actionEnd = nil
            second.actionStart = nil
            second.actionEnd = nil
        }
        // 두 조각 모두 시간이 직접 정해진 것이다. 기존 표시(자막·소리 등)는 그대로 이어받고, 새 조각은 포함·순서 의도도 갖는다.
        first.manual.insert(.timing)
        second.manual.formUnion([.timing, .order, .exclusion])
        scenes[at] = first
        scenes.insert(second, at: at + 1)
        nextID = newID + 1
        return newID
    }

    enum TrimEdge: Equatable { case start, end }

    /// 손잡이를 `delta`초 끌었을 때의 다듬은 창(원본 시작 위치와 길이). 영상은 원본 안(0...원본 길이)과 최소 길이로, 사진은 표시 시간 범위로
    /// 잘라 내며 어느 쪽 손잡이든 사진은 표시 시간만 바뀐다. 장면은 바꾸지 않고, 계산할 수 없으면 nil이다. 실제 적용은 `trim`이 다시 확인한다.
    /// `outputDelta`는 타임라인에서 끈 거리(출력 초)다. 배속이 있으면 원본에서는 그 배속만큼 더 움직이므로 원본 초로 바꿔 적용한다.
    static func trimCandidate(_ scene: TrailerEditScene, edge: TrimEdge, by outputDelta: Double,
                              source: VideoTrailerSource?) -> (start: Double, length: Double)? {
        let delta = outputDelta * outputRate(scene)
        guard let source, source.id == scene.sourceID, delta.isFinite, scene.length.isFinite, scene.start.isFinite else { return nil }
        var probe = scene
        probe.actionStart = nil
        probe.actionEnd = nil
        probe.adjustments = nil
        let bounds = sceneDurationBounds(scene: probe, source: source)
        if source.isImage {
            let proposed = edge == .end ? scene.length + delta : scene.length - delta
            return (scene.start, min(bounds.maximum, max(bounds.minimum, proposed)))
        }
        let duration = source.duration
        guard duration.isFinite, duration > 0 else { return nil }
        let end = scene.start + scene.length
        switch edge {
        case .start:
            let start = min(max(0, scene.start + delta), max(0, end - bounds.minimum))
            return (start, end - start)
        case .end:
            let newEnd = min(duration, max(scene.start + bounds.minimum, end + delta))
            return (scene.start, newEnd - scene.start)
        }
    }

    /// 장면 안 시각 `time`에서 나눌 수 있는지. 실제 `split`과 같은 규칙을 한 장면짜리 복사본에 시험해 본다(원본 목록은 바꾸지 않는다).
    static func canSplit(_ id: Int, atLocalTime time: Double, source: VideoTrailerSource?, in scenes: [TrailerEditScene]) -> Bool {
        guard let at = index(of: id, in: scenes) else { return false }
        var probe = [scenes[at]]
        var nextID = scenes.map(\.id).max().map { $0 + 1 } ?? 1
        return split(id, atLocalTime: time, source: source, in: &probe, nextID: &nextID) != nil
    }

    /// 포함된(제외되지 않은) 이웃 장면 하나 앞(`step` < 0) 또는 뒤(`step` > 0)로 옮긴다. 제외된 장면은 건너뛴다. 옮겼으면 true이고 그 장면은 보호된다.
    @discardableResult
    static func moveIncluded(_ id: Int, step: Int, in scenes: inout [TrailerEditScene]) -> Bool {
        guard step != 0, let from = index(of: id, in: scenes), !scenes[from].excluded else { return false }
        let neighbor = step < 0
            ? scenes[..<from].lastIndex { !$0.excluded }
            : scenes[(from + 1)...].firstIndex { !$0.excluded }
        guard let neighbor else { return false }
        let before = scenes.map(\.id)
        moveScenes(ids: [id], toOneBasedPosition: neighbor + 1, in: &scenes)
        return scenes.map(\.id) != before
    }

    /// 지정한 장면 중 시간이 고정되지 않은 포함 장면만 현재 추천 계획으로 제자리에서 다시 맞춘다. 자막·소리만 고친 장면의 시간은 다시 맞춘다.
    /// 장면 순서·id와 자막·소리·프레이밍·제외는 그대로다.
    /// 영상은 소스의 `plan.proposal`이 주는 창(같은 소스의 대상 장면이 여럿이면 목록 순서대로 서로 다른 구역의 창)과 그 동작 보호 구간,
    /// 사진은 `weightedImageLength`로 길이만 다시 정한다. 소스가 없거나 유효하지 않은 장면은 건너뛰고, 보호된 장면은 절대 건드리지 않는다.
    /// 바뀐 장면 수를 돌려준다.
    @discardableResult
    static func refreshAutomaticScenes(ids: Set<Int>, sources: [VideoTrailerSource], clipLength: Double,
                                       in scenes: inout [TrailerEditScene]) -> Int {
        guard !ids.isEmpty, clipLength.isFinite, clipLength > 0 else { return 0 }
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let eps = 1e-9
        let targets = scenes.indices.filter { ids.contains(scenes[$0].id) && !scenes[$0].timingProtected && !scenes[$0].excluded }
        var perSource: [Int: [Int]] = [:]
        for index in targets { perSource[scenes[index].sourceID, default: []].append(index) }
        var changed = 0
        for (sourceID, indices) in perSource {
            guard let source = byID[sourceID] else { continue }
            if source.isImage {
                for index in indices {
                    let bounds = sceneDurationBounds(scene: scenes[index], source: source)
                    let length = min(bounds.maximum, max(bounds.minimum, source.weightedImageLength(clipLength: clipLength)))
                    guard length.isFinite, abs(length - scenes[index].length) > eps else { continue }
                    scenes[index].length = length
                    changed += 1
                }
                continue
            }
            let duration = source.duration
            guard duration.isFinite, duration > 0 else { continue }
            let length = VideoTrailerBatchPlan.sceneLength(source, clipLength: clipLength)
            guard length.isFinite, length > 0 else { continue }
            let proposals = source.plan.proposal(total: length * Double(indices.count), clipLength: length)
            let peaks = source.plan.rankedActionPeaks()
            for (position, index) in indices.enumerated() where position < proposals.count {
                let proposed = proposals[position]
                guard proposed.start.isFinite, proposed.length.isFinite, proposed.length > 0 else { continue }
                let proposedLength = min(proposed.length, duration)
                let proposedStart = min(max(0, proposed.start), max(0, duration - proposedLength))
                // 근거 있는 추천 창은 새 장면과 같은 규칙으로 동작 구간을 보호한다. 근거 없는 중앙 선택은 보호하지 않는다.
                // 이 동작 구간은 자동 분석의 기준점일 뿐 직접 고정한 시간이 아니므로 목표 길이를 늘리지 않는다:
                // 근거가 있으면 두 경계를 모두 `narrowToLength`로 맞춘다: 동작 구간이 추천 길이보다 길면 같은 소스의 가장 좋은 피크
                // 중심으로 추천 길이만큼 좁히고, 짧거나 같은데 요청 창 밖에 걸쳐 있으면 같은 길이로 창을 옮겨 동작 구간을 담는다.
                var window = source.plan.hasEvidence ? source.plan.actionWindow(start: proposedStart, length: proposedLength)
                                                     : (start: proposedStart, length: proposedLength, action: (start: proposedStart, end: proposedStart + proposedLength))
                if source.plan.hasEvidence {
                    var probe = scenes[index]
                    probe.start = window.start
                    probe.length = window.length
                    probe.actionStart = window.action.start
                    probe.actionEnd = window.action.end
                    narrowToLength(&probe, length: proposedLength, source: source, peaks: peaks)
                    window = (probe.start, probe.length, (probe.actionStart ?? probe.start, probe.actionEnd ?? probe.start + probe.length))
                }
                let protects = source.plan.hasEvidence
                let scene = scenes[index]
                let anchored = keepingAnchors(of: scene, start: min(max(0, window.start), max(0, duration - min(window.length, duration))),
                                              length: min(window.length, duration), duration: duration)
                let newLength = anchored.length
                let newStart = anchored.start
                let newActionStart: Double? = protects ? max(newStart, min(window.action.start, newStart + newLength)) : nil
                let newActionEnd: Double? = protects ? min(newStart + newLength, max(window.action.end, newStart)) : nil
                guard abs(newStart - scene.start) > eps || abs(newLength - scene.length) > eps
                        || newActionStart != scene.actionStart || newActionEnd != scene.actionEnd else { continue }
                scenes[index].start = newStart
                scenes[index].length = newLength
                scenes[index].actionStart = newActionStart
                scenes[index].actionEnd = newActionEnd
                changed += 1
            }
        }
        return changed
    }

    /// 이전 창 안의 직접 놓은 자막·키프레임 앵커를 새 창이 담도록 같은 길이로 옮긴다. 앵커가 새 길이보다 길면 앵커만큼 늘린다.
    /// 앵커가 없으면 그대로 돌려준다. 앵커 둘레 문맥은 새 추천을 따른다.
    static func keepingAnchors(of old: TrailerEditScene, start: Double, length: Double, duration: Double) -> (start: Double, length: Double) {
        guard old.start.isFinite, old.length.isFinite, old.length > 0, duration.isFinite, duration > 0,
              let anchor = old.adjustments?.anchorSpan(windowStart: old.start, windowEnd: old.start + old.length) else { return (start, length) }
        let end = min(duration, anchor.end)
        let first = max(0, min(anchor.start, end))
        let newLength = min(duration, max(length, end - first))
        let lower = max(0, end - newLength), upper = min(first, max(0, duration - newLength))
        let newStart = lower <= upper ? min(max(start, lower), upper) : upper
        return (newStart, newLength)
    }

    /// 보호 구간 길이(동작이 없으면 0). 소스 길이 안으로 잘라 낸다.
    static func protectedLength(_ scene: TrailerEditScene, sourceDuration: Double) -> Double {
        guard let span = scene.protectedSpan else { return 0 }
        return max(0, min(span.end, sourceDuration) - max(span.start, 0))
    }

    /// 새 시간별 자막(직접 추가·자동 생성)의 서체. 장면에 직접 쓴 고정 자막이 있으면 그 서체를 따르되, 같은 자리에 겹쳐 읽을 수 없게 되지 않도록
    /// 위치 행만 반대쪽 가장자리로 옮긴다(고정 자막은 그대로 남고 숨지 않는다). 없으면 기본 서체다.
    static func cueStyle(for scene: TrailerEditScene) -> TrailerCaption {
        guard var style = scene.caption else { return TrailerCaption() }
        style.text = ""
        if !(scene.caption?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            style.row = style.row <= 2 ? 4 : 0
        }
        return style
    }

    /// 사진의 지금 보이는 앵커 끝까지의 논리 사진 시간(없으면 0). 사진 시간은 `start`(0)부터 길이까지이며 창 밖의 저장된 점은 세지 않는다.
    static func photoAnchorLength(_ scene: TrailerEditScene) -> Double {
        guard scene.start.isFinite, scene.length.isFinite, scene.length > 0,
              let anchor = scene.adjustments?.anchorSpan(windowStart: scene.start, windowEnd: scene.start + scene.length) else { return 0 }
        return max(0, anchor.end - scene.start)
    }

    /// 길이가 보호 구간 이상일 때, 창이 보호 구간을 모두 포함하도록 시작점을 옮긴다. 아니면 그대로.
    static func startKeepingAction(_ scene: TrailerEditScene, start: Double, length: Double, sourceDuration: Double) -> Double {
        let protected = protectedLength(scene, sourceDuration: sourceDuration)
        guard protected > 0, length + 1e-9 >= protected, let span = scene.protectedSpan else { return start }
        let a = span.start, b = span.end
        let lower = max(0, min(b, sourceDuration) - length)
        let upper = min(max(a, 0), max(0, sourceDuration - length))
        return min(max(start, lower), max(lower, upper))
    }

    /// 저장된 앵커가 없는 영상 장면(앵커 도입 전 초안)은 저장된 창 전체를 보호 구간으로 이관한다. 수동 트림은 그대로 보존.
    static func migrateLegacyActionWindows(scenes: inout [TrailerEditScene], sources: [VideoTrailerSource]) {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for index in scenes.indices where scenes[index].actionStart == nil && scenes[index].actionEnd == nil {
            guard let source = byID[scenes[index].sourceID], !source.isImage, source.duration > 0 else { continue }
            scenes[index].actionStart = scenes[index].start
            scenes[index].actionEnd = scenes[index].start + scenes[index].length
        }
    }

    /// 직접 편집한 장면을 음악 길이 맞춤(반복 `startCount`회, 자동으로 늘리지 않는다)에 맞춘다. 음악 길이 × 횟수(카드 포함)가
    /// 넘지 않는 예산이며 `fitScenesToBudget`이 동작 구간을 지키며 주변 문맥을 줄이고, 그래도 모자라면 직접 편집한 장면의 동작 구간을
    /// 피크 중심으로 좁히며 덜 중요한 순수 자동 장면을 통째로 뺀다. 직접 시간을 정한 장면은 그대로 두고,
    /// 그 물리적 최소 합이 예산보다 길 때만 실제 길이(`total`)가 이기며 이때도 `fits`는 true다(음악은 렌더가 영상 끝까지 이어 붙인다).
    /// 포함 장면이 하나도 없을 때만 `fits`가 false이고 장면은 그대로다. `maximumRepeats`는 횟수 상한으로만 쓴다.
    /// 반환값은 반복 횟수, 포함 장면 합계, 맞춤 여부와 뺀 장면 수.
    @discardableResult
    static func fitScenesToMusic(
        scenes: inout [TrailerEditScene],
        sources: [VideoTrailerSource],
        musicDuration: Double,
        startCount: Int,
        cardsDuration: Double,
        maximumRepeats: Int,
        capOnly: Bool = false,
        outroLength: Double = 0
    ) -> (count: Int, total: Double, fits: Bool, excluded: Int) {
        func included(_ list: [TrailerEditScene]) -> Double { outputBodyDuration(list, outroLength: outroLength) }
        let count = min(max(1, maximumRepeats), max(1, startCount))
        let cards = cardsDuration.isFinite ? max(0, cardsDuration) : 0
        guard musicDuration.isFinite, musicDuration > 0 else { return (count, included(scenes), true, 0) }
        guard let fit = fitScenesToBudget(scenes: &scenes, sources: sources, bodyTarget: max(0.1, musicDuration * Double(count) - cards),
                                          capOnly: capOnly, outroLength: outroLength) else {
            return (count, included(scenes), false, 0)
        }
        return (count, fit.total, true, fit.excluded)
    }

    /// Android `sceneImportance`와 같은 값: 중요 사진 2, 다른 사진은 품질 비율, 동작을 담은 영상 컷은 1 + 고립 타격 1 + 검증 .5,
    /// 근거는 있는데 동작이 없는 컷 .5, 근거 없는 영상 1(소리 세기는 소스마다 상대값이라 다른 소스 장면끼리 비교하지 않는다).
    static func sceneImportance(_ scene: TrailerEditScene, source: VideoTrailerSource?, peaks: (VideoTrailerSource) -> [VideoTrailerPlan.ActionPeak]) -> Double {
        guard let source else { return 0 }
        if source.isImage { return source.isImportant ? 2 : min(0.95, source.effectiveImageDurationRatio) }
        guard source.duration.isFinite, source.duration > 0 else { return 0 }
        let ranked = peaks(source)
        guard !ranked.isEmpty else { return 1 }
        let a = scene.actionStart ?? scene.start
        let b = scene.actionEnd ?? (scene.start + scene.length)
        return ranked.filter { $0.time >= a - 1e-6 && $0.time <= b + 1e-6 }
            .map { 1 + ($0.sharp ? 1 : 0) + ($0.verified ? 0.5 : 0) }.max() ?? 0.5
    }

    /// 정한 본편 길이(`bodyTarget` = 전체 길이 − 시작/마지막 화면)는 넘지 않는 예산이다(Android `fitEditorToBudget`과 같은 규칙).
    /// 먼저 예산 때문에 뺐던 장면을 되돌린다(사용자가 직접 제외했거나 전체 보호된 장면은 그대로). 시간이 직접 정해진 장면(`timingProtected`)은
    /// 길이·구간을 그대로 두고 그 길이만큼 예산에서 먼저 뗀다. 나머지 자동 시간 장면은 동작 구간(key point)을 지킨 채 주변 문맥만 줄이는
    /// 것이 먼저다(소프트 최소 = 동작 구간, 최소 0.2초). 그래도 못 빼는 직접 편집 장면(자막·소리·화면 구성·순서·포함 의도, `mandatory`)의
    /// 소프트 최소 합이 목표보다 길면 목표는 그대로 두고 그 장면들의 동작 구간을 알려진 가장 좋은 피크 중심으로 좁힌다(`narrowToBestPoint`):
    /// 장면마다 물리적 최소(프레임 한 장 1/30초)부터 소프트 최소까지 같은 비율로 나눠 받으므로 어떤 장면도 빠지지 않고 직접 편집한 필드·포함도 그대로다.
    /// 이때 직접 편집 흔적이 없는 순수 자동 장면은 모두 빠진다. 소프트 최소 합이 목표 안에 들면 남는 자리를 순수 자동 장면이 받는다:
    /// 중요한 장면부터(소스마다 가장 중요한 장면이 먼저, 같으면 앞쪽) 통째로 들어가는 만큼 담고 나머지는 뺀다. 단, 더 중요한 장면이 통째로는
    /// 안 들어가는데 뒤의 덜 중요한 짧은 장면이 들어간다는 이유만으로 그 장면을 받지는 않는다. 더 중요한 장면의 동작 구간을 피크 중심으로 좁혀
    /// 남은 자리에 먼저 담는다. 통째로 들어가는 장면이 하나도 없으면 뒤에 들어갈 장면이 없어도 가장 원하는 장면을 물리적 최소(프레임 한 장)
    /// 이상인 남은 자리에 좁혀 담는다(0.2초 UI 최소에 막히지 않는다). 담을 수 있는 장면이 하나도 없고 직접 정한 장면도 없으면 가장 원하는 장면 하나를 좁혀 남긴다.
    /// 마지막으로 남은 자리를 자동 시간 장면이 다시 나눠 받는다(순서·사용자 제외는 그대로).
    /// 유효 목표는 요청 목표 그대로다. 시간이 직접 정해진 장면과 못 뺀 장면의 물리적 최소(프레임) 합이 목표보다 길 때만 그 합이 이기며,
    /// 이때 결과 길이는 그 합이다(순수 자동 장면은 목록에 남아 목표가 늘면 돌아온다).
    /// 반환 `total`이 실제 본편 길이이고, 그 길이가 `bodyTarget`보다 길면 호출자는 더 짧은 목표를 달성했다고 알리지 않는다. 포함 장면이 없으면 nil(그대로).
    /// 모든 길이는 출력 시간이다: 배속(`rate`)으로 줄거나 늘어난 장면 길이의 합에서 실제로 겹치는 디졸브 길이를 한 번 빼면 본편 길이다.
    /// 겹침은 장면 길이에 따라 달라지므로 겹침을 합 목표에 더해 맞춘 뒤 다시 센다(몇 번 반복). 반환 `total`은 겹침을 뺀 본편 출력 길이다.
    /// `outroLength`는 마지막 화면 길이로, 마지막 장면의 디졸브가 그 화면과 겹치는 길이까지 센다.
    @discardableResult
    static func fitScenesToBudget(scenes: inout [TrailerEditScene], sources: [VideoTrailerSource],
                                  bodyTarget: Double, capOnly: Bool = false, outroLength: Double = 0) -> (total: Double, included: Int, excluded: Int)? {
        guard bodyTarget.isFinite, bodyTarget > 0 else { return nil }
        // 원본 장면 복사본에서 `coreTarget`(겹침을 더한 장면 출력 길이 합)으로 한 번 맞추고, 그 결과의 실제 겹침을 뺀 본편 출력 길이를 돌려준다.
        func evaluate(_ coreTarget: Double) -> (scenes: [TrailerEditScene], total: Double, included: Int, excluded: Int, overlap: Double)? {
            var attempt = scenes
            guard let core = fitScenesToBudgetCore(scenes: &attempt, sources: sources, bodyTarget: coreTarget, capOnly: capOnly) else { return nil }
            let settled = bodyOverlapTotal(attempt, outroLength: outroLength)
            return (attempt, max(0, core.total - settled), core.included, core.excluded, settled)
        }
        var overlap = bodyOverlapTotal(scenes.map { scene in var copy = scene; copy.excluded = copy.excluded && !copy.budgetExcluded; return copy },
                                       outroLength: outroLength)
        var best: (scenes: [TrailerEditScene], total: Double, included: Int, excluded: Int, overlap: Double)?
        var coreTarget = bodyTarget + overlap
        for _ in 0..<4 {
            coreTarget = bodyTarget + overlap
            guard let current = evaluate(coreTarget) else { return nil }
            best = current
            if abs(current.overlap - overlap) < 0.001 { break }
            overlap = current.overlap
        }
        // 고정점 반복이 끝났는데도 실제 출력이 요청보다 물리적 프레임 하나(1/30초) 넘게 길면(큰 디졸브가 다시 잘리는 짧은 목표 등) 같은 맞춤을
        // 겹침을 더한 합 목표에 대해 이분법으로 마저 끝낸다. 실제 출력은 그 목표에 대해 단조 증가하므로 요청 이하인 가장 큰 목표를 찾는다.
        // 가장 작은 목표로도 못 맞추면 고정 장면·물리적 프레임 최소가 이기는 진짜 하한이므로 그 결과를 그대로 쓴다.
        if let over = best, over.total > bodyTarget + frameMinimum {
            var high = coreTarget
            var low = frameMinimum
            if let floor = evaluate(low) {
                best = floor
                if floor.total <= bodyTarget + frameMinimum {
                    for _ in 0..<40 where high - low > 1e-4 {
                        let mid = (low + high) / 2
                        guard let probe = evaluate(mid) else { break }
                        if probe.total <= bodyTarget + 1e-6 {
                            low = mid
                            best = probe
                        } else {
                            high = mid
                        }
                    }
                }
            }
        }
        guard let final = best else { return nil }
        scenes = final.scenes
        return (final.total, final.included, final.excluded)
    }

    /// `fitScenesToBudget`의 한 번 맞춤. `bodyTarget`은 겹침을 더한 장면 출력 길이 합 목표다.
    private static func fitScenesToBudgetCore(scenes: inout [TrailerEditScene], sources: [VideoTrailerSource],
                                              bodyTarget: Double, capOnly: Bool) -> (total: Double, included: Int, excluded: Int)? {
        var next = scenes
        for index in next.indices where next[index].budgetExcluded && !next[index].exclusionProtected {
            next[index].excluded = false
            next[index].budgetExcluded = false
        }
        let included = next.indices.filter { !next[$0].excluded }
        guard !included.isEmpty else { return nil }
        let locked = included.filter { next[$0].timingProtected }
        let lockedSum = locked.reduce(0.0) { $0 + (next[$1].length.isFinite ? max(0, next[$1].length) : 0) / outputRate(next[$1]) }
        // `candidates`는 시간이 자동인 장면. 그중 `droppable`(순수 자동)만 빠질 수 있고 `mandatory`(직접 편집 흔적 있음)는 빠지지 않고 좁아지기만 한다.
        let candidates = included.filter { !next[$0].timingProtected }
        let droppable = candidates.filter { next[$0].isPureAutomatic }
        let mandatory = candidates.filter { !next[$0].isPureAutomatic }
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var peakCache: [Int: [VideoTrailerPlan.ActionPeak]] = [:]
        func peaks(_ source: VideoTrailerSource) -> [VideoTrailerPlan.ActionPeak] {
            if let cached = peakCache[source.id] { return cached }
            let ranked = source.plan.rankedActionPeaks()
            peakCache[source.id] = ranked
            return ranked
        }
        // `minimum`은 소프트 최소(동작 구간을 지킨 채 주변 문맥만 줄인 길이, 최소 0.2초), `frameFloor`는 물리적 최소(프레임 한 장).
        var minimum: [Int: Double] = [:]
        var frameFloor: [Int: Double] = [:]
        // 모두 출력 시간이다. 물리적 최소는 출력 프레임 한 장(1/30초)이며 배속과 무관하다(원본 길이는 그 값 × 배속).
        for index in candidates {
            let source = byID[next[index].sourceID]
            let rate = outputRate(next[index])
            minimum[index] = max(frameMinimum, sceneDurationBounds(scene: next[index], source: source).minimum / rate)
            var probe = next[index]
            probe.actionStart = nil
            probe.actionEnd = nil
            // 직접 놓은 자막·키프레임 앵커는 물리적 최소에도 포함된다.
            // 사진은 논리 사진 시간(0부터 길이까지)에서 지금 보이는 앵커 구간을 그대로 지킨다(`isImage`가 앵커를 무시하는 뜻은 아니다).
            let anchorLength = source.map { src -> Double in
                if src.isImage { return photoAnchorLength(probe) }
                return src.duration > 0 ? protectedLength(probe, sourceDuration: src.duration) : 0
            } ?? 0
            frameFloor[index] = min(minimum[index]!, max(frameMinimum, anchorLength / rate))
        }
        // `narrowedTo`: 이 길이로 동작 구간을 피크 중심으로 좁힐 장면(그 밖의 장면은 아래 재분배가 문맥만 늘이고 줄인다).
        var narrowedTo: [Int: Double] = [:]
        var keep = Set<Int>()
        var effectiveTarget = bodyTarget
        let freeForUnlocked = bodyTarget - lockedSum
        let mandatorySoft = mandatory.reduce(0.0) { $0 + minimum[$1]! }
        if mandatorySoft > freeForUnlocked + 1e-6 {
            // 못 빼는 직접 편집 장면이 목표보다 길다: 목표는 그대로 두고 그 장면들을 물리적 최소부터 소프트 최소 사이에서 같은 비율로 좁힌다.
            // 순수 자동 장면은 모두 빠진다. 고정 장면과 물리적 최소 합이 목표를 넘을 때만 그 합이 목표를 이긴다.
            let mandatoryFloor = mandatory.reduce(0.0) { $0 + frameFloor[$1]! }
            let available = max(freeForUnlocked, mandatoryFloor)
            let span = mandatorySoft - mandatoryFloor
            let share = span > 1e-9 ? min(1, max(0, (available - mandatoryFloor) / span)) : 1
            for index in mandatory {
                let length = frameFloor[index]! + share * (minimum[index]! - frameFloor[index]!)
                if length < minimum[index]! - 1e-9 { narrowedTo[index] = length }
            }
            effectiveTarget = lockedSum + available
        } else {
            let freeTarget = freeForUnlocked - mandatorySoft
            keep = Set(droppable)
            let minSum = droppable.reduce(0.0) { $0 + minimum[$1]! }
            if minSum > freeTarget + 1e-6 {
                var importance: [Int: Double] = [:]
                for index in droppable { importance[index] = sceneImportance(next[index], source: byID[next[index].sourceID], peaks: peaks) }
                var representative = Set<Int>()
                for group in Dictionary(grouping: droppable, by: { next[$0].sourceID }).values {
                    if let best = group.max(by: { l, r in
                        if importance[l]! != importance[r]! { return importance[l]! < importance[r]! }
                        if minimum[l]! != minimum[r]! { return minimum[l]! > minimum[r]! }
                        return l > r
                    }) { representative.insert(best) }
                }
                // 덜 원하는 것부터: 소스 대표가 아닌 추가 장면, 덜 중요한 것, (같은 중요도면) 보호 최소 길이가 긴 것(완전한 샷이 더 많이 들어가게), 뒤쪽.
                let order = droppable.sorted { l, r in
                    let lr = representative.contains(l), rr = representative.contains(r)
                    if lr != rr { return !lr }
                    if importance[l]! != importance[r]! { return importance[l]! < importance[r]! }
                    if minimum[l]! != minimum[r]! { return minimum[l]! > minimum[r]! }
                    return l > r
                }
                let wanted = Array(order.reversed())
                // 장면을 빼야 할 때는 남길 최소 길이 합이 예산의 10%를 비워 두어 컷이 비트로 움직일 여유(와 문맥)를 남긴다(Android BUDGET_SLACK).
                // 그 여유로는 한 장면도 안 들어가면 예산 전체를 쓴다.
                // 중요한 것부터(소스마다 가장 중요한 장면이 다른 소스의 추가 장면보다 먼저, 같으면 앞쪽) 통째로 들어가는 장면을 차례로 담는다.
                // 더 중요한 장면이 통째로는 안 들어가면, 남은 자리가 그 장면의 실제 물리적 최소(프레임 한 장, UI 최소 0.2초가 아님) 이상인 한
                // 뒤에 다른 장면이 있든 없든 이 장면의 동작 구간을 피크 중심으로 좁혀 남은 자리에 담고 다음 순위로 넘어가지 않는다.
                func choose(_ limit: Double) {
                    keep = []
                    narrowedTo = [:]
                    var remaining = limit
                    for index in wanted {
                        let need = minimum[index]!
                        if need <= remaining + 1e-6 {
                            keep.insert(index)
                            remaining -= need
                            continue
                        }
                        if remaining >= frameFloor[index]! - 1e-6 {
                            narrowedTo[index] = remaining
                            keep.insert(index)
                            remaining = 0
                            break
                        }
                    }
                }
                // 좁히기가 끼면 남은 자리를 전부 쓰므로 10% 여유는 의미가 없다: 그때는 예산 전체로 다시 골라 통째로 들어가는 장면을 좁히지 않는다.
                choose(freeTarget * 0.9)
                if keep.isEmpty || !narrowedTo.isEmpty { choose(freeTarget) }
                // 시간이 고정되었거나 못 빼는 장면이 이미 있으면 순수 자동 장면이 하나도 안 들어가도 맞춤은 성립한다.
                // 아무것도 없으면 가장 원하는 장면 하나는 남긴다: 동작 구간을 알려진 가장 좋은 지점 중심으로 좁혀 목표(물리적 최소 이상)에 담는다.
                if keep.isEmpty && locked.isEmpty && mandatory.isEmpty {
                    guard let best = wanted.first else { return nil }
                    let length = min(minimum[best]!, max(frameFloor[best]!, freeTarget))
                    if length < minimum[best]! - 1e-9 { narrowedTo[best] = length }
                    effectiveTarget = max(bodyTarget, length)
                    keep = [best]
                }
            }
        }
        for index in droppable where !keep.contains(index) {
            next[index].excluded = true
            next[index].budgetExcluded = true
        }
        for (index, length) in narrowedTo.sorted(by: { $0.key < $1.key }) {
            // `length`는 출력 시간이다: 원본 길이로 바꿔 좁힌다.
            let sourceLength = length * outputRate(next[index])
            guard let source = byID[next[index].sourceID] else { next[index].length = sourceLength; continue }
            narrowToLength(&next[index], length: sourceLength, source: source, peaks: peaks(source))
        }
        // capOnly(정한 전체 길이 아래 클립 길이 변경): 예산은 상한일 뿐 남은 장면을 채우려고 늘리지 않는다.
        // 좁힌 장면은 동작 구간이 좁힌 창이라 재분배가 UI 최소(0.2초) 아래의 물리적 최소까지 인정한다(조용히 다시 늘이지 않는다).
        let keptSum = next.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length / outputRate($1) }
        redistributeManualTotal(scenes: &next, sources: sources, targetTotal: capOnly ? min(effectiveTarget, keptSum) : effectiveTarget,
                                allowSubMinimum: true)
        scenes = next
        let total = next.filter { !$0.excluded }.reduce(0.0) { $0 + $1.length / outputRate($1) }
        return (total, keep.count + mandatory.count + locked.count, droppable.count - keep.count)
    }

    /// 장면을 `length`초로 줄인다. 동작 구간이 그보다 길면 피크 중심으로 좁혀 좁힌 창을 새 동작 구간으로 쓰고(`narrowToBestPoint`),
    /// 이미 그 안이면 동작 구간을 담은 채 길이만 줄인다.
    private static func narrowToLength(_ scene: inout TrailerEditScene, length: Double, source: VideoTrailerSource,
                                       peaks: [VideoTrailerPlan.ActionPeak]) {
        if narrowToBestPoint(&scene, source: source, limit: length, peaks: peaks) { return }
        guard !source.isImage, source.duration.isFinite, source.duration > 0 else { scene.length = length; return }
        let kept = startKeepingAction(scene, start: scene.start, length: length, sourceDuration: source.duration)
        scene.length = length
        scene.start = min(max(0, kept), max(0, source.duration - length))
    }

    /// 가장 짧은 한 장면(`limit`초, 물리적 최소 길이 1/30초 아래로는 내려가지 않음)보다 동작 구간이 길 때, 그 구간 안의 가장 좋은 알려진 피크
    /// (`peaks`는 `rankedActionPeaks` 순서)의 온셋과 타격을 담도록 창을 좁히고 좁힌 창 전체를 새 동작 구간으로 쓴다. 시각은 모두 기존 구간·피크에서
    /// 나오며 만들어 내지 않는다. 안에 피크가 없으면 구간 시작에서 그 길이만큼만 남긴다. 사진이거나 이미 들어가면 false(그대로).
    @discardableResult
    static func narrowToBestPoint(_ scene: inout TrailerEditScene, source: VideoTrailerSource, limit: Double,
                                  peaks: [VideoTrailerPlan.ActionPeak]) -> Bool {
        guard !source.isImage, source.duration.isFinite, source.duration > 0, limit.isFinite else { return false }
        let duration = source.duration
        // 물리적 최소는 출력 프레임 한 장이다: 원본 길이로는 그 값 × 배속(0.25배속이면 1/120초)이며 원본 1/30초 바닥을 쓰지 않는다.
        let floor = min(duration, frameMinimum * outputRate(scene))
        let length = min(duration, max(floor, limit))
        let span = scene.protectedSpan
        let a = min(max(0, span?.start ?? scene.start), duration)
        let b = max(a, min(span?.end ?? (scene.start + scene.length), duration))
        guard b - a > length + 1e-9 else { return false }
        var start = a
        if let peak = peaks.first(where: { $0.time >= a - 1e-6 && $0.time <= b + 1e-6 }) {
            start = min(max(peak.onset - 0.25 * length, a), max(a, b - length))
            start = max(start, peak.time - length)
        }
        // 직접 놓은 자막·키프레임 앵커는 피크보다 우선해 창 안에 남긴다(앵커가 창보다 길면 앵커 시작을 지킨다).
        if let anchor = scene.adjustments?.anchorSpan(windowStart: scene.start, windowEnd: scene.start + scene.length) {
            let lower = anchor.end - length, upper = anchor.start
            start = lower <= upper ? min(max(start, lower), upper) : upper
        }
        start = min(max(0, start), max(0, duration - length))
        scene.start = start
        scene.length = length
        scene.actionStart = start
        scene.actionEnd = start + length
        return true
    }

    /// 정한 길이로 요청할 수 있는 본편 범위: 가장 짧은 한 장면(통째로) ... 모든 장면(예산으로 뺀 것 포함)의 최대 길이. 사용자 제외는 빼고 센다.
    static func budgetBodyBounds(scenes: [TrailerEditScene], sources: [VideoTrailerSource]) -> (minimum: Double, maximum: Double) {
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bounds = scenes.filter { !$0.excluded || $0.budgetExcluded }.map { scene -> (minimum: Double, maximum: Double) in
            let raw = sceneDurationBounds(scene: scene, source: byID[scene.sourceID])
            let rate = outputRate(scene)
            return (max(frameMinimum, raw.minimum / rate), raw.maximum / rate)
        }
        guard let shortest = bounds.map(\.minimum).min() else { return (0, 0) }
        return (shortest, bounds.reduce(0.0) { $0 + $1.maximum })
    }

    /// 새 추천으로 다시 맞추기: 소스별로 그 소스의 장면들이 (프로젝트 순서대로) 새 분석이 고른 창을 차례로 받는다.
    /// 순서·자막·프레이밍·음량·제외는 그대로이고, 근거 있는 새 창이 없거나 창 개수를 넘는 장면은 건드리지 않는다.
    /// 새 창은 동작 보호 구간으로 기록한다. 장면 수보다 많은 독립 동작(고립 타격·분류기 검증)은 그 소스 장면들 사이에 소스 시간순으로
    /// 새 장면으로 들어간다(이웃 장면의 프레이밍·음량·제외를 잇고 자막은 없음, 새 id는 `nextID`부터). 호출자는 원본이 아닌 복사본에만 쓴다.
    static func rebuiltFromRecommendation(scenes: [TrailerEditScene], sources: [VideoTrailerSource], nextID: inout Int) -> [TrailerEditScene] {
        typealias Window = (start: Double, length: Double, action: (start: Double, end: Double))
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 장면이 m개인 소스는 가장 이른 m개가 아니라 가장 강한 m개 창을 시간순으로 받는다.
        var counts: [Int: Int] = [:]
        for scene in scenes { counts[scene.sourceID, default: 0] += 1 }
        var windows: [Int: [Window]] = [:]
        var extraWindows: [Int: [Window]] = [:]
        for (id, count) in counts {
            guard let source = byID[id], !source.isImage, source.duration > 0, source.plan.hasEvidence else { continue }
            let clip = source.plan.recommendedClipLength
            let length = min(clip, source.duration)
            let picks = source.plan.actionPicks(clipLength: clip)
            guard !picks.isEmpty else { continue }
            windows[id] = picks.prefix(count).sorted { $0.start < $1.start }.map { source.plan.actionWindow(pick: $0, length: length) }
            extraWindows[id] = picks.dropFirst(count).filter { $0.peak?.independent == true }
                .map { source.plan.actionWindow(pick: $0, length: length) }.sorted { $0.action.start < $1.action.start }
        }
        var used: [Int: Int] = [:]
        var result: [TrailerEditScene] = []
        for scene in scenes {
            guard let source = byID[scene.sourceID], !source.isImage, source.duration > 0, source.plan.hasEvidence,
                  let list = windows[source.id] else { result.append(scene); continue }
            let position = used[source.id, default: 0]
            guard position < list.count else { result.append(scene); continue }
            used[source.id] = position + 1
            // 사본의 컷은 보호 동작 전체를 담도록 늘리고 그 동작을 가운데에 둔다.
            func place(_ window: Window, _ base: TrailerEditScene) -> TrailerEditScene {
                let action = window.action
                let span = action.end - action.start
                let length = min(max(base.length, window.length, span), source.duration)
                var placed = base
                let centered = min(max(0, action.start - (length - span) / 2), max(0, source.duration - length))
                let anchored = keepingAnchors(of: base, start: centered, length: length, duration: source.duration)
                placed.start = anchored.start
                placed.length = anchored.length
                placed.actionStart = action.start
                placed.actionEnd = action.end
                return placed
            }
            let current = list[position]
            let extras = extraWindows[source.id] ?? []
            let next = position + 1 < list.count ? list[position + 1] : nil
            let before = position == 0 ? extras.filter { $0.action.start < current.action.start } : []
            let after = extras.filter { $0.action.start > current.action.start && (next == nil || $0.action.start < next!.action.start) }
            func extra(_ window: Window) -> TrailerEditScene {
                var base = scene
                base.id = nextID
                nextID += 1
                base.caption = nil
                // 새 추천이 만든 장면이지 사용자가 고친 장면이 아니다.
                base.automationProtected = false
                // 이웃에서 이어받은 소리·화면 구성 표시만 남기고, 시간·순서·제외는 자동이다.
                base.manual = base.manual.intersection([.audio, .framing])
                return place(window, base)
            }
            result += before.map(extra)
            result.append(place(current, scene))
            result += after.map(extra)
        }
        return result
    }

    /// `nextID` 없이 부르면 기존 장면 id 다음부터 새 id를 쓴다.
    static func rebuiltFromRecommendation(scenes: [TrailerEditScene], sources: [VideoTrailerSource]) -> [TrailerEditScene] {
        var nextID = (scenes.map(\.id).max() ?? 0) + 1
        return rebuiltFromRecommendation(scenes: scenes, sources: sources, nextID: &nextID)
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
        let start = first?.start ?? 0
        let sceneLength = first?.length ?? length
        // 근거 있는 추천 창은 타격 피크 앞뒤(스윙 전체)를 보호한다. 근거 없는 중앙 선택은 보호하지 않는다.
        let protects = source.plan.hasEvidence
        let action = source.plan.protectedInterval(start: start, length: sceneLength)
        return TrailerEditScene(id: id, sourceID: source.id, start: start, length: sceneLength,
            actionStart: protects ? action.start : nil, actionEnd: protects ? action.end : nil)
    }

    /// 계획·내보내기가 실제로 만들 수 있는 가장 짧은 장면: 프레임 한 장(1/30초). 렌더(`VideoTrailerBatchPlan.fitted`)도 이 길이부터 한 장면으로 센다.
    /// 직접 다듬기의 최소 길이 0.2초는 사용자 정책이지 물리적 한계가 아니다.
    static let frameMinimum = 1.0 / 30.0

    /// 장면의 직접 편집(UI) 표시 시간 범위(최소...최대).
    /// 비디오는 max(min(.2, duration), 동작 보호 구간), 시작점 유효 클램프 0...duration-min, max = duration-validStart.
    /// 사진은 1/30...30초. 유효하지 않거나 누락된 소스는 기존 유한 길이를 고정값으로 유지.
    static func sceneDurationBounds(scene: TrailerEditScene, source: VideoTrailerSource?) -> (minimum: Double, maximum: Double) {
        durationBounds(scene: scene, source: source, policyMinimum: 0.2)
    }

    /// 계획 장면이 실제로 가질 수 있는 시간 범위. `sceneDurationBounds`에서 UI 최소 길이(0.2초)만 물리적 최소(`frameMinimum`)로 바꾼 것이다.
    /// 예산이 동작 구간을 피크 중심으로 좁힌 장면(좁힌 창이 곧 동작 보호 구간)이 미리보기·내보내기·저장 뒤 다시 열기에서 조용히 0.2초로 늘지 않게 한다.
    static func planDurationBounds(scene: TrailerEditScene, source: VideoTrailerSource?) -> (minimum: Double, maximum: Double) {
        // 출력 프레임 한 장의 원본 길이(× 배속): 0.25배속이면 1/120초. 원본 1/30초 바닥으로 부풀리지 않는다.
        durationBounds(scene: scene, source: source, policyMinimum: frameMinimum * outputRate(scene))
    }

    private static func durationBounds(scene: TrailerEditScene, source: VideoTrailerSource?,
                                       policyMinimum: Double) -> (minimum: Double, maximum: Double) {
        guard let source else {
            let fixed = scene.length.isFinite && scene.length > 0 ? scene.length : 0.2
            return (fixed, fixed)
        }
        if source.isImage {
            // 직접 놓은 자막·키프레임 앵커가 지금 보이는 사진 시간 안에 있으면 그 끝까지는 물리적 최소다.
            return (min(30.0, max(frameMinimum, photoAnchorLength(scene))), 30.0)
        }
        guard source.duration.isFinite, source.duration > 0 else {
            let fixed = scene.length.isFinite && scene.length > 0 ? scene.length : 0.2
            return (fixed, fixed)
        }
        let duration = source.duration
        let minLen = max(min(policyMinimum, duration), protectedLength(scene, sourceDuration: duration))
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
    /// `allowSubMinimum`이면 장면 최소 길이를 UI 최소(0.2초)가 아니라 물리적 최소(`planDurationBounds`)로 본다. 예산이 좁힌 장면용이다.
    static func redistributeManualTotal(
        scenes: inout [TrailerEditScene],
        sources: [VideoTrailerSource],
        targetTotal: Double,
        allowSubMinimum: Bool = false
    ) {
        guard targetTotal.isFinite, targetTotal > 0 else { return }
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 시간이 직접 정해진 장면은 길이를 바꾸지 않는다. 그 길이만큼은 목표에서 먼저 떼고 나머지 장면만 나눈다.
        // 길이는 모두 출력 시간이다(원본 길이 ÷ 배속).
        let lockedTotal = scenes.filter { !$0.excluded && $0.timingProtected }
            .reduce(0.0) { $0 + ($1.length.isFinite ? max(0, $1.length) : 0) / outputRate($1) }
        let freeTotal = targetTotal - lockedTotal
        let includedIndices = scenes.indices.filter { !scenes[$0].excluded && !scenes[$0].timingProtected }
        guard !includedIndices.isEmpty else { return }

        var minBounds: [Int: Double] = [:]
        var maxBounds: [Int: Double] = [:]
        var totalMin = 0.0
        var totalMax = 0.0

        for index in includedIndices {
            let source = byID[scenes[index].sourceID]
            let bounds = allowSubMinimum ? planDurationBounds(scene: scenes[index], source: source)
                : sceneDurationBounds(scene: scenes[index], source: source)
            let rate = outputRate(scenes[index])
            let low = max(frameMinimum, bounds.minimum / rate)
            let high = max(low, bounds.maximum / rate)
            minBounds[index] = low
            maxBounds[index] = high
            totalMin += low
            totalMax += high
        }

        let clampedTarget = min(totalMax, max(totalMin, freeTotal))

        var lengths: [Int: Double] = [:]
        for index in includedIndices {
            let minB = minBounds[index]!
            let maxB = maxBounds[index]!
            lengths[index] = min(maxB, max(minB, scenes[index].length / outputRate(scenes[index])))
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
            if let outLen = lengths[index] {
                // 출력 길이를 원본 길이로 되돌려 쓴다.
                let len = outLen * outputRate(scenes[index])
                scenes[index].length = len
                let scene = scenes[index]
                if let source = byID[scene.sourceID], !source.isImage, source.duration > 0 {
                    let minLen = (minBounds[index] ?? min(0.2, source.duration)) * outputRate(scene)
                    let kept = startKeepingAction(scene, start: scene.start, length: len, sourceDuration: source.duration)
                    scenes[index].start = min(max(0, kept), max(0, source.duration - max(minLen, len)))
                }
            }
        }
    }

    /// `redistributeManualTotal`을 본편 출력 길이(겹침을 뺀 길이) 기준으로 맞춘다. 겹침은 장면 길이에 따라 달라 몇 번 반복해 수렴시킨다.
    static func redistributeOutputBody(scenes: inout [TrailerEditScene], sources: [VideoTrailerSource],
                                       bodyTarget: Double, outroLength: Double = 0, allowSubMinimum: Bool = false) {
        guard bodyTarget.isFinite, bodyTarget > 0 else { return }
        var overlap = bodyOverlapTotal(scenes, outroLength: outroLength)
        var attempt = scenes
        for _ in 0..<4 {
            attempt = scenes
            redistributeManualTotal(scenes: &attempt, sources: sources, targetTotal: bodyTarget + overlap, allowSubMinimum: allowSubMinimum)
            let settled = bodyOverlapTotal(attempt, outroLength: outroLength)
            if abs(settled - overlap) < 0.001 { break }
            overlap = settled
        }
        scenes = attempt
    }

    /// 클립 길이 줄(−, 1, 2, 추천, 4, 6, +)의 영상 컷 처리(Android `clipLengthScenes`와 같은 규칙). 추천(`recommended`)은 보호를 아는 길이라
    /// 컷 안의 소스 근거로 동작 전체 보호 구간을 되살린다(그보다 짧게는 줄지 않음). 다른 길이는 사용자가 고른 길이라 영상 컷이 정확히 그 길이
    /// (소스 안)가 되고, 아는 임팩트를 담은 채 그 창을 이후의 보호 구간으로 쓴다(1초 컷이 스윙 전체를 담는다고 주장하지 않는다).
    static func applyClipChoice(clipLength: Double, recommended: Bool, scenes: inout [TrailerEditScene], sources: [VideoTrailerSource]) {
        guard clipLength.isFinite, clipLength > 0 else { return }
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var peakCache: [Int: [VideoTrailerPlan.ActionPeak]] = [:]
        for index in scenes.indices where (!scenes[index].excluded || scenes[index].budgetExcluded) && !scenes[index].timingProtected {
            guard let source = byID[scenes[index].sourceID], !source.isImage, source.duration.isFinite, source.duration > 0 else { continue }
            let scene = scenes[index]
            let duration = source.duration
            let span = scene.protectedSpan
            let a = min(max(0, span?.start ?? scene.start), duration)
            let b = max(a, min(span?.end ?? (scene.start + scene.length), duration))
            let ranked = peakCache[source.id] ?? source.plan.rankedActionPeaks()
            peakCache[source.id] = ranked
            let peak = ranked.first { $0.time >= a - 1e-6 && $0.time <= b + 1e-6 }
            if recommended {
                guard let interval = peak?.interval(duration: duration) else { continue }
                scenes[index].actionStart = min(a, interval.start)
                scenes[index].actionEnd = max(b, interval.end)
                continue
            }
            let length = min(clipLength, duration)
            let wanted = (peak?.onset ?? (a + b) / 2) - 0.4 * length
            var start = length <= b - a ? min(max(wanted, a), max(a, b - length)) : min(max(wanted, max(0, b - length)), max(max(0, b - length), a))
            start = min(max(0, start), max(0, duration - length))
            let shorter = length < b - a - 1e-9
            scenes[index].start = start
            scenes[index].length = length
            if shorter, scene.actionStart != nil, scene.actionEnd != nil {
                scenes[index].actionStart = start
                scenes[index].actionEnd = start + length
            }
        }
    }

    /// 공통 영상 클립 길이 변경을 직접 편집 장면에 명시적으로 적용한다.
    /// 영상은 잔여 길이 내 기준 길이, 사진은 저장된 가중치 비율(1/30...30초)로 재계산된다.
    static func applyExplicitClipLength(
        clipLength: Double,
        scenes: inout [TrailerEditScene],
        sources: inout [VideoTrailerSource],
        recommended: Bool = true
    ) {
        guard clipLength.isFinite, clipLength > 0 else { return }
        applyClipChoice(clipLength: clipLength, recommended: recommended, scenes: &scenes, sources: sources)

        // V1 사진 비율이 있으면 1회 안전하게 마이그레이션
        for i in sources.indices where sources[i].isImage && sources[i].imageDurationPolicyVersion < 2 {
            sources[i].imageDurationRatio = VideoTrailerPhotoQuality.migrateV1ToV2Ratio(sources[i].imageDurationRatio)
            sources[i].imageDurationPolicyVersion = 2
        }

        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        for index in scenes.indices where !scenes[index].excluded && !scenes[index].timingProtected {
            let source = byID[scenes[index].sourceID]
            let bounds = sceneDurationBounds(scene: scenes[index], source: source)
            if let source, source.isImage {
                let targetLen = source.weightedImageLength(clipLength: clipLength)
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, targetLen))
            } else if let source, source.duration > 0 {
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, clipLength))
                let kept = startKeepingAction(scenes[index], start: scenes[index].start, length: scenes[index].length, sourceDuration: source.duration)
                scenes[index].start = min(max(0, kept), max(0, source.duration - scenes[index].length))
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

        // 같은 사진 소스의 다른 장면이나 시간이 고정된 장면은 건드리지 않는다. 고르지 않았거나 시간이 고정된 장면의 길이는 그대로다.
        for index in scenes.indices where ids.contains(scenes[index].id) && !scenes[index].timingProtected {
            if let photoSource = photoSourcesByID[scenes[index].sourceID] {
                let bounds = sceneDurationBounds(scene: scenes[index], source: photoSource)
                let newLength = photoSource.weightedImageLength(clipLength: clipLength)
                scenes[index].length = min(bounds.maximum, max(bounds.minimum, newLength))
            }
        }
    }

    /// 음악 비트 온셋에 맞춰 장면 길이(전환 시점)를 조절한다. 제한은 `sceneDurationBounds`가 주는 실제 원본 범위
    /// (영상은 시작 위치부터 남은 원본 길이, 사진은 1/30...30초)뿐이며, 원래 컷 시각에 가장 가까운 비트를 우선하되
    /// 무음 구간처럼 가까운 비트가 없으면 범위 안에서 더 먼 비트를 쓴다. 다음 장면이 어떤 비트에도 닿지 못하게 되는 후보는 피한다.
    /// 영상은 시작 위치를 그대로 두고, 자막·프레이밍·순서와 제외 장면은 보존된다.
    /// 음악 길이 맞춤이면 남은 장면들의 최소/최대 길이 합으로 끝점을 미리 제한해 마지막 장면이 남은 시간을 받아 음악 끝에 정확히 닿게 하며,
    /// 이미 맞춘 중간 컷은 다시 옮기지 않는다. 범위상 불가능한 장면은 그대로 두고 unalignedCount/fitResidual로 알린다.
    /// 시간이 고정된 장면과 `selectedIDs`(nil이면 전체)에 없는 장면은 길이를 바꾸지 않고, 타임라인 위치만 기존 길이만큼 차지한다.
    @discardableResult
    static func syncScenesToBeatOnsets(
        scenes: inout [TrailerEditScene],
        sources: [VideoTrailerSource],
        beatOnsets: [Double],
        musicDuration: Double,
        introOffset: Double = 0,
        policy: TrailerMusicPolicy = .loopMusic,
        maxBudget: Double? = nil,
        selectedIDs: Set<Int>? = nil,
        outroLength: Double = 0,
        refinePasses: Int = 3
    ) -> (adjustedCount: Int, averageShift: Double, unalignedCount: Int, fitResidual: Double) {
        guard !scenes.isEmpty, musicDuration.isFinite, musicDuration > 0 else { return (0, 0.0, 0, 0.0) }
        // 음악 반복과 음악 길이 맞춤은 같은 반복 타임라인을 쓴다. 반복에서는 길이 끝 비트가 다음 반복 첫 비트와 겹치므로 뺀다.
        let single = policy == .single
        let beats = Array(Set(beatOnsets.filter { $0.isFinite && $0 >= 0 && (single ? $0 <= musicDuration : $0 < musicDuration) })).sorted()
        let order = scenes.indices.filter { !scenes[$0].excluded }
        guard !beats.isEmpty, !order.isEmpty else { return (0, 0.0, 0, 0.0) }

        let eps = 1e-6
        let byID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let n = order.count
        var minLen = [Double](), maxLen = [Double](), origLen = [Double](), fixed = [Bool]()
        // 모든 길이는 출력 시간 기준의 "슬롯"(출력 길이 − 다음 장면과 겹치는 길이)이다. 다음 장면은 이 슬롯이 끝나는 시각에 시작하므로 비트 창이 곧 슬롯 끝이다.
        // 겹침은 합성기와 같은 시간표 팩토리가 현재 길이로 정하고, 저장된 배속·전환 값은 그대로 두고 조절 중에는 그 겹침 길이를 유지한다.
        // 마지막 장면과 마지막 화면(outro) 사이의 겹침도 같은 팩토리가 정하며, 마지막 슬롯에서 한 번만 센다.
        func overlapsNow() -> [Double] {
            var inputs = order.enumerated().map { k, index -> TrailerClipInput in
                let scene = scenes[index]
                return TrailerClipInput(sceneID: k, sourceID: scene.sourceID, sourceStart: max(0, scene.start),
                                        sourceLength: max(frameMinimum, scene.length.isFinite ? scene.length : frameMinimum), rate: outputRate(scene),
                                        requestedOutgoingOverlap: scene.adjustments?.transition?.dissolveDuration ?? 0)
            }
            let sceneCount = inputs.count
            guard inputs.contains(where: { $0.requestedOutgoingOverlap > 0 }) else { return [Double](repeating: 0, count: sceneCount) }
            if outroLength.isFinite, outroLength > 0.0001 {
                inputs.append(TrailerClipInput(sceneID: inputs.count, sourceID: -2, sourceStart: 0, sourceLength: outroLength))
            }
            guard let maps = try? TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs), maps.count == inputs.count else {
                return [Double](repeating: 0, count: sceneCount)
            }
            return maps.prefix(sceneCount).map { $0.outgoingOverlap.isFinite ? max(0, $0.outgoingOverlap) : 0 }
        }
        let overlaps = overlapsNow()
        for (k, index) in order.enumerated() {
            let scene = scenes[index]
            let source = byID[scene.sourceID]
            let bounds = sceneDurationBounds(scene: scene, source: source)
            let rate = outputRate(scene)
            let overlap = overlaps[k]
            // 시간을 직접 자르거나 나눈 장면(`timingProtected`)과 선택 범위 밖 장면만 길이를 그대로 두고, 타임라인에는 출력 슬롯만큼 자리를 차지한다.
            // 배속·전환·자막·음성만 손본 장면은 문맥에 따라 줄거나 움직일 수 있다(저장된 배속·전환 값은 그대로).
            if scene.timingProtected || (selectedIDs.map { !$0.contains(scene.id) } ?? false) {
                let existing = scene.length.isFinite && scene.length > 0 ? scene.length / rate : bounds.minimum / rate
                let slot = max(frameMinimum, existing - overlap)
                minLen.append(slot)
                maxLen.append(slot)
                origLen.append(slot)
                fixed.append(true)
                continue
            }
            let outMin = max(frameMinimum, bounds.minimum / rate, overlap + frameMinimum)
            let outMax = max(outMin, bounds.maximum / rate)
            let outOrig = min(outMax, max(outMin, (scene.length.isFinite ? scene.length : bounds.minimum) / rate))
            minLen.append(outMin - overlap)
            maxLen.append(outMax - overlap)
            origLen.append(outOrig - overlap)
            fixed.append(source == nil || (!source!.isImage && !(source!.duration.isFinite && source!.duration > 0)))
        }
        // 보호된 영상이 줄지 못하면 남는 박자 흡수를 사진이 떠맡아 0.2초 깜빡임이나 7초 정지가 생긴다. 사진은 원래 길이의 절반~2배 안에서만 움직인다.
        // 이 범위로 음악 길이를 못 채우게 되면(예산 불가능) 원래의 넓은 범위로 되돌린다.
        do {
            var narrowMin = minLen, narrowMax = maxLen
            for (k, index) in order.enumerated() where !fixed[k] {
                guard byID[scenes[index].sourceID]?.isImage == true else { continue }
                narrowMin[k] = max(minLen[k], min(maxLen[k], origLen[k] * 0.5))
                narrowMax[k] = min(maxLen[k], max(narrowMin[k], origLen[k] * 2.0))
            }
            let begin = max(0.0, introOffset)
            let feasible: Bool = {
                guard let b = maxBudget, b.isFinite else { return true }
                return begin + narrowMin.reduce(0, +) <= b + eps && begin + narrowMax.reduce(0, +) >= b - eps
            }()
            if feasible { minLen = narrowMin; maxLen = narrowMax }
        }
        // i번째 이후 장면들이 낼 수 있는 최소/최대 길이 합. tailSoft는 "여유 있게" 남겨 둘 시간(원래 길이의 절반 이상)이다.
        var tailMin = [Double](repeating: 0, count: n + 1)
        var tailMax = tailMin
        var tailSoft = tailMin
        for i in stride(from: n - 1, through: 0, by: -1) {
            tailMin[i] = tailMin[i + 1] + minLen[i]
            tailMax[i] = tailMax[i + 1] + maxLen[i]
            tailSoft[i] = tailSoft[i + 1] + (fixed[i] ? minLen[i] : min(maxLen[i], max(minLen[i], origLen[i] * 0.5)))
        }
        let start = max(0.0, introOffset)
        // 예산(음악 길이 맞춤의 음악 끝, 그 밖에는 지금 총길이)이 길이 범위상 가능할 때만 끝을 거기에 맞춘다. 불가능하면 비트만 맞추고 차이는 fitResidual로 알린다.
        let budget: Double? = {
            guard let b = maxBudget, b.isFinite,
                  start + tailMin[0] <= b + eps, start + tailMax[0] >= b - eps else { return nil }
            return b
        }()
        let lastAdjustable = fixed.lastIndex(of: false)

        func beatsIn(_ lo: Double, _ hi: Double) -> [Double] {
            guard hi >= lo else { return [] }
            if single { return beats.filter { $0 >= lo && $0 <= hi } }
            let firstLoop = Int(floor(max(0, lo) / musicDuration))
            let lastLoop = Int(floor(hi / musicDuration))
            guard lastLoop >= firstLoop else { return [] }
            var out: [Double] = []
            for loop in firstLoop...lastLoop {
                let base = Double(loop) * musicDuration
                for b in beats where base + b >= lo && base + b <= hi { out.append(base + b) }
            }
            return out
        }

        func firstBeat(from x: Double) -> Double? {
            if single { return beats.first { $0 >= x } }
            let base = floor(max(0, x) / musicDuration) * musicDuration
            if let b = beats.first(where: { base + $0 >= x }) { return base + b }
            return base + musicDuration + beats[0]
        }

        // 시작 s에서 i번째 장면의 끝점이 가질 수 있는 실제 범위(원본 길이 범위 + 남은 장면이 음악 끝을 채울 수 있는 범위)
        func endWindow(_ i: Int, _ s: Double) -> (lo: Double, hi: Double) {
            var lo = s + minLen[i]
            var hi = s + maxLen[i]
            if let budget {
                lo = max(lo, budget - tailMax[i + 1])
                hi = min(hi, budget - tailMin[i + 1])
            } else if let maxBudget {
                hi = min(hi, maxBudget)
            }
            return (lo, hi)
        }

        // i번째 장면이 e에서 끝날 때 다음 조절 대상 장면이 범위 안에서 닿을 비트가 하나라도 있는지(음악 끝을 채우는 마지막 장면은 예외)
        func nextCanReachBeat(_ i: Int, _ e: Double) -> Bool {
            var s = e
            var j = i + 1
            while j < n, fixed[j] { s += minLen[j]; j += 1 }
            if j >= n || (budget != nil && j == lastAdjustable) { return true }
            let window = endWindow(j, s)
            guard let first = firstBeat(from: window.lo - eps) else { return false }
            return first <= window.hi + eps
        }

        var cursor = start
        var origCursor = start
        var adjustedCount = 0
        var unalignedCount = 0
        var totalShift = 0.0

        for i in 0..<n {
            let origEnd = origCursor + origLen[i]
            origCursor = origEnd
            if fixed[i] {
                cursor += minLen[i]
                continue
            }
            let window = endWindow(i, cursor)
            let currentEnd = cursor + origLen[i]
            var pick: Double?
            let end: Double
            if window.lo > window.hi + eps {
                unalignedCount += 1
                end = currentEnd
            } else if budget != nil, i == lastAdjustable {
                // 마지막 장면은 비트가 아니라 음악 끝에 맞추는 장면: 남은 시간을 그대로 받는다.
                end = min(window.hi, max(window.lo, currentEnd))
            } else {
                // 원래 컷 시각에 가까운 비트부터. 남은 장면이 너무 짧아지지 않고(소프트) 다음 장면이 닿을 수 있는 후보를 먼저 쓴다.
                let ordered = beatsIn(window.lo - eps, window.hi + eps).sorted { abs($0 - origEnd) < abs($1 - origEnd) }
                pick = ordered.first { candidate in
                    (budget.map { candidate <= $0 - tailSoft[i + 1] + eps } ?? true) && nextCanReachBeat(i, candidate)
                } ?? ordered.first { nextCanReachBeat(i, $0) } ?? ordered.first
                if pick == nil { unalignedCount += 1 }
                end = pick ?? min(window.hi, max(window.lo, currentEnd))
            }

            var newLen = min(maxLen[i], max(minLen[i], end - cursor))
            // 이미 비트에서 20ms 이내이고 예산 범위 안이면 길이를 건드리지 않는다.
            if pick != nil, abs(newLen - origLen[i]) <= 0.02, currentEnd >= window.lo - eps, currentEnd <= window.hi + eps { newLen = origLen[i] }
            let index = order[i]
            // 슬롯(출력)을 원본 길이로 되돌린다: 원본 = (슬롯 + 겹침) × 배속. 저장된 배속·전환 값은 건드리지 않는다.
            let sourceLength = (newLen + overlaps[i]) * outputRate(scenes[index])
            if abs(sourceLength - scenes[index].length) > 1e-9 {
                scenes[index].length = sourceLength
                if let src = sources.first(where: { $0.id == scenes[index].sourceID }), !src.isImage, src.duration > 0 {
                    scenes[index].start = startKeepingAction(scenes[index], start: scenes[index].start, length: sourceLength, sourceDuration: src.duration)
                }
            }
            if pick != nil, abs(newLen - origLen[i]) > 0.02 {
                adjustedCount += 1
                totalShift += abs(newLen - origLen[i])
            }
            cursor += newLen
        }

        let avgShift = adjustedCount > 0 ? totalShift / Double(adjustedCount) : 0.0

        // 길이가 바뀌면 팩토리가 겹침을 다시 자를 수 있다(짧아진 이웃 등). 최종 시간표의 겹침이 쓴 값과 다르면 그 값으로 다시 맞춘다.
        // 저장된 배속·전환 값은 그대로이고, 보호·선택 밖 장면은 길이를 바꾸지 않으며, 예산은 같은 maxBudget으로 다시 받는다.
        let finalOverlaps = overlapsNow()
        if refinePasses > 0, zip(overlaps, finalOverlaps).contains(where: { abs($0 - $1) > 0.001 }) {
            let again = syncScenesToBeatOnsets(
                scenes: &scenes, sources: sources, beatOnsets: beatOnsets, musicDuration: musicDuration, introOffset: introOffset,
                policy: policy, maxBudget: maxBudget, selectedIDs: selectedIDs, outroLength: outroLength, refinePasses: refinePasses - 1)
            let count = adjustedCount + again.adjustedCount
            let shift = count > 0 ? (avgShift * Double(adjustedCount) + again.averageShift * Double(again.adjustedCount)) / Double(count) : 0.0
            return (count, shift, again.unalignedCount, again.fitResidual)
        }

        // 최종 시간표(최종 겹침)에서 실제로 비트에 닿은 컷만 센다. 닿지 못한 조절 장면은 unalignedCount, 예산 차이는 최종 끝에서 잰다.
        var finalCursor = start
        var finalUnaligned = 0
        for (k, index) in order.enumerated() {
            let scene = scenes[index]
            let out = (scene.length.isFinite ? max(0, scene.length) : 0) / outputRate(scene)
            finalCursor += max(0, out - finalOverlaps[k])
            if fixed[k] || (budget != nil && k == lastAdjustable) { continue }
            if beatsIn(finalCursor - 0.02, finalCursor + 0.02).isEmpty { finalUnaligned += 1 }
        }
        let residual = maxBudget.map { $0 - finalCursor } ?? 0.0
        return (adjustedCount, avgShift, finalUnaligned, abs(residual) <= 0.01 ? 0.0 : residual)
    }

    /// 비트 맞춤. 음악 반복 횟수는 고른 그대로이고(자동으로 늘리지 않는다) 예산을 넘기지 않는다: 음악 길이 맞춤은 음악 끝,
    /// 다른 정책은 지금 포함 장면 총길이가 끝이다(Android와 같은 규칙). 화면의 비트 버튼과 렌더 하네스가 이 한 함수를 같이 부른다.
    /// 반환 `scenes`는 맞춘 결과이고 호출자가 적용한다.
    static func syncToBeatsWithMinimumRepeats(
        scenes: [TrailerEditScene],
        sources: [VideoTrailerSource],
        beatOnsets: [Double],
        music: TrailerMusicSelection,
        cardsDuration: Double,
        introOffset: Double,
        outroDuration: Double,
        selectedIDs: Set<Int>? = nil
    ) -> (scenes: [TrailerEditScene], fitCount: Int,
          result: (adjustedCount: Int, averageShift: Double, unalignedCount: Int, fitResidual: Double)) {
        let fit = music.policy == .fitMusic && music.duration.isFinite && music.duration > 0
        var next = scenes
        // 본편 길이는 마지막 장면↔마지막 화면 겹침까지 센 같은 시간표 값이며, 카드(인트로·아웃트로)는 한 번만 센다.
        let body = outputBodyDuration(scenes, outroLength: outroDuration)
        let result = syncScenesToBeatOnsets(
            scenes: &next, sources: sources, beatOnsets: beatOnsets, musicDuration: music.duration,
            introOffset: introOffset, policy: music.policy,
            maxBudget: fit ? music.duration * Double(music.fitCount) - outroDuration : introOffset + body,
            selectedIDs: selectedIDs, outroLength: outroDuration)
        return (next, music.fitCount, result)
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
        let seeded = TrailerPreparedPlan.seedEdits(mode: mode, sources: sources, total: total, clipLength: clipLength, music: music)
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
            outroCard: outroCard,
            voiceovers: voiceovers)
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
    var voiceovers: [TrailerVoiceoverTake] = []
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
    /// 음성 해설 id → 이 세션이 들고 있는 사본(없으면 nil).
    var voiceURL: (UUID) -> URL? = { _ in nil }
    /// 가져오거나 녹음한 파일을 세션 사본으로 두고 프로젝트 상대 경로를 돌려준다. 원본은 읽기만 한다.
    var stageVoiceover: (URL, UUID) throws -> String = { _, _ in throw CocoaError(.fileWriteUnknown) }
    /// 녹음 임시 파일을 둘 폴더(이 세션의 작업 폴더).
    var voiceWorkFolder: () -> URL? = { nil }
    /// 지금 편집본을 저장하고 성공 여부를 돌려준다(녹음 산출물의 소유권을 넘기기 전 확인).
    var saveDraftNow: () async -> Bool = { false }
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
            if scenes![index].caption != c { scenes![index].manual.insert(.caption) }
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
            for index in scenes!.indices where scenes![index].caption != value {
                scenes![index].caption = value
                scenes![index].manual.insert(.caption)
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
    var volume = 1.0
    /// 고급 편집(배속·색상·키프레임·디졸브·자막 큐). `length`는 원본 구간 길이, 출력 길이는 `length / rate`.
    var adjustments: TrailerClipAdjustments? = nil
    /// 앞 장면과 실제로 겹치는 길이(디졸브). 출력 시간표에서 한 번만 뺀다.
    var incomingOverlap = 0.0
    var rate: Double { adjustments?.rate ?? 1 }
    /// 타임라인에서 이 장면이 차지하는 길이: 배속을 적용한 출력 길이에서 들어오는 겹침을 한 번 뺀 값.
    /// 별도의 표시용 하한을 두지 않는다(합성기의 시간표 한 칸 1/600초만 넘으면 된다). 물리적 프레임 하한(1/30초)은 예산이 지킨다.
    var timelineLength: Double { max(1.0 / 600.0, length / rate - incomingOverlap) }

    /// 사진 내보내기와 같은 규칙: 직접 정한 구성이 있을 때만 고정 구성, 없으면 자동 효과(nil).
    var framing: VideoTrailerImageClip.Framing? {
        (fitsFrame || offsetX != 0 || offsetY != 0)
            ? .init(fitsFrame: fitsFrame, offsetX: offsetX, offsetY: offsetY) : nil
    }
}

/// 필름스트립과 편집 줄이 함께 쓰는 시간 규칙. 구간 길이는 합성기와 같은 출력 시간으로 세고, 플레이어 위치는 전체 길이에 대한 비율로 읽는다.
enum TrailerTimelineGeometry {
    static func weightedLength(_ segment: TrailerTimelineSegment) -> Double { segment.timelineLength }

    static func total(_ segments: [TrailerTimelineSegment]) -> Double {
        max(0.001, segments.reduce(0) { $0 + weightedLength($1) })
    }

    /// 출력 초로 센 재생 위치. 플레이어가 없거나 길이를 모르면 nil이다.
    static func playheadSeconds(currentSeconds: Double, durationSeconds: Double, hasPlayer: Bool,
                                segments: [TrailerTimelineSegment]) -> Double? {
        guard hasPlayer, durationSeconds > 0, currentSeconds.isFinite, !segments.isEmpty else { return nil }
        return min(max(currentSeconds / durationSeconds, 0), 1) * total(segments)
    }

    /// 선택한 본편 장면 안에서 `playhead`(출력 초)가 놓인 장면 안 시각. 선택한 장면 밖이거나 시작/마지막 화면 위면 nil이다.
    static func localTime(ofScene sceneID: Int?, atSeconds playhead: Double?, segments: [TrailerTimelineSegment]) -> Double? {
        guard let sceneID, let playhead, playhead.isFinite else { return nil }
        var start = 0.0
        for segment in segments {
            let length = weightedLength(segment)
            if segment.kind == .clip, segment.sceneID == sceneID {
                guard playhead >= start, playhead <= start + length else { return nil }
                return playhead - start
            }
            start += length
        }
        return nil
    }

    /// 눈금 간격(초): 눈금 글자가 겹치지 않도록 간격이 `minimumPoints` 이상 되는 가장 짧은 값.
    static func tickStep(total: Double, width: Double, minimumPoints: Double = 46) -> Double {
        let steps: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1_800, 3_600]
        guard total > 0, width > 0 else { return steps[0] }
        return steps.first { $0 / total * width >= minimumPoints } ?? steps[steps.count - 1]
    }
}

/// 필름스트립 바로 아래의 장면 편집 줄: 출력 초 눈금자, 장면마다 길이, 선택한 장면의 양끝 손잡이로 직접 다듬기, 이동·잠금 메뉴.
/// 필름스트립과 같은 구간 목록·같은 폭 규칙을 쓰므로 시작/마지막 화면, 제외된 장면, 재생 위치가 서로 어긋나지 않는다.
/// 손잡이를 끄는 동안은 새 길이만 보여 주고 손을 뗄 때 한 번 적용한다(그동안 재생하거나 다시 그리지 않는다).
struct TrailerSceneEditLane: View {
    static let rulerHeight: CGFloat = 14
    static let laneHeight: CGFloat = 32
    static let filmstripLaneHeight: CGFloat = 46
    /// 눈금자 + 줄 + 둘 사이 간격.
    static var totalHeight: CGFloat { rulerHeight + laneHeight + 2 }
    /// 필름스트립 모드는 눈금자를 손가락으로 끌 수 있게 24pt로 키운다.
    static let filmstripRulerHeight: CGFloat = 24
    static var filmstripTotalHeight: CGFloat { filmstripRulerHeight + filmstripLaneHeight + 2 }

    let segments: [TrailerTimelineSegment]
    let scenes: [TrailerEditScene]
    let sources: [VideoTrailerSource]
    let selectedSceneID: Int?
    @ObservedObject var bridge: TrailerTimelineBridge
    var showsFilmstrip: Bool = false
    /// 필름스트립 모드에서 상세가 닫혀 남는 높이를 장면 블록에 더해 준다(편집 공간으로 쓴다).
    var extraLaneHeight: CGFloat = 0
    var onSelect: (Int) -> Void
    /// 장면 id, 끝 손잡이, 끈 거리(출력 초). 적용 가능 여부는 호출한 쪽의 `trim`이 정한다.
    var onTrim: (Int, TrailerSceneEditor.TrimEdge, Double) -> Void
    /// 장면 id, 포함된 이웃 기준 이동 칸(-1 앞, +1 뒤).
    var onMove: (Int, Int) -> Void
    var onToggleProtection: (Int) -> Void

    private struct DragState: Equatable {
        var sceneID: Int
        var edge: TrailerSceneEditor.TrimEdge
        var seconds: Double
    }
    @State private var drag: DragState?

    private var total: Double { TrailerTimelineGeometry.total(segments) }
    private var effectiveLaneHeight: CGFloat { showsFilmstrip ? Self.filmstripLaneHeight + max(0, extraLaneHeight) : Self.laneHeight }
    private var effectiveRulerHeight: CGFloat { showsFilmstrip ? Self.filmstripRulerHeight : Self.rulerHeight }

    var body: some View {
        let sceneByID = Dictionary(scenes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sourceByID = Dictionary(sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            VStack(alignment: .leading, spacing: 2) {
                ruler(width: width)
                    .frame(width: width, height: effectiveRulerHeight, alignment: .topLeading)
                lane(width: width, scenes: sceneByID, sources: sourceByID)
                    .frame(width: width, height: effectiveLaneHeight, alignment: .topLeading)
            }
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("장면 편집 줄")
    }

    // MARK: 눈금자

    private func ruler(width: CGFloat) -> some View {
        let step = TrailerTimelineGeometry.tickStep(total: total, width: Double(width))
        let count = Int((total / step).rounded(.down))
        let totalText = videoTrailerTime(total)
        // 오른쪽 '출력' 레이블과 겹치는 눈금은 숫자를 숨기고 선만 남긴다.
        let labelLimit = width - CGFloat(24 + totalText.count * 6) - CGFloat(6 + totalText.count * 6)
        return ZStack(alignment: .topLeading) {
            ForEach(0...max(0, count), id: \.self) { index in
                let seconds = Double(index) * step
                tick(seconds: seconds, width: width, showsLabel: CGFloat(seconds / total) * width <= labelLimit)
            }
            Text("출력 \(totalText)")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize()
                .frame(width: width, alignment: .trailing)
        }
        .contentShape(Rectangle())
        .overlay {
            if showsFilmstrip {
                TrailerTimelineNativeInput(
                    onPress: { fraction in
                        guard bridge.hasPlayer else { return }
                        bridge.seek(toFraction: fraction)
                    },
                    onDrag: { fraction in
                        guard bridge.hasPlayer else { return }
                        bridge.seek(toFraction: fraction)
                    },
                    onRelease: { fraction, _ in
                        guard bridge.hasPlayer else { return }
                        bridge.seek(toFraction: fraction)
                    }
                )
            }
        }
        .accessibilityElement()
        .accessibilityLabel("출력 시간 눈금자")
        .accessibilityValue("전체 \(videoTrailerTime(total))")
    }

    private func tick(seconds: Double, width: CGFloat, showsLabel: Bool) -> some View {
        let x = CGFloat(seconds / total) * width
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(.white.opacity(0.5)).frame(width: 1, height: 5)
            if showsLabel {
                Text(videoTrailerTime(seconds))
                    .font(.system(size: 9).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize()
                    .offset(x: 3, y: 0)
            }
        }
        .offset(x: x)
        .allowsHitTesting(false)
    }

    // MARK: 장면 줄

    private func lane(width: CGFloat, scenes sceneByID: [Int: TrailerEditScene],
                      sources sourceByID: [Int: VideoTrailerSource]) -> some View {
        let totalSeconds = total
        let numbers = clipNumbers()
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                ForEach(segments) { segment in
                    block(segment, width: max(1, width * CGFloat(TrailerTimelineGeometry.weightedLength(segment) / totalSeconds)),
                          number: numbers[segment.id], scene: segment.sceneID.flatMap { sceneByID[$0] },
                          source: segment.sourceID.flatMap { sourceByID[$0] }, pointsPerSecond: width / CGFloat(totalSeconds))
                }
            }
            playhead(width: width)
        }
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    private func clipNumbers() -> [String: Int] {
        var result: [String: Int] = [:]
        var number = 0
        for segment in segments where segment.kind == .clip {
            number += 1
            result[segment.id] = number
        }
        return result
    }

    @ViewBuilder
    private func playhead(width: CGFloat) -> some View {
        if let seconds = TrailerTimelineGeometry.playheadSeconds(
            currentSeconds: bridge.currentSeconds, durationSeconds: bridge.durationSeconds,
            hasPlayer: bridge.hasPlayer, segments: segments) {
            Rectangle().fill(.white)
                .frame(width: 2, height: effectiveLaneHeight)
                .shadow(color: .black.opacity(0.7), radius: 1.5)
                .offset(x: min(max(CGFloat(seconds / total) * width - 1, 0), width - 2))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func block(_ segment: TrailerTimelineSegment, width: CGFloat, number: Int?, scene: TrailerEditScene?,
                       source: VideoTrailerSource?, pointsPerSecond: CGFloat) -> some View {
        if segment.kind == .clip, let scene {
            clipBlock(segment, width: width, number: number ?? 0, scene: scene, source: source, pointsPerSecond: pointsPerSecond)
        } else {
            ZStack {
                Color.white.opacity(0.08)
                if width >= 34 {
                    Text(segment.kind == .intro ? "시작" : "마지막")
                        .font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(width: width, height: effectiveLaneHeight)
            .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.6)).frame(width: 1) }
            .accessibilityElement()
            .accessibilityLabel(segment.kind == .intro ? "시작 화면" : "마지막 화면")
            .accessibilityValue(String(format: "%.1f초", segment.length))
        }
    }

    private func clipBlock(_ segment: TrailerTimelineSegment, width: CGFloat, number: Int, scene: TrailerEditScene,
                           source: VideoTrailerSource?, pointsPerSecond: CGFloat) -> some View {
        let isSelected = selectedSceneID == scene.id
        let candidate = drag.flatMap { state -> (start: Double, length: Double)? in
            guard state.sceneID == scene.id else { return nil }
            return TrailerSceneEditor.trimCandidate(scene, edge: state.edge, by: state.seconds, source: source)
        }
        // 라벨은 눈금자와 같은 출력 길이다(배속이 있으면 원본 길이 ÷ 배속).
        let shownLength = (candidate?.length ?? segment.length) / segment.rate
        let protectedNote = scene.timingProtected ? ", 직접 편집 보호됨" : ""
        let spoken = "클립 \(number), " + String(format: "%.1f", shownLength) + "초" + protectedNote
        return ZStack {
            if showsFilmstrip, let source {
                TrailerSceneThumb(source: source, time: segment.start)
                    .frame(width: width, height: effectiveLaneHeight)
                    .clipped()
                (isSelected ? PorcelainMetrics.accent.opacity(0.32) : Color.black.opacity(0.28))
            } else {
                (isSelected ? PorcelainMetrics.accent.opacity(0.55) : Color.white.opacity(0.16))
            }
            blockLabel(number: number, length: shownLength, isProtected: scene.timingProtected, width: width,
                       isTrimming: candidate != nil)
        }
        .frame(width: width, height: effectiveLaneHeight)
        .clipped()
        .overlay(alignment: .trailing) { Rectangle().fill(.black.opacity(0.6)).frame(width: 1) }
        .overlay { if isSelected { RoundedRectangle(cornerRadius: 3).stroke(.white.opacity(0.95), lineWidth: showsFilmstrip ? 2.0 : 1.5) } }
        .overlay(alignment: .leading) { if isSelected { handle(.start, scene: scene, width: width, pointsPerSecond: pointsPerSecond) } }
        .overlay(alignment: .trailing) { if isSelected { handle(.end, scene: scene, width: width, pointsPerSecond: pointsPerSecond) } }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(scene.id) }
        .contextMenu { blockMenu(scene) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(spoken)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAction(named: "선택") { onSelect(scene.id) }
        .accessibilityAction(named: "앞으로 이동") { onMove(scene.id, -1) }
        .accessibilityAction(named: "뒤로 이동") { onMove(scene.id, 1) }
        .accessibilityAction(named: scene.timingProtected ? "보호 해제" : "보호") { onToggleProtection(scene.id) }
    }

    private func blockLabel(number: Int, length: Double, isProtected: Bool, width: CGFloat, isTrimming: Bool) -> some View {
        HStack(spacing: 2) {
            if width >= 30 {
                Text(isTrimming || width >= 52 ? String(format: "%.1f초", length) : String(format: "%.1f", length))
                    .font(.system(size: 10, weight: isTrimming ? .bold : .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .shadow(color: showsFilmstrip ? .black.opacity(0.75) : .clear, radius: 1.5)
                    .lineLimit(1).minimumScaleFactor(0.6)
            }
            if isProtected && width >= 44 {
                Image(systemName: "lock.fill").font(.system(size: 8)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding(.horizontal, 14)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func blockMenu(_ scene: TrailerEditScene) -> some View {
        Button("앞으로 이동") { onMove(scene.id, -1) }
        Button("뒤로 이동") { onMove(scene.id, 1) }
        Button(scene.timingProtected ? "보호 해제 (자동 추천 허용)" : "보호 (자동 추천 제외)") { onToggleProtection(scene.id) }
    }

    /// 선택한 장면의 한쪽 끝을 끌어 다듬는 손잡이. 폭이 좁은 장면은 손잡이도 좁아지지만 양쪽이 겹치지 않는다.
    private func handle(_ edge: TrailerSceneEditor.TrimEdge, scene: TrailerEditScene, width: CGFloat,
                        pointsPerSecond: CGFloat) -> some View {
        let name = edge == .start ? "시작 위치" : "끝 위치"
        return Rectangle()
            .fill(.white.opacity(0.001))
            .frame(width: max(8, min(16, width / 2)), height: effectiveLaneHeight)
            .overlay(Capsule().fill(.white).frame(width: 3, height: showsFilmstrip ? 22 : 16).shadow(color: .black.opacity(0.6), radius: 1))
            .contentShape(Rectangle())
            // Catalyst 합성 뷰는 SwiftUI DragGesture를 받지 못하므로(필름스트립과 같은 이유) 실제 UIKit 입력 뷰로 끈다.
            // 끈 거리는 눌린 점 기준 창 좌표라 손잡이 폭 밖까지 이어지고, 전체 타임라인의 pt/초(`pointsPerSecond`)로 초로 바꾼다.
            // 끄는 동안은 후보 길이만 보여 주고(`drag`), 놓을 때 한 번만 `onTrim`으로 적용한다. 시스템이 끊으면 적용하지 않는다.
            .overlay {
                TrailerTimelineNativeInput(onTranslation: { points, phase in
                    guard pointsPerSecond > 0 else { return }
                    let seconds = Double(points / pointsPerSecond)
                    switch phase {
                    case .changed:
                        drag = DragState(sceneID: scene.id, edge: edge, seconds: seconds)
                    case .ended:
                        drag = nil
                        if abs(points) >= 1 { onTrim(scene.id, edge, seconds) }
                    case .cancelled:
                        drag = nil
                    }
                })
            }
            .accessibilityElement()
            .accessibilityLabel("\(name) 다듬기")
            .accessibilityValue(String(format: "클립 길이 %.1f초", scene.length))
            .accessibilityHint("끌어서 원본 안에서 구간을 조절합니다. 위아래로 넘기면 0.1초씩 조절합니다.")
            .accessibilityAdjustableAction { direction in
                onTrim(scene.id, edge, direction == .increment ? 0.1 : -0.1)
            }
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

    private var total: Double { max(0.001, segments.reduce(0) { $0 + $1.timelineLength }) }
    private var clipCount: Int { segments.filter { $0.kind == .clip }.count }

    private func weight(_ segment: TrailerTimelineSegment) -> Double { segment.timelineLength / total }

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

/// 타임라인 위의 실제 UIKit 입력 뷰. hover(마우스 이동)와 눌러서 끌기/클릭을 0...1 비율로 알려 준다.
/// 필름스트립은 비율 콜백만 쓰고(기본값은 아무것도 하지 않음), 편집 줄 손잡이는 `onTranslation`으로 가로 끈 거리를 받는다.
struct TrailerTimelineNativeInput: UIViewRepresentable {
    enum TranslationPhase: Equatable { case changed, ended, cancelled }

    var onHover: (Double) -> Void = { _ in }
    var onHoverEnd: () -> Void = {}
    var onPress: (Double) -> Void = { _ in }
    var onDrag: (Double) -> Void = { _ in }
    var onRelease: (Double, Bool) -> Void = { _, _ in }
    /// 눌린 점에서 가로로 끈 거리(pt, 창 좌표 기준). 보기 경계로 자르지 않아 손잡이 폭 밖까지 끌어도 그대로 이어진다.
    /// 놓으면 `.ended` 한 번, 시스템이 끊으면 `.cancelled`로 끝난다. nil이면 아무것도 보내지 않는다.
    var onTranslation: ((CGFloat, TranslationPhase) -> Void)? = nil

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
        private var pressOrigin: CGPoint?
        private var moved = false
        init(_ parent: TrailerTimelineNativeInput) { self.parent = parent }

        /// 눌린 점 기준 가로 끈 거리. 창 좌표라 보기 안에 갇히지 않고, 끄는 동안 보기가 움직여도 흔들리지 않는다.
        private func translation(_ recognizer: UIGestureRecognizer) -> CGFloat {
            guard let origin = pressOrigin else { return 0 }
            return recognizer.location(in: nil).x - origin.x
        }

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
                pressOrigin = recognizer.location(in: nil)
                moved = false
                parent.onPress(fraction(recognizer))
            case .changed:
                if let start = pressStart, hypot(point.x - start.x, point.y - start.y) >= 4 { moved = true }
                parent.onDrag(fraction(recognizer))
                parent.onTranslation?(translation(recognizer), .changed)
            case .ended:
                parent.onRelease(fraction(recognizer), moved)
                parent.onTranslation?(translation(recognizer), .ended)
                pressStart = nil
                pressOrigin = nil
            case .cancelled, .failed:
                parent.onRelease(fraction(recognizer), true)
                parent.onTranslation?(translation(recognizer), .cancelled)
                pressStart = nil
                pressOrigin = nil
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
            + (scene.excluded ? (scene.budgetExcluded ? " · 길이 맞춤으로 뺌" : " · 제외됨") : "") + (scene.caption == nil ? "" : " · 자막")
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
                        Text("장면 \(index + 1) / \(scenes?.count ?? 0) · \(source.isImage ? "사진" : "영상")" + (scene.excluded ? (scene.budgetExcluded ? " · 길이 맞춤으로 뺌" : " · 제외됨") : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button {
                            set { $0.excluded.toggle(); $0.budgetExcluded = false }
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
                                            $0.actionStart = nil; $0.actionEnd = nil
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
                                        set: { val in set { $0.start = val; $0.actionStart = nil; $0.actionEnd = nil } }
                                    ),
                                    length: Binding(
                                        get: { scene.length },
                                        set: { val in set { $0.length = val; $0.actionStart = nil; $0.actionEnd = nil } }
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
            Text("장면 \(index + 1) / \(scenes?.count ?? 0) · \(source.isImage ? "사진" : "영상")" + (scene.excluded ? (scene.budgetExcluded ? " · 길이 맞춤으로 뺌" : " · 제외됨") : ""))
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
                        $0.actionStart = nil; $0.actionEnd = nil
                    }
                }), in: 0...(duration - 0.2)).accessibilityLabel("시작 지점")
                Text("끝").font(.caption).foregroundStyle(.secondary)
                Slider(value: Binding(get: { end }, set: { value in
                    set { $0.length = max(0.2, min(duration, value) - $0.start); $0.actionStart = nil; $0.actionEnd = nil }
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
        Button { set { $0.excluded.toggle(); $0.budgetExcluded = false } } label: {
            Label(scene.excluded ? "포함" : "제외", interfaceSystemImage: scene.excluded ? "eye" : "eye.slash")
                .frame(minHeight: 44)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - 렌더 전 초안 재생

/// 완성 영상이 없을 때 사진·영상·타이틀 카드로 초안을 재생하기 위한 입력.
struct TrailerDraftPreviewInput {
    var projectID: UUID? = nil
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
    /// 독립 음성 해설 1레인(사본 파일이 있는 것).
    var voices: [TrailerComposerVoice] = []
    /// 사본 파일을 찾지 못한 직접 놓은 해설 수. 0이 아니면 미리보기가 조용히 빼지 않고 오류로 알린다.
    var missingVoiceCount = 0

    /// 음악 배치·음량이 달라질 때만 바뀌는 키. 시계 재생은 이 키와 무관하다.
    var musicKey: String {
        guard let music else { return "none" }
        let layout = segments.map { "\($0.id):\($0.length):\($0.start):\($0.muted)" }.joined(separator: ",")
        let projStr = projectID?.uuidString ?? "default"
        let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: music.url)
        return "\(projStr)|\(music.recordID)|\(music.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)|\(music.policy.rawValue)|\(music.fitCount)|\(music.autoDuck)|\(music.level)|\(layout)"
    }

    /// 타임라인 필름스트립과 같은 가중치로 센 전체 길이.
    var totalDuration: Double {
        max(segments.reduce(0) { $0 + $1.timelineLength }, voiceFloor)
    }
    /// 직접 놓은 음성 해설이 요구하는 출력 끝. 영상이 더 짧아도 해설을 자르지 않는다.
    var voiceFloor: Double { voices.compactMap { $0.take.requiredOutputEnd }.max() ?? 0 }
    var usesAdvanced: Bool { !voices.isEmpty || missingVoiceCount > 0 || segments.contains { $0.adjustments?.isAdvanced == true } }

    func location(at seconds: Double) -> (index: Int, offset: Double)? {
        var acc = 0.0
        for (index, segment) in segments.enumerated() {
            let length = segment.timelineLength
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
            acc += segment.timelineLength
        }
        return nil
    }
}

/// 미리보기 자산(사진 썸네일, 타이틀 카드, 비디오 컴포지션, 메타데이터)을 프로젝트 단위로 유지하는 바운디드 캐시.
/// 인라인과 전체화면 전환, 그리고 탐색 중에 미리보기가 재생성되어도 준비 상태를 유지한다.
/// 앱 전용 private Caches 폴더에 영구 보관하여 프로세스 종료 후 동일 편집 재오픈 시 디스크에서 고속 재사용한다.
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

    private nonisolated static let cacheSchemaVersion = "v1"
    private nonisolated static let maxDiskCacheBytes: Int64 = 120 * 1024 * 1024
    private nonisolated static let maxDiskFileCount = 4096
    private nonisolated static let stateLock = NSLock()
    nonisolated(unsafe) private static var lastPruneTime: TimeInterval = 0
    nonisolated(unsafe) private static var attributeMemo: [String: (size: Int64, mtime: Int64, at: TimeInterval)] = [:]

    nonisolated static let cacheFolder: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("NasFinderPreviewCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    nonisolated static func sha256(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// 크기·수정시각. 뷰 키 계산에서 반복 호출되므로 짧은 시간 동안 메모리에 둔 값을 쓰고, 항목 수를 제한한다.
    nonisolated static func sourceFileAttributes(for url: URL) -> (fileSize: Int64, mtime: Int64) {
        let path = url.path
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        if let hit = attributeMemo[path], now - hit.at < 3 {
            stateLock.unlock()
            return (hit.size, hit.mtime)
        }
        stateLock.unlock()

        var size: Int64 = 0
        var mtime: Int64 = 0
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) {
            size = Int64(values.fileSize ?? 0)
            mtime = Int64(values.contentModificationDate?.timeIntervalSince1970 ?? 0)
        }

        stateLock.lock()
        if attributeMemo.count > 256 { attributeMemo.removeAll(keepingCapacity: true) }
        attributeMemo[path] = (size, mtime, now)
        stateLock.unlock()
        return (size, mtime)
    }

    nonisolated static func photoCacheKey(sourceID: Int, url: URL, projectID: UUID? = nil) -> String {
        let attrs = sourceFileAttributes(for: url)
        let projStr = projectID?.uuidString ?? "default"
        let raw = "photo:\(cacheSchemaVersion):\(projStr):\(sourceID):\(url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
        return sha256(raw)
    }

    nonisolated static func videoSizeCacheKey(url: URL) -> String {
        let attrs = sourceFileAttributes(for: url)
        let raw = "size:\(cacheSchemaVersion):\(url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
        return sha256(raw)
    }

    private struct SizeRecord: Codable { let w: Double; let h: Double }

    init() {
        photoCache.countLimit = 64
        cardCache.countLimit = 16
    }

    // MARK: - Photos

    func photo(for sourceID: Int, url: URL, projectID: UUID? = nil) -> UIImage? {
        let key = Self.photoCacheKey(sourceID: sourceID, url: url, projectID: projectID)
        return photoCache.object(forKey: key as NSString)
    }

    func setPhoto(_ image: UIImage, for sourceID: Int, url: URL, projectID: UUID? = nil) {
        let key = Self.photoCacheKey(sourceID: sourceID, url: url, projectID: projectID)
        photoCache.setObject(image, forKey: key as NSString)
        let fileURL = Self.cacheFolder.appendingPathComponent("photo_\(key).jpg")
        Self.writeAsync(to: fileURL) { image.jpegData(compressionQuality: 0.9) }
    }

    func loadPhoto(for sourceID: Int, url: URL, projectID: UUID? = nil) async -> UIImage? {
        if let existing = photo(for: sourceID, url: url, projectID: projectID) { return existing }
        let key = Self.photoCacheKey(sourceID: sourceID, url: url, projectID: projectID)
        let fileURL = Self.cacheFolder.appendingPathComponent("photo_\(key).jpg")
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value

        if let loaded {
            photoCache.setObject(loaded, forKey: key as NSString)
            return loaded
        }
        return nil
    }

    func hasOrLoadPhoto(for sourceID: Int, url: URL, projectID: UUID? = nil) async -> UIImage? {
        await loadPhoto(for: sourceID, url: url, projectID: projectID)
    }

    // MARK: - Cards

    func card(for key: String) -> UIImage? {
        cardCache.object(forKey: key as NSString)
    }

    func setCard(_ image: UIImage, for key: String) {
        cardCache.setObject(image, forKey: key as NSString)
        let fileURL = Self.cacheFolder.appendingPathComponent("card_\(key).png")
        Self.writeAsync(to: fileURL) { image.pngData() }
    }

    func loadCard(for key: String) async -> UIImage? {
        if let existing = card(for: key) { return existing }
        let fileURL = Self.cacheFolder.appendingPathComponent("card_\(key).png")
        let loaded = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard FileManager.default.fileExists(atPath: fileURL.path),
                  let data = try? Data(contentsOf: fileURL),
                  let img = UIImage(data: data) else { return nil }
            return img.preparingForDisplay() ?? img
        }.value

        if let loaded {
            cardCache.setObject(loaded, forKey: key as NSString)
            return loaded
        }
        return nil
    }

    func hasOrLoadCard(for key: String) async -> UIImage? {
        await loadCard(for: key)
    }

    // MARK: - Video Sizes

    func videoSize(for url: URL) -> CGSize? {
        videoSizes[Self.videoSizeCacheKey(url: url)]
    }

    func setVideoSize(_ size: CGSize, for url: URL) {
        let key = Self.videoSizeCacheKey(url: url)
        if videoSizes[key] == nil {
            videoSizeKeys.append(key)
            if videoSizeKeys.count > 64 {
                let old = videoSizeKeys.removeFirst()
                videoSizes.removeValue(forKey: old)
            }
        }
        videoSizes[key] = size

        let record = SizeRecord(w: Double(size.width), h: Double(size.height))
        let fileURL = Self.cacheFolder.appendingPathComponent("size_\(key).json")
        Self.writeAsync(to: fileURL) { try? JSONEncoder().encode(record) }
    }

    func loadVideoSize(for url: URL) async -> CGSize? {
        if let size = videoSize(for: url) { return size }
        let key = Self.videoSizeCacheKey(url: url)
        let fileURL = Self.cacheFolder.appendingPathComponent("size_\(key).json")

        let loaded = await Task.detached(priority: .userInitiated) { () -> CGSize? in
            guard let data = try? Data(contentsOf: fileURL),
                  let rec = try? JSONDecoder().decode(SizeRecord.self, from: data),
                  rec.w > 0, rec.h > 0 else { return nil }
            return CGSize(width: rec.w, height: rec.h)
        }.value

        if let loaded {
            setVideoSize(loaded, for: url)
            return loaded
        }
        return nil
    }

    // MARK: - Video Compositions (In-Memory Only)

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

    // MARK: - Signatures

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

    // MARK: - Disk I/O & Bounded Budget Background Pruning

    /// 인코딩과 쓰기 모두 백그라운드에서 수행한다. 원자적 쓰기라 중간 파일은 읽히지 않는다.
    private nonisolated static func writeAsync(to fileURL: URL, encode: @escaping @Sendable () -> Data?) {
        Task.detached(priority: .utility) {
            guard let data = encode() else { return }
            try? data.write(to: fileURL, options: .atomic)
            pruneDiskIfNeeded()
        }
    }

    private nonisolated static func pruneDiskIfNeeded() {
        let now = Date().timeIntervalSince1970
        stateLock.lock()
        guard now - lastPruneTime > 60 else {
            stateLock.unlock()
            return
        }
        lastPruneTime = now
        stateLock.unlock()

        let folder = cacheFolder
        let files = FileManager.default
        guard let contents = try? files.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: .skipsHiddenFiles
        ) else { return }

        var totalSize: Int64 = 0
        var items: [(url: URL, size: Int64, date: Date)] = []

        for fileURL in contents {
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = Int64(values?.fileSize ?? 0)
            let date = values?.contentModificationDate ?? Date.distantPast
            totalSize += size
            items.append((fileURL, size, date))
        }

        if totalSize > maxDiskCacheBytes || items.count > maxDiskFileCount {
            items.sort { $0.date < $1.date }
            var currentSize = totalSize
            var currentCount = items.count
            let targetBytes = Int64(Double(maxDiskCacheBytes) * 0.75)
            let targetCount = Int(Double(maxDiskFileCount) * 0.75)
            for item in items {
                guard currentSize > targetBytes || currentCount > targetCount else { break }
                try? files.removeItem(at: item.url)
                currentSize -= item.size
                currentCount -= 1
            }
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
        let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: url)
        return "\(url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)|\(layout.fitsFrame)|\(layout.offsetX)|\(layout.offsetY)|\(Int(layout.renderSize.width))x\(Int(layout.renderSize.height))"
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
    /// 고급 편집이 있을 때만 쓰는 단일 합성 플레이어(내보내기와 같은 시간표·합성기).
    @StateObject private var advanced = TrailerAdvancedPreviewDriver()
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
        guard !input.usesAdvanced else { return }
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
                  let image = (currentPhoto?.sourceID == firstID ? currentPhoto?.image : nil) ?? (input.sources.first(where: { $0.id == firstID })?.url).flatMap({ TrailerDraftPreviewCache.shared.photo(for: firstID, url: $0, projectID: input.projectID) }) {
            return OutputAspectRatio.renderSize(for: image.size)
        }
        return OutputAspectRatio.landscape16x9.renderSize
    }

    private var attachKey: String {
        "\(input.usesAdvanced)|\(input.segments.map { "\($0.id):\($0.length):\($0.timelineLength)" }.joined(separator: ","))"
    }

    /// 고급 합성의 입력 전체(모든 수동 값·해설 id·큐·배속·겹침·색상·키프레임·카드·음악·크기). 하나라도 달라지면 다시 만든다.
    private var advancedKey: String {
        guard input.usesAdvanced else { return "legacy" }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let segKey = input.segments.map { segment in
            let adjust = segment.adjustments.flatMap { try? encoder.encode($0) }.flatMap { String(data: $0, encoding: .utf8) } ?? "-"
            let caption = Self.encodeCaption(input.captions[segment.id])
            return "\(segment.id):\(segment.sourceID ?? -1):\(segment.start):\(segment.length):\(segment.fitsFrame):\(segment.offsetX):\(segment.offsetY):\(segment.muted):\(segment.volume):\(segment.incomingOverlap):\(adjust):\(caption)"
        }.joined(separator: ";")
        let voiceKey = "\(input.missingVoiceCount)|" + input.voices.map { voice in
            let take = (try? encoder.encode(voice.take)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: voice.url)
            return "\(take):\(voice.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
        }.joined(separator: ";")
        let introKey = cardKey(isIntro: true, card: input.introCard, renderSize: renderSize)
        let outroKey = cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize)
        let projStr = input.projectID?.uuidString ?? "default"
        return "adv:v1:\(projStr)|\(segKey)|\(projectSourcesKey)|\(voiceKey)|\(input.musicKey)|\(introKey)|\(outroKey)|\(Int(renderSize.width))x\(Int(renderSize.height))"
    }

    /// 카드 이미지를 미리보기 캐시에서 읽거나, 없으면 같은 규칙으로 그려 캐시에 둔다.
    private func resolveCard(isIntro: Bool) async -> UIImage? {
        let card = isIntro ? input.introCard : input.outroCard
        guard card.isEnabled, card.duration > 0 else { return nil }
        let key = cardKey(isIntro: isIntro, card: card, renderSize: renderSize)
        if let cached = await TrailerDraftPreviewCache.shared.hasOrLoadCard(for: key) { return cached }
        let scale = min(1, 960 / max(renderSize.width, renderSize.height))
        let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
        var background = card.usesFirstOrLastImage ? (isIntro ? input.introBackground : input.outroBackground) : nil
        if background == nil, card.usesFirstOrLastImage, let id = card.backgroundSourceID,
           let source = input.sources.first(where: { $0.id == id }) {
            let ts = card.backgroundTimestamp ?? 0.0
            let clamped = max(0.0, source.duration > 0 ? min(ts, source.duration - 0.05) : 0.0)
            background = try? await VideoTrailerModel.extractStillImage(source: source, at: source.isImage ? 0.0 : clamped, maxPixelSize: 1280)
        }
        let rendered = TrailerTitleCardRenderer.renderCardImage(
            card: card, sourceImage: background, renderSize: size,
            bodyTypography: card.usesBodyTypography ? input.bodyTypography : nil)
        if let rendered { TrailerDraftPreviewCache.shared.setCard(rendered, for: key) }
        return rendered
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
        let tsStr = card.backgroundTimestamp.map { String(format: "%.3f", $0) } ?? "none"
        return "\(card.isEnabled)|\(card.title)|\(card.subtitle)|\(card.duration)|\(card.usesFirstOrLastImage)|\(card.backgroundSourceID ?? -1)|\(tsStr)|\(card.usesBodyTypography)"
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
        input.sources.map {
            let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: $0.url)
            return "\($0.id):\($0.name):\($0.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
        }.joined(separator: ";")
    }

    private func backgroundKey(isIntro: Bool, card: TrailerTitleCard) -> String {
        if let bgID = card.backgroundSourceID {
            let tsStr = card.backgroundTimestamp.map { String(format: "%.3f", $0) } ?? "nil"
            if let src = input.sources.first(where: { $0.id == bgID }) {
                let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: src.url)
                return "bgID:\(bgID):ts:\(tsStr):\(src.name):\(src.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
            }
            return "bgID:\(bgID):ts:\(tsStr):none"
        } else if card.usesFirstOrLastImage {
            if isIntro {
                let firstClipSourceID = input.segments.first(where: { $0.kind == .clip })?.sourceID ?? input.sources.first?.id
                if let src = input.sources.first(where: { $0.id == firstClipSourceID }) {
                    let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: src.url)
                    return "introFirst:\(firstClipSourceID ?? -1):\(src.name):\(src.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
                }
                return "introFirst:\(firstClipSourceID ?? -1):none"
            } else {
                let lastClipSourceID = input.segments.last(where: { $0.kind == .clip })?.sourceID ?? input.sources.last?.id
                if let src = input.sources.first(where: { $0.id == lastClipSourceID }) {
                    let attrs = TrailerDraftPreviewCache.sourceFileAttributes(for: src.url)
                    return "outroLast:\(lastClipSourceID ?? -1):\(src.name):\(src.url.lastPathComponent):\(attrs.fileSize):\(attrs.mtime)"
                }
                return "outroLast:\(lastClipSourceID ?? -1):none"
            }
        } else {
            return "solidColor"
        }
    }

    private func cardKey(isIntro: Bool, card: TrailerTitleCard, renderSize: CGSize) -> String {
        let cardJSON = Self.encodeCard(card)
        let bodyJSON = Self.encodeCaption(input.bodyTypography)
        let bg = backgroundKey(isIntro: isIntro, card: card)
        let projStr = input.projectID?.uuidString ?? "default"
        // v2: invalidates stale card cache from pre-guard background renders
        let raw = "card:v2:\(projStr)|\(isIntro)|\(bg)|\(cardJSON)|\(bodyJSON)|\(Int(renderSize.width))x\(Int(renderSize.height))"
        return TrailerDraftPreviewCache.sha256(raw)
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
                            if input.usesAdvanced {
                                EmptyView()
                            } else if currentVideoSource != nil {
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
                                      let photo = (currentPhoto?.sourceID == id ? currentPhoto?.image : nil) ?? (input.sources.first(where: { $0.id == id })?.url).flatMap({ TrailerDraftPreviewCache.shared.photo(for: id, url: $0, projectID: input.projectID) }) {
                                photoView(photo, segment: segment)
                            } else {
                                Image(systemName: "photo").font(.system(size: 36)).foregroundStyle(.white.opacity(0.6))
                            }
                            if !input.usesAdvanced, let caption = input.captions[segment.id] { CaptionOverlayView(caption: caption) }
                        }
                    }
                }
            }
            .overlay {
                if input.usesAdvanced {
                    ZStack {
#if targetEnvironment(macCatalyst)
                        SharedVideoPlayerSurface(player: video.player, videoGravity: .resizeAspect,
                                                 onScrollVolume: { dy in handleDraftVolumeScroll(delta: dy) })
#else
                        SharedVideoPlayerSurface(player: video.player, videoGravity: .resizeAspect)
#endif
                        if advanced.isPreparing {
                            ProgressView().controlSize(.small).tint(.white)
                                .padding(10).background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .allowsHitTesting(true)
                }
            }
            .task(id: advancedKey) {
                guard input.usesAdvanced else { advanced.stop(); return }
                advanced.attach(player: video.player)
                // 디바운스: 슬라이더를 끄는 동안 매번 다시 만들지 않는다.
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                let intro = await resolveCard(isIntro: true)
                let outro = await resolveCard(isIntro: false)
                guard !Task.isCancelled else { return }
                await advanced.prepare(input: input, key: advancedKey, renderSize: renderSize,
                                       introImage: intro, outroImage: outro, resumeAt: bridge.currentSeconds)
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
                if let cached = await TrailerDraftPreviewCache.shared.loadVideoSize(for: url) {
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
                guard !input.usesAdvanced else { music.stop(); return }
                await music.prepare(input)
                // 준비가 끝난 시점의 재생 위치로 바로 이어 붙는다(재생 중에 음악을 바꾼 경우).
                music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
#if targetEnvironment(macCatalyst)
                music.player.volume = bridge.masterVolume
#endif
            }
            .onChange(of: bridge.currentSeconds) { _, _ in
                guard !input.usesAdvanced else { return }
                syncVideo(); music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
            }
            .onChange(of: videoLayoutKey) { _, _ in syncVideo() }
            .onChange(of: bridge.isPlaying) { _, _ in
                guard !input.usesAdvanced else { return }
                syncVideo(); music.sync(seconds: bridge.currentSeconds, playing: bridge.isPlaying)
            }
            .onChange(of: input.usesAdvanced) { _, isAdvanced in
                // 방식이 바뀌면 이전 방식의 플레이어는 멈춘다(두 소리가 겹치지 않게).
                if isAdvanced { video.stop(); music.stop() } else { advanced.stop() }
            }
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
            .onDisappear { video.stop(); music.stop(); advanced.stop() }
            .onChange(of: input.selectedSceneID) { _, id in
                guard !bridge.isPlaying, let id, let start = input.startSeconds(ofScene: id) else { return }
                bridge.currentSeconds = start
            }
    }

    private var projectPreparationKey: String {
        let segKey = input.segments.map { "\($0.id):\($0.sourceID ?? -1):\($0.start):\($0.length):\($0.fitsFrame):\($0.offsetX):\($0.offsetY)" }.joined(separator: ";")
        let introKey = cardKey(isIntro: true, card: input.introCard, renderSize: renderSize)
        let outroKey = cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize)
        let projStr = input.projectID?.uuidString ?? "default"
        return "prep:v1:\(projStr)|\(segKey)|\(projectSourcesKey)|\(input.musicKey)|\(introKey)|\(outroKey)|\(Int(renderSize.width))x\(Int(renderSize.height))"
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
        if let refVideoURL, await TrailerDraftPreviewCache.shared.loadVideoSize(for: refVideoURL) == nil {
            totalSteps += 1
        }
        let introNeeded = input.segments.contains { $0.kind == .intro }
        let introKey = cardKey(isIntro: true, card: input.introCard, renderSize: renderSize)
        if introNeeded, await TrailerDraftPreviewCache.shared.hasOrLoadCard(for: introKey) == nil {
            totalSteps += 1
        }
        let outroNeeded = input.segments.contains { $0.kind == .outro }
        let outroKey = cardKey(isIntro: false, card: input.outroCard, renderSize: renderSize)
        if outroNeeded, await TrailerDraftPreviewCache.shared.hasOrLoadCard(for: outroKey) == nil {
            totalSteps += 1
        }

        let photoSegments = input.segments.filter { $0.kind == .clip }
        let byID = Dictionary(input.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pendingPhotos: [(Int, URL)] = []
        for seg in photoSegments {
            if let id = seg.sourceID, let src = byID[id], src.isImage {
                if await TrailerDraftPreviewCache.shared.hasOrLoadPhoto(for: src.id, url: src.url, projectID: input.projectID) == nil,
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

        // 진행률은 디스크에도 없는 비싼 자산(영상 크기·카드·사진)에만 보인다.
        // 비디오 컴포지션과 음악은 메모리 전용 경량 재구성이라 진행률 없이 조용히 만든다.
        if totalSteps > 0 {
            isPreparingProject = true
            preparationProgress = 0.0
        }
        var completed = 0
        var failedAssets = 0

        func stepDone() {
            completed += 1
            if totalSteps > 0, preparationGeneration == generation && activePreparationSignature == signature {
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
            var bgImage = input.introCard.usesFirstOrLastImage ? input.introBackground : nil
            if bgImage == nil && input.introCard.usesFirstOrLastImage,
               let bgID = input.introCard.backgroundSourceID,
               let src = input.sources.first(where: { $0.id == bgID }) {
                let ts = input.introCard.backgroundTimestamp ?? 0.0
                let clamped = max(0.0, src.duration > 0 ? min(ts, src.duration - 0.05) : 0.0)
                bgImage = try? await VideoTrailerModel.extractStillImage(source: src, at: src.isImage ? 0.0 : clamped, maxPixelSize: 1280)
            }
            if let img = TrailerTitleCardRenderer.renderCardImage(
                card: input.introCard,
                sourceImage: bgImage,
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
            var bgImage = input.outroCard.usesFirstOrLastImage ? input.outroBackground : nil
            if bgImage == nil && input.outroCard.usesFirstOrLastImage,
               let bgID = input.outroCard.backgroundSourceID,
               let src = input.sources.first(where: { $0.id == bgID }) {
                let ts = input.outroCard.backgroundTimestamp ?? 0.0
                let clamped = max(0.0, src.duration > 0 ? min(ts, src.duration - 0.05) : 0.0)
                bgImage = try? await VideoTrailerModel.extractStillImage(source: src, at: src.isImage ? 0.0 : clamped, maxPixelSize: 1280)
            }
            if let img = TrailerTitleCardRenderer.renderCardImage(
                card: input.outroCard,
                sourceImage: bgImage,
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
                TrailerDraftPreviewCache.shared.setPhoto(img, for: sourceID, url: url, projectID: input.projectID)
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
        }

        guard !Task.isCancelled, preparationGeneration == generation, activePreparationSignature == signature, projectPreparationKey == signature else { return }
        if failedAssets == 0 {
            TrailerDraftPreviewCache.shared.markPrepared(signature: signature)
        }
        failedAssetCount = failedAssets
        isPreparingProject = false
        preparationProgress = nil
        await loadFrame()
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
            if let cached = await TrailerDraftPreviewCache.shared.hasOrLoadCard(for: key) {
                cardImage = cached
            } else {
                let scale = min(1, 960 / max(renderSize.width, renderSize.height))
                let size = CGSize(width: renderSize.width * scale, height: renderSize.height * scale)
                var bgImage = card.usesFirstOrLastImage ? (isIntro ? input.introBackground : input.outroBackground) : nil
                if bgImage == nil && card.usesFirstOrLastImage,
                   let bgID = card.backgroundSourceID,
                   let src = input.sources.first(where: { $0.id == bgID }) {
                    let ts = card.backgroundTimestamp ?? 0.0
                    let clamped = max(0.0, src.duration > 0 ? min(ts, src.duration - 0.05) : 0.0)
                    bgImage = try? await VideoTrailerModel.extractStillImage(source: src, at: src.isImage ? 0.0 : clamped, maxPixelSize: 1280)
                }
                let rendered = TrailerTitleCardRenderer.renderCardImage(
                    card: card,
                    sourceImage: bgImage,
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
            if let cached = await TrailerDraftPreviewCache.shared.hasOrLoadPhoto(for: id, url: source.url, projectID: input.projectID) {
                currentPhoto = (id, cached)
            } else if let image = await trailerThumbnailImage(at: source.url, maxPixelSize: 1280), !Task.isCancelled {
                TrailerDraftPreviewCache.shared.setPhoto(image, for: id, url: source.url, projectID: input.projectID)
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
        if input.usesAdvanced {
            // 고급 합성은 플레이어가 시계의 기준이다. 시계는 그 위치와 실제 합성 길이를 따라간다.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                if advanced.duration > 0, abs(bridge.durationSeconds - advanced.duration) > 0.001 {
                    bridge.durationSeconds = advanced.duration
                }
#if targetEnvironment(macCatalyst)
                video.player.volume = bridge.masterVolume
#endif
                advanced.attach(player: video.player)
                advanced.follow(bridge)
            }
            bridge.detach(ifOwner: token)
            return
        }
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

// MARK: - 효과 탭: 속도·색상·전환·키프레임·시간별 자막·음성 해설

/// 음성 해설 녹음과 자막 자동 생성을 실제 어댑터에 연결하는 컨트롤러. 버튼을 눌렀을 때만 마이크/음성 인식을 쓴다.
/// 로그에는 전사 문구나 소스 주소를 남기지 않는다.
@MainActor
final class TrailerVoiceCoordinator: ObservableObject {
    enum Phase: Equatable { case idle, requesting, recording, stopping, saving }
    @Published private(set) var phase = Phase.idle
    @Published private(set) var message: String?
    @Published private(set) var isGenerating = false
    private let recorder = TrailerVoiceoverRecorder()
    private let transcriber = TrailerOnDeviceCaptionTranscriber()
    /// 마지막 자막 생성 요청 번호. 취소·재요청으로 바뀌면 늦게 온 결과는 버린다.
    private var captionGeneration = 0
    /// 저장이 성공할 때까지 소유권을 넘기지 않은 녹음 산출물.
    private var pending: TrailerVoiceoverArtifact?

    var hasUncommittedRecording: Bool { pending != nil }

    func startRecording(in folder: URL?) {
        guard phase == .idle, let folder else { return }
        phase = .requesting
        message = nil
        Task { @MainActor in
            do {
                try await recorder.startRecording(in: folder)
                phase = .recording
            } catch {
                phase = .idle
                message = (error as? LocalizedError)?.errorDescription ?? "녹음을 시작하지 못했습니다."
            }
        }
    }

    /// 녹음을 끝내고 `commit`이 프로젝트 사본을 만들어 저장까지 성공했을 때만 산출물의 소유권을 넘긴다.
    func stopRecording(commit: @escaping (TrailerVoiceoverArtifact) async -> Bool) {
        guard phase == .recording else { return }
        phase = .stopping
        Task { @MainActor in
            do {
                let artifact = try await recorder.stopRecording()
                pending = artifact
                phase = .saving
                if await commit(artifact) {
                    _ = recorder.markCommitted()
                    pending = nil
                    message = nil
                } else {
                    message = "저장하지 못했어요. 녹음은 지워지지 않았습니다. 다시 저장해 주세요."
                }
                phase = .idle
            } catch {
                phase = .idle
                message = (error as? LocalizedError)?.errorDescription ?? "녹음을 끝내지 못했습니다."
            }
        }
    }

    /// 저장에 실패해 남은 녹음을 다시 저장해 본다.
    func retryCommit(commit: @escaping (TrailerVoiceoverArtifact) async -> Bool) {
        guard phase == .idle, let artifact = pending else { return }
        phase = .saving
        Task { @MainActor in
            if await commit(artifact) {
                _ = recorder.markCommitted()
                pending = nil
                message = nil
            }
            phase = .idle
        }
    }

    /// 사용자가 직접 취소할 때만: 이번 녹음이 만든 파일만 지운다(소스·프로젝트 파일은 건드리지 않는다).
    func cancelRecording() {
        guard phase == .recording || phase == .saving || pending != nil else { return }
        Task { @MainActor in
            await recorder.cancel()
            pending = nil
            phase = .idle
            message = nil
        }
    }

    /// 화면이 닫힐 때: 녹음 중이면 마무리하되 지우지 않는다.
    func shutdown() {
        captionGeneration += 1
        transcriber.cancel()
        isGenerating = false
        Task { @MainActor in await recorder.handleViewCloseOrShutdown() }
    }

    func cancelGeneration() {
        captionGeneration += 1
        transcriber.cancel()
        isGenerating = false
        message = nil
    }

    /// 선택한 영상 장면의 소리에서 자막 큐를 만든다. 결과는 `apply`가 그 시점의 최신 큐와 병합한다.
    func generateCaptions(source: VideoTrailerSource, scene: TrailerEditScene, workFolder: URL?, style: TrailerCaption,
                          apply: @escaping (_ generated: [TrailerTimedCaptionCue]) -> Void) {
        guard !isGenerating, !source.isImage, let workFolder else { return }
        captionGeneration += 1
        let generation = captionGeneration
        isGenerating = true
        message = nil
        let start = scene.start, length = scene.length
        Task { @MainActor in
            let audioURL = workFolder.appendingPathComponent("caption-audio-\(UUID().uuidString).m4a")
            defer { try? FileManager.default.removeItem(at: audioURL) }
            do {
                let asset = AVURLAsset(url: source.url)
                guard try await !asset.loadTracks(withMediaType: .audio).isEmpty,
                      let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
                    throw TrailerTranscriptionError.invalidSource("이 영상에는 인식할 소리가 없습니다.")
                }
                session.outputURL = audioURL
                session.outputFileType = .m4a
                session.timeRange = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600),
                                                duration: CMTime(seconds: length, preferredTimescale: 600))
                await session.export()
                guard session.status == .completed else { throw session.error ?? TrailerTranscriptionError.invalidSource("소리를 준비하지 못했습니다.") }
                guard generation == captionGeneration else { return }
                let cues = try await transcriber.generateCaptions(
                    for: audioURL, sourceID: source.id, sourceOffset: start,
                    localeIdentifier: Locale.current.identifier, style: style)
                guard generation == captionGeneration else { return }
                apply(cues)
                message = cues.isEmpty ? "인식된 말이 없어요." : nil
            } catch {
                guard generation == captionGeneration else { return }
                message = (error as? LocalizedError)?.errorDescription ?? "자막을 만들지 못했습니다. 직접 입력은 그대로 쓸 수 있어요."
            }
            if generation == captionGeneration { isGenerating = false }
        }
    }
}

enum EffectTool: String, CaseIterable, Identifiable {
    case speed = "속도", color = "색상", transition = "전환", motion = "움직임", captions = "자막"
    var id: String { rawValue }
}

/// '효과' 탭. 선택한 클립의 속도·색상·전환·키프레임·시간별 자막과, 프로젝트 전체의 음성 해설 한 레인.
/// 모든 값은 미리보기와 내보내기가 같이 쓰는 합성기(`TrailerAdvancedComposer`)에 그대로 들어간다.
struct TrailerEffectsInspector: View {
    let sources: [VideoTrailerSource]
    @Binding var scenes: [TrailerEditScene]?
    @Binding var selectedID: Int?
    @Binding var voiceovers: [TrailerVoiceoverTake]
    let segments: [TrailerTimelineSegment]
    @ObservedObject var bridge: TrailerTimelineBridge
    let chrome: TrailerEditorChrome
    /// true면 프로젝트 전체(음성 해설)만, false면 선택 클립 속성만, nil이면 둘 다.
    var projectScope: Bool? = nil
    /// 폰 좁은 화면은 위쪽 선택 줄에 클립 정보가 이미 있으므로 반복 제목과 두 겹 세그먼트를 생략한다.
    var showsClipHeader: Bool = true
    @State private var tool: EffectTool = .speed
    @StateObject private var voice = TrailerVoiceCoordinator()
    @State private var importing = false
    @State private var voiceOpen = false
    @State private var importMessage: String?

    private var scene: TrailerEditScene? { selectedID.flatMap { id in scenes?.first { $0.id == id } } }
    private var source: VideoTrailerSource? { scene.flatMap { s in sources.first { $0.id == s.sourceID } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if projectScope != true {
                if let scene, let source {
                    clipEffects(scene: scene, source: source)
                } else {
                    Text("편집할 클립을 고르면 속도·색상·움직임·자막을 바꿀 수 있어요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if projectScope == nil { Divider() }
            if projectScope != false {
                if showsClipHeader {
                    voiceoverSection
                } else {
                    DisclosureGroup(isExpanded: $voiceOpen) { voiceoverSection.padding(.top, 6) } label: {
                        Text("음성 해설" + (voiceovers.isEmpty ? "" : " \(voiceovers.count)개")).font(.subheadline.weight(.semibold))
                    }
                }
            }
        }
        .onDisappear { voice.shutdown() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: false) { result in
            importVoiceover(result)
        }
    }

    // MARK: 클립 효과

    private func adjust(_ change: @escaping (inout TrailerClipAdjustments) -> Void) {
        guard let id = selectedID, scenes != nil else { return }
        TrailerSceneEditor.update(id, in: &scenes!) { scene in
            var value = scene.adjustments ?? TrailerClipAdjustments()
            change(&value)
            scene.adjustments = value == TrailerClipAdjustments() ? nil : value
        }
    }

    private func clipNumber(_ id: Int) -> Int {
        (scenes?.firstIndex { $0.id == id } ?? 0) + 1
    }

    private func playheadSourceTime(_ scene: TrailerEditScene) -> Double {
        guard let local = TrailerTimelineGeometry.localTime(ofScene: scene.id, atSeconds: bridge.currentSeconds, segments: segments) else {
            return scene.start
        }
        let overlap = segments.first { $0.sceneID == scene.id }?.incomingOverlap ?? 0
        let rate = scene.adjustments?.rate ?? 1
        return min(scene.start + scene.length, max(scene.start, scene.start + (local + overlap) * rate))
    }

    /// 도구 이름 옆 점: 이 클립에서 값이 바뀐 도구.
    private func toolTitle(_ tool: EffectTool, _ adjustments: TrailerClipAdjustments) -> String {
        let edited: Bool
        switch tool {
        case .speed: edited = adjustments.rate != 1
        case .color: edited = !(adjustments.color?.isNeutral ?? true)
        case .transition: edited = (adjustments.transition?.dissolveDuration ?? 0) > 0
        case .motion: edited = !adjustments.keyframes.isEmpty
        case .captions: edited = !adjustments.cues.isEmpty
        }
        return edited ? tool.rawValue + " •" : tool.rawValue
    }

    @ViewBuilder
    private func clipEffects(scene: TrailerEditScene, source: VideoTrailerSource) -> some View {
        let adjustments = scene.adjustments ?? TrailerClipAdjustments()
        let tools = EffectTool.allCases.filter { !($0 == .speed && source.isImage) }
        let active = tools.contains(tool) ? tool : (tools.first ?? .color)
        if showsClipHeader {
            Text("선택한 클립 · \(source.name)").font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Picker("효과 도구", selection: Binding(get: { active }, set: { tool = $0 })) {
                ForEach(tools) { Text(toolTitle($0, adjustments)).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
        } else {
            // 폰: 선택한 클립 맥락과 하위 도구 선택을 한 줄에 둔다(도구는 메뉴로 모두 접근).
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Text("선택한 클립 \(clipNumber(scene.id))").font(.subheadline.weight(.semibold))
                    if scene.timingProtected { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary) }
                    if scene.excluded { Text("제외됨").font(.caption.weight(.semibold)).foregroundStyle(.orange) }
                }
                Spacer(minLength: 0)
                Menu {
                    ForEach(tools) { item in
                        Button { tool = item } label: {
                            if item == active { Label(toolTitle(item, adjustments), systemImage: "checkmark") }
                            else { Text(toolTitle(item, adjustments)) }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(toolTitle(active, adjustments)).font(.caption.weight(.semibold))
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                    .foregroundStyle(PorcelainMetrics.onAccent)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .frame(minHeight: 36)
                    .background(PorcelainMetrics.solidAction, in: Capsule())
                }
                .accessibilityLabel("효과 도구 \(active.rawValue)")
                .accessibilityHint("속도, 색상, 전환, 움직임, 자막 중에서 고릅니다")
            }
        }

        switch active {
        case .speed:
            labeled("속도 \(String(format: "%.2f", adjustments.rate))배", reset: adjustments.rate != 1 ? { adjust { $0.rate = 1 } } : nil) {
                Slider(value: Binding(get: { adjustments.rate }, set: { value in adjust { $0.rate = (value * 20).rounded() / 20 } }), in: 0.25...4)
                HStack(spacing: 6) {
                    ForEach([0.5, 1.0, 2.0], id: \.self) { preset in
                        Button("\(String(format: "%g", preset))×") { adjust { $0.rate = preset } }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            Text("출력 길이 \(String(format: "%.1f", scene.length / adjustments.rate))초 (원본 \(String(format: "%.1f", scene.length))초)")
                .font(.caption).foregroundStyle(.secondary)
        case .color:
            let color = adjustments.color ?? TrailerColorAdjustment()
            labeled("색상", reset: color.isNeutral ? nil : { adjust { $0.color = nil } }) {
                colorSlider("밝기", value: color.brightness, range: -1...1) { value in adjust { var c = $0.color ?? TrailerColorAdjustment(); c.brightness = value; $0.color = c.isNeutral ? nil : c } }
                colorSlider("대비", value: color.contrast, range: 0.25...4) { value in adjust { var c = $0.color ?? TrailerColorAdjustment(); c.contrast = value; $0.color = c.isNeutral ? nil : c } }
                colorSlider("채도", value: color.saturation, range: 0...3) { value in adjust { var c = $0.color ?? TrailerColorAdjustment(); c.saturation = value; $0.color = c.isNeutral ? nil : c } }
            }
        case .transition:
            let dissolve = adjustments.transition?.dissolveDuration ?? 0
            labeled(dissolve > 0 ? "다음 장면과 겹치기 \(String(format: "%.1f", dissolve))초" : "다음 장면과 겹치기 없음(컷)",
                    reset: dissolve > 0 ? { adjust { $0.transition = nil } } : nil) {
                Slider(value: Binding(get: { dissolve }, set: { value in
                    adjust { $0.transition = value < 0.05 ? nil : TrailerTransition(dissolveDuration: (value * 10).rounded() / 10) }
                }), in: 0...3)
            }
        case .motion:
            keyframeSection(scene: scene, adjustments: adjustments)
        case .captions:
            cueSection(scene: scene, source: source, adjustments: adjustments)
        }
    }

    private func labeled<Content: View>(_ title: String, reset: (() -> Void)? = nil, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption.weight(.semibold))
                Spacer()
                if let reset { Button("초기화", action: reset).font(.caption).buttonStyle(.borderless) }
            }
            content()
        }
    }

    private func colorSlider(_ title: String, value: Double, range: ClosedRange<Double>, set: @escaping (Double) -> Void) -> some View {
        HStack {
            Text(title).font(.caption).frame(width: 34, alignment: .leading)
            Slider(value: Binding(get: { value }, set: set), in: range)
            Text(String(format: "%.2f", value)).font(.caption).monospacedDigit().frame(width: 40, alignment: .trailing)
        }
    }

    // MARK: 키프레임

    @ViewBuilder
    private func keyframeSection(scene: TrailerEditScene, adjustments: TrailerClipAdjustments) -> some View {
        let sorted = TrailerTransformKeyframe.sanitizeAndSort(adjustments.keyframes)
        labeled("키프레임 \(sorted.count)개") {
            Button {
                let time = playheadSourceTime(scene)
                let seed = TrailerTransformKeyframe.interpolate(keyframes: adjustments.keyframes, at: time)
                adjust { $0.keyframes.append(TrailerTransformKeyframe(sourceTime: time, offsetX: seed.offsetX, offsetY: seed.offsetY,
                                                                      scale: seed.scale, opacity: seed.opacity)) }
            } label: { Label("현재 위치에 추가", systemImage: "plus.circle") }
                .buttonStyle(.bordered).controlSize(.small)
            ForEach(sorted) { keyframe in
                let inWindow = keyframe.sourceTime >= scene.start - 1e-6 && keyframe.sourceTime <= scene.start + scene.length + 1e-6
                DisclosureGroup {
                    keyframeEditor(keyframe)
                } label: {
                    HStack {
                        Text(String(format: "원본 %.2f초", keyframe.sourceTime)).font(.caption).monospacedDigit()
                        if !inWindow { Text("(잘린 구간 · 보관됨)").font(.caption2).foregroundStyle(.secondary) }
                        Spacer()
                        Button(role: .destructive) { adjust { $0.keyframes.removeAll { $0.stableID == keyframe.stableID } } } label: {
                            Image(systemName: "trash")
                        }.buttonStyle(.borderless).accessibilityLabel("키프레임 삭제")
                    }
                }
            }
        }
    }

    private func updateKeyframe(_ id: UUID, _ change: @escaping (inout TrailerTransformKeyframe) -> Void) {
        adjust { value in
            guard let index = value.keyframes.firstIndex(where: { $0.stableID == id }) else { return }
            change(&value.keyframes[index])
        }
    }

    @ViewBuilder
    private func keyframeEditor(_ keyframe: TrailerTransformKeyframe) -> some View {
        let id = keyframe.stableID
        VStack(spacing: 4) {
            HStack {
                Text("시간").font(.caption).frame(width: 34, alignment: .leading)
                Stepper(value: Binding(get: { keyframe.sourceTime }, set: { value in updateKeyframe(id) { $0.sourceTime = max(0, value) } }),
                        in: 0...100_000, step: 0.1) { Text(String(format: "%.1f초", keyframe.sourceTime)).font(.caption).monospacedDigit() }
            }
            colorSlider("좌우", value: keyframe.offsetX, range: -1...1) { v in updateKeyframe(id) { $0.offsetX = v } }
            colorSlider("상하", value: keyframe.offsetY, range: -1...1) { v in updateKeyframe(id) { $0.offsetY = v } }
            colorSlider("크기", value: keyframe.scale, range: 0.1...4) { v in updateKeyframe(id) { $0.scale = v } }
            colorSlider("투명", value: keyframe.opacity, range: 0...1) { v in updateKeyframe(id) { $0.opacity = v } }
        }
    }

    // MARK: 시간별 자막

    @ViewBuilder
    private func cueSection(scene: TrailerEditScene, source: VideoTrailerSource, adjustments: TrailerClipAdjustments) -> some View {
        let cues = adjustments.cues.sorted { $0.sourceStart < $1.sourceStart }
        labeled("시간별 자막 \(cues.count)개") {
            HStack(spacing: 6) {
                Button {
                    let start = playheadSourceTime(scene)
                    let end = min(scene.start + scene.length, start + 2)
                    adjust { $0.cues.append(TrailerTimedCaptionCue(sourceID: scene.sourceID, sourceStart: start, sourceEnd: max(end, start + 0.5),
                                                                    text: "자막", style: TrailerSceneEditor.cueStyle(for: scene), origin: .manual, manuallyEdited: true)) }
                } label: { Label("현재 위치에 추가", systemImage: "plus.circle") }
                    .buttonStyle(.bordered).controlSize(.small)
                if !source.isImage {
                    if voice.isGenerating {
                        Button("만드는 중 · 취소") { voice.cancelGeneration() }.buttonStyle(.bordered).controlSize(.small)
                    } else {
                        Button {
                            voice.generateCaptions(source: source, scene: scene, workFolder: chrome.voiceWorkFolder(),
                                                   style: TrailerSceneEditor.cueStyle(for: scene)) { generated in
                                // 늦게 온 결과는 그 시점의 최신 큐·삭제 기록과 병합한다: 직접 고친 큐와 지운 구간은 그대로고,
                                // 자동 병합이라 직접 편집 표시는 켜지지 않는다.
                                guard scenes != nil else { return }
                                TrailerSceneEditor.mergeGeneratedCues(generated, intoSceneID: scene.id, in: &scenes!)
                            }
                        } label: { Label("자막 만들기", systemImage: "waveform") }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
            }
            if let message = voice.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            if let caption = scene.caption, !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !cues.isEmpty {
                Text("클립 자막 “\(caption.text)”은 시간별 자막과 함께 계속 보여요.").font(.caption2).foregroundStyle(.secondary)
            }
            ForEach(cues) { cue in cueRow(cue, scene: scene) }
        }
    }

    private func updateCue(_ id: UUID, _ change: @escaping (inout TrailerTimedCaptionCue) -> Void) {
        adjust { value in
            guard let index = value.cues.firstIndex(where: { $0.stableID == id }) else { return }
            change(&value.cues[index])
            value.cues[index].origin = .manual
            value.cues[index].manuallyEdited = true
        }
    }

    private func cueRow(_ cue: TrailerTimedCaptionCue, scene: TrailerEditScene) -> some View {
        let id = cue.stableID
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                TextField("자막 문구", text: Binding(get: { cue.text }, set: { value in updateCue(id) { $0.text = value } }))
                    .textFieldStyle(.roundedBorder)
                Button(role: .destructive) {
                    adjust { value in
                        value.cues.removeAll { $0.stableID == id }
                        // 사용자가 지운 자막은 자동이든 직접 만든 것이든 구간을 기록해, 새 id로 다시 만들어도 되살아나지 않게 한다.
                        let tombstone = TrailerCueSuppression(sourceID: cue.sourceID, sourceStart: cue.sourceStart, sourceEnd: cue.sourceEnd)
                        if !value.suppressions.contains(tombstone) { value.suppressions.append(tombstone) }
                    }
                } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("자막 삭제")
            }
            HStack(spacing: 10) {
                Stepper(value: Binding(get: { cue.sourceStart }, set: { value in updateCue(id) { $0.sourceStart = min(max(0, value), $0.sourceEnd - 0.1) } }),
                        in: 0...100_000, step: 0.1) { Text(String(format: "시작 %.1f", cue.sourceStart)).font(.caption).monospacedDigit() }
                Stepper(value: Binding(get: { cue.sourceEnd }, set: { value in updateCue(id) { $0.sourceEnd = max(value, $0.sourceStart + 0.1) } }),
                        in: 0...100_000, step: 0.1) { Text(String(format: "끝 %.1f", cue.sourceEnd)).font(.caption).monospacedDigit() }
            }
            if cue.sourceStart >= scene.start + scene.length || cue.sourceEnd <= scene.start {
                Text("잘린 구간 밖 · 보관됨").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: 음성 해설

    private var voiceoverSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsClipHeader { Text("음성 해설").font(.subheadline.weight(.semibold)) }
            HStack(spacing: 6) {
                switch voice.phase {
                case .idle:
                    Button { voice.startRecording(in: chrome.voiceWorkFolder()) } label: { Label("녹음", systemImage: "mic") }
                        .buttonStyle(.bordered).controlSize(.small)
                    Button { importing = true } label: { Label("가져오기", systemImage: "square.and.arrow.down") }
                        .buttonStyle(.bordered).controlSize(.small)
                    if voice.hasUncommittedRecording {
                        Button("다시 저장") { voice.retryCommit(commit: commitRecording) }.buttonStyle(.bordered).controlSize(.small)
                        Button("녹음 취소") { voice.cancelRecording() }.buttonStyle(.borderless).controlSize(.small)
                    }
                case .requesting:
                    ProgressView().controlSize(.small)
                    Text("마이크 확인 중").font(.caption)
                case .recording:
                    Button { voice.stopRecording(commit: commitRecording) } label: { Label("정지", systemImage: "stop.circle.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.small).tint(.red)
                    Button("취소") { voice.cancelRecording() }.buttonStyle(.bordered).controlSize(.small)
                    Text("녹음 중").font(.caption).foregroundStyle(.red)
                case .stopping, .saving:
                    ProgressView().controlSize(.small)
                    Text("저장 중").font(.caption)
                }
            }
            if let message = voice.message ?? importMessage { Text(message).font(.caption).foregroundStyle(.secondary) }
            ForEach(voiceovers) { take in voiceRow(take) }
            if voiceovers.isEmpty { Text("현재 위치에서 녹음하거나 소리 파일을 가져오세요.").font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func updateTake(_ id: UUID, _ change: @escaping (inout TrailerVoiceoverTake) -> Void) {
        guard let index = voiceovers.firstIndex(where: { $0.stableID == id }) else { return }
        change(&voiceovers[index])
    }

    private func voiceRow(_ take: TrailerVoiceoverTake) -> some View {
        let id = take.stableID
        let length = take.sourceOut - take.sourceIn
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(String(format: "해설 %.1f초 · %.1f초부터", length, take.outputStart)).font(.caption).monospacedDigit()
                if chrome.voiceURL(id) == nil { Text("파일 없음").font(.caption2).foregroundStyle(.red) }
                Spacer()
                Button("현재 위치로") { updateTake(id) { $0.outputStart = max(0, bridge.currentSeconds) } }.font(.caption).buttonStyle(.borderless)
                Button(role: .destructive) { voiceovers.removeAll { $0.stableID == id } } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless).accessibilityLabel("해설 삭제")
            }
            Stepper(value: Binding(get: { take.outputStart }, set: { value in updateTake(id) { $0.outputStart = max(0, value) } }),
                    in: 0...100_000, step: 0.1) { Text("시작 위치").font(.caption) }
            colorSlider("음량", value: take.volume, range: 0...2) { v in updateTake(id) { $0.volume = v } }
        }
    }

    /// 녹음 산출물을 세션 사본 → 해설로 넣고 편집본을 저장한다. 저장이 성공해야 true.
    private func commitRecording(_ artifact: TrailerVoiceoverArtifact) async -> Bool {
        let id = artifact.id
        if !voiceovers.contains(where: { $0.stableID == id }) {
            guard let relative = try? chrome.stageVoiceover(artifact.url, id) else { return false }
            voiceovers.append(TrailerVoiceoverTake(stableID: id, relativeFile: relative, outputStart: max(0, bridge.currentSeconds),
                                                   sourceIn: 0, sourceOut: artifact.duration, volume: 1))
        }
        return await chrome.saveDraftNow()
    }

    private func importVoiceover(_ result: Result<[URL], Error>) {
        importMessage = nil
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        Task { @MainActor in
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let asset = AVURLAsset(url: url)
                guard let track = try await asset.loadTracks(withMediaType: .audio).first, try await track.load(.isDecodable) else {
                    importMessage = "이 파일의 소리를 읽을 수 없어요."
                    return
                }
                let duration = try await asset.load(.duration).seconds
                guard duration.isFinite, duration > 0.05 else { importMessage = "소리 길이를 알 수 없어요."; return }
                let id = UUID()
                let relative = try chrome.stageVoiceover(url, id)
                voiceovers.append(TrailerVoiceoverTake(stableID: id, relativeFile: relative, outputStart: max(0, bridge.currentSeconds),
                                                       sourceIn: 0, sourceOut: duration, volume: 1))
            } catch {
                importMessage = "가져오지 못했어요. 파일은 그대로입니다."
            }
        }
    }
}
