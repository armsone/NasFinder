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

enum CompatibilityVideoThumbnailAttemptPolicy {
    static let seekFallbackDelay: Duration = .seconds(2)
    static let seekWarmupDelay: Duration = .seconds(1)

    static func usesPlayerSnapshotFirst(for connectionKind: ConnectionKind) -> Bool {
        false
    }
}

enum CompatibilityExternalSubtitlePolicy {
    private static let preferredExtensions = [
        "srt", "ass", "ssa", "vtt", "smi", "sub",
    ]

    static func matchingSubtitle(
        for video: RemoteFileItem,
        in items: [RemoteFileItem]
    ) -> RemoteFileItem? {
        guard video.isVideo else { return nil }
        let videoBaseName = deletingPathExtension(video.name)
        let videoDirectory = (video.path as NSString).deletingLastPathComponent

        return preferredExtensions.lazy.compactMap { subtitleExtension in
            items.first { candidate in
                !candidate.isDirectory
                    && candidate.id != video.id
                    && (candidate.path as NSString).deletingLastPathComponent
                        == videoDirectory
                    && (candidate.name as NSString).pathExtension
                        .caseInsensitiveCompare(subtitleExtension) == .orderedSame
                    && deletingPathExtension(candidate.name)
                        .caseInsensitiveCompare(videoBaseName) == .orderedSame
            }
        }.first
    }

    private static func deletingPathExtension(_ filename: String) -> String {
        (filename as NSString).deletingPathExtension
    }
}

enum CompatibilityVideoPlayerError: LocalizedError {
    case invalidRemoteFileSize
    case cannotCreateMedia
    case remoteReadFailed
    case remoteReadTimedOut

    var errorDescription: String? {
        switch self {
        case .invalidRemoteFileSize:
            "원격 영상의 파일 크기를 확인할 수 없습니다."
        case .cannotCreateMedia:
            "호환 영상 소스를 열 수 없습니다."
        case .remoteReadFailed:
            "호환 영상을 원격 위치에서 읽지 못했습니다."
        case .remoteReadTimedOut:
            "원격 영상 데이터 응답 시간이 초과되었습니다."
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

    static let maximumReadChunkBytes = 1_024 * 1_024
    static let maximumCachedBytes = 2 * 1_024 * 1_024
    static let remoteReadTimeout: TimeInterval = 8

    private let item: RemoteFileItem
    private let service: any RemoteFileService
    private let maximumTransferredBytes: Int?
    private let onTransfer: (@Sendable (Int) -> Void)?
    private let rangeReadTimeout: TimeInterval
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
        maximumTransferredBytes: Int? = nil,
        onTransfer: (@Sendable (Int) -> Void)? = nil,
        rangeReadTimeout: TimeInterval = CompatibilityRemoteInputStream.remoteReadTimeout
    ) throws {
        guard item.size.map({ $0 > 0 }) == true else {
            throw CompatibilityVideoPlayerError.invalidRemoteFileSize
        }
        self.item = item
        self.service = service
        self.maximumTransferredBytes = maximumTransferredBytes
        self.onTransfer = onTransfer
        self.rangeReadTimeout = rangeReadTimeout
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
            max(len, 64 * 1_024),
            Self.maximumReadChunkBytes,
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
            length: preferredLength,
            timeout: rangeReadTimeout
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
            let currentTransferredBytes = transferredBytes
            store(data, at: readOffset)
            let returned = min(len, data.count)
            offset += Int64(returned)
            if data.isEmpty { status = .atEnd }
            lock.unlock()
            onTransfer?(currentTransferredBytes)
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
        length: Int,
        timeout: TimeInterval
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
        let deadline = Date(timeIntervalSinceNow: timeout)
        while result == nil && !isCancelled {
            if !condition.wait(until: deadline), result == nil {
                isCancelled = true
            }
        }
        let timedOut = result == nil && isCancelled
        let activeTask = task
        let finalResult = result ?? .failure(
            timedOut
                ? CompatibilityVideoPlayerError.remoteReadTimedOut
                : CancellationError()
        )
        task = nil
        condition.unlock()
        if timedOut { activeTask?.cancel() }
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
final class CompatibilityPlaybackWatchdog {
    private var task: Task<Void, Never>?

    func start(
        stallTimeout: Duration,
        pollInterval: Duration,
        isPlaybackExpected: @escaping @MainActor () -> Bool,
        currentSeconds: @escaping @MainActor () -> Double,
        onStall: @escaping @MainActor () -> Void
    ) {
        stop()
        task = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            var lastObservedSeconds = currentSeconds()
            var lastProgressAt = clock.now

            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled else { return }

                guard isPlaybackExpected() else {
                    lastObservedSeconds = currentSeconds()
                    lastProgressAt = clock.now
                    continue
                }

                let observedSeconds = currentSeconds()
                if abs(observedSeconds - lastObservedSeconds) >= 0.05 {
                    lastObservedSeconds = observedSeconds
                    lastProgressAt = clock.now
                    continue
                }

                guard lastProgressAt.duration(to: clock.now) >= stallTimeout else {
                    continue
                }
                self?.task = nil
                onStall()
                return
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

private enum CompatibilityVideoPlayerCommandExecutor {
    private static let queue = DispatchQueue(
        label: "com.armsone.nasfinder.vlc-player-commands",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func play(_ player: VLCMediaPlayer) -> CompatibilityVideoPlayerCommand {
        let command = CompatibilityVideoPlayerCommand(player: player, action: .play)
        queue.async { command.execute() }
        return command
    }

    static func stop(_ player: VLCMediaPlayer) {
        let command = CompatibilityVideoPlayerCommand(player: player, action: .stop)
        queue.async { command.execute() }
    }
}

private final class CompatibilityVideoPlayerCommand: @unchecked Sendable {
    enum Action {
        case play
        case stop
    }

    private let player: VLCMediaPlayer
    private let action: Action
    private let lock = NSLock()
    private var isCancelled = false

    init(player: VLCMediaPlayer, action: Action) {
        self.player = player
        self.action = action
    }

    func execute() {
        lock.lock()
        let shouldExecute = !isCancelled
        lock.unlock()
        guard shouldExecute else { return }

        switch action {
        case .play:
            player.play()
        case .stop:
            player.stop()
        }
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
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
    private var pendingPlayCommand: CompatibilityVideoPlayerCommand?

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

    init(
        item: RemoteFileItem,
        service: any RemoteFileService,
        onTransfer: (@Sendable (Int) -> Void)? = nil
    ) throws {
        let inputStream = try CompatibilityRemoteInputStream(
            item: item,
            service: service,
            onTransfer: onTransfer
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
        pendingPlayCommand?.cancel()
        pendingPlayCommand = CompatibilityVideoPlayerCommandExecutor.play(mediaPlayer)
    }

    func pause() {
        mediaPlayer.pause()
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        mediaPlayer.time = VLCTime(number: NSNumber(value: seconds * 1_000))
        currentSeconds = seconds
    }

    @discardableResult
    func addExternalSubtitle(at url: URL) -> Bool {
        mediaPlayer.addPlaybackSlave(
            url,
            type: .subtitle,
            enforce: true
        ) == 0
    }

    func stop() {
        guard !isStopping else { return }
        isStopping = true
        pendingPlayCommand?.cancel()
        pendingPlayCommand = nil
        mediaPlayer.delegate = nil
        // VLC waits for its synchronous input callback to return while stopping.
        // Cancel a blocked NAS range read first so dismissal never waits for the
        // remote timeout on the main actor.
        inputStream?.close()
        mediaPlayer.drawable = nil
        CompatibilityVideoPlayerCommandExecutor.stop(mediaPlayer)
    }

    var usesRemoteStream: Bool { inputStream != nil }

    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // VLCKit 4: 0 nothing, 1 opening, 2 playing, 3 paused,
            // 4 stopped, 5 stopping, 6 error.
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
    var sourceLabel: String?
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 5 : 10) {
            Text(formattedTime(player.currentSeconds))
                .frame(width: compact ? 34 : 42, alignment: .trailing)

            VStack(spacing: -4) {
                if let sourceLabel {
                    Text(sourceLabel)
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.48))
                        .lineLimit(1)
                }

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
            }

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
    private static var activeSnapshotOperation:
        CompatibilityVideoPlayerSnapshotOperation?

    static func generate(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        mode: RemoteVideoThumbnailGenerationMode,
        timeout: Duration,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        try await CompatibilityVideoThumbnailExecutionLimiter.shared.withPermit {
            try await generateExclusively(
                for: item,
                service: service,
                size: size,
                trafficBudget: trafficBudget,
                mode: mode,
                timeout: timeout,
                progress: progress
            )
        }
    }

    private static func generateExclusively(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        mode: RemoteVideoThumbnailGenerationMode,
        timeout: Duration,
        progress: (@Sendable (Int64, Int64) -> Void)?
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        guard service.supportsRangeStreaming,
              item.size.map({ $0 > 0 }) == true else {
            throw RemoteVideoThumbnailGenerationError.unsupportedSource
        }
        guard let lease = await trafficBudget.lease(for: item) else {
            throw RemoteVideoThumbnailGenerationError.trafficBudgetExhausted
        }

        var stream: CompatibilityRemoteInputStream?
        var localURL: URL?
        var transferredBytes = 0
        var priorStreamBytes = 0
        let clock = ContinuousClock()
        var deadline = clock.now.advanced(by: timeout)
        func remainingGenerationTime() throws -> Duration {
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else {
                throw RemoteVideoThumbnailGenerationError.timedOut
            }
            return remaining
        }
        func makeStream(
            maximumBytes: Int,
            baseTransferredBytes: Int
        ) throws -> CompatibilityRemoteInputStream {
            try CompatibilityRemoteInputStream(
                item: item,
                service: service,
                maximumTransferredBytes: maximumBytes,
                onTransfer: { streamBytes in
                    progress?(
                        Int64(baseTransferredBytes + streamBytes),
                        Int64(lease.maximumBytes)
                    )
                }
            )
        }
        defer {
            if let localURL {
                try? FileManager.default.removeItem(at: localURL)
            }
        }
        do {
            if mode == .completeFile {
                let fastPassLimit = min(64 * 1_024 * 1_024, lease.maximumBytes)
                let fastStream = try makeStream(
                    maximumBytes: fastPassLimit,
                    baseTransferredBytes: 0
                )
                stream = fastStream
                if let fastMedia = VLCMedia(stream: fastStream) {
                    let fastOperation = CompatibilityVideoThumbnailOperation()
                    activeOperation = fastOperation
                    do {
                        let fastImage = try await fastOperation.generate(
                            media: fastMedia,
                            stream: fastStream,
                            dimensions: maximumDimensions(for: size),
                            snapshotPosition: 0.3,
                            preciseSeek: true,
                            closesStreamOnSuccess: true,
                            timeout: min(try remainingGenerationTime(), .seconds(20))
                        )
                        if activeOperation === fastOperation { activeOperation = nil }
                        let fastBytes = fastStream.accountedByteCount
                        if !RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(fastImage) {
                            let data = try jpegData(from: fastImage)
                            transferredBytes = fastBytes
                            await trafficBudget.finish(
                                lease,
                                transferredBytes: transferredBytes
                            )
                            return RemoteVideoThumbnailGenerationResult(
                                data: data,
                                transferredBytes: transferredBytes,
                                mediaDurationSeconds: mediaDurationSeconds(
                                    from: fastMedia
                                ),
                                processingPath: .compatibilityRange
                            )
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // Escalate to the guaranteed local-file pass below.
                    }
                }
                if activeOperation != nil { activeOperation = nil }
                priorStreamBytes = fastStream.accountedByteCount
                fastStream.close()
                stream = nil
            }

            let media: VLCMedia?
            if mode != .completeFile,
               let fileSize = item.size,
               fileSize <= Int64(lease.maximumBytes),
               fileSize <= Int64(Int.max) {
                let data = try await service.readRange(
                    of: item,
                    offset: 0,
                    length: Int(fileSize)
                )
                try Task.checkCancellation()
                guard !data.isEmpty else {
                    throw CompatibilityVideoPlayerError.remoteReadFailed
                }
                transferredBytes = data.count
                let url = FileManager.default.temporaryDirectory
                    .appending(path: UUID().uuidString)
                    .appendingPathExtension(
                        (item.name as NSString).pathExtension.lowercased()
                    )
                try data.write(to: url, options: .atomic)
                localURL = url
                media = VLCMedia(url: url)
            } else {
                let remainingBytes = max(
                    lease.maximumBytes - priorStreamBytes,
                    0
                )
                guard remainingBytes > 0 else {
                    throw RemoteVideoThumbnailGenerationError
                        .itemTrafficLimitReached
                }
                let remoteStream = try makeStream(
                    maximumBytes: remainingBytes,
                    baseTransferredBytes: priorStreamBytes
                )
                stream = remoteStream
                media = VLCMedia(stream: remoteStream)
            }
            guard let media else {
                throw CompatibilityVideoPlayerError.cannotCreateMedia
            }
            if localURL != nil {
                // Network transfer and local decoding are separate phases.
                // A large download must not consume the time reserved for VLC.
                deadline = clock.now.advanced(by: .seconds(95))
            }
            let dimensions = maximumDimensions(for: size)
            let initialPosition: Float = 0.3
            let preciseSeekTimeout = min(timeout, .seconds(14))
            let initialOperation = CompatibilityVideoThumbnailOperation()
            defer {
                if activeOperation === initialOperation { activeOperation = nil }
            }
            let initialImage: CGImage
            do {
                if localURL != nil
                    || CompatibilityVideoThumbnailAttemptPolicy.usesPlayerSnapshotFirst(
                        for: service.connection.kind
                    ) {
                    let snapshotOperation =
                        CompatibilityVideoPlayerSnapshotOperation()
                    activeSnapshotOperation = snapshotOperation
                    defer {
                        if activeSnapshotOperation === snapshotOperation {
                            activeSnapshotOperation = nil
                        }
                    }
                    initialImage = try await snapshotOperation.generate(
                        media: media,
                        stream: stream,
                        dimensions: dimensions,
                        position: initialPosition,
                        timeout: min(
                            try remainingGenerationTime(),
                            localURL == nil ? .seconds(14) : .seconds(20)
                        )
                    )
                } else {
                    activeOperation = initialOperation
                    initialImage = try await initialOperation.generate(
                        media: media,
                        stream: stream,
                        dimensions: dimensions,
                        snapshotPosition: initialPosition,
                        preciseSeek: true,
                        closesStreamOnSuccess: false,
                        timeout: preciseSeekTimeout
                    )
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try Task.checkCancellation()
                if activeOperation === initialOperation { activeOperation = nil }
                let fallbackMedia: VLCMedia?
                if let localURL {
                    fallbackMedia = VLCMedia(url: localURL)
                } else {
                    if let stream {
                        priorStreamBytes += stream.accountedByteCount
                        stream.close()
                    }
                    let remainingBytes = max(
                        lease.maximumBytes - priorStreamBytes,
                        0
                    )
                    guard remainingBytes > 0 else { throw error }
                    let freshStream = try makeStream(
                        maximumBytes: remainingBytes,
                        baseTransferredBytes: priorStreamBytes
                    )
                    stream = freshStream
                    fallbackMedia = VLCMedia(stream: freshStream)
                }
                guard let fallbackMedia else { throw error }
                let fallbackOperation = CompatibilityVideoThumbnailOperation()
                activeOperation = fallbackOperation
                defer {
                    if activeOperation === fallbackOperation {
                        activeOperation = nil
                    }
                }
                do {
                    let fallbackTimeout = min(
                        try remainingGenerationTime(),
                        localURL == nil ? .seconds(12) : .seconds(25)
                    )
                    initialImage = try await fallbackOperation.generate(
                        media: fallbackMedia,
                        stream: stream,
                        dimensions: dimensions,
                        snapshotPosition: initialPosition,
                        preciseSeek: false,
                        closesStreamOnSuccess: false,
                        timeout: fallbackTimeout
                    )
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    try Task.checkCancellation()
                    if activeOperation === fallbackOperation {
                        activeOperation = nil
                    }
                    if let localURL {
                        guard let recoveryMedia = VLCMedia(url: localURL) else {
                            throw error
                        }
                        let recoveryOperation = CompatibilityVideoThumbnailOperation()
                        activeOperation = recoveryOperation
                        defer {
                            if activeOperation === recoveryOperation {
                                activeOperation = nil
                            }
                        }
                        do {
                            initialImage = try await recoveryOperation.generate(
                                media: recoveryMedia,
                                stream: nil,
                                dimensions: dimensions,
                                snapshotPosition: 0.65,
                                preciseSeek: false,
                                closesStreamOnSuccess: true,
                                timeout: min(
                                    try remainingGenerationTime(),
                                    .seconds(25)
                                )
                            )
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            if activeOperation === recoveryOperation {
                                activeOperation = nil
                            }
                            guard let sequentialMedia = VLCMedia(url: localURL) else {
                                throw error
                            }
                            let sequentialSnapshot =
                                CompatibilityVideoPlayerSnapshotOperation()
                            activeSnapshotOperation = sequentialSnapshot
                            defer {
                                if activeSnapshotOperation === sequentialSnapshot {
                                    activeSnapshotOperation = nil
                                }
                            }
                            initialImage = try await sequentialSnapshot.generate(
                                media: sequentialMedia,
                                stream: nil,
                                dimensions: dimensions,
                                position: 0,
                                timeout: min(
                                    try remainingGenerationTime(),
                                    .seconds(20)
                                )
                            )
                        }
                    } else {
                        guard service.connection.kind == .synology else {
                            throw error
                        }
                        if let stream {
                            priorStreamBytes += stream.accountedByteCount
                            stream.close()
                        }
                        let remainingBytes = max(
                            lease.maximumBytes - priorStreamBytes,
                            0
                        )
                        guard remainingBytes > 0 else { throw error }
                        let freshStream = try makeStream(
                            maximumBytes: remainingBytes,
                            baseTransferredBytes: priorStreamBytes
                        )
                        stream = freshStream
                        guard let snapshotMedia = VLCMedia(stream: freshStream) else {
                            throw error
                        }
                        let snapshotOperation =
                            CompatibilityVideoPlayerSnapshotOperation()
                        activeSnapshotOperation = snapshotOperation
                        defer {
                            if activeSnapshotOperation === snapshotOperation {
                                activeSnapshotOperation = nil
                            }
                        }
                        initialImage = try await snapshotOperation.generate(
                            media: snapshotMedia,
                            stream: freshStream,
                            dimensions: dimensions,
                            position: initialPosition,
                            timeout: try remainingGenerationTime()
                        )
                    }
                }
            }
            if activeOperation === initialOperation { activeOperation = nil }
            if let stream {
                transferredBytes = priorStreamBytes + stream.accountedByteCount
            }

            var image = initialImage
            if RemoteVideoThumbnailQuality.isAtLeast50PercentBlack(initialImage) {
                let transferredBeforeRetry = transferredBytes
                let retryMedia: VLCMedia?
                let retryStream: CompatibilityRemoteInputStream?
                if let localURL {
                    retryMedia = VLCMedia(url: localURL)
                    retryStream = nil
                } else {
                    stream?.close()
                    let remainingBytes = max(
                        lease.maximumBytes - transferredBeforeRetry,
                        0
                    )
                    if remainingBytes > 0 {
                        let freshStream = try makeStream(
                            maximumBytes: remainingBytes,
                            baseTransferredBytes: transferredBeforeRetry
                        )
                        stream = freshStream
                        retryStream = freshStream
                        retryMedia = VLCMedia(stream: freshStream)
                    } else {
                        retryStream = nil
                        retryMedia = nil
                    }
                }

                if let retryMedia {
                    let retryOperation = CompatibilityVideoThumbnailOperation()
                    activeOperation = retryOperation
                    defer {
                        if activeOperation === retryOperation { activeOperation = nil }
                    }
                    do {
                        let retryTimeout = try remainingGenerationTime()
                        image = try await retryOperation.generate(
                            media: retryMedia,
                            stream: retryStream,
                            dimensions: dimensions,
                            snapshotPosition: initialPosition
                                + (1 - initialPosition) / 2,
                            preciseSeek: true,
                            closesStreamOnSuccess: true,
                            timeout: min(preciseSeekTimeout, retryTimeout)
                        )
                    } catch is CancellationError {
                        if let retryStream {
                            transferredBytes = transferredBeforeRetry
                                + retryStream.accountedByteCount
                        }
                        throw CancellationError()
                    } catch {
                        // The first frame is already a valid thumbnail. A
                        // best-effort later seek must not turn that success
                        // into a missing thumbnail.
                        retryStream?.close()
                    }
                    if let retryStream {
                        transferredBytes = transferredBeforeRetry
                            + retryStream.accountedByteCount
                    }
                }
            } else {
                stream?.close()
            }
            let data = try jpegData(from: image)
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            return RemoteVideoThumbnailGenerationResult(
                data: data,
                transferredBytes: transferredBytes,
                mediaDurationSeconds: mediaDurationSeconds(from: media),
                processingPath: localURL == nil
                    ? .compatibilityRange
                    : .compatibilityLocalFile
            )
        } catch {
            stream?.close()
            if let stream {
                transferredBytes = max(
                    transferredBytes,
                    priorStreamBytes + stream.accountedByteCount
                )
            }
            await trafficBudget.finish(lease, transferredBytes: transferredBytes)
            if mode == .completeFile,
               let generationError = error as? RemoteVideoThumbnailGenerationError {
                if case .trafficBudgetExhausted = generationError {
                    throw RemoteVideoThumbnailGenerationError
                        .itemTrafficLimitReached
                }
            }
            throw error
        }
    }

    private static func mediaDurationSeconds(from media: VLCMedia) -> TimeInterval? {
        let milliseconds = media.length.value?.doubleValue ?? 0
        guard milliseconds.isFinite, milliseconds > 0 else { return nil }
        return milliseconds / 1_000
    }

    static func cancelAll() async {
        await CompatibilityVideoThumbnailExecutionLimiter.shared.cancelWaitingOperations()
        activeOperation?.cancel()
        activeSnapshotOperation?.cancel()
        while activeOperation != nil || activeSnapshotOperation != nil {
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
private final class CompatibilityVideoPlayerSnapshotOperation {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var player: VLCMediaPlayer?
    private var stream: CompatibilityRemoteInputStream?
    private var pollingTask: Task<Void, Never>?
    private var drawable: UIView?
    private var snapshotURL: URL?
    private var isFinished = false

    func generate(
        media: VLCMedia,
        stream: CompatibilityRemoteInputStream?,
        dimensions: CGSize,
        position: Float,
        timeout: Duration
    ) async throws -> CGImage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.stream = stream
                media.addOption(":no-audio")

                let player = VLCMediaPlayer()
                let drawable = UIView(
                    frame: CGRect(
                        x: -max(dimensions.width, 1) - 1,
                        y: 0,
                        width: max(dimensions.width, 1),
                        height: max(dimensions.height, 1)
                    )
                )
                drawable.backgroundColor = .black
                drawable.isUserInteractionEnabled = false
                drawable.accessibilityElementsHidden = true
                let keyWindow = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap(\.windows)
                    .first(where: \.isKeyWindow)
                keyWindow?.addSubview(drawable)
                player.drawable = drawable
                player.media = media
                player.audio?.volume = 0
                self.player = player
                self.drawable = drawable
                if stream == nil {
                    player.play()
                } else {
                    CompatibilityVideoPlayerSnapshotStartExecutor.start(player)
                }

                pollingTask = Task { @MainActor [weak self] in
                    await self?.capture(
                        dimensions: dimensions,
                        position: position,
                        timeout: timeout
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    private func capture(
        dimensions: CGSize,
        position: Float,
        timeout: Duration
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var didSeek = false
        var didRequestSnapshot = false
        let targetPosition = Double(position)
        var playbackStartedAt: ContinuousClock.Instant?

        while clock.now < deadline, !Task.isCancelled {
            guard let player else { return }
            player.audio?.volume = 0
            if player.state.rawValue == 6 {
                finish(
                    .failure(RemoteVideoThumbnailGenerationError.imageGenerationFailed)
                )
                return
            }
            if player.isPlaying {
                if playbackStartedAt == nil {
                    playbackStartedAt = clock.now
                }
                let playbackElapsed = playbackStartedAt.map {
                    $0.duration(to: clock.now)
                } ?? .zero
                let canSeek = (player.media?.length.value?.doubleValue ?? 0) > 0
                    && playbackElapsed
                        >= CompatibilityVideoThumbnailAttemptPolicy.seekWarmupDelay
                if canSeek,
                   !didRequestSnapshot,
                   !didSeek {
                    player.position = targetPosition
                    didSeek = true
                }
                let reachedTarget = didSeek
                    && player.position >= max(targetPosition - 0.04, 0)
                let seekFallbackElapsed = playbackStartedAt.map {
                    $0.duration(to: clock.now)
                        >= CompatibilityVideoThumbnailAttemptPolicy.seekFallbackDelay
                } ?? false
                if !didRequestSnapshot,
                   reachedTarget || seekFallbackElapsed {
                    let url = FileManager.default.temporaryDirectory
                        .appending(path: UUID().uuidString)
                        .appendingPathExtension("png")
                    snapshotURL = url
                    didRequestSnapshot = true
                    player.saveVideoSnapshot(
                        at: url.path,
                        withWidth: Int32(max(dimensions.width, 1)),
                        andHeight: Int32(max(dimensions.height, 1))
                    )
                }
            }
            if didRequestSnapshot,
               let snapshotURL,
               let image = UIImage(contentsOfFile: snapshotURL.path)?.cgImage {
                finish(.success(image))
                return
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        finish(.failure(RemoteVideoThumbnailGenerationError.timedOut))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        guard !isFinished else { return }
        isFinished = true
        let continuation = continuation
        self.continuation = nil
        pollingTask?.cancel()
        pollingTask = nil
        let streamToClose = stream
        self.stream = nil
        streamToClose?.close()
        player?.audio?.volume = 0
        player?.drawable = nil
        let playerToDispose = player
        self.player = nil
        drawable?.removeFromSuperview()
        drawable = nil
        if let snapshotURL {
            try? FileManager.default.removeItem(at: snapshotURL)
        }
        snapshotURL = nil
        continuation?.resume(with: result)
        if let playerToDispose {
            CompatibilityVideoPlayerSnapshotCleanupExecutor.dispose(
                playerToDispose
            )
        }
    }
}

private enum CompatibilityVideoPlayerSnapshotStartExecutor {
    private static let queue = DispatchQueue(
        label: "com.armsone.nasfinder.vlc-thumbnail-player-start",
        qos: .utility
    )

    static func start(_ player: VLCMediaPlayer) {
        let resource = CompatibilityVideoPlayerSnapshotStartResource(player)
        queue.async {
            resource.play()
        }
    }
}

private final class CompatibilityVideoPlayerSnapshotStartResource:
    @unchecked Sendable
{
    private let player: VLCMediaPlayer

    init(_ player: VLCMediaPlayer) {
        self.player = player
    }

    func play() {
        player.play()
    }
}

@MainActor
private final class CompatibilityVideoThumbnailOperation:
    NSObject,
    VLCMediaThumbnailerDelegate
{
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var thumbnailer: VLCMediaThumbnailer?
    private var stream: CompatibilityRemoteInputStream?
    private var timeoutTask: Task<Void, Never>?
    private var closesStreamOnSuccess = true
    private var isFinished = false

    func generate(
        media: VLCMedia,
        stream: CompatibilityRemoteInputStream?,
        dimensions: CGSize,
        snapshotPosition: Float,
        preciseSeek: Bool,
        closesStreamOnSuccess: Bool,
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
                self.closesStreamOnSuccess = closesStreamOnSuccess
                let thumbnailer = VLCMediaThumbnailer(
                    media: media,
                    andDelegate: self
                )
                thumbnailer.thumbnailWidth = max(dimensions.width, 1)
                thumbnailer.thumbnailHeight = max(dimensions.height, 1)
                thumbnailer.snapshotPosition = snapshotPosition
                thumbnailer.preciseSeek = preciseSeek
                thumbnailer.cropsToFit = false
                self.thumbnailer = thumbnailer
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
                CompatibilityVideoThumbnailFetchExecutor.fetch(thumbnailer)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancel(with: CancellationError())
            }
        }
    }

    nonisolated func mediaThumbnailerDidTimeOut(
        _ mediaThumbnailer: VLCMediaThumbnailer
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.cancel(
                with: RemoteVideoThumbnailGenerationError.imageGenerationFailed
            )
        }
    }

    nonisolated func mediaThumbnailer(
        _ mediaThumbnailer: VLCMediaThumbnailer,
        didFinishThumbnail thumbnail: CGImage
    ) {
        DispatchQueue.main.async { [weak self] in
            self?.finish(.success(thumbnail))
        }
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
        thumbnailer?.delegate = nil
        let thumbnailer = thumbnailer
        let stream = stream
        self.thumbnailer = nil
        self.stream = nil
        timeoutTask?.cancel()

        guard let thumbnailer else {
            stream?.close()
            continuation?.resume(with: result)
            return
        }
        let shouldCancel: Bool
        if case .failure = result {
            shouldCancel = true
        } else {
            shouldCancel = false
        }
        continuation?.resume(with: result)
        CompatibilityVideoThumbnailCleanupExecutor.dispose(
            thumbnailer: thumbnailer,
            stream: shouldCancel || closesStreamOnSuccess ? stream : nil,
            cancel: shouldCancel
        )
    }
}

private enum CompatibilityVideoThumbnailFetchExecutor {
    private static let queue = DispatchQueue(
        label: "com.armsone.nasfinder.vlc-thumbnail-fetch",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func fetch(_ thumbnailer: VLCMediaThumbnailer) {
        let resource = CompatibilityVideoThumbnailFetchResource(thumbnailer)
        queue.async { resource.fetch() }
    }
}

private final class CompatibilityVideoThumbnailFetchResource: @unchecked Sendable {
    private let thumbnailer: VLCMediaThumbnailer

    init(_ thumbnailer: VLCMediaThumbnailer) {
        self.thumbnailer = thumbnailer
    }

    func fetch() {
        thumbnailer.fetchThumbnail()
    }
}

private enum CompatibilityVideoPlayerSnapshotCleanupExecutor {
    private static let queue = DispatchQueue(
        label: "com.armsone.nasfinder.vlc-snapshot-cleanup",
        qos: .utility,
        attributes: .concurrent
    )

    static func dispose(_ player: VLCMediaPlayer) {
        let resource = CompatibilityVideoPlayerSnapshotCleanupResource(player)
        queue.async { resource.dispose() }
    }
}

private final class CompatibilityVideoPlayerSnapshotCleanupResource:
    @unchecked Sendable
{
    private var player: VLCMediaPlayer?

    init(_ player: VLCMediaPlayer) {
        self.player = player
    }

    func dispose() {
        player?.audio?.volume = 0
        player?.stop()
        player = nil
    }
}

private enum CompatibilityVideoThumbnailCleanupExecutor {
    private static let queue = DispatchQueue(
        label: CompatibilityVideoThumbnailPlaybackPolicy.cleanupQueueLabel,
        qos: .utility,
        attributes: .concurrent
    )

    static func dispose(
        thumbnailer: VLCMediaThumbnailer,
        stream: CompatibilityRemoteInputStream?,
        cancel: Bool
    ) {
        let resources = CompatibilityVideoThumbnailCleanupResources(
            thumbnailer: thumbnailer,
            stream: stream
        )
        queue.async {
            resources.dispose(cancel: cancel)
        }
    }
}

private final class CompatibilityVideoThumbnailCleanupResources: @unchecked Sendable {
    private var thumbnailer: VLCMediaThumbnailer?
    private var stream: CompatibilityRemoteInputStream?

    init(
        thumbnailer: VLCMediaThumbnailer,
        stream: CompatibilityRemoteInputStream?
    ) {
        self.thumbnailer = thumbnailer
        self.stream = stream
    }

    func dispose(cancel: Bool) {
        if cancel {
            stream?.close()
            thumbnailer?.cancel()
        }
        thumbnailer = nil
        if !cancel { stream?.close() }
        stream = nil
    }
}

enum CompatibilityVideoThumbnailPlaybackPolicy {
    static let usesDedicatedThumbnailer = true
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
