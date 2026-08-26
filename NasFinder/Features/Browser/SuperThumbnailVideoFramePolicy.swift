import Foundation

/// Shared frame-selection contract for every Super Thumbnail video producer
/// on iPhone, iPad and the Mac helper. The Mac helper carries a byte-identical
/// copy in `VideoFramePolicy.swift` because it is a separate package.
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
