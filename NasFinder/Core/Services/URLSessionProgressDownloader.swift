import Foundation

struct URLSessionProgressDownload: @unchecked Sendable {
    let temporaryURL: URL
    let response: URLResponse
}

/// Uses a dedicated download session so byte progress is available without
/// buffering the remote file in memory. The returned file remains valid after
/// the delegate callback and is owned by the caller.
final class URLSessionProgressDownloader: NSObject,
    URLSessionDownloadDelegate,
    @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let authenticationCredential: URLCredential?
    private let progressRelay: URLSessionDownloadProgressRelay
    private let stagingDestinationProvider: @Sendable () -> URL
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URLSessionProgressDownload, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var stagedURL: URL?
    private var stagingError: Error?
    private var isCancelled = false
    private var isCompletionScheduled = false
    private var isFinished = false

    init(
        configuration: URLSessionConfiguration,
        authenticationCredential: URLCredential? = nil,
        progressHandler: @escaping RemoteDownloadProgressHandler,
        stagingDestinationProvider: @escaping @Sendable () -> URL = {
            FileManager.default.temporaryDirectory
                .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        }
    ) {
        self.configuration = configuration
        self.authenticationCredential = authenticationCredential
        progressRelay = URLSessionDownloadProgressRelay(handler: progressHandler)
        self.stagingDestinationProvider = stagingDestinationProvider
    }

    func download(_ request: URLRequest) async throws -> URLSessionProgressDownload {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if isCancelled {
                    lock.unlock()
                    Task { await self.progressRelay.finish() }
                    continuation.resume(throwing: CancellationError())
                    return
                }

                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: Self.makeDelegateQueue()
                )
                let task = session.downloadTask(with: request)
                self.session = session
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.cancel()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        let activeTask = task
        lock.unlock()

        activeTask?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if let authenticationCredential,
           method == NSURLAuthenticationMethodHTTPBasic
                || method == NSURLAuthenticationMethodHTTPDigest
                || method == NSURLAuthenticationMethodDefault {
            completionHandler(.useCredential, authenticationCredential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let shouldReport = !isCancelled && !isCompletionScheduled && !isFinished
        lock.unlock()
        guard shouldReport else { return }

        progressRelay.yield(
            RemoteDownloadProgress(
                completedByteCount: totalBytesWritten,
                totalByteCount: totalBytesExpectedToWrite > 0
                    ? totalBytesExpectedToWrite
                    : nil
            )
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let destination = stagingDestinationProvider()

        do {
            try FileManager.default.moveItem(at: location, to: destination)
            lock.lock()
            let shouldDiscard = isCancelled || isCompletionScheduled || isFinished
            if !shouldDiscard {
                stagedURL = destination
            }
            lock.unlock()
            if shouldDiscard {
                try? FileManager.default.removeItem(at: destination)
            }
        } catch {
            lock.lock()
            if !isCancelled && !isCompletionScheduled && !isFinished {
                stagingError = error
            }
            lock.unlock()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let isCancelled = isCancelled
        let stagedURL = stagedURL
        let stagingError = stagingError
        let response = task.response
        lock.unlock()

        if isCancelled || (error as? URLError)?.code == .cancelled {
            scheduleFinish(.failure(CancellationError()))
        } else if let error {
            scheduleFinish(.failure(error))
        } else if let stagingError {
            scheduleFinish(.failure(stagingError))
        } else if let stagedURL, let response {
            scheduleFinish(
                .success(
                    URLSessionProgressDownload(
                        temporaryURL: stagedURL,
                        response: response
                    )
                )
            )
        } else {
            scheduleFinish(.failure(URLSessionProgressDownloadError.missingDownloadedFile))
        }
    }

    private func scheduleFinish(_ result: Result<URLSessionProgressDownload, Error>) {
        lock.lock()
        guard !isCompletionScheduled, !isFinished else {
            lock.unlock()
            return
        }
        isCompletionScheduled = true
        lock.unlock()

        Task {
            await progressRelay.finish()
            finish(result)
        }
    }

    private func finish(_ result: Result<URLSessionProgressDownload, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let session = session
        self.session = nil
        task = nil
        let stagedURL = stagedURL
        let finalResult: Result<URLSessionProgressDownload, Error> = isCancelled
            ? .failure(CancellationError())
            : result
        lock.unlock()

        if case .failure = finalResult, let stagedURL {
            try? FileManager.default.removeItem(at: stagedURL)
        }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: finalResult)
    }

    private static func makeDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.nasfinder.download-progress"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        return queue
    }
}

/// URLSession delegate callbacks are synchronous. This relay keeps their order
/// while allowing the app's progress handler to hop to another actor safely.
final class URLSessionDownloadProgressRelay: @unchecked Sendable {
    private let continuation: AsyncStream<RemoteDownloadProgress>.Continuation
    private let consumer: Task<Void, Never>

    init(handler: @escaping RemoteDownloadProgressHandler) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: RemoteDownloadProgress.self,
            // UI only needs the newest pending byte count. Coalescing avoids
            // accumulating thousands of callbacks on a fast large download.
            bufferingPolicy: .bufferingNewest(1)
        )
        self.continuation = continuation
        consumer = Task {
            for await update in stream {
                await handler(update)
            }
        }
    }

    func yield(_ update: RemoteDownloadProgress) {
        continuation.yield(update)
    }

    func finish() async {
        continuation.finish()
        await consumer.value
    }
}

private enum URLSessionProgressDownloadError: LocalizedError {
    case missingDownloadedFile

    var errorDescription: String? {
        "내려받은 임시 파일을 찾을 수 없습니다."
    }
}
