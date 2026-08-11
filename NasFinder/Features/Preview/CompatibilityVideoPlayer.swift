@preconcurrency import Foundation
import SwiftUI
import UIKit
import ImageIO
import UniformTypeIdentifiers
@preconcurrency import VLCKit

enum CompatibilityVideoFormatPolicy {
    private static let preferredExtensions: Set<String> = [
        "asf", "avi", "flv", "mkv", "ogv", "vob", "webm", "wmv",
    ]

    static func prefersCompatibilityPlayer(for item: RemoteFileItem) -> Bool {
        preferredExtensions.contains(
            (item.name as NSString).pathExtension.lowercased()
        )
    }
}

enum CompatibilityVideoPlayerError: LocalizedError {
    case invalidRemoteFileSize
    case cannotCreateMedia
    case remoteReadFailed

    var errorDescription: String? {
        switch self {
        case .invalidRemoteFileSize:
            "원격 영상의 파일 크기를 확인할 수 없습니다."
        case .cannotCreateMedia:
            "호환 영상 소스를 열 수 없습니다."
        case .remoteReadFailed:
            "호환 영상을 원격 위치에서 읽지 못했습니다."
        }
    }
}

/// A seekable NSInputStream backed by RemoteFileService byte ranges. VLCKit
/// performs synchronous reads, so each bounded async range request is bridged
/// on VLC's input thread. The most recent ranges are retained in a small cache
/// to avoid charging repeated demux probes to the network.
final class CompatibilityRemoteInputStream: InputStream, @unchecked Sendable {
    private struct CacheEntry {
        let offset: Int64
        let data: Data

        var endOffset: Int64 { offset + Int64(data.count) }
    }

    static let maximumReadChunkBytes = 512 * 1_024
    static let maximumCachedBytes = 2 * 1_024 * 1_024

    private let item: RemoteFileItem
    private let service: any RemoteFileService
    private let maximumTransferredBytes: Int?
    private let lock = NSLock()
    private var status: Stream.Status = .notOpen
    private var storedError: Error?
    private var offset: Int64 = 0
    private var cache: [CacheEntry] = []
    private var transferredBytes = 0
    private var activeRead: BlockingRemoteRangeRead?

    init(
        item: RemoteFileItem,
        service: any RemoteFileService,
        maximumTransferredBytes: Int? = nil
    ) throws {
        guard item.size.map({ $0 > 0 }) == true else {
            throw CompatibilityVideoPlayerError.invalidRemoteFileSize
        }
        self.item = item
        self.service = service
        self.maximumTransferredBytes = maximumTransferredBytes
        super.init(data: Data())
    }

    override func open() {
        lock.lock()
        if status == .notOpen { status = .open }
        lock.unlock()
    }

    override func close() {
        lock.lock()
        status = .closed
        let read = activeRead
        activeRead = nil
        lock.unlock()
        read?.cancel()
    }

    override var streamStatus: Stream.Status {
        lock.lock()
        defer { lock.unlock() }
        return status
    }

    override var streamError: Error? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    override var hasBytesAvailable: Bool {
        lock.lock()
        defer { lock.unlock() }
        return status == .open && offset < (item.size ?? 0)
    }

    override func read(
        _ buffer: UnsafeMutablePointer<UInt8>,
        maxLength len: Int
    ) -> Int {
        guard len > 0 else { return 0 }

        lock.lock()
        guard status == .open else {
            lock.unlock()
            return -1
        }
        guard let fileSize = item.size, offset < fileSize else {
            status = .atEnd
            lock.unlock()
            return 0
        }
        let readOffset = offset
        if let cached = cachedData(at: readOffset, maximumLength: len) {
            offset += Int64(cached.count)
            lock.unlock()
            cached.copyBytes(to: buffer, count: cached.count)
            return cached.count
        }

        let remainingBudget = maximumTransferredBytes.map {
            max($0 - transferredBytes, 0)
        }
        guard remainingBudget.map({ $0 > 0 }) != false else {
            storedError = RemoteVideoThumbnailGenerationError.trafficBudgetExhausted
            status = .error
            lock.unlock()
            return -1
        }
        let remainingFileBytes = Int(min(Int64(Int.max), fileSize - readOffset))
        let preferredLength = min(
            max(len, Self.maximumReadChunkBytes),
            remainingFileBytes,
            remainingBudget ?? Int.max
        )
        let blockingRead = BlockingRemoteRangeRead()
        activeRead = blockingRead
        lock.unlock()

        let result = blockingRead.perform(
            service: service,
            item: item,
            offset: readOffset,
            length: preferredLength
        )

        lock.lock()
        if activeRead === blockingRead { activeRead = nil }
        guard status == .open else {
            lock.unlock()
            return -1
        }
        switch result {
        case let .success(data):
            transferredBytes += data.count
            store(data, at: readOffset)
            let returned = min(len, data.count)
            offset += Int64(returned)
            if data.isEmpty { status = .atEnd }
            lock.unlock()
            if returned > 0 {
                data.copyBytes(to: buffer, count: returned)
            }
            return returned
        case let .failure(error):
            storedError = RemoteRequestCancellation.normalized(error)
            status = .error
            lock.unlock()
            return -1
        }
    }

    override func getBuffer(
        _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>,
        length len: UnsafeMutablePointer<Int>
    ) -> Bool {
        false
    }

    override func property(forKey key: Stream.PropertyKey) -> Any? {
        guard key == .fileCurrentOffsetKey else { return nil }
        lock.lock()
        defer { lock.unlock() }
        return NSNumber(value: offset)
    }

    override func setProperty(_ property: Any?, forKey key: Stream.PropertyKey) -> Bool {
        guard key == .fileCurrentOffsetKey,
              let number = property as? NSNumber,
              let fileSize = item.size else { return false }
        let requestedOffset = number.int64Value
        guard requestedOffset >= 0, requestedOffset <= fileSize else { return false }
        lock.lock()
        offset = requestedOffset
        if status == .atEnd { status = .open }
        lock.unlock()
        return true
    }

    var accountedByteCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return transferredBytes
    }

    private func cachedData(at requestedOffset: Int64, maximumLength: Int) -> Data? {
        guard let entry = cache.last(where: {
            $0.offset <= requestedOffset && requestedOffset < $0.endOffset
        }), let relativeOffset = Int(exactly: requestedOffset - entry.offset) else {
            return nil
        }
        let count = min(maximumLength, entry.data.count - relativeOffset)
        guard count > 0 else { return nil }
        return entry.data.subdata(in: relativeOffset..<(relativeOffset + count))
    }

    private func store(_ data: Data, at storedOffset: Int64) {
        guard !data.isEmpty else { return }
        cache.append(CacheEntry(offset: storedOffset, data: data))
        var cachedBytes = cache.reduce(0) { $0 + $1.data.count }
        while cache.count > 1, cachedBytes > Self.maximumCachedBytes {
            cachedBytes -= cache.removeFirst().data.count
        }
    }
}

private final class BlockingRemoteRangeRead: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<Data, Error>?
    private var task: Task<Void, Never>?
    private var isCancelled = false

    func perform(
        service: any RemoteFileService,
        item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) -> Result<Data, Error> {
        condition.lock()
        task = Task.detached(priority: .userInitiated) { [weak self] in
            let result: Result<Data, Error>
            do {
                result = .success(
                    try await service.readRange(
                        of: item,
                        offset: offset,
                        length: length
                    )
                )
            } catch {
                result = .failure(error)
            }
            self?.finish(result)
        }
        while result == nil && !isCancelled {
            condition.wait()
        }
        let finalResult = result ?? .failure(CancellationError())
        task = nil
        condition.unlock()
        return finalResult
    }

    func cancel() {
        condition.lock()
        isCancelled = true
        let task = task
        condition.broadcast()
        condition.unlock()
        task?.cancel()
    }

    private func finish(_ result: Result<Data, Error>) {
        condition.lock()
        guard self.result == nil else {
            condition.unlock()
            return
        }
        self.result = result
        condition.broadcast()
        condition.unlock()
    }
}

@MainActor
final class CompatibilityVideoPlayer: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    @Published private(set) var currentSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    @Published private(set) var isPreparing = true

    let mediaPlayer: VLCMediaPlayer
    private let inputStream: CompatibilityRemoteInputStream?
    private var didStartPlayback = false
    private var isStopping = false

    var onPlaybackEnded: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?

    init(localURL: URL) throws {
        mediaPlayer = VLCMediaPlayer()
        inputStream = nil
        super.init()
        guard let media = VLCMedia(url: localURL) else {
            throw CompatibilityVideoPlayerError.cannotCreateMedia
        }
        configure(media: media)
    }

    init(item: RemoteFileItem, service: any RemoteFileService) throws {
        let inputStream = try CompatibilityRemoteInputStream(
            item: item,
            service: service
        )
        mediaPlayer = VLCMediaPlayer()
        self.inputStream = inputStream
        super.init()
        guard let media = VLCMedia(stream: inputStream) else {
            throw CompatibilityVideoPlayerError.cannotCreateMedia
        }
        configure(media: media)
    }

    private func configure(media: VLCMedia) {
        mediaPlayer.delegate = self
        mediaPlayer.timeChangeUpdateInterval = 0.1
        mediaPlayer.media = media
    }

    func attach(drawable: UIView) {
        mediaPlayer.drawable = drawable
    }

    func detach(drawable: UIView) {
        guard mediaPlayer.drawable as? UIView === drawable else { return }
        mediaPlayer.drawable = nil
    }

    func play() {
        SharedMediaAudioSession.activatePlayback()
        isStopping = false
        mediaPlayer.play()
    }

    func pause() {
        mediaPlayer.pause()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        mediaPlayer.time = VLCTime(number: NSNumber(value: seconds * 1_000))
        currentSeconds = seconds
    }

    func stop() {
        isStopping = true
        mediaPlayer.delegate = nil
        mediaPlayer.stop()
        inputStream?.close()
        mediaPlayer.drawable = nil
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState.rawValue {
            case 1:
                self.isPreparing = true
            case 2:
                self.didStartPlayback = true
                self.isPreparing = false
                self.onReady?()
            case 4:
                self.isPreparing = false
                if self.didStartPlayback && !self.isStopping {
                    self.didStartPlayback = false
                    self.onPlaybackEnded?()
                }
            case 6:
                self.isPreparing = false
                self.onFailure?("지원하지 않는 코덱이거나 원격 데이터를 읽지 못했습니다.")
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerLengthChanged(_ length: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard length > 0 else { return }
            self?.durationSeconds = Double(length) / 1_000
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let milliseconds = self.mediaPlayer.time.value?.doubleValue ?? 0
            self.currentSeconds = max(milliseconds / 1_000, 0)
            let length = self.mediaPlayer.media?.length.value?.doubleValue ?? 0
            if length > 0 { self.durationSeconds = length / 1_000 }
        }
    }
}

struct CompatibilityVideoPlayerSurface: UIViewRepresentable {
    @ObservedObject var player: CompatibilityVideoPlayer

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        player.attach(drawable: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        player.attach(drawable: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Void) {
        // Player teardown owns final detachment. SwiftUI may dismantle an old
        // surface after a new one has already attached during navigation.
    }
}

struct CompatibilityVideoProgressBar: View {
    @ObservedObject var player: CompatibilityVideoPlayer
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 10) {
            Text(formattedTime(player.currentSeconds))
                .frame(width: compact ? 34 : 42, alignment: .trailing)

            Slider(
                value: Binding(
                    get: { min(player.currentSeconds, sliderMaximum) },
                    set: { player.seek(to: $0) }
                ),
                in: 0...sliderMaximum
            )
            .tint(.white)
            .accessibilityLabel("재생 위치")
            .accessibilityValue(
                "\(formattedTime(player.currentSeconds)) / \(formattedTime(player.durationSeconds))"
            )

            Text(formattedTime(player.durationSeconds))
                .frame(width: compact ? 34 : 42, alignment: .leading)
        }
        .font(.system(size: 11, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, compact ? 8 : 14)
        .frame(height: 44)
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private var sliderMaximum: Double { max(player.durationSeconds, 0.1) }

    private func formattedTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct CompatibilityVideoMiniProgressLine: View {
    @ObservedObject var player: CompatibilityVideoPlayer

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22))
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .accessibilityHidden(true)
    }

    private var progress: CGFloat {
        guard player.durationSeconds > 0 else { return 0 }
        return CGFloat(min(1, max(0, player.currentSeconds / player.durationSeconds)))
    }
}

@MainActor
enum CompatibilityRemoteVideoThumbnailGenerator {
    private static var activeOperation: CompatibilityVideoThumbnailOperation?

    static func generate(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        timeout: Duration
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        try await CompatibilityVideoThumbnailExecutionLimiter.shared.withPermit {
            try await generateExclusively(
                for: item,
                service: service,
                size: size,
                trafficBudget: trafficBudget,
                timeout: timeout
            )
        }
    }

    private static func generateExclusively(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        timeout: Duration
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        guard service.supportsRangeStreaming,
              item.size.map({ $0 > 0 }) == true else {
            throw RemoteVideoThumbnailGenerationError.unsupportedSource
        }
        guard let lease = await trafficBudget.lease(for: item) else {
            throw RemoteVideoThumbnailGenerationError.trafficBudgetExhausted
        }

        let stream: CompatibilityRemoteInputStream
        do {
            stream = try CompatibilityRemoteInputStream(
                item: item,
                service: service,
                maximumTransferredBytes: lease.maximumBytes
            )
        } catch {
            await trafficBudget.finish(lease, transferredBytes: 0)
            throw error
        }

        do {
            guard let media = VLCMedia(stream: stream) else {
                throw CompatibilityVideoPlayerError.cannotCreateMedia
            }
            let dimensions = maximumDimensions(for: size)
            let operation = CompatibilityVideoThumbnailOperation()
            activeOperation = operation
            defer {
                if activeOperation === operation { activeOperation = nil }
            }
            let image = try await operation.generate(
                media: media,
                stream: stream,
                dimensions: dimensions,
                timeout: timeout
            )
            let data = try jpegData(from: image)
            let transferredBytes = stream.accountedByteCount
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            return RemoteVideoThumbnailGenerationResult(
                data: data,
                transferredBytes: transferredBytes
            )
        } catch {
            stream.close()
            let transferredBytes = stream.accountedByteCount
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            throw error
        }
    }

    static func cancelAll() async {
        await CompatibilityVideoThumbnailExecutionLimiter.shared.cancelWaitingOperations()
        activeOperation?.cancel()
        while activeOperation != nil {
            await Task.yield()
        }
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
            kCGImageDestinationLossyCompressionQuality: 0.62,
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw RemoteVideoThumbnailGenerationError.imageEncodingFailed
        }
        return data as Data
    }
}

@MainActor
private final class CompatibilityVideoThumbnailOperation:
    NSObject,
    VLCMediaPlayerDelegate
{
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var player: VLCMediaPlayer?
    private var stream: CompatibilityRemoteInputStream?
    private var drawable: UIView?
    private var snapshotURL: URL?
    private var timeoutTask: Task<Void, Never>?
    private var isFinished = false
    private var didScheduleSnapshot = false

    func generate(
        media: VLCMedia,
        stream: CompatibilityRemoteInputStream,
        dimensions: CGSize,
        timeout: Duration
    ) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !isFinished else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                self.stream = stream
                let player = VLCMediaPlayer()
                let drawable = UIView(
                    frame: CGRect(
                        origin: .zero,
                        size: CGSize(
                            width: max(dimensions.width, 1),
                            height: max(dimensions.height, 1)
                        )
                    )
                )
                let snapshotURL = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString)
                    .appendingPathExtension("png")
                player.delegate = self
                player.drawable = drawable
                media.addOption(CompatibilityVideoThumbnailPlaybackPolicy.noAudioOption)
                player.media = media
                player.audio?.isMuted = true
                self.player = player
                self.drawable = drawable
                self.snapshotURL = snapshotURL
                timeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.cancel(
                        with: RemoteVideoThumbnailGenerationError.timedOut
                    )
                }
                player.play()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(with: CancellationError())
            }
        }
    }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            switch newState.rawValue {
            case 2:
                self.scheduleSnapshot()
            case 6:
                self.cancel(
                    with: RemoteVideoThumbnailGenerationError.imageGenerationFailed
                )
            default:
                break
            }
        }
    }

    nonisolated func mediaPlayerSnapshot(_ notification: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.loadSnapshot(attemptsRemaining: 10)
        }
    }

    private func loadSnapshot(attemptsRemaining: Int) {
        guard !isFinished, let snapshotURL else { return }
        if let data = try? Data(contentsOf: snapshotURL),
           !data.isEmpty,
           let image = UIImage(data: data)?.cgImage {
            finish(.success(image))
            return
        }
        guard attemptsRemaining > 0 else {
            cancel(with: RemoteVideoThumbnailGenerationError.imageGenerationFailed)
            return
        }
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.loadSnapshot(attemptsRemaining: attemptsRemaining - 1)
        }
    }

    private func scheduleSnapshot() {
        guard !didScheduleSnapshot else { return }
        didScheduleSnapshot = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            self?.captureSnapshot(attemptsRemaining: 20)
        }
    }

    private func captureSnapshot(attemptsRemaining: Int) {
        guard !isFinished, let player, let snapshotURL else { return }
        guard player.hasVideoOut else {
            guard attemptsRemaining > 0 else {
                cancel(
                    with: RemoteVideoThumbnailGenerationError.imageGenerationFailed
                )
                return
            }
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.captureSnapshot(attemptsRemaining: attemptsRemaining - 1)
            }
            return
        }
        player.saveVideoSnapshot(
            at: snapshotURL.path,
            withWidth: Int32(drawable?.bounds.width ?? 0),
            andHeight: Int32(drawable?.bounds.height ?? 0)
        )
    }

    private func cancel(with error: Error) {
        finish(.failure(error))
    }

    func cancel() {
        cancel(with: CancellationError())
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        let timeoutTask = timeoutTask
        self.timeoutTask = nil
        player?.delegate = nil
        player?.drawable = nil
        let player = player
        let stream = stream
        let snapshotURL = snapshotURL
        self.player = nil
        drawable = nil
        self.stream = nil
        self.snapshotURL = nil
        timeoutTask?.cancel()

        guard let player else {
            if let snapshotURL {
                try? FileManager.default.removeItem(at: snapshotURL)
            }
            continuation?.resume(with: result)
            return
        }
        CompatibilityVideoThumbnailCleanupExecutor.dispose(
            player: player,
            stream: stream,
            snapshotURL: snapshotURL,
            closeStreamFirst: result.requiresRemoteReadCancellation
        ) {
            continuation?.resume(with: result)
        }
    }
}

private enum CompatibilityVideoThumbnailCleanupExecutor {
    private static let queue = DispatchQueue(
        label: CompatibilityVideoThumbnailPlaybackPolicy.cleanupQueueLabel,
        qos: .utility
    )

    static func dispose(
        player: VLCMediaPlayer,
        stream: CompatibilityRemoteInputStream?,
        snapshotURL: URL?,
        closeStreamFirst: Bool,
        completion: @escaping @MainActor () -> Void
    ) {
        let resources = CompatibilityVideoThumbnailCleanupResources(
            player: player,
            stream: stream,
            snapshotURL: snapshotURL
        )
        let completion = CompatibilityVideoThumbnailCleanupCompletion(completion)
        queue.async {
            resources.dispose(closeStreamFirst: closeStreamFirst)
            Task { @MainActor in
                completion.action()
            }
        }
    }
}

private final class CompatibilityVideoThumbnailCleanupResources: @unchecked Sendable {
    private var player: VLCMediaPlayer?
    private var stream: CompatibilityRemoteInputStream?
    private let snapshotURL: URL?

    init(
        player: VLCMediaPlayer,
        stream: CompatibilityRemoteInputStream?,
        snapshotURL: URL?
    ) {
        self.player = player
        self.stream = stream
        self.snapshotURL = snapshotURL
    }

    func dispose(closeStreamFirst: Bool) {
        if closeStreamFirst { stream?.close() }
        player?.stop()
        if !closeStreamFirst { stream?.close() }
        player = nil
        stream = nil
        if let snapshotURL {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
    }
}

private final class CompatibilityVideoThumbnailCleanupCompletion: @unchecked Sendable {
    let action: @MainActor () -> Void

    init(_ action: @escaping @MainActor () -> Void) {
        self.action = action
    }
}

private extension Result where Success == CGImage, Failure == Error {
    var requiresRemoteReadCancellation: Bool {
        guard case let .failure(error) = self else { return false }
        if error is CancellationError { return true }
        guard let generationError = error as? RemoteVideoThumbnailGenerationError else {
            return false
        }
        if case .timedOut = generationError { return true }
        return false
    }
}

enum CompatibilityVideoThumbnailPlaybackPolicy {
    static let noAudioOption = ":no-audio"
    static let maximumConcurrentOperations = 1
    static let cleanupQueueLabel = "com.armsone.nasfinder.vlc-thumbnail-cleanup"
}

private actor CompatibilityVideoThumbnailExecutionLimiter {
    static let shared = CompatibilityVideoThumbnailExecutionLimiter(
        maximumConcurrentWork:
            CompatibilityVideoThumbnailPlaybackPolicy.maximumConcurrentOperations
    )

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private let maximumConcurrentWork: Int
    private var activeWorkCount = 0
    private var waiters: [Waiter] = []

    init(maximumConcurrentWork: Int) {
        self.maximumConcurrentWork = max(maximumConcurrentWork, 1)
    }

    func withPermit<Value: Sendable>(
        _ operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if activeWorkCount < maximumConcurrentWork {
            activeWorkCount += 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancel(waiterID: waiterID) }
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeWorkCount = max(activeWorkCount - 1, 0)
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else {
            return
        }
        waiters.remove(at: index).continuation.resume(
            throwing: CancellationError()
        )
    }

    func cancelWaitingOperations() {
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach {
            $0.continuation.resume(throwing: CancellationError())
        }
    }
}
