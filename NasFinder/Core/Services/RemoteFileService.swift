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

protocol RemoteFileService: Sendable {
    var connection: RemoteConnection { get }
    var capabilities: RemoteFileServiceCapabilities { get }

    func list(directory path: String?) async throws -> [RemoteFileItem]
    func download(_ item: RemoteFileItem) async throws -> URL
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
