// Shared trailer analysis, copied from HanClip for an independent NasFinder build.
import AVFoundation
import Foundation

enum ClipAudioAvailability: String, Codable, Sendable {
    case unknown
    case present
    case noTrack
    case silent

    var hasUsableAudio: Bool {
        self == .present || self == .unknown
    }
}

enum ClipHighlightSource: String, Codable, Sendable {
    case audio
    case visualMotion
    case fallback

    var displayTitle: String {
        switch self {
        case .audio:
            "소리 분석"
        case .visualMotion:
            "화면 움직임 분석"
        case .fallback:
            "화면 변화 적음 · 중앙 선택"
        }
    }
}

struct AudioAnalysisResult: Sendable {
    let waveform: [Double]
    let peakTime: Double
    let peakTimes: [Double]
    let audioAvailability: ClipAudioAvailability
    let highlightSource: ClipHighlightSource
    /// `peakTimes` 중 임팩트 분류기가 직접 타격으로 판정한 것(나머지는 단지 가장 큰/일반 소리).
    let verifiedPeakTimes: [Double]
    /// 조용한 클럽/공 클릭처럼 짧고 고립된 날카로운 소리의 시각. 더 뒤의 큰 지속 소음이 점수로는 앞서도 진짜 임팩트는 이쪽일 수 있다.
    let transientTimes: [Double]

    init(
        waveform: [Double],
        peakTime: Double,
        peakTimes: [Double]? = nil,
        audioAvailability: ClipAudioAvailability = .present,
        highlightSource: ClipHighlightSource = .audio,
        verifiedPeakTimes: [Double] = [],
        transientTimes: [Double] = []
    ) {
        self.waveform = waveform
        self.peakTime = peakTime
        self.peakTimes = peakTimes ?? [peakTime]
        self.audioAvailability = audioAvailability
        self.highlightSource = highlightSource
        self.verifiedPeakTimes = verifiedPeakTimes
        self.transientTimes = transientTimes
    }
}

enum AudioAnalysisService {
    static func analyze(url: URL, bucketCount: Int = 192) async throws
        -> AudioAnalysisResult {
        try await Task.detached(priority: .userInitiated) {
            let bucketCount = max(1, bucketCount)
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else {
                throw MediaError.videoTrackUnavailable
            }

            guard let track = try await asset.loadTracks(
                withMediaType: .audio
            ).first else {
                return try await analyzeVisualMotionOrFallback(
                    asset: asset,
                    duration: duration,
                    bucketCount: bucketCount,
                    audioAvailability: .noTrack
                )
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else {
                throw MediaError.videoTrackUnavailable
            }
            reader.add(output)
            reader.startReading()

            var energy = Array(repeating: 0.0, count: bucketCount)
            var peaks = Array(repeating: 0.0, count: bucketCount)
            var crossings = Array(repeating: 0, count: bucketCount)
            var sampleTotals = Array(repeating: 0, count: bucketCount)
            var counts = Array(repeating: 0, count: bucketCount)

            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else {
                    continue
                }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == kCMBlockBufferNoErr,
                      let pointer,
                      length >= MemoryLayout<Int16>.size
                else { continue }

                let sampleCount = length / MemoryLayout<Int16>.size
                let values = UnsafeRawPointer(pointer)
                    .assumingMemoryBound(to: Int16.self)
                var sum = 0.0
                var peak = 0.0
                var crossingCount = 0
                var previousSign = 0
                for index in 0..<sampleCount {
                    let value = Double(values[index]) / Double(Int16.max)
                    let sign = value >= 0 ? 1 : -1
                    sum += value * value
                    peak = max(peak, abs(value))
                    if index > 0, sign != previousSign {
                        crossingCount += 1
                    }
                    previousSign = sign
                }
                let rms = sqrt(sum / Double(max(1, sampleCount)))
                let time = CMSampleBufferGetPresentationTimeStamp(sample)
                    .seconds
                let bucket = min(
                    bucketCount - 1,
                    max(0, Int(time / duration * Double(bucketCount)))
                )
                energy[bucket] += rms
                peaks[bucket] = max(peaks[bucket], peak)
                crossings[bucket] += crossingCount
                sampleTotals[bucket] += sampleCount
                counts[bucket] += 1
            }

            let metrics = (0..<bucketCount).map { index in
                AudioImpactMetrics(
                    rms: counts[index] > 0
                        ? energy[index] / Double(counts[index])
                        : 0,
                    peak: peaks[index],
                    crossingRate: sampleTotals[index] > 0
                        ? Double(crossings[index])
                            / Double(sampleTotals[index])
                        : 0
                )
            }

            let maximumPeak = peaks.max() ?? 0
            let maximumRMS = metrics.map(\.rms).max() ?? 0
            if maximumPeak < 0.0032, maximumRMS < 0.0016 {
                return try await analyzeVisualMotionOrFallback(
                    asset: asset,
                    duration: duration,
                    bucketCount: bucketCount,
                    audioAvailability: .silent
                )
            }

            var values = metrics.map(\.impactScore)
            let impactFrames = metrics.enumerated().map { index, metrics in
                AudioImpactFrame(
                    time: (Double(index) + 0.5) / Double(bucketCount)
                        * duration,
                    metrics: metrics
                )
            }
            let maximum = max(values.max() ?? 0, 0.000_1)
            values = values.map { max(0.04, min(1, $0 / maximum)) }

            var candidates: [(index: Int, score: Double)] = []
            var bestCandidate = (
                index: bucketCount / 2,
                score: -Double.infinity
            )
            for index in 1..<bucketCount {
                let historyStart = max(0, index - 5)
                let history = values[historyStart..<index]
                let baseline = history.reduce(0, +)
                    / Double(max(1, history.count))
                let rise = values[index] - baseline
                let score = rise + values[index] * 0.25
                if score > bestCandidate.score {
                    bestCandidate = (index, score)
                }
                let previous = values[index - 1]
                let next = index + 1 < bucketCount ? values[index + 1] : 0
                if rise > 0.04 {
                    candidates.append((index, score))
                }
                if values[index] >= previous, values[index] >= next {
                    candidates.append((index, score))
                }
            }

            if !candidates.contains(
                where: { $0.index == bestCandidate.index }
            ) {
                candidates.append(bestCandidate)
            }

            for candidate in strongestEnergyCandidates(values: values) {
                candidates.append(candidate)
            }
            // Android와 같은 후보 풀: 분류기 후보와 피크를 12개에서 자르지 않는다(Android 분석은 이 상한이 실제로 적용되지 않아
            // 긴 영상의 조용한 퍼팅·1인칭 샷이 후보에 남는다). 추천 선택이 소스당 한도·병합으로 장면 수를 정한다.
            let classifiedImpacts = AudioImpactClassifier.rankedImpacts(
                frames: impactFrames,
                duration: duration,
                limit: Int.max
            )
            for peak in classifiedImpacts.map(\.time) {
                let index = min(
                    bucketCount - 1,
                    max(0, Int(peak / duration * Double(bucketCount)))
                )
                candidates.append((index, 2.0 + values[index]))
            }

            let bucketsPerSecond = Double(bucketCount) / max(duration, 0.1)
            let minimumSeparation = max(1, Int((bucketsPerSecond * 0.45).rounded()))
            var selected: [(index: Int, score: Double)] = []
            for candidate in candidates.sorted(by: { $0.score > $1.score }) {
                guard selected.allSatisfy({
                    abs($0.index - candidate.index) >= minimumSeparation
                }) else { continue }
                selected.append(candidate)
            }

            if selected.isEmpty {
                selected.append(bestCandidate)
            }

            let selectedTimes = selected.map {
                (Double($0.index) + 0.5) / Double(bucketCount) * duration
            }
            let verifiedTimes = selectedTimes.filter { time in
                classifiedImpacts.contains {
                    $0.isTriggered && abs($0.time - time) <= 0.5 / bucketsPerSecond + 0.25
                }
            }
            return AudioAnalysisResult(
                waveform: values,
                peakTime: selectedTimes[0],
                peakTimes: selectedTimes,
                audioAvailability: .present,
                highlightSource: .audio,
                verifiedPeakTimes: verifiedTimes,
                transientTimes: isolatedTransientTimes(impactFrames)
            )
        }.value
    }

    /// 프레임(버킷)의 peak가 들을 수 있고(>= 0.04), 앞 8프레임 peak 중앙값의 6배 이상이며, 2~3프레임 뒤에는 35% 이하로 사라지는 시각.
    /// 바람·손잡이 소음·말소리 같은 지속음은 그렇게 빨리 줄지 않으므로 제외된다.
    static func isolatedTransientTimes(_ frames: [AudioImpactFrame]) -> [Double] {
        frames.indices.compactMap { index -> Double? in
            let peak = frames[index].metrics.peak
            let history = frames[max(0, index - 8)..<index].map(\.metrics.peak).sorted()
            let median = history.isEmpty ? 0 : history[history.count / 2]
            let after = (index + 2...index + 3).filter { $0 < frames.count }.map { frames[$0].metrics.peak }
            guard peak >= 0.04, peak >= 6 * max(median, 0.004), let loudest = after.max(), loudest <= 0.35 * peak else { return nil }
            return frames[index].time
        }
    }

    private static func strongestEnergyCandidates(
        values: [Double]
    ) -> [(index: Int, score: Double)] {
        values.enumerated().map { index, value in
            (index: index, score: value * 0.55)
        }
    }

    private static func analyzeVisualMotionOrFallback(
        asset: AVAsset,
        duration: Double,
        bucketCount: Int,
        audioAvailability: ClipAudioAvailability
    ) async throws -> AudioAnalysisResult {
        do {
            return try await VisualMotionAnalysisService.analyze(
                asset: asset,
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let center = max(0, duration / 2)
            return AudioAnalysisResult(
                waveform: Array(repeating: 0, count: bucketCount),
                peakTime: center,
                peakTimes: [center],
                audioAvailability: audioAvailability,
                highlightSource: .fallback
            )
        }
    }

    /// 음악 파일의 PCM 오디오 신호에서 에너지 변화량(Onset)을 감지하여 비트 타임스탬프 후보(초 단위)를 추출한다.
    /// AVAssetReader 스트리밍을 통해 메모리를 제한(bounded memory)하고 메인 스레드 밖에서 비동기로 수행된다.
    static func extractBeatOnsets(url: URL, maxDuration: Double = 3600.0) async throws -> [Double] {
        guard maxDuration.isFinite, maxDuration > 0 else { return [] }
        let boundedMaxDuration = min(maxDuration, 7200.0)
        let task = Task.detached(priority: .userInitiated) { () -> [Double] in
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0.5 else { return [] }
            let analyzeDuration = min(duration, boundedMaxDuration)

            guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return []
            }

            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { return [] }
            reader.add(output)
            guard reader.startReading() else { return [] }

            // 5ms 구간별 RMS. 시각은 샘플 버퍼의 PTS가 아니라 지금까지 디코드된 PCM 프레임 수 / 샘플레이트로 계산한다.
            // AVAssetReader는 MP3/AAC의 인코더 지연·패딩을 직접 잘라 내므로 누적 프레임 0이 곧 재생 시작이다.
            let binSeconds = 0.005
            let totalBins = max(1, Int(analyzeDuration / binSeconds) + 1)
            var squareSums = [Double](repeating: 0, count: totalBins)
            var sampleCounts = [Int](repeating: 0, count: totalBins)
            var decodedFrames = 0

            while let sample = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: nil,
                    totalLengthOut: &length,
                    dataPointerOut: &pointer
                ) == kCMBlockBufferNoErr,
                      let pointer,
                      length >= MemoryLayout<Int16>.size
                else { continue }

                let format = CMSampleBufferGetFormatDescription(sample)
                    .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = max(1, Int(format?.mChannelsPerFrame ?? 2))
                let rate = (format?.mSampleRate ?? 0) > 0 ? format!.mSampleRate : 44100.0
                let framesPerBin = rate * binSeconds
                let frames = length / MemoryLayout<Int16>.size / channels
                let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
                for frame in 0..<frames {
                    let bin = Int(Double(decodedFrames + frame) / framesPerBin)
                    if bin >= totalBins { break }
                    var sum = 0.0
                    for channel in 0..<channels {
                        let v = Double(values[frame * channels + channel]) / Double(Int16.max)
                        sum += v * v
                    }
                    squareSums[bin] += sum
                    sampleCounts[bin] += channels
                }
                decodedFrames += frames
            }

            if reader.status == .failed || reader.status == .cancelled {
                return []
            }

            let energyCurve = (0..<totalBins).map { sampleCounts[$0] > 0 ? (squareSums[$0] / Double(sampleCounts[$0])).squareRoot() : 0.0 }
            return pickPercussiveBeats(energyCurve, binSeconds: binSeconds)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// 5ms RMS 곡선에서 타악기처럼 갑자기 커지는 지점을 비트로 고른다. 온셋 세기는 직전 40ms 평균 대비 이후 20ms 평균의 증가량이고,
    /// 근처 1초 평균의 1.5배 이상(지역 임계값)이면서 전체 상위 1% 세기의 20% 이상(전역 하한)인 극대점만 세기 순으로 0.15초 간격을 두고 남긴다.
    private static func pickPercussiveBeats(_ energy: [Double], binSeconds: Double) -> [Double] {
        guard (energy.max() ?? 0) > 0.005 else { return [] }
        let size = energy.count
        var prefix = [Double](repeating: 0, count: size + 1)
        for i in 0..<size { prefix[i + 1] = prefix[i] + energy[i] }
        func mean(_ from: Int, _ to: Int) -> Double {
            let a = max(0, from), b = min(size, to)
            return b > a ? (prefix[b] - prefix[a]) / Double(b - a) : 0
        }
        var strength = [Double](repeating: 0, count: size)
        if size > 1 { for i in 1..<size { strength[i] = max(0, mean(i, i + 4) - mean(i - 8, i)) } }
        let floorValue = strength.sorted()[min(size - 1, Int(Double(size) * 0.99))] * 0.20
        guard floorValue > 0, size > 2 else { return [] }

        var strengthPrefix = [Double](repeating: 0, count: size + 1)
        for i in 0..<size { strengthPrefix[i + 1] = strengthPrefix[i] + strength[i] }
        let localRadius = Int(0.5 / binSeconds)
        let peakRadius = 4
        var candidates: [Int] = []
        for i in 1..<(size - 1) {
            let value = strength[i]
            if value < floorValue { continue }
            if (max(0, i - peakRadius)...min(size - 1, i + peakRadius)).contains(where: { strength[$0] > value }) { continue }
            let from = max(0, i - localRadius), to = min(size, i + localRadius + 1)
            let localAverage = (strengthPrefix[to] - strengthPrefix[from]) / Double(to - from)
            if value > localAverage * 1.5 { candidates.append(i) }
        }
        let minGap = Int(0.15 / binSeconds)
        var taken: [Int] = []
        for i in candidates.sorted(by: { strength[$0] > strength[$1] }) where !taken.contains(where: { abs($0 - i) < minGap }) {
            taken.append(i)
        }
        // 온셋이 시작된 구간의 시작 시각이 비트 시각이다(+0.5 구간이면 전환이 비트보다 늦는다).
        return taken.sorted().map { Double($0) * binSeconds }
    }
}

/// How loud a file's own sound actually is over time, used to decide when background
/// music should step back. Unlike `AudioAnalysisResult.waveform`, every value is the raw
/// RMS of the decoded PCM (0...1 of full scale) and is never scaled to the file's own
/// peak, so quiet room noise stays quiet instead of looking like sound throughout.
struct AudioActivityEnvelope: Sendable {
    let binDuration: Double
    /// One value per `binDuration` from time zero. Empty when there is no audio track.
    let rms: [Float]
}

extension AudioAnalysisService {
    static func activityEnvelope(url: URL, binDuration: Double = 0.1) async throws -> AudioActivityEnvelope {
        let work = Task.detached(priority: .userInitiated) { () async throws -> AudioActivityEnvelope in
            let silent = AudioActivityEnvelope(binDuration: binDuration, rms: [])
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0, binDuration > 0,
                  let track = try await asset.loadTracks(withMediaType: .audio).first else {
                return silent
            }
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(
                track: track,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM,
                    AVLinearPCMBitDepthKey: 16,
                    AVLinearPCMIsFloatKey: false,
                    AVLinearPCMIsBigEndianKey: false,
                    AVLinearPCMIsNonInterleaved: false
                ]
            )
            output.alwaysCopiesSampleData = false
            guard reader.canAdd(output) else { throw MediaError.videoTrackUnavailable }
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? MediaError.videoTrackUnavailable }

            let binCount = max(1, Int((duration / binDuration).rounded(.up)))
            var sums = Array(repeating: 0.0, count: binCount)
            var counts = Array(repeating: 0, count: binCount)
            while let sample = output.copyNextSampleBuffer() {
                if Task.isCancelled {
                    reader.cancelReading()
                    throw CancellationError()
                }
                guard let block = CMSampleBufferGetDataBuffer(sample),
                      let format = CMSampleBufferGetFormatDescription(sample),
                      let description = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                      description.mSampleRate > 0 else { continue }
                var length = 0
                var pointer: UnsafeMutablePointer<Int8>?
                guard CMBlockBufferGetDataPointer(
                    block,
                    atOffset: 0,
                    lengthAtOffsetOut: &length,
                    totalLengthOut: nil,
                    dataPointerOut: &pointer
                ) == kCMBlockBufferNoErr, let pointer else { continue }
                let start = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                guard start.isFinite else { continue }

                let rate = description.mSampleRate
                let channels = max(1, Int(description.mChannelsPerFrame))
                let frames = length / (MemoryLayout<Int16>.size * channels)
                let values = UnsafeRawPointer(pointer).assumingMemoryBound(to: Int16.self)
                // A decoded buffer can span more than one bin, so each run of frames
                // goes to the bin its own time falls in.
                var frame = 0
                while frame < frames {
                    let time = start + Double(frame) / rate
                    let bin = Int((time / binDuration).rounded(.down))
                    let boundary = Double(bin + 1) * binDuration
                    let end = min(frames, max(frame + 1, Int(((boundary - start) * rate).rounded(.up))))
                    if bin >= 0, bin < binCount {
                        var sum = 0.0
                        for index in (frame * channels)..<(end * channels) {
                            let value = Double(values[index]) / 32_768
                            sum += value * value
                        }
                        sums[bin] += sum
                        counts[bin] += (end - frame) * channels
                    }
                    frame = end
                }
            }
            if reader.status == .failed { throw reader.error ?? MediaError.videoTrackUnavailable }
            return AudioActivityEnvelope(
                binDuration: binDuration,
                rms: (0..<binCount).map { counts[$0] > 0 ? Float((sums[$0] / Double(counts[$0])).squareRoot()) : 0 }
            )
        }
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }
}

private enum VisualMotionAnalysisService {
    private struct FrameSummary {
        let time: Double
        let cells: [Double]
        let averageBrightness: Double
    }

    private struct MotionSample {
        let time: Double
        let score: Double
    }

    static func analyze(
        asset: AVAsset,
        duration: Double,
        bucketCount: Int,
        audioAvailability: ClipAudioAvailability
    ) async throws -> AudioAnalysisResult {
        guard let track = try await asset.loadTracks(
            withMediaType: .video
        ).first else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String:
                    kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 160,
                kCVPixelBufferHeightKey as String: 90,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }

        let maximumSamples = 1_200.0
        let sampleInterval = max(0.2, duration / maximumSamples)
        var nextSampleTime = 0.0
        var previousFrame: FrameSummary?
        var motionBaseline = 0.008
        var samples: [MotionSample] = []
        samples.reserveCapacity(
            min(Int(ceil(duration / sampleInterval)), Int(maximumSamples))
        )

        do {
            while let sampleBuffer = output.copyNextSampleBuffer() {
                try Task.checkCancellation()
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    .seconds
                guard time.isFinite, time + 0.000_1 >= nextSampleTime else {
                    continue
                }
                while nextSampleTime <= time {
                    nextSampleTime += sampleInterval
                }

                guard let frame = frameSummary(
                    from: sampleBuffer,
                    time: time
                ) else { continue }
                defer { previousFrame = frame }
                guard let previousFrame,
                      previousFrame.cells.count == frame.cells.count
                else { continue }

                let differences = zip(frame.cells, previousFrame.cells).map {
                    abs($0 - $1)
                }
                let meanDifference = differences.reduce(0, +)
                    / Double(max(1, differences.count))
                let sortedDifferences = differences.sorted()
                let medianDifference = sortedDifferences[
                    sortedDifferences.count / 2
                ]
                let residuals = differences
                    .map { max(0, $0 - medianDifference * 0.9) }
                    .sorted(by: >)
                let focusedCount = max(1, residuals.count / 4)
                let localMotion = residuals.prefix(focusedCount).reduce(0, +)
                    / Double(focusedCount)
                let widespreadRatio = Double(
                    differences.filter { $0 > 0.12 }.count
                ) / Double(max(1, differences.count))
                let brightnessChange = abs(
                    frame.averageBrightness
                        - previousFrame.averageBrightness
                )
                let isSceneBoundary = widespreadRatio > 0.72
                    && meanDifference > 0.14
                let isFlash = brightnessChange > 0.22
                    && widespreadRatio > 0.55

                let cappedBaselineSample = min(
                    localMotion,
                    max(0.006, motionBaseline * 1.5)
                )
                motionBaseline = motionBaseline * 0.94
                    + cappedBaselineSample * 0.06
                let contrast = localMotion / max(0.004, motionBaseline)
                let score: Double
                if isSceneBoundary || isFlash || localMotion < 0.0035 {
                    score = 0
                } else {
                    score = min(
                        1,
                        max(0, contrast - 1) * 0.28
                            + min(1, localMotion * 8) * 0.72
                    )
                }
                samples.append(MotionSample(time: time, score: score))
            }
        } catch {
            reader.cancelReading()
            throw error
        }

        if reader.status == .failed {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }
        guard samples.count >= 3 else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }

        let edgeDuration = min(
            max(0.5, duration * 0.05),
            max(0.5, duration / 3)
        )
        var smoothed = samples.indices.map { index -> Double in
            let previous = index > 0 ? samples[index - 1].score : 0
            let current = samples[index].score
            let next = index + 1 < samples.count
                ? samples[index + 1].score
                : 0
            let value = previous * 0.22 + current * 0.56 + next * 0.22
            let time = samples[index].time
            guard time >= edgeDuration,
                  time <= duration - edgeDuration
            else { return 0 }
            return value
        }

        let maximumScore = smoothed.max() ?? 0
        guard maximumScore >= 0.12 else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }
        smoothed = smoothed.map { min(1, max(0, $0 / maximumScore)) }

        var candidates: [(index: Int, score: Double)] = []
        for index in smoothed.indices {
            let previous = index > 0 ? smoothed[index - 1] : 0
            let next = index + 1 < smoothed.count
                ? smoothed[index + 1]
                : 0
            guard smoothed[index] >= 0.28,
                  smoothed[index] >= previous,
                  smoothed[index] >= next
            else { continue }
            candidates.append((index, smoothed[index]))
        }

        let minimumSeparation = max(0.75, duration / 20)
        var selected: [(index: Int, score: Double)] = []
        for candidate in candidates.sorted(by: {
            if abs($0.score - $1.score) < 0.000_1 {
                return samples[$0.index].time < samples[$1.index].time
            }
            return $0.score > $1.score
        }) {
            guard selected.allSatisfy({
                abs(
                    samples[$0.index].time
                        - samples[candidate.index].time
                ) >= minimumSeparation
            }) else { continue }
            selected.append(candidate)
            if selected.count >= 12 { break }
        }

        guard let strongest = selected.first else {
            return fallbackResult(
                duration: duration,
                bucketCount: bucketCount,
                audioAvailability: audioAvailability
            )
        }

        var waveform = Array(repeating: 0.0, count: bucketCount)
        for (index, sample) in samples.enumerated() {
            let bucket = min(
                bucketCount - 1,
                max(0, Int(sample.time / duration * Double(bucketCount)))
            )
            waveform[bucket] = max(waveform[bucket], smoothed[index])
        }

        return AudioAnalysisResult(
            waveform: waveform,
            peakTime: samples[strongest.index].time,
            peakTimes: selected.map { samples[$0.index].time },
            audioAvailability: audioAvailability,
            highlightSource: .visualMotion
        )
    }

    private static func frameSummary(
        from sampleBuffer: CMSampleBuffer,
        time: Double
    ) -> FrameSummary? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard CVPixelBufferGetPixelFormatType(pixelBuffer)
            == kCVPixelFormatType_32BGRA,
              let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        else { return nil }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        let gridWidth = 8
        let gridHeight = 8
        let bytes = baseAddress.assumingMemoryBound(to: UInt8.self)
        var cells: [Double] = []
        cells.reserveCapacity(gridWidth * gridHeight)
        var brightnessTotal = 0.0

        for yCell in 0..<gridHeight {
            for xCell in 0..<gridWidth {
                var cellBrightness = 0.0
                for yQuarter in [1, 3] {
                    let y = min(
                        height - 1,
                        (yCell * height + yQuarter * height / 4)
                            / gridHeight
                    )
                    for xQuarter in [1, 3] {
                        let x = min(
                            width - 1,
                            (xCell * width + xQuarter * width / 4)
                                / gridWidth
                        )
                        let offset = y * bytesPerRow + x * 4
                        let blue = Double(bytes[offset])
                        let green = Double(bytes[offset + 1])
                        let red = Double(bytes[offset + 2])
                        cellBrightness += (
                            red * 0.299
                                + green * 0.587
                                + blue * 0.114
                        ) / 255
                    }
                }
                let average = cellBrightness / 4
                cells.append(average)
                brightnessTotal += average
            }
        }

        return FrameSummary(
            time: time,
            cells: cells,
            averageBrightness: brightnessTotal
                / Double(max(1, cells.count))
        )
    }

    private static func fallbackResult(
        duration: Double,
        bucketCount: Int,
        audioAvailability: ClipAudioAvailability
    ) -> AudioAnalysisResult {
        let center = max(0, duration / 2)
        return AudioAnalysisResult(
            waveform: Array(repeating: 0, count: bucketCount),
            peakTime: center,
            peakTimes: [center],
            audioAvailability: audioAvailability,
            highlightSource: .fallback
        )
    }
}
