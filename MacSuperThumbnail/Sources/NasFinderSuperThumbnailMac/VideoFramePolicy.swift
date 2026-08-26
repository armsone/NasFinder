import CoreGraphics
import Foundation

/// Shared frame-selection contract for every Super Thumbnail video producer.
/// This is a byte-identical copy of the iOS
/// `SuperThumbnailVideoFramePolicy` because the Mac helper is a separate
/// package.
///
/// - The primary frame is captured at exactly `duration * 3/13`.
/// - Only when the primary frame is at least 50% black is a single retry
///   captured at exactly `duration * 6/13`.
/// - The retry replaces the primary only when it is below 50% black. A black
///   retry or a failed retry keeps the primary frame.
enum SuperThumbnailVideoFramePolicy {
    /// Exact rational positions so integer-timescale producers
    /// (`CMTimeMultiplyByRatio`) and fractional producers (VLC `position`)
    /// agree on the same instant.
    static let primaryRatio = (multiplier: 3, divisor: 13)
    static let retryRatio = (multiplier: 6, divisor: 13)

    static var primaryFraction: Double {
        Double(primaryRatio.multiplier) / Double(primaryRatio.divisor)
    }

    static var retryFraction: Double {
        Double(retryRatio.multiplier) / Double(retryRatio.divisor)
    }

    /// VLC seeks by a `Float` position in `0...1`.
    static var primaryPosition: Float { Float(primaryFraction) }
    static var retryPosition: Float { Float(retryFraction) }

    static func captureSeconds(
        durationSeconds: Double,
        ratio: (multiplier: Int, divisor: Int)
    ) -> Double {
        guard durationSeconds.isFinite, durationSeconds > 0 else { return 0 }
        return durationSeconds * Double(ratio.multiplier) / Double(ratio.divisor)
    }

    enum Selection: Equatable {
        case primary
        case retry
    }

    /// `retryIsBlack == nil` means no retry frame exists (not attempted
    /// because the primary was usable, or the retry extraction failed).
    static func selectedFrame(primaryIsBlack: Bool, retryIsBlack: Bool?) -> Selection {
        guard primaryIsBlack, let retryIsBlack, !retryIsBlack else { return .primary }
        return .retry
    }

    static func shouldCaptureRetry(primaryIsBlack: Bool) -> Bool {
        primaryIsBlack
    }
}

/// Black-frame definition shared with the iOS `RemoteVideoThumbnailQuality`:
/// the frame is downsampled to a 32x32 grayscale grid, a sample is black when
/// its value is at most 0.05, and the frame is black when black samples cover
/// at least 50% of the full sampled image (inclusive).
enum VideoFrameBlackPolicy {
    static let blackPixelMaximumLuminance = 0.05
    static let blackCoverageThreshold = 0.5
    static let sampleSide = 32

    static func isBlack(blackPixelCount: Int, sampleCount: Int) -> Bool {
        guard sampleCount > 0 else { return false }
        return Double(blackPixelCount) / Double(sampleCount) >= blackCoverageThreshold
    }

    static func isAtLeast50PercentBlack(_ image: CGImage) -> Bool {
        let values = grayscaleSamples(from: image)
        guard !values.isEmpty else { return false }
        let blackPixels = values.lazy.filter { $0 <= blackPixelMaximumLuminance }.count
        return isBlack(blackPixelCount: blackPixels, sampleCount: values.count)
    }

    private static func grayscaleSamples(from image: CGImage) -> [Double] {
        let width = sampleSide
        let height = sampleSide
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.map { Double($0) / 255.0 }
    }
}
