import Foundation

struct VideoTrailerScene: Identifiable {
    let id: Int
    let start: Double
    let length: Double
    var sourceID = 0
}

struct VideoTrailerPlan {
    let analysis: AudioAnalysisResult
    let duration: Double
    let recommendedClipLength: Double
    let recommendedTotal: Double

    init(analysis: AudioAnalysisResult, duration: Double) {
        self.analysis = analysis
        self.duration = duration
        let waveform = analysis.waveform
        let baseline = waveform.isEmpty ? 0 : waveform.reduce(0, +) / Double(waveform.count)
        let strong = analysis.peakTimes.filter { peak in
            guard !waveform.isEmpty else { return false }
            let index = min(waveform.count - 1, max(0, Int(peak / duration * Double(waveform.count))))
            return waveform[index] >= max(baseline, (waveform.max() ?? 0) * 0.55)
        }
        let lengths = analysis.peakTimes.map { peak -> Double in
            guard !waveform.isEmpty else { return min(4, duration) }
            let index = min(waveform.count - 1, max(0, Int(peak / duration * Double(waveform.count))))
            let threshold = baseline + max(0, waveform[index] - baseline) * 0.4
            var left = index
            var right = index
            while left > 0, waveform[left - 1] > threshold, index - left < 12 { left -= 1 }
            while right + 1 < waveform.count, waveform[right + 1] > threshold, right - index < 12 { right += 1 }
            return min(duration, max(1, min(10, Double(right - left + 1) * duration / Double(waveform.count) + 1)))
        }.sorted()
        recommendedClipLength = max(min(1, duration), min(duration, (lengths.isEmpty ? 4 : lengths[lengths.count / 2]).rounded()))
        let count = min(max(1, Int(duration / max(0.001, recommendedClipLength))), max(1, min(8, strong.count)))
        recommendedTotal = Double(count) * recommendedClipLength
    }

    func proposal(total: Double? = nil, clipLength: Double? = nil) -> [VideoTrailerScene] {
        let length = max(0.001, min(duration, clipLength ?? recommendedClipLength))
        let capacity = max(1, Int((duration / length + 0.000001).rounded(.down)))
        let count = min(capacity, max(1, Int(((total ?? recommendedTotal) / length).rounded())))
        let regionLength = duration / Double(count)
        // One distinct region per required clip guarantees the requested count,
        // while the shared analysis chooses the strongest moment in each region.
        return (0..<count).map { index in
            let lower = Double(index) * regionLength
            let upper = min(duration, Double(index + 1) * regionLength)
            let rankedPeaks = analysis.peakTimes.filter { $0 >= lower && $0 < upper }
            let waveformPeaks = analysis.waveform.indices.compactMap { bucket -> (Double, Double)? in
                let time = (Double(bucket) + 0.5) / Double(analysis.waveform.count) * duration
                return time >= lower && time < upper ? (time, analysis.waveform[bucket]) : nil
            }
            let peak = analysis.highlightSource == .fallback ? (lower + upper) / 2
                : (rankedPeaks.first ?? waveformPeaks.max(by: { $0.1 < $1.1 })?.0 ?? (lower + upper) / 2)
            let start = max(lower, min(upper - length, peak - length / 2))
            return VideoTrailerScene(id: index, start: start, length: length)
        }
    }
}

/// `mediaMusic` is "영상에 음악 입히기": the selected photos and videos are joined
/// whole and in order, with no scene picking, and music is chosen before any export.
enum VideoTrailerMode {
    case trailer
    case mediaMusic
}

struct VideoTrailerSelection: Identifiable {
    let id = UUID()
    let items: [RemoteFileItem]
    var mode = VideoTrailerMode.trailer
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
    /// A photo-only trailer (every retained source is a still image) always uses exactly
    /// 1 second per photo; a mixed trailer keeps every still image at exactly half the
    /// video clip length. `photoOnly` must be recomputed from the actual retained sources
    /// each time (after decode skips, removing the last video, retry, reopen or
    /// recommend), never decided once from the initial items.
    static func imageClipLength(for clipLength: Double, photoOnly: Bool) -> Double {
        photoOnly ? 1 : clipLength / 2
    }

    /// Every source once, in order and uncut: whole videos and 1 second per photo.
    static func wholeMedia(sources: [VideoTrailerSource]) -> [VideoTrailerScene] {
        sources.enumerated().map { index, source in
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
            result.append(fittedScene)
            used += length
        }
        return result.isEmpty ? nil : result
    }

    static func proposal(sources: [VideoTrailerSource], total: Double, clipLength: Double) -> [VideoTrailerScene] {
        guard clipLength > 0, !sources.isEmpty else { return [] }
        let photoOnly = sources.allSatisfy(\.isImage)
        let photoLength = imageClipLength(for: clipLength, photoOnly: photoOnly)
        // A still image always contributes exactly one clip at `photoLength`, regardless
        // of its nominal duration; videos planned against the shared duration total still
        // use the video clip length so timing isn't skewed by the photo length.
        let capacity = sources.map { $0.isImage ? 1 : max(0, Int(($0.duration / clipLength + 0.000001).rounded(.down))) }
        let lengthFor: (Int) -> Double = { sources[$0].isImage ? photoLength : clipLength }
        guard capacity.contains(where: { $0 > 0 }) else { return [] }
        var counts = Array(repeating: 0, count: sources.count)
        var remainingTime = total
        // Include each source once when it has capacity and the budget allows it, then
        // distribute any remaining video-only capacity by duration.
        for index in sources.indices where capacity[index] > 0 && remainingTime >= lengthFor(index) {
            counts[index] = 1
            remainingTime -= lengthFor(index)
        }
        while remainingTime > 0 {
            guard let index = sources.indices.filter({ !sources[$0].isImage && counts[$0] < capacity[$0] }).max(by: {
                sources[$0].duration / Double(counts[$0] + 1) < sources[$1].duration / Double(counts[$1] + 1)
            }), remainingTime >= clipLength else { break }
            counts[index] += 1
            remainingTime -= clipLength
        }
        // A budget too small for even one scene still yields the single shortest one,
        // matching the previous behaviour of always proposing at least one clip.
        if counts.allSatisfy({ $0 == 0 }), let index = sources.indices.filter({ capacity[$0] > 0 }).min(by: { lengthFor($0) < lengthFor($1) }) {
            counts[index] = 1
        }
        var result: [VideoTrailerScene] = []
        for index in sources.indices where counts[index] > 0 {
            if sources[index].isImage {
                var combined = VideoTrailerScene(id: result.count, start: 0, length: photoLength)
                combined.sourceID = sources[index].id
                result.append(combined)
            } else {
                for scene in sources[index].plan.proposal(total: Double(counts[index]) * clipLength, clipLength: clipLength) {
                    var combined = VideoTrailerScene(id: result.count, start: scene.start, length: scene.length)
                    combined.sourceID = sources[index].id
                    result.append(combined)
                }
            }
        }
        return result
    }
}
