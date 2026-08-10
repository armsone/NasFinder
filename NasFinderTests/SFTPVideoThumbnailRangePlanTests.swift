import XCTest
@testable import NasFinder

final class SFTPVideoThumbnailRangePlanTests: XCTestCase {
    func testSmallVideoReadsTheCompleteFileWithoutOverlap() throws {
        let fileSize: UInt64 = 3 * 1_024 * 1_024
        let plan = try SFTPVideoThumbnailRangePlan(
            fileSize: fileSize,
            thumbnailSize: .medium
        )

        XCTAssertEqual(
            plan.segments,
            [.init(offset: 0, length: fileSize)]
        )
    }

    func testMediumVideoUsesTwoContiguousRangesToReadTheCompleteFile() throws {
        let fileSize: UInt64 = 3_500 * 1_024
        let plan = try SFTPVideoThumbnailRangePlan(
            fileSize: fileSize,
            thumbnailSize: .medium
        )

        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0].length, 3 * 1_024 * 1_024)
        XCTAssertEqual(plan.segments[1].offset, plan.segments[0].length)
        XCTAssertEqual(
            plan.segments.reduce(UInt64(0)) { $0 + $1.length },
            fileSize
        )
    }

    func testLargeVideoNeverExceedsTheHardReadLimit() throws {
        let fileSize: UInt64 = 9 * 1_024 * 1_024 * 1_024
        let plan = try SFTPVideoThumbnailRangePlan(
            fileSize: fileSize,
            thumbnailSize: .large
        )

        XCTAssertEqual(plan.segments.count, 2)
        XCTAssertEqual(plan.segments[0], .init(offset: 0, length: 6 * 1_024 * 1_024))
        XCTAssertEqual(
            plan.segments[1],
            .init(
                offset: fileSize - (2 * 1_024 * 1_024),
                length: 2 * 1_024 * 1_024
            )
        )
        XCTAssertEqual(
            plan.segments.reduce(UInt64(0)) { $0 + $1.length },
            SFTPVideoThumbnailRangePlan.maximumTotalBytes
        )
    }

    func testSmallThumbnailUsesTwoMiBAtMost() throws {
        let fileSize: UInt64 = 500 * 1_024 * 1_024
        let plan = try SFTPVideoThumbnailRangePlan(
            fileSize: fileSize,
            thumbnailSize: .small
        )

        XCTAssertEqual(
            plan.segments,
            [
                .init(offset: 0, length: 1_536 * 1_024),
                .init(
                    offset: fileSize - (512 * 1_024),
                    length: 512 * 1_024
                )
            ]
        )
        XCTAssertEqual(
            plan.segments.reduce(UInt64(0)) { $0 + $1.length },
            2 * 1_024 * 1_024
        )
    }

    func testEmptyAndUnrepresentableFilesAreRejected() {
        XCTAssertThrowsError(
            try SFTPVideoThumbnailRangePlan(fileSize: 0, thumbnailSize: .small)
        )
        XCTAssertThrowsError(
            try SFTPVideoThumbnailRangePlan(
                fileSize: UInt64(Int64.max) + 1,
                thumbnailSize: .large
            )
        )
    }
}
