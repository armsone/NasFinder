import XCTest
@testable import NasFinder

final class RemoteVideoStreamingTaskRegistryTests: XCTestCase {
    func testEightMiBVirtualRequestUsesSmallBoundedNetworkChunks() {
        let eightMiB = Int64(8 * 1_024 * 1_024)

        XCTAssertEqual(
            RemoteVideoStreamingReadPolicy.preferredLength(
                remainingBytes: eightMiB,
                isBounded: true
            ),
            256 * 1_024
        )
        XCTAssertEqual(
            RemoteVideoStreamingReadPolicy.preferredLength(
                remainingBytes: eightMiB,
                isBounded: false
            ),
            8 * 1_024 * 1_024
        )
    }

    func testRangeCacheReusesIdenticalAndContainedRanges() throws {
        let cache = RemoteVideoStreamingRangeCache()
        let source = Data((0..<64).map(UInt8.init))
        cache.store(source, at: 1_000)

        XCTAssertEqual(cache.data(at: 1_000, maximumLength: 64), source)
        XCTAssertEqual(
            cache.data(at: 1_016, maximumLength: 12),
            source.subdata(in: 16..<28)
        )
        XCTAssertEqual(
            cache.data(at: 1_048, maximumLength: 64),
            source.subdata(in: 48..<64)
        )
        XCTAssertNil(cache.data(at: 999, maximumLength: 1))
        XCTAssertNil(cache.data(at: 1_064, maximumLength: 1))
    }

    func testContainedStoreDoesNotReplaceLargerCachedRange() {
        let cache = RemoteVideoStreamingRangeCache()
        let source = Data((0..<64).map(UInt8.init))
        cache.store(source, at: 2_000)
        cache.store(Data(repeating: 0xFF, count: 8), at: 2_016)

        XCTAssertEqual(cache.data(at: 2_016, maximumLength: 8), source.subdata(in: 16..<24))
    }

    func testFolderTrafficBudgetNeverOvercommitsConcurrentLeases() async {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 1_000,
            maximumItemBytes: 700,
            minimumLeaseBytes: 1
        )
        let connectionID = UUID()
        let firstItem = thumbnailItem(
            connectionID: connectionID,
            path: "/home/folder/first.mp4"
        )
        let secondItem = thumbnailItem(
            connectionID: connectionID,
            path: "/home/folder/second.mp4"
        )

        let firstLease = await budget.lease(for: firstItem)
        let secondLease = await budget.lease(for: secondItem)
        XCTAssertEqual(firstLease?.maximumBytes, 700)
        XCTAssertEqual(secondLease?.maximumBytes, 300)

        if let firstLease {
            await budget.finish(firstLease, transferredBytes: 400)
        }
        if let secondLease {
            await budget.finish(secondLease, transferredBytes: 250)
        }
        let transferredBytes = await budget.transferredBytes(for: firstItem)
        XCTAssertEqual(transferredBytes, 650)
    }

    func testFolderTrafficBudgetResetKeepsActiveReservationsCharged() async {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 1_000,
            maximumItemBytes: 700,
            minimumLeaseBytes: 1
        )
        let connectionID = UUID()
        let item = thumbnailItem(
            connectionID: connectionID,
            path: "/home/folder/video.mp4"
        )

        let firstLease = await budget.lease(for: item)
        XCTAssertEqual(firstLease?.maximumBytes, 700)
        if let firstLease {
            await budget.finish(firstLease, transferredBytes: 700)
        }
        let secondLease = await budget.lease(for: item)
        XCTAssertEqual(secondLease?.maximumBytes, 300)

        await budget.reset()

        let transferredBytesAfterReset = await budget.transferredBytes(for: item)
        XCTAssertEqual(transferredBytesAfterReset, 0)
        let leaseAfterReset = await budget.lease(for: item)
        XCTAssertEqual(leaseAfterReset?.maximumBytes, 700)

        if let secondLease {
            await budget.finish(secondLease, transferredBytes: 200)
        }
        if let leaseAfterReset {
            await budget.finish(leaseAfterReset, transferredBytes: 600)
        }
        let finalTransferredBytes = await budget.transferredBytes(for: item)
        XCTAssertEqual(finalTransferredBytes, 800)
    }

    func testCellularTrafficBudgetCapsTransfersAcrossFolders() async {
        let budget = RemoteVideoThumbnailTrafficBudget(
            maximumFolderBytes: 1_000,
            maximumItemBytes: 700,
            minimumLeaseBytes: 1,
            maximumTotalBytes: 900
        )
        let connectionID = UUID()
        let firstItem = thumbnailItem(
            connectionID: connectionID,
            path: "/home/first/video.mp4"
        )
        let secondItem = thumbnailItem(
            connectionID: connectionID,
            path: "/home/second/video.mp4"
        )

        let firstLease = await budget.lease(for: firstItem)
        XCTAssertEqual(firstLease?.maximumBytes, 700)
        if let firstLease {
            await budget.finish(firstLease, transferredBytes: 700)
        }

        let secondLease = await budget.lease(for: secondItem)
        XCTAssertEqual(secondLease?.maximumBytes, 200)
        if let secondLease {
            await budget.finish(secondLease, transferredBytes: 200)
        }
        let hasCapacity = await budget.hasCapacity()
        XCTAssertFalse(hasCapacity)
    }

    func testByteBudgetNeverExceedsConfiguredLimit() {
        let budget = RemoteVideoStreamingByteBudget(maximumBytes: 1_024)

        let firstReservation = budget.reserve(upTo: 800)
        let secondReservation = budget.reserve(upTo: 800)
        XCTAssertEqual(firstReservation, 800)
        XCTAssertEqual(secondReservation, 224)
        XCTAssertEqual(budget.reserve(upTo: 1), 0)
        XCTAssertEqual(budget.accountedByteCount, 1_024)

        budget.complete(reservedBytes: firstReservation, receivedBytes: 600)
        budget.complete(reservedBytes: secondReservation, receivedBytes: 224)
        XCTAssertEqual(budget.transferredByteCount, 824)
        XCTAssertEqual(budget.reserve(upTo: 500), 200)
        XCTAssertEqual(budget.accountedByteCount, 1_024)
    }

    func testCancelBeforeStartRejectsLateRangeRead() async {
        let registry = RemoteVideoStreamingTaskRegistry()
        let recorder = StreamingTaskRecorder()
        let identifier = ObjectIdentifier(NSObject())

        registry.cancelAll()
        let didStart = registry.start(for: identifier) {
            await recorder.recordStart()
        }
        await Task.yield()

        let startCount = await recorder.startCount
        XCTAssertFalse(didStart)
        XCTAssertEqual(startCount, 0)
    }

    func testCancelAfterStartReachesPublishedRangeRead() async throws {
        let registry = RemoteVideoStreamingTaskRegistry()
        let recorder = StreamingTaskRecorder()
        let identifier = ObjectIdentifier(NSObject())

        XCTAssertTrue(
            registry.start(for: identifier) {
                await recorder.recordStart()
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch is CancellationError {
                    await recorder.recordCancellation()
                } catch {
                    XCTFail("예상하지 못한 오류: \(error)")
                }
            }
        )
        try await recorder.waitUntilStarted()

        registry.cancelAll()
        try await recorder.waitUntilCancelled()

        let cancellationCount = await recorder.cancellationCount
        XCTAssertEqual(cancellationCount, 1)
    }

    private func thumbnailItem(connectionID: UUID, path: String) -> RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: .file,
            size: 1_024,
            modifiedAt: nil,
            contentTypeIdentifier: "public.mpeg-4"
        )
    }
}

private actor StreamingTaskRecorder {
    private(set) var startCount = 0
    private(set) var cancellationCount = 0

    func recordStart() {
        startCount += 1
    }

    func recordCancellation() {
        cancellationCount += 1
    }

    func waitUntilStarted() async throws {
        try await waitUntil { startCount > 0 }
    }

    func waitUntilCancelled() async throws {
        try await waitUntil { cancellationCount > 0 }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while !condition() {
            guard clock.now < deadline else {
                throw StreamingTaskRegistryTestError.timedOut
            }
            await Task.yield()
        }
    }
}

private enum StreamingTaskRegistryTestError: Error {
    case timedOut
}
