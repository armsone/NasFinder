import CoreGraphics
import XCTest
@testable import NasFinder

final class SuperThumbnailVideoFramePolicyTests: XCTestCase {
    func testPrimaryAndRetryFractionsAreExactThirteenths() {
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryRatio.multiplier, 3)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryRatio.divisor, 13)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryRatio.multiplier, 6)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryRatio.divisor, 13)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.primaryFraction, 3.0 / 13.0, accuracy: 1e-12)
        XCTAssertEqual(SuperThumbnailVideoFramePolicy.retryFraction, 6.0 / 13.0, accuracy: 1e-12)
        // VLC producers seek by Float position.
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
                durationSeconds: -1,
                ratio: SuperThumbnailVideoFramePolicy.primaryRatio
            ),
            0
        )
    }

    func testBlackThresholdIsInclusiveAtExactlyHalf() {
        XCTAssertEqual(RemoteVideoThumbnailQuality.blackCoverageThreshold, 0.5)
        XCTAssertEqual(RemoteVideoThumbnailQuality.blackPixelMaximumLuminance, 0.05)
        XCTAssertTrue(RemoteVideoThumbnailQuality.isBlack(blackPixelCount: 512, sampleCount: 1_024))
        XCTAssertFalse(RemoteVideoThumbnailQuality.isBlack(blackPixelCount: 511, sampleCount: 1_024))
        XCTAssertTrue(RemoteVideoThumbnailQuality.isBlack(blackPixelCount: 1_024, sampleCount: 1_024))
        XCTAssertFalse(RemoteVideoThumbnailQuality.isBlack(blackPixelCount: 0, sampleCount: 0))
    }

    func testBlackDetectionCoversFullSampledImage() throws {
        // Exactly half of the columns black → black (inclusive).
        XCTAssertTrue(
            RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 16, of: 32)
            )
        )
        // One column short of half → not black.
        XCTAssertFalse(
            RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(
                try makeFrame(blackColumns: 15, of: 32)
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
