import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Frame timing and memory rules for animated images shown in the media
/// viewer. The viewer's `UIImageView` plays a `UIImage.animatedImage`, which
/// shows every frame for the same duration, so variable GIF delays are
/// expanded into repeated frame indices over a common time slice.
enum AnimatedImagePlaybackPolicy {
    /// GIF delays of 10 ms or less are shown at 100 ms, matching browsers.
    static let minimumMeaningfulDelay = 0.011
    static let fallbackFrameDelay = 0.1
    static let maximumFrameCount = 600
    static let maximumExpandedFrameCount = 1_500
    /// Decoded frames stay within this many bytes (RGBA) in total.
    static let maximumDecodedByteCount = 256 * 1_024 * 1_024
    static let minimumPixelSize = 256

    struct Timeline: Equatable {
        /// Source frame index for each uniform playback slot.
        let frameIndices: [Int]
        let totalDuration: TimeInterval
    }

    static func normalizedDelay(_ rawDelay: Double?) -> Double {
        guard let rawDelay, rawDelay.isFinite, rawDelay >= minimumMeaningfulDelay else {
            return fallbackFrameDelay
        }
        return rawDelay
    }

    static func maximumPixelSize(frameCount: Int, preferred: Int) -> Int {
        let frames = max(frameCount, 1)
        let pixelsPerFrame = Double(maximumDecodedByteCount) / (4 * Double(frames))
        let side = Int(pixelsPerFrame.squareRoot().rounded(.down))
        return min(max(side, minimumPixelSize), preferred)
    }

    static func timeline(frameDelays: [Double]) -> Timeline {
        let milliseconds = frameDelays.map { max(Int(($0 * 1_000).rounded()), 1) }
        let total = Double(milliseconds.reduce(0, +)) / 1_000
        guard !milliseconds.isEmpty else {
            return Timeline(frameIndices: [], totalDuration: 0)
        }
        let slice = milliseconds.reduce(0, greatestCommonDivisor)
        let expandedCount = milliseconds.reduce(0) { $0 + $1 / slice }
        guard expandedCount <= maximumExpandedFrameCount else {
            // Too irregular to expand exactly: fall back to one slot per
            // frame at the average delay so playback still completes.
            return Timeline(
                frameIndices: Array(milliseconds.indices),
                totalDuration: total
            )
        }
        var indices: [Int] = []
        indices.reserveCapacity(expandedCount)
        for (index, duration) in milliseconds.enumerated() {
            indices.append(contentsOf: repeatElement(index, count: duration / slice))
        }
        return Timeline(frameIndices: indices, totalDuration: total)
    }

    private static func greatestCommonDivisor(_ a: Int, _ b: Int) -> Int {
        var (x, y) = (a, b)
        while y != 0 {
            (x, y) = (y, x % y)
        }
        return x
    }
}

struct AnimatedImageFrames: @unchecked Sendable {
    let frames: [CGImage]
    let timeline: AnimatedImagePlaybackPolicy.Timeline

    /// A `UIImage` whose `images` play the timeline in a `UIImageView`.
    func makeUIImage() -> UIImage? {
        let images = timeline.frameIndices.compactMap { index -> UIImage? in
            guard frames.indices.contains(index) else { return nil }
            return UIImage(cgImage: frames[index])
        }
        guard images.count == timeline.frameIndices.count, !images.isEmpty else {
            return nil
        }
        return UIImage.animatedImage(with: images, duration: timeline.totalDuration)
    }
}

enum AnimatedImageDecoder {
    /// Decodes an animated GIF into bounded frames. Returns nil for still
    /// images and non-GIF files so callers keep their existing still path.
    static func decodeGIF(
        fileURL: URL,
        maximumPixelSize preferredMaximumPixelSize: Int
    ) async throws -> AnimatedImageFrames? {
        let decodeTask = Task.detached(priority: .userInitiated) { () throws -> AnimatedImageFrames? in
            try Task.checkCancellation()
            return try autoreleasepool {
                try decodeGIFSynchronously(
                    fileURL: fileURL,
                    maximumPixelSize: preferredMaximumPixelSize
                )
            }
        }
        return try await withTaskCancellationHandler {
            try await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }

    private static func decodeGIFSynchronously(
        fileURL: URL,
        maximumPixelSize preferredMaximumPixelSize: Int
    ) throws -> AnimatedImageFrames? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, sourceOptions),
              let typeIdentifier = CGImageSourceGetType(source) as String?,
              UTType(typeIdentifier)?.conforms(to: .gif) == true else {
            return nil
        }
        let sourceFrameCount = CGImageSourceGetCount(source)
        guard sourceFrameCount > 1 else { return nil }
        let frameCount = min(sourceFrameCount, AnimatedImagePlaybackPolicy.maximumFrameCount)
        let maximumPixelSize = AnimatedImagePlaybackPolicy.maximumPixelSize(
            frameCount: frameCount,
            preferred: preferredMaximumPixelSize
        )
        let frameOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
        ] as CFDictionary

        var frames: [CGImage] = []
        var delays: [Double] = []
        frames.reserveCapacity(frameCount)
        delays.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            try Task.checkCancellation()
            guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, frameOptions) else {
                continue
            }
            frames.append(frame)
            delays.append(AnimatedImagePlaybackPolicy.normalizedDelay(frameDelay(source, index: index)))
        }
        guard frames.count > 1 else { return nil }
        return AnimatedImageFrames(
            frames: frames,
            timeline: AnimatedImagePlaybackPolicy.timeline(frameDelays: delays)
        )
    }

    private static func frameDelay(_ source: CGImageSource, index: Int) -> Double? {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any] else {
            return nil
        }
        if let unclamped = gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double, unclamped > 0 {
            return unclamped
        }
        return gif[kCGImagePropertyGIFDelayTime] as? Double
    }
}
