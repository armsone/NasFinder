import XCTest
@testable import NasFinder

final class RemoteVideoStreamingTaskRegistryTests: XCTestCase {
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
