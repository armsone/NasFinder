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
            return min(duration, max(2, min(10, Double(right - left + 1) * duration / Double(waveform.count) + 1)))
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

struct VideoTrailerSelection: Identifiable {
    let id = UUID()
    let items: [RemoteFileItem]
}

struct VideoTrailerSource: Identifiable {
    let id: Int
    let name: String
    let url: URL
    let plan: VideoTrailerPlan
    var duration: Double { plan.duration }
}

func videoTrailerTime(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

enum VideoTrailerBatchPlan {
    static func proposal(sources: [VideoTrailerSource], total: Double, clipLength: Double) -> [VideoTrailerScene] {
        guard clipLength > 0, !sources.isEmpty else { return [] }
        let capacity = sources.map { max(0, Int(($0.duration / clipLength + 0.000001).rounded(.down))) }
        let requested = min(capacity.reduce(0, +), max(1, Int((total / clipLength).rounded())))
        guard requested > 0 else { return [] }
        var counts = Array(repeating: 0, count: sources.count)
        var remaining = requested
        // Include each source when there are enough clips, then distribute by duration.
        for index in sources.indices where capacity[index] > 0 && remaining > 0 {
            counts[index] = 1
            remaining -= 1
        }
        while remaining > 0 {
            guard let index = sources.indices.filter({ counts[$0] < capacity[$0] }).max(by: {
                sources[$0].duration / Double(counts[$0] + 1) < sources[$1].duration / Double(counts[$1] + 1)
            }) else { break }
            counts[index] += 1
            remaining -= 1
        }
        var result: [VideoTrailerScene] = []
        for index in sources.indices where counts[index] > 0 {
            for scene in sources[index].plan.proposal(total: Double(counts[index]) * clipLength, clipLength: clipLength) {
                var combined = VideoTrailerScene(id: result.count, start: scene.start, length: scene.length)
                combined.sourceID = sources[index].id
                result.append(combined)
            }
        }
        return result
    }
}
