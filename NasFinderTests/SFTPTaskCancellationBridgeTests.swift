import XCTest
@testable import NasFinder

final class SFTPTaskCancellationBridgeTests: XCTestCase {
    func testDownloadSizeUsesLiveValueAndFallsBackToListedValue() {
        XCTAssertEqual(
            SFTPDownloadSizePolicy.expectedByteCount(
                liveByteCount: 2_048,
                listedByteCount: 1_024
            ),
            2_048
        )
        XCTAssertEqual(
            SFTPDownloadSizePolicy.expectedByteCount(
                liveByteCount: nil,
                listedByteCount: 1_024
            ),
            1_024
        )
    }

    func testCancellationClosesTransportAndNormalizesUncooperativeReadError() async {
        let input = NonCooperativeSFTPInput(completionOnClose: .failure)
        let task = Task {
            try await SFTPTaskCancellationBridge.run {
                try await input.read()
            } onCancel: {
                await input.close()
            }
        }

        await input.waitUntilReadStarts()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소된 비협조적 SFTP read가 성공하면 안 됩니다.")
        } catch is CancellationError {
            // Expected. Closing the transport unblocks the pending operation.
        } catch {
            XCTFail("CancellationError가 필요하지만 \(error)가 발생했습니다.")
        }

        let closeCount = await input.closeCount
        XCTAssertEqual(closeCount, 1)
    }

    func testCancellationCannotReturnSuccessWhenCloseUnblocksReadSuccessfully() async {
        let input = NonCooperativeSFTPInput(completionOnClose: .success)
        let task = Task {
            try await SFTPTaskCancellationBridge.run {
                try await input.read()
            } onCancel: {
                await input.close()
            }
        }

        await input.waitUntilReadStarts()
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소와 동시에 완료된 SFTP read가 성공으로 반환되면 안 됩니다.")
        } catch is CancellationError {
            // The post-operation cancellation check normalizes this race too.
        } catch {
            XCTFail("CancellationError가 필요하지만 \(error)가 발생했습니다.")
        }
    }

}

private actor NonCooperativeSFTPInput {
    enum CompletionOnClose {
        case success
        case failure
    }

    private let completionOnClose: CompletionOnClose
    private var readContinuation: CheckedContinuation<Int, Error>?
    private var readStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var closeCount = 0

    init(completionOnClose: CompletionOnClose) {
        self.completionOnClose = completionOnClose
    }

    func read() async throws -> Int {
        readStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }

        return try await withCheckedThrowingContinuation { continuation in
            readContinuation = continuation
        }
    }

    func waitUntilReadStarts() async {
        guard !readStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func close() {
        closeCount += 1
        guard let continuation = readContinuation else { return }
        readContinuation = nil
        switch completionOnClose {
        case .success:
            continuation.resume(returning: 1)
        case .failure:
            continuation.resume(throwing: NonCooperativeSFTPError.transportClosed)
        }
    }
}

private enum NonCooperativeSFTPError: Error {
    case transportClosed
}
