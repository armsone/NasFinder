import Foundation
import SwiftUI

@MainActor
final class PageNetworkTrafficTracker: ObservableObject {
    @Published private(set) var uploadedByteCount: Int64 = 0
    @Published private(set) var downloadedByteCount: Int64 = 0

    var totalByteCount: Int64 {
        uploadedByteCount + downloadedByteCount
    }

    func reset() {
        uploadedByteCount = 0
        downloadedByteCount = 0
    }

    func recordUpload(_ byteCount: Int64) {
        uploadedByteCount = uploadedByteCount.addingClamped(max(0, byteCount))
    }

    func recordDownload(_ byteCount: Int64) {
        downloadedByteCount = downloadedByteCount.addingClamped(max(0, byteCount))
    }

    static func formatted(_ byteCount: Int64) -> String {
        guard byteCount > 0 else { return "0 KB" }
        return ByteCountFormatter.string(
            fromByteCount: byteCount,
            countStyle: .file
        )
    }
}

private extension Int64 {
    func addingClamped(_ value: Int64) -> Int64 {
        let result = addingReportingOverflow(value)
        return result.overflow ? .max : result.partialValue
    }
}

actor NetworkTrafficDeltaAccumulator {
    private var latestCompletedByteCount: Int64 = 0

    func delta(for completedByteCount: Int64) -> Int64 {
        let normalized = max(0, completedByteCount)
        guard normalized > latestCompletedByteCount else { return 0 }
        let delta = normalized - latestCompletedByteCount
        latestCompletedByteCount = normalized
        return delta
    }

    var accountedByteCount: Int64 {
        latestCompletedByteCount
    }
}

/// Adds page-scoped payload accounting without changing a backend's transfer behavior.
final class TrafficMeasuringRemoteFileService: RemoteFileService, @unchecked Sendable {
    typealias CacheLookup = @Sendable (RemoteFileItem) async -> Bool

    let base: any RemoteFileService
    private let tracker: PageNetworkTrafficTracker
    private let isDownloadCached: CacheLookup

    init(
        base: any RemoteFileService,
        tracker: PageNetworkTrafficTracker,
        isDownloadCached: @escaping CacheLookup = { item in
            DownloadCache.shared.cachedURL(for: item) != nil
        }
    ) {
        self.base = base
        self.tracker = tracker
        self.isDownloadCached = isDownloadCached
    }

    var connection: RemoteConnection { base.connection }
    var capabilities: RemoteFileServiceCapabilities { base.capabilities }
    var permitsFullDownloadForVideoThumbnail: Bool {
        base.permitsFullDownloadForVideoThumbnail
    }
    var supportsRangeStreaming: Bool { base.supportsRangeStreaming }

    func list(directory path: String?) async throws -> [RemoteFileItem] {
        try await base.list(directory: path)
    }

    func download(_ item: RemoteFileItem) async throws -> URL {
        try await download(item) { _ in }
    }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        let wasCached = await isDownloadCached(item)
        let accumulator = NetworkTrafficDeltaAccumulator()
        return try await base.download(item) { [tracker] update in
            if !wasCached {
                let delta = await accumulator.delta(for: update.completedByteCount)
                if delta > 0 {
                    await tracker.recordDownload(delta)
                }
            }
            await progress(update)
        }
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        let data = try await base.readRange(of: item, offset: offset, length: length)
        await tracker.recordDownload(Int64(data.count))
        return data
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        let data = try await base.thumbnailData(for: item, size: size)
        if let data {
            await tracker.recordDownload(Int64(data.count))
        }
        return data
    }

    func testConnection() async throws {
        try await base.testConnection()
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try await base.createFolder(named: name, in: directoryPath, context: context)
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        try await base.rename(item, to: newName, context: context)
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await base.delete(item, recursive: recursive, context: context)
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        let localByteCount = Int64(
            max(0, (try? localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        )
        let accumulator = NetworkTrafficDeltaAccumulator()
        let measuredContext = RemoteOperationContext(operationID: context.operationID) {
            [tracker] update in
            if update.operation == .upload,
               update.unit == .bytes,
               update.phase == .writing || update.phase == .completed {
                let delta = await accumulator.delta(for: update.completedUnitCount)
                if delta > 0 {
                    await tracker.recordUpload(delta)
                }
            }
            await context.report(update)
        }

        let result = try await base.upload(
            localURL: localURL,
            to: directoryPath,
            preferredName: preferredName,
            conflictPolicy: conflictPolicy,
            context: measuredContext
        )
        let accounted = await accumulator.accountedByteCount
        if localByteCount > accounted, result.hasSuccessfulOutcome {
            await tracker.recordUpload(localByteCount - accounted)
        }
        return result
    }

    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await base.copy(
            item,
            to: directoryPath,
            conflictPolicy: conflictPolicy,
            strategy: strategy,
            context: context
        )
    }

    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        try await base.move(
            item,
            to: directoryPath,
            conflictPolicy: conflictPolicy,
            strategy: strategy,
            context: context
        )
    }
}

private extension RemoteOperationContext {
    func report(_ progress: RemoteOperationProgress) async {
        await report(
            operation: progress.operation,
            phase: progress.phase,
            unit: progress.unit,
            completedUnitCount: progress.completedUnitCount,
            totalUnitCount: progress.totalUnitCount,
            currentPath: progress.currentPath
        )
    }
}

private extension RemoteOperationResult {
    var hasSuccessfulOutcome: Bool {
        outcomes.contains { $0.status == .succeeded }
    }
}
