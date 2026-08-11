import Foundation

struct URLSessionBoundedRangeRead: @unchecked Sendable {
    let data: Data
    let response: HTTPURLResponse
}

/// Reads one HTTP byte range while rejecting a server that ignores `Range`
/// before its response body is accepted. The data delegate also cancels as
/// soon as the requested byte ceiling would be exceeded.
final class URLSessionBoundedRangeReader: NSObject,
    URLSessionDataDelegate,
    @unchecked Sendable {
    private let configuration: URLSessionConfiguration
    private let expectedOffset: Int64
    private let maximumByteCount: Int
    private let lock = NSLock()

    private var continuation: CheckedContinuation<URLSessionBoundedRangeRead, Error>?
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var data = Data()
    private var terminalError: Error?
    private var isCancelled = false
    private var isFinished = false

    init(
        configuration: URLSessionConfiguration,
        expectedOffset: Int64,
        maximumByteCount: Int
    ) {
        self.configuration = configuration
        self.expectedOffset = expectedOffset
        self.maximumByteCount = max(maximumByteCount, 0)
    }

    func read(_ request: URLRequest) async throws -> URLSessionBoundedRangeRead {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isCancelled, self.continuation == nil else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let session = URLSession(
                    configuration: configuration,
                    delegate: self,
                    delegateQueue: Self.makeDelegateQueue()
                )
                let task = session.dataTask(with: request)
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
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        do {
            let http = try validatedResponse(response)
            lock.lock()
            self.response = http
            lock.unlock()
            completionHandler(.allow)
        } catch {
            lock.lock()
            terminalError = error
            lock.unlock()
            completionHandler(.cancel)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive newData: Data
    ) {
        lock.lock()
        guard terminalError == nil, !isCancelled, !isFinished else {
            lock.unlock()
            return
        }
        guard newData.count <= maximumByteCount - data.count else {
            terminalError = NasFinderError.invalidResponse
            let activeTask = task
            lock.unlock()
            activeTask?.cancel()
            return
        }
        data.append(newData)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.lock()
        let terminalError = terminalError
        let isCancelled = isCancelled
        let response = response
        let data = data
        lock.unlock()

        if let terminalError {
            finish(.failure(terminalError))
        } else if isCancelled || (error as? URLError)?.code == .cancelled {
            finish(.failure(CancellationError()))
        } else if let error {
            finish(.failure(error))
        } else if let response, !data.isEmpty, data.count <= maximumByteCount {
            finish(.success(URLSessionBoundedRangeRead(data: data, response: response)))
        } else {
            finish(.failure(NasFinderError.invalidResponse))
        }
    }

    private func validatedResponse(_ response: URLResponse) throws -> HTTPURLResponse {
        guard maximumByteCount > 0,
              let http = response as? HTTPURLResponse else {
            throw NasFinderError.invalidResponse
        }
        let contentRange = http.value(forHTTPHeaderField: "Content-Range")
        guard http.statusCode == 206,
              let contentRange,
              let parsedRange = Self.parseContentRange(contentRange),
              parsedRange.lowerBound == expectedOffset,
              response.expectedContentLength <= 0
                || response.expectedContentLength <= Int64(maximumByteCount) else {
            throw NasFinderError.invalidResponse
        }
        let distance = parsedRange.upperBound.subtractingReportingOverflow(
            parsedRange.lowerBound
        )
        let count = distance.partialValue.addingReportingOverflow(1)
        guard parsedRange.lowerBound >= 0,
              parsedRange.upperBound >= parsedRange.lowerBound,
              !distance.overflow,
              !count.overflow,
              count.partialValue <= Int64(maximumByteCount) else {
            throw NasFinderError.invalidResponse
        }
        return http
    }

    private func finish(_ result: Result<URLSessionBoundedRangeRead, Error>) {
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
        lock.unlock()

        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private static func parseContentRange(
        _ value: String
    ) -> ClosedRange<Int64>? {
        let components = value.lowercased().split(separator: " ", maxSplits: 1)
        guard components.count == 2, components[0] == "bytes" else { return nil }
        let rangeAndSize = components[1].split(separator: "/", maxSplits: 1)
        guard let rangeText = rangeAndSize.first else { return nil }
        let bounds = rangeText.split(separator: "-", maxSplits: 1)
        guard bounds.count == 2,
              let lowerBound = Int64(bounds[0]),
              let upperBound = Int64(bounds[1]) else { return nil }
        return lowerBound...upperBound
    }

    private static func makeDelegateQueue() -> OperationQueue {
        let queue = OperationQueue()
        queue.name = "com.nasfinder.bounded-range-reader"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }
}
