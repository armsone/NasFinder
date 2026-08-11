import XCTest
@testable import NasFinder

final class SFTPAdaptiveThumbnailPlanTests: XCTestCase {
    func testFirstStageReadsOnlySmallHeadAndTailWindows() throws {
        let fileSize: UInt64 = 100 * 1_024 * 1_024
        var plan = try SFTPAdaptiveVideoThumbnailRangePlan(
            fileSize: fileSize,
            maximumTotalBytes: 4 * 1_024 * 1_024
        )

        XCTAssertEqual(
            plan.nextStage(),
            [
                .init(offset: 0, length: 256 * 1_024),
                .init(
                    offset: fileSize - 64 * 1_024,
                    length: 64 * 1_024
                ),
            ]
        )
        XCTAssertEqual(plan.plannedTotalBytes, 320 * 1_024)
    }

    func testStagesNeverOverlapAndStopAtItemBudget() throws {
        let maximumBytes: UInt64 = 4 * 1_024 * 1_024
        var plan = try SFTPAdaptiveVideoThumbnailRangePlan(
            fileSize: 200 * 1_024 * 1_024,
            maximumTotalBytes: maximumBytes
        )
        var segments: [SFTPAdaptiveVideoThumbnailRangePlan.Segment] = []
        while let stage = plan.nextStage() {
            segments.append(contentsOf: stage)
        }

        XCTAssertEqual(plan.plannedTotalBytes, maximumBytes)
        XCTAssertEqual(
            segments.reduce(UInt64(0)) { $0 + $1.length },
            maximumBytes
        )
        for (index, lhs) in segments.enumerated() {
            let lhsRange = lhs.offset..<(lhs.offset + lhs.length)
            for rhs in segments.dropFirst(index + 1) {
                let rhsRange = rhs.offset..<(rhs.offset + rhs.length)
                XCTAssertFalse(lhsRange.overlaps(rhsRange))
            }
        }
    }

    func testFiftyFirstStageSuccessesFitEighteenMegabytePayloadGoal() async throws {
        let connectionID = UUID()
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 18_000_000,
            maximumItemBytes: 4 * 1_024 * 1_024,
            minimumLeaseBytes: 1
        )
        let firstStageBytes = 320 * 1_024
        var lastItem: RemoteFileItem?

        for index in 0..<50 {
            let item = RemoteFileItem(
                connectionID: connectionID,
                path: "/videos/clip-\(index).mp4",
                name: "clip-\(index).mp4",
                kind: .file,
                size: 100 * 1_024 * 1_024,
                modifiedAt: nil,
                contentTypeIdentifier: "public.mpeg-4"
            )
            lastItem = item
            let optionalLease = await budget.lease(for: item)
            let lease = try XCTUnwrap(optionalLease)
            XCTAssertGreaterThanOrEqual(lease.maximumBytes, firstStageBytes)
            await budget.finish(lease, transferredBytes: firstStageBytes)
        }

        let item = try XCTUnwrap(lastItem)
        let transferredBytes = await budget.transferredBytes(for: item)
        XCTAssertEqual(transferredBytes, 50 * firstStageBytes)
        XCTAssertLessThanOrEqual(transferredBytes, 18_000_000)
    }

    func testByteBudgetReportsRemainingCapacity() {
        let budget = RemoteVideoStreamingByteBudget(maximumBytes: 1_000)
        let reservation = budget.reserve(upTo: 400)
        XCTAssertEqual(budget.remainingByteCount, 600)
        budget.complete(reservedBytes: reservation, receivedBytes: 250)
        XCTAssertEqual(budget.remainingByteCount, 750)
    }
}
