@preconcurrency import AVFoundation
import Foundation

/// Supplies AVFoundation with bounded remote byte ranges. AVPlayer can begin
/// once the container header and the first media ranges arrive instead of
/// waiting for a complete SFTP download.
final class RemoteVideoStreamingLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    let asset: AVURLAsset

    private let item: RemoteFileItem
    private let service: any RemoteFileService
    private let delegateQueue = DispatchQueue(
        label: "com.armsone.nasfinder.video-resource-loader",
        qos: .userInitiated
    )
    private let taskRegistry = RemoteVideoStreamingTaskRegistry()

    init(item: RemoteFileItem, service: any RemoteFileService) {
        self.item = item
        self.service = service

        var components = URLComponents()
        components.scheme = "nasfinder-stream"
        components.host = item.connectionID.uuidString.lowercased()
        components.path = "/\(item.id.hashValue.magnitude)/\(item.name)"
        let url = components.url ?? URL(string: "nasfinder-stream://file/video")!
        asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        super.init()
        asset.resourceLoader.setDelegate(self, queue: delegateQueue)
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let fileSize = item.size, fileSize > 0 else {
            loadingRequest.finishLoading(with: RemoteVideoStreamingError.missingFileSize)
            return false
        }

        if let informationRequest = loadingRequest.contentInformationRequest {
            informationRequest.contentType = item.contentType.identifier
            informationRequest.contentLength = fileSize
            informationRequest.isByteRangeAccessSupported = true
        }

        guard let dataRequest = loadingRequest.dataRequest else {
            loadingRequest.finishLoading()
            return true
        }

        let identifier = ObjectIdentifier(loadingRequest)
        let didStart = taskRegistry.start(for: identifier) { [weak self, weak loadingRequest] in
            guard let self, let loadingRequest else { return }
            do {
                var offset = max(dataRequest.currentOffset, dataRequest.requestedOffset)
                let requestedEnd: Int64
                if dataRequest.requestsAllDataToEndOfResource {
                    requestedEnd = fileSize
                } else {
                    let requestedLength = Int64(max(dataRequest.requestedLength, 0))
                    requestedEnd = min(fileSize, dataRequest.requestedOffset + requestedLength)
                }

                while offset < requestedEnd {
                    try Task.checkCancellation()
                    let length = Int(min(requestedEnd - offset, 8 * 1_024 * 1_024))
                    let data = try await service.readRange(
                        of: item,
                        offset: offset,
                        length: length
                    )
                    guard !data.isEmpty else { break }
                    try Task.checkCancellation()
                    dataRequest.respond(with: data)
                    offset += Int64(data.count)
                    if data.count < length { break }
                }

                if offset >= requestedEnd || offset >= fileSize {
                    loadingRequest.finishLoading()
                } else {
                    loadingRequest.finishLoading(with: RemoteVideoStreamingError.unexpectedEndOfFile)
                }
            } catch is CancellationError {
                loadingRequest.finishLoading(with: CancellationError())
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        guard didStart else {
            loadingRequest.finishLoading(with: CancellationError())
            return false
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        taskRegistry.cancelTask(for: ObjectIdentifier(loadingRequest))
    }

    func cancel() {
        taskRegistry.cancelAll()
    }
}

/// Registers a range-read task atomically with respect to whole-loader
/// cancellation. `Task` begins executing immediately when it is created, so
/// creating it before taking the registry lock leaves a window where
/// `cancelAll()` cannot see it. Creating and publishing it under the same lock
/// closes that window; a task that finishes immediately simply waits to remove
/// itself until publication is complete.
final class RemoteVideoStreamingTaskRegistry: @unchecked Sendable {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Entry] = [:]
    private var isCancelled = false

    @discardableResult
    func start(
        for identifier: ObjectIdentifier,
        operation: @escaping @Sendable () async -> Void
    ) -> Bool {
        lock.lock()
        guard !isCancelled else {
            lock.unlock()
            return false
        }
        let previousTask = tasks.removeValue(forKey: identifier)
        let token = UUID()
        let task = Task(priority: .userInitiated) { [weak self] in
            await operation()
            self?.removeTask(for: identifier, token: token)
        }
        tasks[identifier] = Entry(token: token, task: task)
        lock.unlock()
        previousTask?.task.cancel()
        return true
    }

    private func removeTask(for identifier: ObjectIdentifier, token: UUID) {
        lock.lock()
        if tasks[identifier]?.token == token {
            tasks.removeValue(forKey: identifier)
        }
        lock.unlock()
    }

    func cancelTask(for identifier: ObjectIdentifier) {
        lock.lock()
        let task = tasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.task.cancel()
    }

    func cancelAll() {
        lock.lock()
        isCancelled = true
        let activeTasks = tasks.values.map(\.task)
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }
}

private enum RemoteVideoStreamingError: LocalizedError, Sendable {
    case missingFileSize
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .missingFileSize:
            "영상 크기를 알 수 없어 스트리밍을 시작할 수 없습니다."
        case .unexpectedEndOfFile:
            "원격 영상 데이터를 끝까지 읽지 못했습니다."
        }
    }
}
