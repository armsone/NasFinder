import Foundation

enum RemoteThumbnailSize: String, Sendable {
    case small
    case medium
    case large
}

/// Signals that a backend cannot produce an efficient preview without first
/// downloading the complete original. The UI should display a placeholder
/// instead of immediately falling back to `download(_:)` for this error.
enum RemoteThumbnailError: Error, Sendable {
    case optimizedPreviewUnavailable
}

struct RemoteDownloadProgress: Sendable, Hashable {
    let completedByteCount: Int64
    let totalByteCount: Int64?

    var fractionCompleted: Double? {
        guard let totalByteCount, totalByteCount >= 0 else { return nil }
        if totalByteCount == 0 {
            return completedByteCount == 0 ? 1 : nil
        }
        let fraction = Double(completedByteCount) / Double(totalByteCount)
        return min(max(fraction, 0), 1)
    }
}

enum RemoteDownloadIntegrityError: LocalizedError, Sendable, Equatable {
    case sizeMismatch(expected: Int64, actual: Int64)

    static func validate(expectedByteCount: Int64?, actualByteCount: Int64) throws {
        guard let expectedByteCount,
              expectedByteCount >= 0,
              expectedByteCount != actualByteCount else { return }
        throw Self.sizeMismatch(
            expected: expectedByteCount,
            actual: actualByteCount
        )
    }

    var errorDescription: String? {
        switch self {
        case let .sizeMismatch(expected, actual):
            let expectedText = ByteCountFormatter.string(
                fromByteCount: expected,
                countStyle: .file
            )
            let actualText = ByteCountFormatter.string(
                fromByteCount: actual,
                countStyle: .file
            )
            return "파일을 끝까지 내려받지 못했습니다. 예상 \(expectedText), 수신 \(actualText)"
        }
    }
}

typealias RemoteDownloadProgressHandler = @Sendable (RemoteDownloadProgress) async -> Void

protocol RemoteFileService: Sendable {
    var connection: RemoteConnection { get }
    var capabilities: RemoteFileServiceCapabilities { get }
    /// Whether a missing optimized preview may fall back to downloading an
    /// entire video. Remote NAS backends should normally keep this disabled.
    var permitsFullDownloadForVideoThumbnail: Bool { get }

    func list(directory path: String?) async throws -> [RemoteFileItem]
    func download(_ item: RemoteFileItem) async throws -> URL
    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL
    var supportsRangeStreaming: Bool { get }
    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data
    /// Returns a server-produced thumbnail when the backend supports one.
    /// Backends without a thumbnail API return `nil` and the UI generates one
    /// from the downloaded file.
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data?
    func testConnection() async throws

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem
    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem
    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult
    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult
    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult
    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult
}

extension RemoteFileService {
    var capabilities: RemoteFileServiceCapabilities { [] }
    var supportsRangeStreaming: Bool { false }
    var permitsFullDownloadForVideoThumbnail: Bool { true }

    func download(
        _ item: RemoteFileItem,
        progress: @escaping RemoteDownloadProgressHandler
    ) async throws -> URL {
        await progress(
            RemoteDownloadProgress(
                completedByteCount: 0,
                totalByteCount: item.size
            )
        )
        let url = try await download(item)
        let localSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let actualByteCount = localSize.map(Int64.init)
        let completedByteCount = actualByteCount ?? item.size ?? 0
        await progress(
            RemoteDownloadProgress(
                completedByteCount: completedByteCount,
                totalByteCount: actualByteCount ?? item.size
            )
        )
        return url
    }

    func readRange(
        of item: RemoteFileItem,
        offset: Int64,
        length: Int
    ) async throws -> Data {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        nil
    }

    func testConnection() async throws {
        _ = try await list(directory: connection.normalizedRootPath)
    }

    func createFolder(
        named name: String,
        in directoryPath: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        throw RemoteFileOperationError.unsupported(operation: .createFolder)
    }

    func rename(
        _ item: RemoteFileItem,
        to newName: String,
        context: RemoteOperationContext
    ) async throws -> RemoteFileItem {
        throw RemoteFileOperationError.unsupported(operation: .rename)
    }

    func delete(
        _ item: RemoteFileItem,
        recursive: Bool,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        throw RemoteFileOperationError.unsupported(operation: .delete)
    }

    func upload(
        localURL: URL,
        to directoryPath: String,
        preferredName: String?,
        conflictPolicy: RemoteConflictPolicy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        throw RemoteFileOperationError.unsupported(operation: .upload)
    }

    func copy(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        throw RemoteFileOperationError.unsupported(operation: .copy)
    }

    func move(
        _ item: RemoteFileItem,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        strategy: RemoteTransferStrategy,
        context: RemoteOperationContext
    ) async throws -> RemoteOperationResult {
        throw RemoteFileOperationError.unsupported(operation: .move)
    }
}
