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

    init(
        waveform: [Double],
        peakTime: Double,
        peakTimes: [Double]? = nil,
        audioAvailability: ClipAudioAvailability = .present,
        highlightSource: ClipHighlightSource = .audio
    ) {
        self.waveform = waveform
        self.peakTime = peakTime
        self.peakTimes = peakTimes ?? [peakTime]
        self.audioAvailability = audioAvailability
        self.highlightSource = highlightSource
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
            let classifiedPeaks = AudioImpactClassifier.rankedImpactTimes(
                frames: impactFrames,
                duration: duration,
                limit: 12
            )
            for peak in classifiedPeaks {
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
                if selected.count >= 12 {
                    break
                }
            }

            if selected.isEmpty {
                selected.append(bestCandidate)
            }

            return AudioAnalysisResult(
                waveform: values,
                peakTime: (Double(selected[0].index) + 0.5)
                    / Double(bucketCount) * duration,
                peakTimes: selected.map {
                    (Double($0.index) + 0.5) / Double(bucketCount) * duration
                },
                audioAvailability: .present,
                highlightSource: .audio
            )
        }.value
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
