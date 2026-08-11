import Foundation
import XCTest
@testable import NasFinder

final class URLSessionProgressDownloaderTests: XCTestCase {
    func testProgressRelayCoalescesInOrderAndDrainsBeforeReturning() async {
        let recorder = SuspendedProgressRecorder()
        let relay = URLSessionDownloadProgressRelay { update in
            await recorder.record(update.completedByteCount)
        }

        relay.yield(RemoteDownloadProgress(completedByteCount: 25, totalByteCount: 100))
        await recorder.waitUntilFirstUpdateStarts()
        relay.yield(RemoteDownloadProgress(completedByteCount: 50, totalByteCount: 100))
        relay.yield(RemoteDownloadProgress(completedByteCount: 100, totalByteCount: 100))

        let finishState = CompletionState()
        let finishTask = Task {
            await relay.finish()
            await finishState.markFinished()
        }
        await Task.yield()
        let didFinishEarly = await finishState.isFinished
        XCTAssertFalse(didFinishEarly)

        await recorder.releaseFirstUpdate()
        await finishTask.value

        let recordedValues = await recorder.values
        let didFinish = await finishState.isFinished
        XCTAssertEqual(recordedValues, [25, 100])
        XCTAssertTrue(didFinish)
    }

    func testCancelledDownloadAlwaysThrowsCancellationError() async throws {
        CancelledDownloadURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CancelledDownloadURLProtocol.self]
        let progress = ProgressValues()
        let downloader = URLSessionProgressDownloader(configuration: configuration) { update in
            await progress.append(update.completedByteCount)
        }
        let request = URLRequest(url: URL(string: "https://cancel.nasfinder.invalid/video.mov")!)

        let operation = Task {
            try await downloader.download(request)
        }
        try await CancelledDownloadURLProtocol.waitUntilStarted()
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("취소한 다운로드가 성공하면 안 됩니다.")
        } catch is CancellationError {
            // Expected. URLSession's URLError.cancelled is normalized.
        } catch {
            XCTFail("CancellationError가 필요하지만 \(error)가 발생했습니다.")
        }
    }

    func testCancelledDownloaderDiscardsLateDownloadedFile() async throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        let stagedURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        try Data(repeating: 0x5A, count: 1_024).write(to: sourceURL)
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            try? FileManager.default.removeItem(at: stagedURL)
        }

        let downloader = URLSessionProgressDownloader(
            configuration: .ephemeral,
            progressHandler: { _ in },
            stagingDestinationProvider: { stagedURL }
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.downloadTask(
            with: URL(string: "https://late.nasfinder.invalid/video.mov")!
        )

        downloader.cancel()
        downloader.urlSession(
            session,
            downloadTask: task,
            didFinishDownloadingTo: sourceURL
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        do {
            _ = try await downloader.download(
                URLRequest(url: URL(string: "https://late.nasfinder.invalid/video.mov")!)
            )
            XCTFail("이미 취소한 downloader가 시작되면 안 됩니다.")
        } catch is CancellationError {
            // Also closes the progress relay created during initialization.
        }
    }
}

private actor SuspendedProgressRecorder {
    private(set) var values: [Int64] = []
    private var hasStarted = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    func record(_ value: Int64) async {
        if !hasStarted {
            hasStarted = true
            let waiters = startWaiters
            startWaiters.removeAll()
            waiters.forEach { $0.resume() }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }
        values.append(value)
    }

    func waitUntilFirstUpdateStarts() async {
        guard !hasStarted else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func releaseFirstUpdate() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private actor CompletionState {
    private(set) var isFinished = false

    func markFinished() {
        isFinished = true
    }
}

private actor ProgressValues {
    private(set) var values: [Int64] = []

    func append(_ value: Int64) {
        values.append(value)
    }
}

private final class CancelledDownloadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let state = CancellationProtocolState()

    static func reset() {
        state.reset()
    }

    static func waitUntilStarted() async throws {
        try await state.waitUntilStarted()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "cancel.nasfinder.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "1048576"]
              ) else { return }
        Self.state.markStarted()
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0x41, count: 1_024))
        // Intentionally wait for URLSession to call stopLoading after cancellation.
    }

    override func stopLoading() {}
}

private final class CancellationProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func reset() {
        lock.lock()
        started = false
        lock.unlock()
    }

    func markStarted() {
        lock.lock()
        started = true
        lock.unlock()
    }

    func waitUntilStarted() async throws {
        for _ in 0..<200 {
            if currentStartedValue() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw CancellationProtocolTestError.didNotStart
    }

    private func currentStartedValue() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return started
    }
}

private enum CancellationProtocolTestError: Error {
    case didNotStart
}
