import CoreGraphics
import CoreMedia
import XCTest
@testable import NasFinderSuperThumbnailMac

final class VideoFramePolicyTests: XCTestCase {
    func testPrimaryAndRetryFractionsAreExactThirteenths() {
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryRatio.multiplier, 3)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryRatio.divisor, 13)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryRatio.multiplier, 6)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryRatio.divisor, 13)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryFraction, 3.0 / 13.0, accuracy: 1e-12)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryFraction, 6.0 / 13.0, accuracy: 1e-12)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryPosition, Float(3.0 / 13.0))
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryPosition, Float(6.0 / 13.0))

        XCTAssertEqual(
            SuperThumbnailVideoFramePolicy.captureSeconds(
                durationSeconds: 130,
                ratio: SuperThumbnailVideoFramePolicy.primaryRatio
            ),
            30,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            SuperThumbnailVideoFramePolicy.captureSeconds(
                durationSeconds: 130,
                ratio: SuperThumbnailVideoFramePolicy.retryRatio
            ),
            60,
            accuracy: 1e-9
        )
        XCTAssertEqual(
            SuperThumbnailVideoFramePolicy.captureSeconds(
                durationSeconds: .nan,
                ratio: SuperThumbnailVideoFramePolicy.primaryRatio
            ),
            0
        )
    }

    func testCaptureTimeIsExactRationalMultipleOfAssetDuration() {
        // 13 s at timescale 100 → 3/13 is exactly 3 s, 6/13 exactly 6 s.
        let duration = CMTime(value: 1_300, timescale: 100)
        let primary = VaultProcessor.captureTime(
            duration: duration,
            ratio: SuperThumbnailVideoFramePolicy.primaryRatio
        )
        let retry = VaultProcessor.captureTime(
            duration: duration,
            ratio: SuperThumbnailVideoFramePolicy.retryRatio
        )
        XCTAssertEqual(primary.seconds, 3, accuracy: 1e-9)
        XCTAssertEqual(retry.seconds, 6, accuracy: 1e-9)
        XCTAssertEqual(
            VaultProcessor.captureTime(
                duration: .indefinite,
                ratio: SuperThumbnailVideoFramePolicy.primaryRatio
            ),
            .zero
        )
        XCTAssertEqual(
            VaultProcessor.captureTime(
                duration: .zero,
                ratio: SuperThumbnailVideoFramePolicy.primaryRatio
            ),
            .zero
        )
    }

    func testBlackThresholdIsInclusiveAtExactlyHalf() {
        XCTAssertEqual(VideoFrameBlackPolicy.blackCoverageThreshold, 0.5)
        XCTAssertEqual(VideoFrameBlackPolicy.blackPixelMaximumLuminance, 0.05)
        XCTAssertTrue(VideoFrameBlackPolicy.isBlack(blackPixelCount: 512, sampleCount: 1_024))
        XCTAssertFalse(VideoFrameBlackPolicy.isBlack(blackPixelCount: 511, sampleCount: 1_024))
        XCTAssertTrue(VideoFrameBlackPolicy.isBlack(blackPixelCount: 1_024, sampleCount: 1_024))
        XCTAssertFalse(VideoFrameBlackPolicy.isBlack(blackPixelCount: 0, sampleCount: 0))
    }

    func testBlackDetectionCoversFullSampledImage() throws {
        // Exactly half of the columns black → black (inclusive).
        XCTAssertTrue(
            VideoFrameBlackPolicy.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 16, of: 32)
            )
        )
        // One column short of half → not black.
        XCTAssertFalse(
            VideoFrameBlackPolicy.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 15, of: 32)
            )
        )
        XCTAssertTrue(
            VideoFrameBlackPolicy.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 32, of: 32)
            )
        )
        XCTAssertFalse(
            VideoFrameBlackPolicy.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 0, of: 32)
            )
        )
    }

    func testRetrySelectionKeepsPrimaryUnlessRetryIsBelowHalfBlack() {
        typealias Policy = SuperThumbnailVideoFramePolicy
        XCTAssertFalse(Policy.shouldCaptureRetry(primaryIsBlack: false))
        XCTAssertTrue(Policy.shouldCaptureRetry(primaryIsBlack: true))

        // Primary usable → primary, regardless of any retry.
        XCTAssertEqual(Policy.selectedFrame(primaryIsBlack: false, retryIsBlack: nil), .primary)
        XCTAssertEqual(Policy.selectedFrame(primaryIsBlack: false, retryIsBlack: false), .primary)
        // Primary black and retry below 50% black → retry.
        XCTAssertEqual(Policy.selectedFrame(primaryIsBlack: true, retryIsBlack: false), .retry)
        // Primary black and retry also black → keep primary.
        XCTAssertEqual(Policy.selectedFrame(primaryIsBlack: true, retryIsBlack: true), .primary)
        // Primary black and retry extraction failed → keep primary.
        XCTAssertEqual(Policy.selectedFrame(primaryIsBlack: true, retryIsBlack: nil), .primary)
    }

    private func makeFrame(blackColumns: Int, of side: Int) throws -> CGImage {
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: blackColumns, height: side))
        return try XCTUnwrap(context.makeImage())
    }
}
