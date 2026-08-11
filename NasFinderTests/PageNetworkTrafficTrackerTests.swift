import XCTest
@testable import NasFinder

@MainActor
final class PageNetworkTrafficTrackerTests: XCTestCase {
    func testZeroTrafficUsesNumericZero() {
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(0), "0 kb")
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(-1), "0 kb")
    }

    func testTrafficUsesCompactIntegerUnits() {
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(999), "999 b")
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(1_499), "1 kb")
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(1_500), "2 kb")
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(3_700_000), "4 mb")
        XCTAssertEqual(PageNetworkTrafficTracker.formatted(2_600_000_000), "3 gb")
    }

    func testTrackerAccumulatesAndResetsTraffic() {
        let tracker = PageNetworkTrafficTracker()

        tracker.recordUpload(120)
        tracker.recordDownload(80)

        XCTAssertEqual(tracker.uploadedByteCount, 120)
        XCTAssertEqual(tracker.downloadedByteCount, 80)
        XCTAssertEqual(tracker.totalByteCount, 200)

        tracker.reset()

        XCTAssertEqual(tracker.uploadedByteCount, 0)
        XCTAssertEqual(tracker.downloadedByteCount, 0)
        XCTAssertEqual(tracker.totalByteCount, 0)
    }

    func testProgressDeltasDoNotDoubleCountRepeatedCompletion() async {
        let accumulator = NetworkTrafficDeltaAccumulator()

        let deltas = [
            await accumulator.delta(for: 0),
            await accumulator.delta(for: 10),
            await accumulator.delta(for: 25),
            await accumulator.delta(for: 25),
            await accumulator.delta(for: 20),
        ]
        let accountedByteCount = await accumulator.accountedByteCount

        XCTAssertEqual(deltas, [0, 10, 15, 0, 0])
        XCTAssertEqual(accountedByteCount, 25)
    }

    func testUncachedDownloadCountsOnlyPositiveProgressDeltas() async throws {
        let tracker = PageNetworkTrafficTracker()
        let service = TrafficMeasuringRemoteFileService(
            base: ProgressDownloadService(),
            tracker: tracker,
            isDownloadCached: { _ in false }
        )

        _ = try await service.download(ProgressDownloadService.item) { _ in }

        XCTAssertEqual(tracker.downloadedByteCount, 25)
    }

    func testCachedDownloadDoesNotCountPayloadAgain() async throws {
        let tracker = PageNetworkTrafficTracker()
        let service = TrafficMeasuringRemoteFileService(
            base: ProgressDownloadService(),
            tracker: tracker,
            isDownloadCached: { _ in true }
        )

        _ = try await service.download(ProgressDownloadService.item) { _ in }

        XCTAssertEqual(tracker.downloadedByteCount, 0)
    }
}

private struct ProgressDownloadService: RemoteFileService {
    static let testConnection = RemoteConnection(
        name: "Traffic test",
        kind: .synology,
        host: "nas.example.com",
        username: "tester"
    )
    static let item = RemoteFileItem(
        connectionID: testConnection.id,
        path: "/clip.mp4",
        name: "clip.mp4",
        kind: .file,
        size: 25,
        modifiedAt: nil,
        contentTypeIdentifier: nil
    )

    let connection = Self.testConnection

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        []
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        FileManager.default.temporaryDirectory.appending(path: "traffic-test.mp4")
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        for completed in [0, 10, 25, 25] {
            await progress(
                RemoteDownloadProgress(
                    completedByteCount: Int64(completed),
                    totalByteCount: 25
                )
            )
        }
        return FileManager.default.temporaryDirectory.appending(path: "traffic-test.mp4")
    }
}
