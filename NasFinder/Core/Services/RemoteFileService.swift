import Foundation

enum RemoteThumbnailSize: String, CaseIterable, Sendable {
    case small
    case medium
    case large
}

/// Signals that a backend cannot produce an efficient preview without first
/// downloading the complete original. The UI should display a placeholder
/// instead of immediately falling back to `download(_:)` for this error.
enum RemoteThumbnailError: Error, Sendable {
    case optimizedPreviewUnavailable
    case responseTooLarge
}

enum RemoteRequestCancellation {
    static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain
            && nsError.code == NSURLErrorCancelled
    }

    static func normalized(_ error: Error) -> Error {
        isCancellation(error) ? CancellationError() : error
    }
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

/// Where an external player can read an item from without the app copying it first.
enum RemoteExternalPlaybackTarget: Sendable, Equatable {
    /// A file that already exists on this device (read in place, never copied).
    case localFile(URL)
    /// A credential-free http(s) original address. The app's own headers/cookies are not sent;
    /// the external player decides network access and any login.
    case remoteURL(URL)
    /// Same credential-free address, but the server asks for a login: the external player has to
    /// authenticate by itself (the app never puts a password into the address).
    case remoteURLRequiresPlayerLogin(URL)
    /// No safe original address exists (private/auth-bound source). Never a credential URL.
    case unavailable(reason: String)
}

/// 파일 일부만 읽는 범위 읽기(스트리밍)를 제공하지 않는 연결의 오류. 예전 기본 구현은 '복사' 미지원 문구를 잘못 보였다.
struct RemoteRangeReadUnsupportedError: LocalizedError, Sendable, Equatable {
    var errorDescription: String? {
        "이 연결은 파일 일부만 읽는 스트리밍을 지원하지 않습니다. 파일을 내려받아 열어 주세요."
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
    /// Read-only lookup for handing the original to another app. Never downloads, copies or
    /// builds a URL carrying credentials, session ids or user info.
    func externalPlaybackTarget(for item: RemoteFileItem) -> RemoteExternalPlaybackTarget
    /// The authenticated original file-stream address for one item, for a player the user just chose.
    /// The address carries the NAS login session (never the password), so it must stay in transient
    /// memory and go only to that player. nil when the backend has no such address.
    func authenticatedOriginalHandoff(for item: RemoteFileItem) async throws -> NASSessionHandoff?
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
    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int
    ) async throws -> Data?
    /// Cancels connection work that may outlive an individual thumbnail task,
    /// such as a shared authentication refresh.
    func cancelPendingThumbnailWork() async
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
    func externalPlaybackTarget(for item: RemoteFileItem) -> RemoteExternalPlaybackTarget {
        .unavailable(reason: "이 연결은 앱에 저장된 로그인으로만 열 수 있어 외부 플레이어에 주소를 넘기거나 복사할 수 없습니다. 앱 안의 플레이어로 재생해 주세요.")
    }
    func authenticatedOriginalHandoff(for item: RemoteFileItem) async throws -> NASSessionHandoff? { nil }
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
        throw RemoteRangeReadUnsupportedError()
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize
    ) async throws -> Data? {
        nil
    }

    func thumbnailData(
        for item: RemoteFileItem,
        size: RemoteThumbnailSize,
        maximumByteCount: Int
    ) async throws -> Data? {
        let data = try await thumbnailData(for: item, size: size)
        guard let data else { return nil }
        guard data.count <= maximumByteCount else {
            throw RemoteThumbnailError.responseTooLarge
        }
        return data
    }

    func cancelPendingThumbnailWork() async {}

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
