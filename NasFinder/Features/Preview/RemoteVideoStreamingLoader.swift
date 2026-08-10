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
    private let lock = NSLock()
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

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
        let task = Task(priority: .userInitiated) { [weak self, weak loadingRequest] in
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
            self.removeTask(for: identifier)
        }
        store(task, for: identifier)
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        removeAndCancelTask(for: ObjectIdentifier(loadingRequest))
    }

    func cancel() {
        lock.lock()
        let activeTasks = Array(tasks.values)
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }

    private func store(_ task: Task<Void, Never>, for identifier: ObjectIdentifier) {
        lock.lock()
        tasks[identifier]?.cancel()
        tasks[identifier] = task
        lock.unlock()
    }

    private func removeTask(for identifier: ObjectIdentifier) {
        lock.lock()
        tasks.removeValue(forKey: identifier)
        lock.unlock()
    }

    private func removeAndCancelTask(for identifier: ObjectIdentifier) {
        lock.lock()
        let task = tasks.removeValue(forKey: identifier)
        lock.unlock()
        task?.cancel()
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
