import Foundation

struct VideoTrailerScene: Identifiable {
    let id: Int
    let start: Double
    let length: Double
    var sourceID = 0
    /// 직접 편집한 장면에서만 켜진다: 이 장면의 원본 소리를 넣지 않는다.
    var muted = false
    /// 직접 편집한 영상 장면에서만 켜진다: 화면을 채우지 않고 안에 맞춘다.
    var fitsFrame = false
    /// 직접 편집한 영상 장면의 원본 소리 음량(0...1).
    var volume = 1.0
    /// 직접 편집한 사진·영상 장면을 채울 때의 화면 위치(-1...1). 0이 가운데.
    var offsetX = 0.0
    var offsetY = 0.0
    /// 직접 편집에서 이 장면에 붙인 자막. 미리보기와 내보내기가 같은 값을 그린다.
    var caption: TrailerCaption? = nil
}

struct VideoTrailerPlan {
    let analysis: AudioAnalysisResult
    /// Always finite and never negative; 0 marks a source whose duration was missing or invalid,
    /// which never produces a scene.
    let duration: Double
    let recommendedClipLength: Double
    /// Distinct clips the recommendation takes from this source at `recommendedClipLength`.
    let recommendedCount: Int
    var recommendedTotal: Double { Double(recommendedCount) * recommendedClipLength }
    /// True only when the analysis found real, contrasting audio/motion energy. Silence, a flat
    /// or empty waveform and the centre-pick fallback are unknown content, not highlights.
    let hasEvidence: Bool
    private let waveform: [Double]
    private let peaks: [Double]

    static let maximumDuration: Double = 31_536_000

    /// Scene pacing follows the source: short sources get shorter scenes, long ones longer.
    /// 2...4 s floor (duration / 20) and 4...10 s ceiling (duration / 8), never beyond the source.
    static func sceneBounds(duration: Double) -> (minimum: Double, maximum: Double) {
        (min(duration, max(2, min(4, duration / 20))), min(duration, max(4, min(10, duration / 8))))
    }

    init(analysis: AudioAnalysisResult, duration: Double) {
        self.analysis = analysis
        // Bounded so the clip-count arithmetic below can never overflow an Int.
        let length = duration.isFinite && duration > 0 ? min(duration, Self.maximumDuration) : 0
        self.duration = length
        let waveform = analysis.waveform.map { $0.isFinite ? max(0, $0) : 0 }
        let verified = analysis.verifiedPeakTimes
        func isVerified(_ time: Double) -> Bool { verified.contains { abs($0 - time) < 1e-6 } }
        // 검증된 타격을 먼저, 그다음 기존 순서(점수순)를 유지한다.
        let allPeaks = analysis.peakTimes.filter { $0.isFinite && $0 >= 0 && $0 <= length }
        let peaks = allPeaks.filter(isVerified) + allPeaks.filter { !isVerified($0) }
        self.waveform = waveform
        self.peaks = peaks
        let top = waveform.max() ?? 0
        let baseline = waveform.isEmpty ? 0 : waveform.reduce(0, +) / Double(waveform.count)
        // Contrast: a flat waveform (peak barely above its own average) has no highlight either.
        let evidence = length > 0 && analysis.highlightSource != .fallback && top > 0
            && (top - baseline) >= top * 0.15 && !peaks.isEmpty
        hasEvidence = evidence
        guard length > 0 else {
            recommendedClipLength = 1
            recommendedCount = 0
            return
        }
        let bounds = Self.sceneBounds(duration: length)
        let bucket = length / Double(max(1, waveform.count))
        func index(_ time: Double) -> Int { min(waveform.count - 1, max(0, Int(time / length * Double(waveform.count)))) }
        // 검증된 타격은 55% 음량 컷에 걸리지 않는다. 검증 안 된 피크는 기존대로 큰 소리여야 한다.
        let strong = evidence ? peaks.filter { isVerified($0) || waveform[index($0)] >= max(baseline, top * 0.55) } : []
        // Highlights that carry the sizing: the strong ones, or every found peak when none is.
        let sizing = strong.isEmpty ? (evidence ? peaks : []) : strong
        // A scene covers the continuous run of high energy around a peak (up to the ceiling), so a
        // narrow spike is only a floor-length scene and a long loud stretch gets a longer one.
        let lengths = sizing.map { peak -> Double in
            let center = index(peak)
            let threshold = baseline + max(0, waveform[center] - baseline) * 0.4
            var left = center
            var right = center
            while left > 0, waveform[left - 1] > threshold, Double(center - left + 1) * bucket < bounds.maximum { left -= 1 }
            while right + 1 < waveform.count, waveform[right + 1] > threshold, Double(right - center + 1) * bucket < bounds.maximum { right += 1 }
            return Double(right - left + 1) * bucket
        }.sorted()
        // Unknown content gets the neutral 4 seconds (within the source's own bounds).
        let typical = lengths.isEmpty ? 4 : lengths[lengths.count / 2]
        let clip = min(length, max(bounds.minimum, min(bounds.maximum, typical.rounded())))
        recommendedClipLength = clip
        // Budget: distinct usable highlights (at least the 3 best peaks when fewer are strong),
        // never repeats; unknown content scales with duration. At most half the source.
        var kept: [Double] = []
        func distinct(_ times: [Double]) -> Int {
            kept = []
            for time in times where kept.allSatisfy({ abs($0 - time) >= clip }) { kept.append(time) }
            return kept.count
        }
        let wanted: Int
        if evidence {
            let strongCount = distinct(strong)
            wanted = min(8, max(strongCount, min(3, distinct(peaks))))
        } else {
            wanted = min(3, 1 + Int(length / 20))
        }
        let capacity = max(1, Int(length / clip))
        let shareCap = max(1, Int(length * 0.5 / clip))
        recommendedCount = min(capacity, shareCap, max(1, wanted))
    }

    /// 실제 스윙 영상은 타격 소리 피크 앞(셋업·백스윙)부터 뒤(피니시·공 구름)까지 이어진다. 실측에서 소리 이벤트가 실제 임팩트보다
    /// 1초 남짓 늦거나, 연습 스윙 소리 2초 남짓 뒤에 소리 없는 실제 샷·퍼팅이 오므로 앞 2.5초, 뒤 3.5초를 지킨다(Android와 같은 값).
    static let actionLeadSeconds = 2.5
    static let actionFollowSeconds = 3.5
    /// 큰 클릭이 아닌 소리 뒤: 4초 남짓 뒤 소리 없는 실제 스트로크(연습 스윙 뒤 샷, 조용한 퍼팅)와 그 결과(공 구름·카메라 추적)까지(Android와 같은 값).
    static let weakActionFollowSeconds = 6.0
    /// 피크 직전 이 시간 안의 고립된 짧은 타격은 그 동작의 실제 임팩트다(뒤의 큰 소리는 그다음 소리).
    static let onsetSearchSeconds = 3.8
    /// 이보다 가까운 transient는 같은 타격(분석 프레임에 나뉜 한 클릭)이다.
    static let transientMergeSeconds = 0.6
    /// 검증된 이웃 타격은 합친 동작이 보호 구간 3개 길이 안일 때만 합친다.
    static let maximumMergedActionSeconds = 3 * (actionLeadSeconds + actionFollowSeconds)
    /// 유지한 두 동작 사이 틈이 이 이하이고 근거의 보호 구간이 그 틈에 걸치면 메운다.
    static let maximumBridgedGapSeconds = 2.0
    static let maximumScenesPerSource = 8

    /// 시작 `start`, 길이 `length`인 창이 지켜야 할 소스 시각 구간. 창 안의 가장 강한(검증 우선) 피크 앞뒤를 소스 안으로 잘라 보호하고,
    /// 창 안에 피크가 없으면 창 전체를 보호한다. 피크 직전 3.8초 안에 고립된 짧은 타격(조용한 임팩트)이 있으면
    /// 가장 이른 그 타격이 실제 임팩트이므로 앞쪽 보호는 피크가 아니라 그 타격 기준이다(뒤쪽은 그대로).
    func protectedInterval(start: Double, length: Double) -> (start: Double, end: Double) {
        guard let peak = peaks.first(where: { $0 >= start - 1e-6 && $0 <= start + length + 1e-6 }) else { return (start, start + length) }
        let onset = analysis.transientTimes.filter { $0 < peak && peak - $0 <= Self.onsetSearchSeconds }.min() ?? peak
        return (max(0, onset - Self.actionLeadSeconds), min(duration, peak + Self.actionFollowSeconds))
    }

    /// 요청한 창이 보호 구간보다 짧으면 창을 보호 구간 전체로 넓힌다(아니면 그대로). 보호 구간도 함께 돌려준다.
    func actionWindow(start: Double, length: Double) -> (start: Double, length: Double, action: (start: Double, end: Double)) {
        let action = protectedInterval(start: start, length: length)
        guard action.end - action.start > length + 1e-9 else { return (start, length, action) }
        return (action.start, action.end - action.start, action)
    }

    /// 동작 근거 하나. sharp: 고립된 짧은 타격(클럽·공 클릭)이 이 동작이거나 이 동작으로 이어진다. 바람·카트·말소리는 지속음이라 sharp가 아니다.
    struct ActionPeak {
        let time: Double
        let score: Double
        let onset: Double
        let verified: Bool
        let sharp: Bool
        let loud: Bool
        /// 독립 동작: 분류기 검증, 고립 타격, 또는 0.3초 이상 앞선 고립 클릭이 이끄는 피크.
        var independent: Bool { verified || sharp || time - onset >= 0.3 }
        /// 큰(55% 컷 이상) 고립 클릭만 임팩트 그 자체다. 그보다 약한 소리는 연습 스윙·준비 소리일 수 있어 뒤를 더 길게 지킨다.
        func interval(duration: Double) -> (start: Double, end: Double) {
            let follow = sharp && loud ? VideoTrailerPlan.actionFollowSeconds : VideoTrailerPlan.weakActionFollowSeconds
            return (max(0, onset - VideoTrailerPlan.actionLeadSeconds), min(duration, time + follow))
        }
    }

    /// 창 시작과 그 창이 잘린 근거, 지켜야 할 동작 구간(이웃 타격을 합치면 근거 하나의 구간보다 넓다).
    struct ActionPick {
        var start: Double
        let peak: ActionPeak?
        var actionStart: Double
        var actionEnd: Double
    }

    /// Android `recommendationEvidence`와 같은 후보: 큰 소리(55% 컷) 또는 분류기 검증 피크, 그리고 그 순위가 놓친 고립 타격.
    /// 순서는 sharp, 검증, 세기(같으면 원래 순서).
    func rankedActionPeaks() -> [ActionPeak] {
        guard hasEvidence, duration > 0, !waveform.isEmpty else { return [] }
        let top = waveform.max() ?? 0
        let baseline = waveform.reduce(0, +) / Double(waveform.count)
        let strongCut = max(baseline, top * 0.55)
        func index(_ time: Double) -> Int { min(waveform.count - 1, max(0, Int(time / duration * Double(waveform.count)))) }
        var seen = Set<Double>()
        var candidates: [(time: Double, score: Double, verified: Bool)] = []
        for time in analysis.peakTimes where time.isFinite && time >= 0 && time <= duration && !seen.contains(time) {
            seen.insert(time)
            let verified = analysis.verifiedPeakTimes.contains { abs($0 - time) < 1e-6 }
            let score = waveform[index(time)]
            if score >= strongCut || verified { candidates.append((time, score, verified)) }
        }
        guard !candidates.isEmpty else { return [] }
        var transients: [Double] = []
        for time in analysis.transientTimes.filter({ $0.isFinite && $0 >= 0 && $0 <= duration }).sorted()
            where transients.last.map({ time - $0 >= Self.transientMergeSeconds }) ?? true { transients.append(time) }
        let peaks = candidates.map { candidate -> ActionPeak in
            let onset = transients.filter { $0 < candidate.time && candidate.time - $0 <= Self.onsetSearchSeconds }.min() ?? candidate.time
            let sharp = transients.contains { $0 <= candidate.time + Self.transientMergeSeconds && candidate.time - $0 <= Self.onsetSearchSeconds }
            return ActionPeak(time: candidate.time, score: candidate.score, onset: onset, verified: candidate.verified, sharp: sharp,
                              loud: candidate.score >= strongCut)
        }
        // 소리 크기·분류기 순위가 빠뜨린 고립 타격(조용한 퍼팅, 바람 속 1인칭 샷)도 그 자체로 동작 후보다.
        let extra = transients.filter { time in !peaks.contains { time >= $0.onset - 1e-6 && time <= $0.time + Self.transientMergeSeconds } }
            .map { ActionPeak(time: $0, score: waveform[index($0)], onset: $0, verified: false, sharp: true, loud: waveform[index($0)] >= strongCut) }
        return (peaks + extra).enumerated().sorted { lhs, rhs in
            if lhs.element.sharp != rhs.element.sharp { return lhs.element.sharp }
            if lhs.element.verified != rhs.element.verified { return lhs.element.verified }
            if lhs.element.score != rhs.element.score { return lhs.element.score > rhs.element.score }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// 이 소스가 내는 동작 창(강한 순). Android `rankedSourcePicks`와 같은 규칙: 고립 타격 동작은 개수 한도 없이 모두 남고 이웃이면
    /// 합친다. 검증 이웃은 합친 길이가 짧을 때만 합치고, 안 되면 빈 틈에 따로 둔다. 그 밖의 피크는 소스당 한도(용량·절반·8개)까지.
    func actionPicks(clipLength clip: Double) -> [ActionPick] {
        let ranked = rankedActionPeaks()
        guard !ranked.isEmpty else { return [] }
        let sceneLength = max(0.001, min(duration, clip))
        let capacity = max(1, Int((duration / sceneLength + 1e-6).rounded(.down)))
        let halfBudget = max(1, Int((duration / 2 / sceneLength + 1e-6).rounded(.down)))
        let limit = min(capacity, halfBudget, Self.maximumScenesPerSource)
        let maxStart = max(0, duration - sceneLength)
        var picks: [ActionPick] = []
        var deferred: [ActionPeak] = []
        func overlaps(_ a: Double, _ b: Double, _ pick: ActionPick) -> Bool { a < pick.actionEnd - 1e-6 && pick.actionStart < b - 1e-6 }
        func consider(_ peak: ActionPeak, retry: Bool) {
            let (a, b) = peak.interval(duration: duration)
            let start = min(max(0, peak.time - sceneLength / 2), maxStart)
            guard let clash = picks.firstIndex(where: { abs($0.start - start) < sceneLength - 1e-6 || overlaps(a, b, $0) }) else {
                if !peak.sharp && picks.count >= limit {
                    if !retry && peak.verified { deferred.append(peak) }
                    return
                }
                picks.append(ActionPick(start: start, peak: peak, actionStart: a, actionEnd: b))
                return
            }
            // 이미 남긴 동작 옆의 별개 타격은 버리지 않고 한 동작으로 합친다.
            var members: Set<Int> = [clash]
            var action = (min(a, picks[clash].actionStart), max(b, picks[clash].actionEnd))
            var changed = true
            while changed {
                changed = false
                for (i, other) in picks.enumerated() where !members.contains(i) && overlaps(action.0, action.1, other) {
                    members.insert(i)
                    action = (min(action.0, other.actionStart), max(action.1, other.actionEnd))
                    changed = true
                }
            }
            let grows = members.contains { action.0 < picks[$0].actionStart - 1e-6 || action.1 > picks[$0].actionEnd + 1e-6 }
            guard grows else { return }
            guard peak.sharp || (peak.verified && action.1 - action.0 <= Self.maximumMergedActionSeconds) else {
                // 합치기엔 너무 길다: 아직 어느 동작에도 없는 검증 타격은 앞뒤 1초가 들어가는 빈 틈에 따로 둔다.
                // 이미 남긴 동작 사이만 채우므로 소스당 한도는 적용하지 않는다.
                let lo = max(a, picks.filter { $0.actionEnd <= peak.time + 1e-6 }.map(\.actionEnd).max() ?? a)
                let hi = min(b, picks.filter { $0.actionStart >= peak.time - 1e-6 }.map(\.actionStart).min() ?? b)
                if peak.independent && peak.time - lo >= 1.0 - 1e-6 && hi - peak.time >= 1.0 - 1e-6
                    && !picks.contains(where: { overlaps(lo, hi, $0) }) {
                    picks.append(ActionPick(start: start, peak: peak, actionStart: lo, actionEnd: hi))
                }
                return
            }
            // 합친 것 중 가장 강한 창이 순위 자리를 지킨다.
            let first = members.min()!
            var strongest = picks[first]
            strongest.actionStart = action.0
            strongest.actionEnd = action.1
            for i in members.sorted(by: >) { picks.remove(at: i) }
            picks.insert(strongest, at: first)
        }
        for peak in ranked { consider(peak, retry: false) }
        for peak in deferred { consider(peak, retry: true) }
        // 2초 이하 틈에 독립 타격의 보호 구간이 걸치면 앞 동작을 다음 동작 시작까지 늘려, 그 타격이 둘 사이에서 잘리지 않게 한다.
        let order = picks.indices.sorted { picks[$0].actionStart < picks[$1].actionStart }
        for k in order.indices.dropLast() {
            let cur = picks[order[k]]
            let next = picks[order[k + 1]]
            let gap = next.actionStart - cur.actionEnd
            guard gap > 1e-6, gap <= Self.maximumBridgedGapSeconds else { continue }
            let reaches = ranked.contains { peak in
                let (a, b) = peak.interval(duration: duration)
                return peak.independent && a < next.actionStart - 1e-6 && b > cur.actionEnd + 1e-6
            }
            if reaches { picks[order[k]].actionEnd = next.actionStart }
        }
        return picks
    }

    /// 동작 창: 보호 구간이 요청 길이보다 길면 구간 전체, 아니면 요청 길이 창을 구간이 들어가도록 옮긴다.
    func actionWindow(pick: ActionPick, length: Double) -> (start: Double, length: Double, action: (start: Double, end: Double)) {
        let a = pick.actionStart, b = pick.actionEnd
        if b - a > length + 1e-9 { return (a, b - a, (a, b)) }
        return (min(max(pick.start, max(0, b - length)), a), length, (a, b))
    }

    /// 강한 순서대로 서로 `clip` 이상 떨어진 상위 `count`개 창 시작점을 시간순으로 돌려준다(근거 있는 소스 전용).
    func strongestStarts(count: Int, clipLength clip: Double) -> [Double] {
        guard hasEvidence, duration > 0, count > 0 else { return [] }
        let length = max(0.001, min(duration, clip))
        var starts: [Double] = []
        for peak in peaks where starts.count < count {
            let start = max(0, min(duration - length, peak - length / 2))
            if starts.allSatisfy({ abs($0 - start) >= length - 1e-6 }) { starts.append(start) }
        }
        return starts.sorted()
    }

    func proposal(total: Double? = nil, clipLength: Double? = nil) -> [VideoTrailerScene] {
        guard duration > 0 else { return [] }
        let requestedClip = clipLength.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? recommendedClipLength
        let requestedTotal = total.flatMap { $0.isFinite ? $0 : nil } ?? recommendedTotal
        let length = max(0.001, min(duration, requestedClip))
        let capacity = max(1, Int((duration / length + 0.000001).rounded(.down)))
        let count = Int(min(Double(capacity), max(1, (requestedTotal / length).rounded())))
        let regionLength = duration / Double(count)
        // One distinct region per required clip guarantees the requested count,
        // while the shared analysis chooses the strongest moment in each region.
        return (0..<count).map { index in
            let lower = Double(index) * regionLength
            let upper = min(duration, Double(index + 1) * regionLength)
            let rankedPeaks = peaks.filter { $0 >= lower && $0 < upper }
            let waveformPeaks = waveform.indices.compactMap { bucket -> (Double, Double)? in
                let time = (Double(bucket) + 0.5) / Double(waveform.count) * duration
                return time >= lower && time < upper ? (time, waveform[bucket]) : nil
            }
            let peak = !hasEvidence ? (lower + upper) / 2
                : (rankedPeaks.first ?? waveformPeaks.max(by: { $0.1 < $1.1 })?.0 ?? (lower + upper) / 2)
            let start = max(lower, min(upper - length, peak - length / 2))
            return VideoTrailerScene(id: index, start: start, length: length)
        }
    }
}

/// `mediaMusic` is "영상에 뮤직비디오": the selected photos and videos are joined
/// whole and in order, with no scene picking, and music is chosen before any export.
enum VideoTrailerMode {
    case trailer
    case mediaMusic
}

struct VideoTrailerSelection: Identifiable {
    let id = UUID()
    let items: [RemoteFileItem]
    var mode = VideoTrailerMode.trailer
    /// Keeps the caller's item order as the editor's initial source order (default: chronological).
    var keepsSelectionOrder = false
}

struct VideoTrailerSource: Identifiable {
    let id: Int
    let name: String
    let url: URL
    let plan: VideoTrailerPlan
    var isImage = false
    /// The original remote item's content type, used only as a fallback for the
    /// thumbnail's extension label when its name has none (the staged temp copy's
    /// own extension is never shown).
    var contentTypeIdentifier: String?
    /// Actual media capture/creation timestamp (EXIF/QuickTime metadata) when available,
    /// otherwise the remote file's reported modification time. Never the local temp
    /// copy's filesystem creation time, which would reflect only when it was downloaded.
    var captureDate: Date?
    /// Fraction of the configured video clip length this photo's own scene lasts: set once
    /// from the staged photo's own HanYang quality/similarity analysis (`VideoTrailerPhotoQuality`)
    /// right after every photo in the batch finishes staging, so it stays the same across
    /// every preview redraw, export and resumed session until the photo is staged again.
    /// This default only shows briefly while that analysis is still running.
    var imageDurationRatio: Double = 0.55
    /// 1 = 레거시(0.35...0.75 범위), 2 = 현재 정책(0.10...0.95 + 보너스). 새 소스는 2.
    var imageDurationPolicyVersion: Int = 2
    var isImportant: Bool = false
    var duration: Double { plan.duration }

    /// 추천 및 자동 계획 계산 시 구버전 비율을 안전하게 마이그레이션된 값으로 평가한다.
    var effectiveImageDurationRatio: Double {
        if imageDurationPolicyVersion < 2 {
            return VideoTrailerPhotoQuality.migrateV1ToV2Ratio(imageDurationRatio)
        }
        return imageDurationRatio
    }

    /// 사진 소스의 가중치 적용 길이 계산 (isImportant 우선순위 반영)
    /// 기본: clipLength * ratio (1/30...30초)
    /// 중요: ratio = 0.85 + 0.15 * clamp(effectiveHanYangRatio / 0.95, 0...1), min 3.0, max = max(clipLength, 3.0) bounded by hard 30.0
    func weightedImageLength(clipLength: Double) -> Double {
        guard isImage else { return max(0.001, min(clipLength, duration)) }
        let rawRatio = effectiveImageDurationRatio
        let validRatio = rawRatio.isFinite && rawRatio > 0 ? rawRatio : 0.55
        if isImportant {
            let clampedHanYang = min(1.0, max(0.0, validRatio / 0.95))
            let importantRatio = 0.85 + 0.15 * clampedHanYang
            let configuredMax = min(30.0, max(3.0, clipLength))
            let calculated = clipLength * importantRatio
            return min(configuredMax, max(3.0, calculated))
        } else {
            return min(30.0, max(1.0 / 30.0, clipLength * validRatio))
        }
    }
}

enum VideoTrailerSourceOrder {
    /// Stable shuffle that always produces a fresh order, even when invoked repeatedly
    /// with the sources already in a previously-shuffled arrangement.
    static func randomized(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        guard sources.count > 1 else { return sources }
        let currentIDs = sources.map(\.id)
        for _ in 0..<5 {
            let candidate = sources.shuffled()
            if candidate.map(\.id) != currentIDs {
                return candidate
            }
        }
        return Array(sources.dropFirst()) + [sources[0]]
    }

    static func added(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.sorted { $0.id < $1.id }
    }

    static func chronological(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.sorted { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default:
                let cmp = lhs.name.compare(rhs.name, options: [.numeric], range: nil, locale: Locale(identifier: "ko_KR"))
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.id < rhs.id
            }
        }
    }

    static func byName(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.sorted {
            let cmp = $0.name.compare($1.name, options: [.numeric], range: nil, locale: Locale(identifier: "ko_KR"))
            if cmp != .orderedSame { return cmp == .orderedAscending }
            return $0.id < $1.id
        }
    }

    private static func nameTiebreak(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.numeric], range: nil, locale: Locale(identifier: "ko_KR")) == .orderedAscending
    }
}

func videoTrailerTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

enum VideoTrailerBatchPlan {
    static let maximumRequestedDuration: Double = 7_200

    /// Every source once, in order and uncut: whole videos and 1 second per photo. A video without
    /// a valid duration has nothing to show and is skipped.
    static func wholeMedia(sources: [VideoTrailerSource]) -> [VideoTrailerScene] {
        sources.filter { $0.isImage || $0.duration > 0 }.enumerated().map { index, source in
            var scene = VideoTrailerScene(id: index, start: 0, length: source.isImage ? 1 : source.duration)
            scene.sourceID = source.id
            return scene
        }
    }

    static let maximumFittedScenes = 600

    /// Makes the already planned scenes last `seconds`: they are repeated from the first
    /// one, in the same order, while the plan is too short, and the last one is cut
    /// where the time runs out. Nothing is sped up or slowed down. Lengths are counted
    /// in 1/600 second, the composition's own time scale, so the total never drifts.
    /// Returns nil when that would take more than `maximumFittedScenes` scenes.
    static func fitted(_ scenes: [VideoTrailerScene], to seconds: Double) -> [VideoTrailerScene]? {
        let ticks: (Double) -> Int64 = { Int64(($0 * 600).rounded()) }
        // Anything under one frame (1/30 second) is too short to show as its own scene.
        let usable = scenes.filter { ticks($0.length) >= 20 }
        guard seconds.isFinite, seconds > 0, !usable.isEmpty else { return nil }
        let target = Int64((seconds * 600).rounded(.down))
        var result: [VideoTrailerScene] = []
        var used: Int64 = 0
        while target - used >= 20 {
            guard result.count < maximumFittedScenes else { return nil }
            let scene = usable[result.count % usable.count]
            let length = min(ticks(scene.length), target - used)
            var fittedScene = VideoTrailerScene(id: result.count, start: scene.start, length: Double(length) / 600)
            fittedScene.sourceID = scene.sourceID
            fittedScene.muted = scene.muted
            fittedScene.fitsFrame = scene.fitsFrame
            fittedScene.volume = scene.volume
            fittedScene.offsetX = scene.offsetX
            fittedScene.offsetY = scene.offsetY
            fittedScene.caption = scene.caption
            result.append(fittedScene)
            used += length
        }
        return result.isEmpty ? nil : result
    }

    /// 총길이 지정은 장면 파일을 복제하지 않고 같은 소스 범위를 순서대로 반복한다.
    /// 음악 길이 맞추기의 별도 장면 제한/정책에는 영향을 주지 않는다.
    static func looped(_ scenes: [VideoTrailerScene], to seconds: Double) -> [VideoTrailerScene] {
        guard seconds.isFinite, seconds > 0 else { return [] }
        let target = Int64((min(maximumRequestedDuration, seconds) * 600).rounded())
        let usable = scenes.filter { $0.length.isFinite && $0.length * 600 >= 20 }
        guard target > 0, !usable.isEmpty else { return [] }
        var result: [VideoTrailerScene] = []
        var used: Int64 = 0
        while used < target {
            let source = usable[result.count % usable.count]
            let ticks = min(max(20, Int64((source.length * 600).rounded())), target - used)
            var repeated = VideoTrailerScene(id: result.count, start: source.start, length: Double(ticks) / 600)
            repeated.sourceID = source.sourceID
            repeated.muted = source.muted
            repeated.fitsFrame = source.fitsFrame
            repeated.volume = source.volume
            repeated.offsetX = source.offsetX
            repeated.offsetY = source.offsetY
            repeated.caption = source.caption
            result.append(repeated)
            used += ticks
        }
        return result
    }

    /// The common scene length: the median of the videos' own recommended lengths (photos never
    /// count; sources without real highlight evidence only when no video has any). A short
    /// video does not shrink it, it is clamped per source in `proposal`.
    static func recommendedClipLength(_ sources: [VideoTrailerSource]) -> Double {
        let videos = sources.filter { !$0.isImage && $0.duration > 0 }
        let informed = videos.filter { $0.plan.hasEvidence }
        let lengths = (informed.isEmpty ? videos : informed).map { $0.plan.recommendedClipLength }.sorted()
        return lengths.isEmpty ? 4 : lengths[lengths.count / 2]
    }

    /// Length of one scene of `source` when the common scene length is `clipLength`: a photo's own
    /// fraction of it, a video the common length (its whole length when it is shorter).
    static func sceneLength(_ source: VideoTrailerSource, clipLength: Double) -> Double {
        if source.isImage {
            return source.weightedImageLength(clipLength: clipLength)
        } else {
            return max(0.001, min(clipLength, source.duration))
        }
    }

    /// How many scenes the automatic recommendation takes from `source` at the common `clipLength`:
    /// one per photo, none from a video without a valid duration, otherwise the video's own
    /// recommended clip count (distinct highlights) limited by what fits at this length and
    /// by half of the source, so one long video can never use another source's budget.
    static func recommendedCount(_ source: VideoTrailerSource, clipLength: Double) -> Int {
        if source.isImage { return 1 }
        guard source.duration > 0, clipLength.isFinite, clipLength > 0 else { return 0 }
        let length = sceneLength(source, clipLength: clipLength)
        let capacity = max(1, Int((source.duration / length + 0.000001).rounded(.down)))
        let share = max(1, Int(source.duration * 0.5 / length))
        return min(source.plan.recommendedCount, capacity, share)
    }

    /// Time budget of the automatic recommendation: every source's recommended scene count times
    /// its scene length at the common `clipLength` (photos included, in full), so the budget is
    /// exactly what the automatic proposal can place.
    static func recommendedBudget(sources: [VideoTrailerSource], clipLength: Double) -> Double {
        guard clipLength.isFinite, clipLength > 0 else { return 0 }
        return sources.reduce(0) { $0 + Double(recommendedCount($1, clipLength: clipLength)) * sceneLength($1, clipLength: clipLength) }
    }

    /// What the editor starts with, and what an export without a chosen total makes: the real
    /// sum of the proposed scenes, so the shown total and the exported video agree.
    static func recommendedTotal(sources: [VideoTrailerSource], clipLength: Double) -> Double {
        recommendedProposal(sources: sources, clipLength: clipLength).reduce(0) { $0 + $1.length }
    }

    /// The automatic scene plan itself: the one scene list the initial settings, the preview and
    /// the export all share while the length and clip length are still the recommended ones.
    /// Android `recommendTrailerPlan`과 같은 규칙: 근거 있는 영상은 모든 보호 동작(`actionPicks`)을 시간순으로 낸다.
    static func recommendedProposal(sources: [VideoTrailerSource], clipLength: Double) -> [VideoTrailerScene] {
        TrailerPreparedPlan.manual(actionSeed(sources: sources, clipLength: clipLength), sources: sources)
    }

    /// 자동 추천의 장면 목록(앵커 포함, id 1부터). 사진은 한 장면, 근거 있는 영상은 동작 창 전부, 근거 없는 영상은 기존 영역 추천.
    static func actionSeed(sources: [VideoTrailerSource], clipLength: Double) -> [TrailerEditScene] {
        guard clipLength.isFinite, clipLength > 0 else { return [] }
        var result: [TrailerEditScene] = []
        func append(_ sourceID: Int, _ start: Double, _ length: Double, _ action: (start: Double, end: Double)?) {
            result.append(TrailerEditScene(id: result.count + 1, sourceID: sourceID, start: start, length: length,
                                           actionStart: action?.start, actionEnd: action?.end))
        }
        for source in sources {
            if source.isImage { append(source.id, 0, source.weightedImageLength(clipLength: clipLength), nil); continue }
            guard source.duration > 0 else { continue }
            let length = sceneLength(source, clipLength: clipLength)
            let picks = source.plan.hasEvidence ? source.plan.actionPicks(clipLength: clipLength) : []
            if !picks.isEmpty {
                for pick in picks.sorted(by: { $0.start < $1.start }) {
                    let window = source.plan.actionWindow(pick: pick, length: length)
                    append(source.id, window.start, window.length, window.action)
                }
                continue
            }
            let count = max(1, recommendedCount(source, clipLength: clipLength))
            for scene in source.plan.proposal(total: Double(count) * length, clipLength: length) {
                let action = source.plan.hasEvidence ? source.plan.protectedInterval(start: scene.start, length: scene.length) : nil
                append(source.id, scene.start, scene.length, action)
            }
        }
        return result
    }

    /// 자동 추천 시드를 `total`로 나눈다. 보호된 동작보다 짧게는 줄이지 않으므로 결과가 `total`보다 길 수 있다(조용히 샷을 빼지 않는다).
    /// 사용자가 정한 전체 길이(예산)는 장면 목록이 생긴 뒤 화면의 `setManualTotal`이 `fitScenesToBudget`으로 맞춘다(예전 자동 총길이는 예산이 아님).
    static func actionSeed(sources: [VideoTrailerSource], total: Double, clipLength: Double) -> [TrailerEditScene] {
        var seeded = actionSeed(sources: sources, clipLength: clipLength)
        let recommended = seeded.reduce(0) { $0 + $1.length }
        if total.isFinite, total > 0, abs(total - recommended) >= 0.0005 {
            TrailerSceneEditor.redistributeManualTotal(scenes: &seeded, sources: sources, targetTotal: min(maximumRequestedDuration, total))
        }
        return seeded
    }

    /// The scenes for the settings in effect. A missing total, or a total equal (within floating
    /// tolerance, also after the 1...maximum clamp a chosen total goes through) to the
    /// recommended one, is the automatic plan. Any other total is a manual one, which may use
    /// each source up to its capacity and repeat scenes to fill the exact length.
    static func selection(sources: [VideoTrailerSource], total: Double?, clipLength: Double) -> [VideoTrailerScene] {
        let automatic = recommendedProposal(sources: sources, clipLength: clipLength)
        guard let total else { return automatic }
        let recommended = automatic.reduce(0) { $0 + $1.length }
        let clamped = min(maximumRequestedDuration, max(1, recommended))
        if abs(total - recommended) < 0.0005 || abs(total - clamped) < 0.0005 { return automatic }
        // 다른 길이: 같은 동작 시드를 그 길이로 나눈다(보호 동작은 줄이지 않음). 영역을 새로 골라 샷을 빼지 않는다.
        return TrailerPreparedPlan.manual(actionSeed(sources: sources, total: total, clipLength: clipLength), sources: sources)
    }

    /// `repeatToFill: false` is the automatic recommendation: every source is limited to its own
    /// recommended count and nothing is repeated just to fill time. `true` (a chosen total) may
    /// use every source up to its full capacity and then repeats the scenes to the exact total.
    static func proposal(sources: [VideoTrailerSource], total: Double, clipLength: Double, repeatToFill: Bool = true) -> [VideoTrailerScene] {
        guard total.isFinite, total > 0, clipLength.isFinite, clipLength > 0, !sources.isEmpty else { return [] }
        let requestedTotal = min(maximumRequestedDuration, total)
        // A still image always contributes exactly one clip, at its own quality/similarity
        // analysis-derived fraction of the video clip length. A video shorter than the common
        // clip length keeps its place with one scene of its own whole length; a video without a
        // valid duration is skipped.
        let lengthFor: (Int) -> Double = { sceneLength(sources[$0], clipLength: clipLength) }
        let fullCapacity = sources.indices.map { index -> Int in
            if sources[index].isImage { return 1 }
            guard sources[index].duration > 0 else { return 0 }
            return max(1, Int((sources[index].duration / lengthFor(index) + 0.000001).rounded(.down)))
        }
        guard fullCapacity.contains(where: { $0 > 0 }) else { return [] }
        let capacity = repeatToFill ? fullCapacity
            : sources.indices.map { min(fullCapacity[$0], recommendedCount(sources[$0], clipLength: clipLength)) }
        var counts = Array(repeating: 0, count: sources.count)
        var remainingTime = requestedTotal
        // Include each source once when it has capacity and the budget allows it, then
        // distribute any remaining video-only capacity by duration.
        for index in sources.indices where capacity[index] > 0 && remainingTime + 0.000001 >= lengthFor(index) {
            counts[index] = 1
            remainingTime -= lengthFor(index)
        }
        while remainingTime > 0 {
            guard let index = sources.indices.filter({ !sources[$0].isImage && counts[$0] < capacity[$0] }).max(by: {
                sources[$0].duration / Double(counts[$0] + 1) < sources[$1].duration / Double(counts[$1] + 1)
            }), remainingTime + 0.000001 >= lengthFor(index) else { break }
            counts[index] += 1
            remainingTime -= lengthFor(index)
        }
        // A budget too small for even one scene still yields the single shortest one,
        // matching the previous behaviour of always proposing at least one clip.
        if counts.allSatisfy({ $0 == 0 }), let index = sources.indices.filter({ fullCapacity[$0] > 0 }).min(by: { lengthFor($0) < lengthFor($1) }) {
            counts[index] = 1
        }
        var result: [VideoTrailerScene] = []
        for index in sources.indices where counts[index] > 0 {
            if sources[index].isImage {
                var combined = VideoTrailerScene(id: result.count, start: 0, length: lengthFor(index))
                combined.sourceID = sources[index].id
                result.append(combined)
            } else {
                for scene in sources[index].plan.proposal(total: Double(counts[index]) * lengthFor(index), clipLength: lengthFor(index)) {
                    var combined = VideoTrailerScene(id: result.count, start: scene.start, length: scene.length)
                    combined.sourceID = sources[index].id
                    result.append(combined)
                }
            }
        }
        return repeatToFill ? looped(result, to: requestedTotal) : result
    }
}
