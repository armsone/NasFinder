import Foundation
import XCTest
@testable import NasFinderSuperThumbnailMac

final class PreviewSizingTests: XCTestCase {
    typealias Sizing = SuperThumbnailPreviewSizing

    func testDefaultIsLargerThanLegacyStripAndCard() {
        XCTAssertGreaterThan(Sizing.defaultHeight, 176)
        XCTAssertGreaterThan(Sizing.cardSide(forStripHeight: Sizing.defaultHeight), 112)
        XCTAssertGreaterThanOrEqual(Sizing.defaultHeight, Sizing.minimumHeight)
        XCTAssertLessThanOrEqual(Sizing.defaultHeight, Sizing.maximumHeight)
    }

    func testClampingKeepsHeightWithinBounds() {
        XCTAssertEqual(Sizing.clamped(10), Sizing.minimumHeight)
        XCTAssertEqual(Sizing.clamped(10_000), Sizing.maximumHeight)
        XCTAssertEqual(Sizing.clamped(320), 320)
        XCTAssertEqual(Sizing.clamped(.nan), Sizing.defaultHeight)
        XCTAssertEqual(Sizing.clamped(.infinity), Sizing.defaultHeight)
    }

    func testDraggingDownGrowsAndDraggingUpShrinks() {
        let base: CGFloat = 300
        XCTAssertEqual(Sizing.resized(from: base, dragTranslation: 40), 340)
        XCTAssertEqual(Sizing.resized(from: base, dragTranslation: -40), 260)
        XCTAssertEqual(Sizing.resized(from: base, dragTranslation: -1_000), Sizing.minimumHeight)
        XCTAssertEqual(Sizing.resized(from: base, dragTranslation: 1_000), Sizing.maximumHeight)
    }

    func testSteppingMovesByFixedStepAndClamps() {
        XCTAssertEqual(Sizing.stepped(300, .increment), 300 + Sizing.stepHeight)
        XCTAssertEqual(Sizing.stepped(300, .decrement), 300 - Sizing.stepHeight)
        XCTAssertEqual(Sizing.stepped(Sizing.minimumHeight, .decrement), Sizing.minimumHeight)
        XCTAssertEqual(Sizing.stepped(Sizing.maximumHeight, .increment), Sizing.maximumHeight)
    }

    func testAvailableHeightLowersTheMaximumButNeverBelowMinimum() {
        XCTAssertEqual(Sizing.maximumHeight(availableHeight: nil), Sizing.maximumHeight)
        XCTAssertEqual(Sizing.maximumHeight(availableHeight: 0), Sizing.maximumHeight)
        XCTAssertEqual(Sizing.maximumHeight(availableHeight: 2_000), Sizing.maximumHeight)

        let short: CGFloat = 448
        let fitted = Sizing.maximumHeight(availableHeight: short)
        XCTAssertEqual(fitted, short - Sizing.reservedHeightAroundPreview)
        XCTAssertEqual(Sizing.clamped(Sizing.maximumHeight, availableHeight: short), fitted)
        XCTAssertEqual(Sizing.resized(from: 500, dragTranslation: 200, availableHeight: short), fitted)

        XCTAssertEqual(Sizing.maximumHeight(availableHeight: 100), Sizing.minimumHeight)
    }

    func testCardSideTracksStripHeightAndKeepsLegacyMinimum() {
        XCTAssertEqual(Sizing.cardSide(forStripHeight: Sizing.minimumHeight), 112)
        XCTAssertEqual(Sizing.cardSide(forStripHeight: 50), 112)

        let heights: [CGFloat] = [176, 200, 300, 400, 560]
        let sides = heights.map(Sizing.cardSide(forStripHeight:))
        XCTAssertEqual(sides, sides.sorted())
        XCTAssertLessThan(sides.last!, Sizing.maximumHeight)
    }

    func testMaxPixelSizeIsBucketedAndCoversRetina() {
        XCTAssertEqual(Sizing.maxPixelSize(forCardSide: 112), 256)
        XCTAssertEqual(Sizing.maxPixelSize(forCardSide: 128), 256)
        XCTAssertEqual(Sizing.maxPixelSize(forCardSide: 129), 384)
        XCTAssertEqual(Sizing.maxPixelSize(forCardSide: 0), 128)
        XCTAssertGreaterThanOrEqual(Sizing.maxPixelSize(forCardSide: 496), 992)
    }

    func testHeightTextIsShortKoreanPointValue() {
        XCTAssertEqual(Sizing.heightText(300), "300포인트")
        XCTAssertEqual(Sizing.heightText(299.6), "300포인트")
    }
}
