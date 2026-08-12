@preconcurrency import AVFoundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

struct RemoteVideoThumbnailGenerationResult: Sendable {
    let data: Data
    let transferredBytes: Int
}

enum RemoteVideoThumbnailRoutingPolicy {
    static func bypassesBackendThumbnail(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) -> Bool {
        service.supportsRangeStreaming
            && CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item)
    }

    static func canGenerateBoundedThumbnail(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) -> Bool {
        item.isVideo
            && service.supportsRangeStreaming
            && (
                service.connection.kind == .synology
                    || CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item)
            )
    }

    static func trafficBudget(
        for service: any RemoteFileService
    ) -> RemoteVideoThumbnailTrafficBudget {
        service.connection.kind == .sftp ? .sftpShared : .shared
    }
}

enum RemoteVideoThumbnailGenerationError: LocalizedError, Sendable {
    case unsupportedSource
    case trafficBudgetExhausted
    case invalidDuration
    case imageGenerationFailed
    case imageEncodingFailed
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unsupportedSource:
            "이 연결에서는 영상 일부를 읽어 썸네일을 만들 수 없습니다."
        case .trafficBudgetExhausted:
            "이 폴더의 썸네일 데이터 사용 한도에 도달했습니다."
        case .invalidDuration:
            "영상 재생 시간을 확인할 수 없습니다."
        case .imageGenerationFailed:
            "원격 영상에서 썸네일 프레임을 만들 수 없습니다."
        case .imageEncodingFailed:
            "생성한 썸네일을 이미지로 저장할 수 없습니다."
        case .timedOut:
            "원격 영상의 썸네일 생성 시간이 초과됐습니다."
        }
    }
}

/// Creates a thumbnail from an AVFoundation asset backed by the service's
/// byte-range API. The folder lease makes the folder ceiling shared by every
/// visible cell and preheating request in the current app process.
enum RemoteVideoThumbnailGenerator {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.armsone.nasfinder",
        category: "remote-video-thumbnail"
    )
    private static let coordinator = RemoteVideoThumbnailGenerationCoordinator()
    static let defaultGenerationTimeout: Duration = .seconds(20)

    static func generate(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget = .shared,
        timeout: Duration = defaultGenerationTimeout
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        if CompatibilityVideoFormatPolicy.prefersCompatibilityPlayer(for: item) {
            // Keep VLCKit work structured under the cell task. The shared
            // coordinator intentionally outlives individual waiters, which is
            // useful for AVFoundation but retained cancelled VLC players when
            // pull-to-refresh replaced a grid generation.
            return try await CompatibilityRemoteVideoThumbnailGenerator.generate(
                for: item,
                service: service,
                size: size,
                trafficBudget: trafficBudget,
                timeout: timeout
            )
        }
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        let key = "\(item.id)|\(version)|\(item.size ?? -1)|\(size.rawValue)"
        return try await coordinator.value(for: key) {
            try await generateUncoordinated(
                for: item,
                service: service,
                size: size,
                trafficBudget: trafficBudget,
                timeout: timeout
            )
        }
    }

    private static func generateUncoordinated(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        timeout: Duration
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        guard item.isVideo,
              service.supportsRangeStreaming,
              item.size.map({ $0 > 0 }) == true else {
            throw RemoteVideoThumbnailGenerationError.unsupportedSource
        }
        guard let lease = await trafficBudget.lease(for: item) else {
            throw RemoteVideoThumbnailGenerationError.trafficBudgetExhausted
        }

        let loader = RemoteVideoStreamingLoader(
            item: item,
            service: service,
            maximumTransferredBytes: lease.maximumBytes
        )
        let generator = AVAssetImageGenerator(asset: loader.asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = maximumDimensions(for: size)
        let timeTolerance = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = timeTolerance
        generator.requestedTimeToleranceAfter = timeTolerance
        let cancellationController = RemoteVideoThumbnailCancellationController(
            generator: generator,
            loader: loader
        )

        do {
            let data = try await withGenerationTimeout(
                timeout,
                cancellationController: cancellationController
            ) {
                // Loading duration first makes AVFoundation request all bytes
                // to EOF for many remote MP4/MOV files. Start from inexpensive
                // early frames instead; the finite tolerance also handles
                // clips shorter than the first candidate.
                let candidateSeconds = [0.5, 1.5, 3.0, 0]

                var generatedImage: CGImage?
                for candidate in candidateSeconds {
                    try Task.checkCancellation()
                    do {
                        let result = try await generator.image(
                            at: CMTime(seconds: candidate, preferredTimescale: 600)
                        )
                        if RemoteVideoThumbnailQuality.isUsable(result.image) {
                            generatedImage = result.image
                            break
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        continue
                    }
                }

                guard let generatedImage else {
                    throw RemoteVideoThumbnailGenerationError.imageGenerationFailed
                }
                return try jpegData(from: generatedImage)
            }
            loader.cancel()
            let transferredBytes = loader.accountedByteCount
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            logger.info(
                "Range thumbnail succeeded with \(transferredBytes, privacy: .public) bytes"
            )
            return RemoteVideoThumbnailGenerationResult(
                data: data,
                transferredBytes: transferredBytes
            )
        } catch {
            generator.cancelAllCGImageGeneration()
            loader.cancel()
            let transferredBytes = loader.accountedByteCount
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            logger.error(
                "Range thumbnail failed after \(transferredBytes, privacy: .public) bytes"
            )
            throw error
        }
    }

    private static func withGenerationTimeout<Value: Sendable>(
        _ timeout: Duration,
        cancellationController: RemoteVideoThumbnailCancellationController,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let race = RemoteVideoThumbnailDeadlineRace<Value>()
        return try await race.value(
            timeout: timeout,
            cancellationController: cancellationController,
            operation: operation
        )
    }

    private static func maximumDimensions(for size: RemoteThumbnailSize) -> CGSize {
        switch size {
        case .small:
            CGSize(width: 192, height: 192)
        case .medium:
            CGSize(width: 384, height: 384)
        case .large:
            CGSize(width: 720, height: 720)
        }
    }

    private static func jpegData(from image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw RemoteVideoThumbnailGenerationError.imageEncodingFailed
        }
        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.62
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw RemoteVideoThumbnailGenerationError.imageEncodingFailed
        }
        return data as Data
    }
}

private final class RemoteVideoThumbnailCancellationController: @unchecked Sendable {
    private let generator: AVAssetImageGenerator
    private let loader: RemoteVideoStreamingLoader

    init(generator: AVAssetImageGenerator, loader: RemoteVideoStreamingLoader) {
        self.generator = generator
        self.loader = loader
    }

    func cancel() {
        generator.cancelAllCGImageGeneration()
        loader.cancel()
    }
}

/// Returns as soon as generation or its deadline wins. This deliberately does
/// not use a task group because a task-group scope waits for a non-cooperative
/// AVFoundation child even after cancellation, which would defeat the bound.
private final class RemoteVideoThumbnailDeadlineRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var operationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false

    func value(
        timeout: Duration,
        cancellationController: RemoteVideoThumbnailCancellationController,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !isFinished else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let operationTask = Task(priority: .userInitiated) { [weak self] in
                    do {
                        self?.finish(.success(try await operation()))
                    } catch {
                        self?.finish(.failure(error))
                    }
                }
                let timeoutTask = Task(priority: .userInitiated) { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    cancellationController.cancel()
                    operationTask.cancel()
                    self?.finish(
                        .failure(RemoteVideoThumbnailGenerationError.timedOut)
                    )
                }
                self.operationTask = operationTask
                self.timeoutTask = timeoutTask
                lock.unlock()
            }
        } onCancel: {
            cancellationController.cancel()
            self.finish(.failure(CancellationError()))
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let operationTask = operationTask
        let timeoutTask = timeoutTask
        self.operationTask = nil
        self.timeoutTask = nil
        lock.unlock()

        operationTask?.cancel()
        timeoutTask?.cancel()
        continuation?.resume(with: result)
    }
}

enum RemoteVideoThumbnailQuality {
    static func isAtLeast95PercentBlack(_ image: CGImage) -> Bool {
        let values = grayscaleSamples(from: image)
        guard !values.isEmpty else { return false }
        let blackPixels = values.lazy.filter { $0 <= 0.05 }.count
        return Double(blackPixels) / Double(values.count) >= 0.95
    }

    /// Rejects near-uniform black or white intro frames while retaining normal
    /// bright and dark scenes that still contain visible detail.
    static func isUsable(_ image: CGImage) -> Bool {
        let values = grayscaleSamples(from: image)
        guard !values.isEmpty else { return true }
        if isAtLeast95PercentBlack(image) { return false }

        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { partial, value in
            let difference = value - mean
            return partial + difference * difference
        } / Double(values.count)
        let standardDeviation = variance.squareRoot()
        let minimum = values.min() ?? mean
        let maximum = values.max() ?? mean
        let luminanceRange = maximum - minimum

        if mean > 0.97,
           standardDeviation < 0.03,
           luminanceRange < 0.08 { return false }
        return true
    }

    private static func grayscaleSamples(from image: CGImage) -> [Double] {
        let width = 32
        let height = 32
        var pixels = [UInt8](repeating: 0, count: width * height)
        guard let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return [] }
        context.interpolationQuality = .low
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels.map { Double($0) / 255.0 }
    }
}

private actor RemoteVideoThumbnailGenerationCoordinator {
    private struct Entry {
        let token: UUID
        let task: Task<RemoteVideoThumbnailGenerationResult, Error>
    }

    private var entries: [String: Entry] = [:]

    func value(
        for key: String,
        operation: @escaping @Sendable () async throws
            -> RemoteVideoThumbnailGenerationResult
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        if let entry = entries[key] {
            return try await entry.task.value
        }

        let token = UUID()
        let task = Task(priority: .userInitiated) {
            try await operation()
        }
        entries[key] = Entry(token: token, task: task)
        do {
            let result = try await task.value
            if entries[key]?.token == token {
                entries.removeValue(forKey: key)
            }
            return result
        } catch {
            if entries[key]?.token == token {
                entries.removeValue(forKey: key)
            }
            throw error
        }
    }
}

actor RemoteVideoThumbnailTrafficBudget {
    struct Lease: Sendable {
        fileprivate let identifier: UUID
        fileprivate let folderKey: String
        let maximumBytes: Int
    }

    static let shared = RemoteVideoThumbnailTrafficBudget()
    static let sftpShared = RemoteVideoThumbnailTrafficBudget(
        maximumFolderBytes: 18_000_000,
        maximumItemBytes: defaultMaximumItemBytes,
        minimumLeaseBytes: defaultMinimumLeaseBytes
    )

    static let defaultMaximumFolderBytes = 256 * 1_024 * 1_024
    static let defaultMaximumItemBytes = 16 * 1_024 * 1_024
    static let defaultMinimumLeaseBytes = 128 * 1_024

    private struct FolderState {
        var transferredBytes = 0
        var reservations: [UUID: Int] = [:]
    }

    private let maximumFolderBytes: Int
    private let maximumItemBytes: Int
    private let minimumLeaseBytes: Int
    private var folders: [String: FolderState] = [:]

    init(
        maximumFolderBytes: Int = defaultMaximumFolderBytes,
        maximumItemBytes: Int = defaultMaximumItemBytes,
        minimumLeaseBytes: Int = defaultMinimumLeaseBytes
    ) {
        self.maximumFolderBytes = max(maximumFolderBytes, 0)
        self.maximumItemBytes = max(maximumItemBytes, 0)
        self.minimumLeaseBytes = max(minimumLeaseBytes, 1)
    }

    func lease(for item: RemoteFileItem) -> Lease? {
        let folderKey = Self.folderKey(for: item)
        var state = folders[folderKey] ?? FolderState()
        let reservedBytes = state.reservations.values.reduce(0, +)
        let availableBytes = max(
            maximumFolderBytes - state.transferredBytes - reservedBytes,
            0
        )
        let grantedBytes = min(maximumItemBytes, availableBytes)
        guard grantedBytes >= minimumLeaseBytes else { return nil }

        let identifier = UUID()
        state.reservations[identifier] = grantedBytes
        folders[folderKey] = state
        return Lease(
            identifier: identifier,
            folderKey: folderKey,
            maximumBytes: grantedBytes
        )
    }

    func finish(_ lease: Lease, transferredBytes: Int) {
        guard var state = folders[lease.folderKey],
              let reservedBytes = state.reservations.removeValue(
                  forKey: lease.identifier
              ) else { return }
        state.transferredBytes += min(max(transferredBytes, 0), reservedBytes)
        folders[lease.folderKey] = state
    }

    func transferredBytes(for item: RemoteFileItem) -> Int {
        folders[Self.folderKey(for: item)]?.transferredBytes ?? 0
    }

    func reset() {
        // Completed traffic belongs to the previous user-initiated session,
        // but active reservations stay charged. Otherwise an old transfer and
        // the new session could exceed the folder traffic ceiling together.
        folders = folders.compactMapValues { state in
            guard !state.reservations.isEmpty else { return nil }
            return FolderState(
                transferredBytes: 0,
                reservations: state.reservations
            )
        }
    }

    private static func folderKey(for item: RemoteFileItem) -> String {
        let parentPath = (item.path as NSString).deletingLastPathComponent
        return "\(item.connectionID.uuidString)|\(parentPath)"
    }
}
