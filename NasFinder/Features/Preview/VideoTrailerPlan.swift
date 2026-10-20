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
        let peaks = analysis.peakTimes.filter { $0.isFinite && $0 >= 0 && $0 <= length }
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
        let strong = evidence ? peaks.filter { waveform[index($0)] >= max(baseline, top * 0.55) } : []
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
    var duration: Double { plan.duration }
}

enum VideoTrailerSourceOrder {
    /// Stable shuffle that always produces a fresh order, even when invoked repeatedly
    /// with the sources already in a previously-shuffled arrangement.
    static func randomized(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.shuffled()
    }

    static func chronological(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.sorted { lhs, rhs in
            switch (lhs.captureDate, rhs.captureDate) {
            case let (l?, r?) where l != r: return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            default: return nameTiebreak(lhs.name, rhs.name)
            }
        }
    }

    static func byName(_ sources: [VideoTrailerSource]) -> [VideoTrailerSource] {
        sources.sorted { nameTiebreak($0.name, $1.name) }
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
        source.isImage ? clipLength * source.imageDurationRatio : max(0.001, min(clipLength, source.duration))
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
    static func recommendedProposal(sources: [VideoTrailerSource], clipLength: Double) -> [VideoTrailerScene] {
        proposal(sources: sources, total: recommendedBudget(sources: sources, clipLength: clipLength),
                 clipLength: clipLength, repeatToFill: false)
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
        return proposal(sources: sources, total: total, clipLength: clipLength)
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
