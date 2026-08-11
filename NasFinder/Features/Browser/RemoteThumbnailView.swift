import CryptoKit
import ImageIO
import QuickLookThumbnailing
import SwiftUI
import UIKit

@MainActor
final class RemoteThumbnailActivityTracker: ObservableObject {
    static let shared = RemoteThumbnailActivityTracker()

    @Published private(set) var isActive = false
    @Published private(set) var fractionCompleted: Double = 0

    private var activeOperationIDs: Set<UUID> = []
    private var completedCount = 0
    private var totalCount = 0
    private var hideTask: Task<Void, Never>?

    private init() {}

    func begin(_ operationID: UUID) {
        guard activeOperationIDs.insert(operationID).inserted else { return }
        hideTask?.cancel()
        hideTask = nil

        if activeOperationIDs.count == 1 {
            completedCount = 0
            totalCount = 0
            fractionCompleted = 0
        }
        totalCount += 1
        isActive = true
        updateFraction()
    }

    func finish(_ operationID: UUID) {
        guard activeOperationIDs.remove(operationID) != nil else { return }
        completedCount += 1
        updateFraction()

        guard activeOperationIDs.isEmpty else { return }
        fractionCompleted = 1
        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled, self?.activeOperationIDs.isEmpty == true else { return }
            self?.isActive = false
        }
    }

    private func updateFraction() {
        guard totalCount > 0 else {
            fractionCompleted = 0
            return
        }
        fractionCompleted = min(Double(completedCount) / Double(totalCount), 1)
    }
}

enum RemoteThumbnailCacheKey {
    static func remoteData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) -> String {
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(item.id)|\(version)|\(item.size ?? -1)|\(size.rawValue)"
    }

    static func renderedImage(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        displaySize: CGSize,
        scale: CGFloat
    ) -> NSString {
        let pixelWidth = Int((displaySize.width * scale).rounded(.up))
        let pixelHeight = Int((displaySize.height * scale).rounded(.up))
        return "\(remoteData(for: item, size: size))|\(pixelWidth)x\(pixelHeight)" as NSString
    }
}

struct RemoteThumbnailView: View {
    let item: RemoteFileItem
    let service: any RemoteFileService
    let size: CGSize

    @StateObject private var loader = RemoteThumbnailLoader()

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let image = loader.image {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(
                            width: geometry.size.width,
                            height: geometry.size.height
                        )
                        .clipped()
                } else {
                    Image(systemName: item.systemImage)
                        .font(.system(size: min(geometry.size.width, geometry.size.height) * 0.38))
                        .foregroundStyle(
                            item.isDirectory
                                ? SkyBreezeTheme.folderBlue
                                : SkyBreezeTheme.secondaryText
                        )
                }

                if loader.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .task(id: taskIdentity) {
            await loader.load(item: item, service: service, size: size)
        }
    }

    private var taskIdentity: String {
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(item.id)|\(version)|\(item.size ?? -1)|\(size.width)x\(size.height)|\(UIScreen.main.scale)"
    }
}

@MainActor
private final class RemoteThumbnailLoader: ObservableObject {
    @Published var image: UIImage?
    @Published var isLoading = false

    private static let imageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 240
        cache.totalCostLimit = 64 * 1_024 * 1_024
        return cache
    }()
    private static var negativeCacheExpirations: [NSString: Date] = [:]

    private var loadedCacheKey: NSString?
    private var operationID: UUID?

    func load(
        item: RemoteFileItem,
        service: any RemoteFileService,
        size: CGSize
    ) async {
        guard shouldGenerateThumbnail(for: item) else {
            image = nil
            isLoading = false
            return
        }

        let requestedRemoteSize = requestedRemoteSize(for: size)
        let cacheKey = RemoteThumbnailCacheKey.renderedImage(
            for: item,
            size: requestedRemoteSize,
            displaySize: size,
            scale: UIScreen.main.scale
        )
        let diskCacheKey = RemoteThumbnailCacheKey.remoteData(
            for: item,
            size: requestedRemoteSize
        )
        guard loadedCacheKey != cacheKey else { return }
        loadedCacheKey = cacheKey

        if let cachedImage = Self.imageCache.object(forKey: cacheKey) {
            image = cachedImage
            isLoading = false
            return
        }
        var cachedDiskData = await RemoteThumbnailDiskCache.shared.data(forKey: diskCacheKey)
        if cachedDiskData == nil, requestedRemoteSize != .small {
            cachedDiskData = await RemoteThumbnailDiskCache.shared.data(
                forKey: RemoteThumbnailCacheKey.remoteData(for: item, size: .small)
            )
        }
        if let diskData = cachedDiskData,
           let decodedImage = try? await RemoteThumbnailImageDecoder.downsample(
               data: diskData,
               maximumPixelSize: maximumPixelSize(for: size)
           ) {
            try? Task.checkCancellation()
            let diskImage = UIImage(
                cgImage: decodedImage.image,
                scale: UIScreen.main.scale,
                orientation: .up
            )
            image = diskImage
            cache(diskImage, forKey: cacheKey)
            return
        }
        if isNegativelyCached(cacheKey) {
            image = nil
            isLoading = false
            return
        }

        let currentOperationID = UUID()
        operationID = currentOperationID
        image = nil
        isLoading = true
        RemoteThumbnailActivityTracker.shared.begin(currentOperationID)
        defer {
            RemoteThumbnailActivityTracker.shared.finish(currentOperationID)
            if operationID == currentOperationID {
                isLoading = false
                operationID = nil
            }
        }

        let remoteThumbnailData: Data?
        do {
            remoteThumbnailData = try await fetchRemoteThumbnailData(
                item: item,
                service: service,
                size: requestedRemoteSize
            )
        } catch RemoteThumbnailError.optimizedPreviewUnavailable {
            // SFTP video previews deliberately avoid downloading the complete
            // original when a bounded head/tail range is not sufficient.
            // Keep the video icon visible and allow a later reload to retry.
            cacheNegative(cacheKey, for: 5 * 60)
            return
        } catch is CancellationError {
            if operationID == currentOperationID {
                loadedCacheKey = nil
            }
            return
        } catch {
            // Backends may not have a thumbnail for every media format. In
            // that case, fall through to local Quick Look generation.
            if service.connection.kind == .sftp, item.isVideo {
                cacheNegative(cacheKey, for: 60)
                return
            }
            remoteThumbnailData = nil
        }

        if let remoteThumbnailData {
            do {
                let maximumPixelSize = maximumPixelSize(for: size)
                let decodedImage = try await RemoteThumbnailWorkLimiter.shared.withPermit {
                    try await RemoteThumbnailImageDecoder.downsample(
                        data: remoteThumbnailData,
                        maximumPixelSize: maximumPixelSize
                    )
                }
                try Task.checkCancellation()
                guard operationID == currentOperationID else { return }
                let remoteImage = UIImage(
                    cgImage: decodedImage.image,
                    scale: UIScreen.main.scale,
                    orientation: .up
                )
                image = remoteImage
                cache(remoteImage, forKey: cacheKey)
                await RemoteThumbnailDiskCache.shared.store(
                    remoteThumbnailData,
                    forKey: diskCacheKey
                )
                return
            } catch is CancellationError {
                if operationID == currentOperationID {
                    loadedCacheKey = nil
                }
                return
            } catch {
                // A malformed server thumbnail may still have a valid original,
                // except when doing so would require a complete remote movie.
                if item.isVideo, !service.permitsFullDownloadForVideoThumbnail {
                    cacheNegative(cacheKey, for: 5 * 60)
                    return
                }
            }
        } else if item.isVideo, !service.permitsFullDownloadForVideoThumbnail {
            // A remote video thumbnail must remain a bounded request. Never
            // replace a missing optimized result with the complete movie.
            cacheNegative(cacheKey, for: 5 * 60)
            return
        }

        do {
            try Task.checkCancellation()
            let url = try await RemoteThumbnailWorkLimiter.shared.withPermit {
                try await service.download(item)
            }
            try Task.checkCancellation()
            let scale = UIScreen.main.scale
            let generatedImage = try await RemoteThumbnailWorkLimiter.shared.withPermit {
                try await RemoteQuickLookThumbnailGenerator.generate(
                    fileURL: url,
                    size: size,
                    scale: scale
                )
            }
            try Task.checkCancellation()
            guard operationID == currentOperationID else { return }
            image = generatedImage.image
            cache(generatedImage.image, forKey: cacheKey)
            if let generatedThumbnailData = generatedImage.image.jpegData(
                compressionQuality: 0.82
            ) {
                await RemoteThumbnailDiskCache.shared.store(
                    generatedThumbnailData,
                    forKey: diskCacheKey
                )
            }
        } catch is CancellationError {
            if operationID == currentOperationID {
                loadedCacheKey = nil
            }
            return
        } catch {
            // A file icon remains visible when a thumbnail cannot be generated.
            if operationID == currentOperationID {
                cacheNegative(cacheKey, for: 60)
            }
        }
    }

    private func fetchRemoteThumbnailData(
        item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        let attemptCount = item.isVideo
            && service.connection.kind == .synology
            && !service.permitsFullDownloadForVideoThumbnail
            ? 3
            : 1

        var lastError: Error?
        for attempt in 0..<attemptCount {
            do {
                let data = try await RemoteThumbnailWorkLimiter.shared.withPermit {
                    try await service.thumbnailData(for: item, size: size)
                }
                if let data, !data.isEmpty { return data }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }

            if attempt + 1 < attemptCount {
                try await Task.sleep(nanoseconds: 650_000_000)
            }
        }

        if let lastError { throw lastError }
        return nil
    }

    private func shouldGenerateThumbnail(for item: RemoteFileItem) -> Bool {
        item.supportsQuickLookThumbnail
    }

    private func requestedRemoteSize(for size: CGSize) -> RemoteThumbnailSize {
        let maximumPixels = max(size.width, size.height) * UIScreen.main.scale
        if maximumPixels <= 360 { return .small }
        if maximumPixels <= 1_024 { return .medium }
        return .large
    }

    private func maximumPixelSize(for size: CGSize) -> Int {
        let maximumPoints = max(size.width, size.height)
        guard maximumPoints.isFinite, maximumPoints > 0 else { return 1 }
        return max(Int((maximumPoints * UIScreen.main.scale).rounded(.up)), 1)
    }

    private func cache(_ image: UIImage, forKey key: NSString) {
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        let estimatedCost = max(pixelWidth * pixelHeight * 4, 1)
        Self.imageCache.setObject(image, forKey: key, cost: estimatedCost)
        Self.negativeCacheExpirations.removeValue(forKey: key)
    }

    private func isNegativelyCached(_ key: NSString) -> Bool {
        guard let expiration = Self.negativeCacheExpirations[key] else { return false }
        if expiration > Date() { return true }
        Self.negativeCacheExpirations.removeValue(forKey: key)
        return false
    }

    private func cacheNegative(_ key: NSString, for duration: TimeInterval) {
        Self.negativeCacheExpirations[key] = Date().addingTimeInterval(duration)
        if Self.negativeCacheExpirations.count > 240 {
            let now = Date()
            Self.negativeCacheExpirations = Self.negativeCacheExpirations.filter {
                $0.value > now
            }
        }
    }
}

actor RemoteThumbnailDiskCache {
    static let shared = RemoteThumbnailDiskCache()

    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let maximumFileCount = 5_000
    private let maximumTotalBytes: Int64 = 256 * 1_024 * 1_024
    private let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    private var storesSincePrune = 0

    init() {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        directoryURL = baseURL.appendingPathComponent(
            "RemoteThumbnails.v2",
            isDirectory: true
        )
    }

    func data(forKey key: String) -> Data? {
        let url = fileURL(forKey: key)
        guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey]),
              let modificationDate = values.contentModificationDate,
              Date().timeIntervalSince(modificationDate) <= maximumAge else {
            try? fileManager.removeItem(at: url)
            return nil
        }
        return try? Data(contentsOf: url, options: .mappedIfSafe)
    }

    func containsData(forKey key: String) -> Bool {
        data(forKey: key) != nil
    }

    func store(_ data: Data, forKey key: String) {
        guard !data.isEmpty else { return }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(forKey: key), options: .atomic)
            storesSincePrune += 1
            if storesSincePrune >= 25 {
                storesSincePrune = 0
                pruneIfNeeded()
            }
        } catch {
            // Disk caching is an optimization. The in-memory thumbnail remains
            // valid even if the cache directory cannot be written.
        }
    }

    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func pruneIfNeeded() {
        let keys: Set<URLResourceKey> = [
            .contentModificationDateKey,
            .fileSizeKey
        ]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }

        let entries = urls.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (
                url: url,
                modifiedAt: values?.contentModificationDate ?? .distantPast,
                byteCount: Int64(values?.fileSize ?? 0)
            )
        }
        let expirationDate = Date().addingTimeInterval(-maximumAge)
        for entry in entries where entry.modifiedAt < expirationDate {
            try? fileManager.removeItem(at: entry.url)
        }

        var remaining = entries.filter { $0.modifiedAt >= expirationDate }
            .sorted { $0.modifiedAt < $1.modifiedAt }
        var totalBytes = remaining.reduce(Int64(0)) { $0 + $1.byteCount }
        while remaining.count > maximumFileCount || totalBytes > maximumTotalBytes {
            let entry = remaining.removeFirst()
            totalBytes -= entry.byteCount
            try? fileManager.removeItem(at: entry.url)
        }
    }
}

struct RemoteThumbnailSendableCGImage: @unchecked Sendable {
    let image: CGImage
}

/// Decodes server thumbnail bytes away from the main actor and only allocates
/// enough pixels for the current cell. This avoids full-resolution bitmap
/// inflation when a NAS returns an unexpectedly large image.
enum RemoteThumbnailImageDecoder {
    static func downsample(
        data: Data,
        maximumPixelSize: Int
    ) async throws -> RemoteThumbnailSendableCGImage {
        let boundedMaximumPixelSize = max(maximumPixelSize, 1)
        let decodeTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try autoreleasepool {
                let sourceOptions = [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary
                guard let source = CGImageSourceCreateWithData(
                    data as CFData,
                    sourceOptions
                ), CGImageSourceGetCount(source) > 0 else {
                    throw RemoteThumbnailGenerationError.invalidImageData
                }

                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: boundedMaximumPixelSize
                ] as CFDictionary
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions
                ) else {
                    throw RemoteThumbnailGenerationError.cannotCreateThumbnail
                }
                return RemoteThumbnailSendableCGImage(image: thumbnail)
            }
            try Task.checkCancellation()
            return result
        }

        return try await withTaskCancellationHandler {
            try await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
    }
}

private struct RemoteThumbnailSendableUIImage: @unchecked Sendable {
    let image: UIImage
}

private enum RemoteQuickLookThumbnailGenerator {
    static func generate(
        fileURL: URL,
        size: CGSize,
        scale: CGFloat
    ) async throws -> RemoteThumbnailSendableUIImage {
        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: scale,
            representationTypes: .thumbnail
        )
        let operation = RemoteQuickLookThumbnailOperation(request: request)
        return try await operation.value()
    }
}

/// Bridges Quick Look's callback API into structured concurrency. Cancellation
/// both cancels the underlying request and completes the continuation. The
/// lock guarantees that a late Quick Look callback cannot resume it twice.
private final class RemoteQuickLookThumbnailOperation: @unchecked Sendable {
    private let generator = QLThumbnailGenerator.shared
    private let request: QLThumbnailGenerator.Request
    private let lock = NSLock()
    private var continuation: CheckedContinuation<RemoteThumbnailSendableUIImage, Error>?
    private var completedResult: Result<RemoteThumbnailSendableUIImage, Error>?

    init(request: QLThumbnailGenerator.Request) {
        self.request = request
    }

    func value() async throws -> RemoteThumbnailSendableUIImage {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                start(continuation: continuation)
            }
        } onCancel: {
            cancel()
        }
    }

    private func start(
        continuation newContinuation: CheckedContinuation<RemoteThumbnailSendableUIImage, Error>
    ) {
        lock.lock()
        if let completedResult {
            lock.unlock()
            newContinuation.resume(with: completedResult)
            return
        }
        continuation = newContinuation
        lock.unlock()

        generator.generateBestRepresentation(for: request) { [weak self] representation, error in
            guard let self else { return }
            if let image = representation?.uiImage {
                finish(.success(RemoteThumbnailSendableUIImage(image: image)))
            } else {
                finish(.failure(error ?? NasFinderError.invalidResponse))
            }
        }

        // Cancellation can race with the call above. Re-cancel after the
        // request has been submitted so that neither ordering leaks work.
        lock.lock()
        let wasCancelled = completedResult?.isCancellation == true
        lock.unlock()
        if wasCancelled {
            generator.cancel(request)
        }
    }

    private func cancel() {
        generator.cancel(request)
        finish(.failure(CancellationError()))
    }

    private func finish(
        _ result: Result<RemoteThumbnailSendableUIImage, Error>
    ) {
        lock.lock()
        guard completedResult == nil else {
            lock.unlock()
            return
        }
        completedResult = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private extension Result where Success == RemoteThumbnailSendableUIImage, Failure == Error {
    var isCancellation: Bool {
        guard case let .failure(error) = self else { return false }
        return error is CancellationError
    }
}

enum RemoteThumbnailGenerationError: Error, Sendable {
    case invalidImageData
    case cannotCreateThumbnail
}

/// Prevents a thumbnail grid from opening one SSH/HTTP transfer per visible
/// cell at the same time. A small bounded queue is faster on NAS hardware and
/// avoids intermittent failures caused by connection bursts.
private actor RemoteThumbnailWorkLimiter {
    static let shared = RemoteThumbnailWorkLimiter(maximumConcurrentWork: 3)

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
            let waiter = waiters.removeFirst()
            waiter.continuation.resume()
        }
    }

    private func cancel(waiterID: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == waiterID }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }
}
