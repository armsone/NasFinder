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
    private let byteBudget: RemoteVideoStreamingByteBudget?
    private let rangeCache: RemoteVideoStreamingRangeCache?

    init(
        item: RemoteFileItem,
        service: any RemoteFileService,
        maximumTransferredBytes: Int? = nil
    ) {
        self.item = item
        self.service = service
        byteBudget = maximumTransferredBytes.map(RemoteVideoStreamingByteBudget.init)
        rangeCache = maximumTransferredBytes.map { _ in
            RemoteVideoStreamingRangeCache()
        }

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
                    let preferredLength = RemoteVideoStreamingReadPolicy.preferredLength(
                        remainingBytes: requestedEnd - offset,
                        isBounded: byteBudget != nil
                    )
                    if let cachedData = rangeCache?.data(
                        at: offset,
                        maximumLength: preferredLength
                    ) {
                        dataRequest.respond(with: cachedData)
                        offset += Int64(cachedData.count)
                        continue
                    }
                    let length = byteBudget?.reserve(upTo: preferredLength)
                        ?? preferredLength
                    guard length > 0 else {
                        throw RemoteVideoStreamingError.transferLimitReached
                    }

                    let data: Data
                    do {
                        data = try await service.readRange(
                            of: item,
                            offset: offset,
                            length: length
                        )
                        byteBudget?.complete(
                            reservedBytes: length,
                            receivedBytes: data.count
                        )
                        rangeCache?.store(data, at: offset)
                    } catch {
                        byteBudget?.complete(
                            reservedBytes: length,
                            receivedBytes: 0
                        )
                        throw error
                    }
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

    var transferredByteCount: Int {
        byteBudget?.transferredByteCount ?? 0
    }

    var accountedByteCount: Int {
        byteBudget?.accountedByteCount ?? 0
    }
}

enum RemoteVideoStreamingReadPolicy {
    static let boundedChunkBytes = 256 * 1_024
    static let playbackChunkBytes = 8 * 1_024 * 1_024

    static func preferredLength(
        remainingBytes: Int64,
        isBounded: Bool
    ) -> Int {
        let maximumChunk = isBounded ? boundedChunkBytes : playbackChunkBytes
        return Int(min(max(remainingBytes, 0), Int64(maximumChunk)))
    }
}

/// Keeps byte ranges already fetched for one AVAsset so duration probing and
/// image generation do not charge the network budget for the same bytes twice.
/// The cache is intentionally loader-local and therefore cannot affect another
/// file or outlive the thumbnail/playback asset that owns it.
final class RemoteVideoStreamingRangeCache: @unchecked Sendable {
    private struct Entry {
        let offset: Int64
        let data: Data

        var endOffset: Int64 { offset + Int64(data.count) }
    }

    private let lock = NSLock()
    private var entries: [Entry] = []

    func data(at offset: Int64, maximumLength: Int) -> Data? {
        guard offset >= 0, maximumLength > 0 else { return nil }
        lock.lock()
        let entry = entries
            .filter { $0.offset <= offset && offset < $0.endOffset }
            .max { $0.endOffset < $1.endOffset }
        lock.unlock()
        guard let entry,
              let relativeOffset = Int(exactly: offset - entry.offset) else {
            return nil
        }
        let availableCount = entry.data.count - relativeOffset
        let count = min(maximumLength, availableCount)
        guard count > 0 else { return nil }
        return entry.data.subdata(in: relativeOffset..<(relativeOffset + count))
    }

    func store(_ data: Data, at offset: Int64) {
        guard offset >= 0, !data.isEmpty else { return }
        let newEntry = Entry(offset: offset, data: data)
        lock.lock()
        entries.removeAll {
            newEntry.offset <= $0.offset && newEntry.endOffset >= $0.endOffset
        }
        if !entries.contains(where: {
            $0.offset <= newEntry.offset && $0.endOffset >= newEntry.endOffset
        }) {
            entries.append(newEntry)
        }
        lock.unlock()
    }
}

/// Bounds the bytes fetched by a streaming asset without changing playback's
/// existing unlimited behavior. Reservations keep concurrent AVFoundation
/// resource requests from exceeding the limit before their reads complete.
final class RemoteVideoStreamingByteBudget: @unchecked Sendable {
    private let maximumBytes: Int
    private let lock = NSLock()
    private var reservedBytes = 0
    private var receivedBytes = 0

    init(maximumBytes: Int) {
        self.maximumBytes = max(maximumBytes, 0)
    }

    func reserve(upTo requestedBytes: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let availableBytes = max(maximumBytes - receivedBytes - reservedBytes, 0)
        let grantedBytes = min(max(requestedBytes, 0), availableBytes)
        reservedBytes += grantedBytes
        return grantedBytes
    }

    func complete(reservedBytes completedReservation: Int, receivedBytes: Int) {
        lock.lock()
        reservedBytes = max(reservedBytes - max(completedReservation, 0), 0)
        self.receivedBytes += min(
            max(receivedBytes, 0),
            max(completedReservation, 0)
        )
        lock.unlock()
    }

    var transferredByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes
    }

    var accountedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return receivedBytes + reservedBytes
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
    case transferLimitReached

    var errorDescription: String? {
        switch self {
        case .missingFileSize:
            "영상 크기를 알 수 없어 스트리밍을 시작할 수 없습니다."
        case .unexpectedEndOfFile:
            "원격 영상 데이터를 끝까지 읽지 못했습니다."
        case .transferLimitReached:
            "원격 영상의 데이터 사용 한도에 도달했습니다."
        }
    }
}
