import AVFoundation
import Foundation
import ImageIO
import OSLog
import Photos
import UniformTypeIdentifiers
import Vision

/// 편집할 때만 Live Photo의 대표사진·paired video·좋은 한 프레임 중 하나를 고른다.
/// 사진/영상 보관함과 원본 복사 동작에는 관여하지 않으며 분석과 판단은 기기 안에서 끝난다.
enum LivePhotoEditingSelection {
    enum Kind: String, Sendable { case originalPhoto, video, frame }
    struct Decision: Sendable {
        let kind: Kind
        let url: URL
        let duration: Double?
        let ownedURLs: [URL]
        let reason: String
    }
    private struct Sample {
        let time: Double
        let quality: VideoTrailerPhotoQuality.Measurement
        var technicalScore: Double { quality.sharpnessScore * 0.65 + quality.exposureScore * 0.35 }
    }
    private static let logger = Logger(subsystem: "com.armsone.nasfinder", category: "LivePhotoEditingSelection")

    static func choose(asset: PHAsset, originalPhotoURL: URL) async throws -> Decision {
        let original = Decision(kind: .originalPhoto, url: originalPhotoURL, duration: nil, ownedURLs: [], reason: "representative_fallback")
        guard asset.mediaSubtypes.contains(.photoLive) else { return original }
        try Task.checkCancellation()
        var transientURLs: [URL] = []
        var retainedURLs: Set<URL> = []
        defer {
            for url in transientURLs where !retainedURLs.contains(url) { try? FileManager.default.removeItem(at: url) }
        }
        do {
            guard let still = await VideoTrailerPhotoQuality.measure(fileAt: originalPhotoURL, maxPixelSize: 256, includeAesthetics: false) else { return original }
            try Task.checkCancellation()
            let videoURL = try await LocalPhotoLibraryCalendarService.exportPairedVideo(for: asset)
            transientURLs.append(videoURL)
            let video = AVURLAsset(url: videoURL)
            let duration = try await video.load(.duration).seconds
            guard duration.isFinite, duration > 0,
                  let track = try await video.loadTracks(withMediaType: .video).first else { return original }
            let naturalSize = try await track.load(.naturalSize)
            let videoPixels = abs(Double(naturalSize.width * naturalSize.height))
            let stillPixels = Double(pixelCount(at: originalPhotoURL))
            let resolutionRatio = stillPixels > 0 ? videoPixels / stillPixels : 0
            let generator = AVAssetImageGenerator(asset: video)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 256, height: 256)
            generator.requestedTimeToleranceBefore = CMTime(seconds: 0.04, preferredTimescale: 600)
            generator.requestedTimeToleranceAfter = CMTime(seconds: 0.04, preferredTimescale: 600)
            var samples: [Sample] = []
            for position in [0.1, 0.3, 0.5, 0.7, 0.9] {
                try Task.checkCancellation()
                let time = duration * position
                do {
                    let image = try generator.copyCGImage(at: CMTime(seconds: time, preferredTimescale: 600), actualTime: nil)
                    let temporary = temporaryURL(extension: "jpg")
                    transientURLs.append(temporary)
                    try writeJPEG(image, to: temporary)
                    if let quality = await VideoTrailerPhotoQuality.measure(fileAt: temporary, maxPixelSize: 256, includeAesthetics: false) {
                        samples.append(Sample(time: time, quality: quality))
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { continue }
            }
            try Task.checkCancellation()
            guard samples.count >= 4, let best = samples.max(by: { $0.technicalScore < $1.technicalScore }) else { return original }
            let stillScore = still.sharpnessScore * 0.65 + still.exposureScore * 0.35
            let average = samples.map(\.technicalScore).reduce(0, +) / Double(samples.count)
            let gain = best.technicalScore - stillScore
            let qualityRange = (samples.map(\.technicalScore).max() ?? 0) - (samples.map(\.technicalScore).min() ?? 0)
            let meanExposure = samples.map { $0.quality.exposureScore }.reduce(0, +) / Double(samples.count)
            let meanSharpness = samples.map { $0.quality.sharpnessScore }.reduce(0, +) / Double(samples.count)
            let nearStillCount = samples.filter { $0.technicalScore >= stillScore - 0.10 }.count
            let motion = motionMetrics(samples.map { $0.quality.fingerprint })
            let usefulMotion = motion.residual >= 0.008 && motion.residual <= 0.10
                && motion.raw <= 0.16 && motion.maximumRaw <= 0.25
                && motion.residual / max(motion.raw, 0.0001) >= 0.25
            let videoUsable = duration >= 0.8 && duration <= 8 && resolutionRatio >= 0.20
                && nearStillCount >= 4 && average >= stillScore - 0.035
                && meanExposure >= 0.35 && meanSharpness >= max(0.008, still.sharpnessScore * 0.60)
                && usefulMotion
            var frameUsable = gain >= 0.08 && resolutionRatio >= 0.20
                && best.quality.exposureScore >= 0.35
                && best.quality.sharpnessScore >= max(0.005, still.sharpnessScore * 0.80)
            let consistentlyBetterVideo = videoUsable && average - stillScore >= 0.02 && qualityRange < 0.06
            if frameUsable && !consistentlyBetterVideo {
                // Export the chosen frame at the video's real resolution, never the 256px analysis copy.
                generator.maximumSize = .zero
                try Task.checkCancellation()
                let image = try generator.copyCGImage(at: CMTime(seconds: best.time, preferredTimescale: 600), actualTime: nil)
                let frameURL = temporaryURL(extension: "jpg")
                transientURLs.append(frameURL)
                try writeJPEG(image, to: frameURL)
                let originalFace = faceQuality(at: originalPhotoURL)
                let frameFace = faceQuality(at: frameURL)
                // A clear face in the original must not be lost to an apparently sharper background.
                if let originalFace, originalFace > 0.25,
                   frameFace == nil || (frameFace ?? 0) < originalFace - 0.15 { frameUsable = false }
                if frameUsable {
                    retainedURLs.insert(frameURL)
                    log(kind: .frame, reason: "peak_frame", still: stillScore, average: average, gain: gain,
                        motion: motion, resolution: resolutionRatio)
                    return Decision(kind: .frame, url: frameURL, duration: nil, ownedURLs: [frameURL], reason: "peak_frame")
                }
            }
            if videoUsable {
                retainedURLs.insert(videoURL)
                let reason = consistentlyBetterVideo ? "consistent_motion" : "usable_motion"
                log(kind: .video, reason: reason, still: stillScore, average: average, gain: gain,
                    motion: motion, resolution: resolutionRatio)
                return Decision(kind: .video, url: videoURL, duration: duration, ownedURLs: [videoURL], reason: reason)
            }
            log(kind: .originalPhoto, reason: original.reason, still: stillScore, average: average, gain: gain,
                motion: motion, resolution: resolutionRatio)
            return original
        } catch is CancellationError { throw CancellationError() }
        catch {
            logger.info("kind=originalPhoto reason=representative_fallback cause=analysis_unavailable")
            return original
        }
    }

    private struct Motion { let raw: Double; let residual: Double; let maximumRaw: Double }
    private static func motionMetrics(_ fingerprints: [[UInt8]]) -> Motion {
        var raw: [Double] = [], residual: [Double] = []
        for index in 1..<fingerprints.count {
            let lhs = fingerprints[index - 1], rhs = fingerprints[index]
            guard lhs.count == 256, rhs.count == 256 else { continue }
            func distance(dx: Int, dy: Int) -> Double {
                var total = 0.0, count = 0.0
                for y in 0..<16 { for x in 0..<16 {
                    let tx = x + dx, ty = y + dy
                    guard tx >= 0, tx < 16, ty >= 0, ty < 16 else { continue }
                    total += abs(Double(lhs[y * 16 + x]) - Double(rhs[ty * 16 + tx])) / 255
                    count += 1
                } }
                return total / max(1, count)
            }
            raw.append(distance(dx: 0, dy: 0))
            residual.append((-1...1).flatMap { dy in (-1...1).map { dx in distance(dx: dx, dy: dy) } }.min() ?? 0)
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        }
        return Motion(raw: median(raw), residual: median(residual), maximumRaw: raw.max() ?? 0)
    }

    private static func temporaryURL(extension ext: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("nasfinder-live-edit-\(UUID().uuidString)").appendingPathExtension(ext)
    }
    private static func writeJPEG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw LocalPhotoLibraryError.fileUnavailable
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw LocalPhotoLibraryError.fileUnavailable }
    }
    private static func pixelCount(at url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return width * height
    }
    private static func faceQuality(at url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 256
              ] as CFDictionary) else { return nil }
        do {
            let request = VNDetectFaceCaptureQualityRequest()
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            let qualities = (request.results ?? []).compactMap { $0.faceCaptureQuality.map { Double($0) } }
            return qualities.isEmpty ? nil : qualities.reduce(0, +) / Double(qualities.count)
        } catch { return nil }
    }
    private static func log(kind: Kind, reason: String, still: Double, average: Double, gain: Double, motion: Motion, resolution: Double) {
        logger.info("kind=\(kind.rawValue, privacy: .public) reason=\(reason, privacy: .public) still=\(still) videoMean=\(average) peakGain=\(gain) motionRaw=\(motion.raw) motionResidual=\(motion.residual) resolutionRatio=\(resolution)")
    }
}
