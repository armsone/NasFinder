#if targetEnvironment(macCatalyst)
import SwiftUI

enum CompatibilityVideoFormatPolicy {
    static func prefersCompatibilityPlayer(for item: RemoteFileItem) -> Bool { false }
}

enum CompatibilityExternalSubtitlePolicy {
    static func matchingSubtitle(
        for video: RemoteFileItem,
        in items: [RemoteFileItem]
    ) -> RemoteFileItem? { nil }
}

enum CompatibilityVideoPlayerError: LocalizedError {
    case unavailableOnMac

    var errorDescription: String? {
        "이 영상 형식은 현재 Mac에서 지원하지 않습니다."
    }
}

@MainActor
final class CompatibilityPlaybackWatchdog {
    func start(
        stallTimeout: Duration,
        pollInterval: Duration,
        isPlaybackExpected: @escaping @MainActor () -> Bool,
        currentSeconds: @escaping @MainActor () -> Double,
        onStall: @escaping @MainActor () -> Void
    ) {}

    func stop() {}
}

@MainActor
final class CompatibilityVideoPlayer: ObservableObject {
    @Published private(set) var currentSeconds = 0.0
    @Published private(set) var durationSeconds = 0.0
    var onPlaybackEnded: (() -> Void)?
    var onReady: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var usesRemoteStream: Bool { false }

    init(localURL: URL) throws {
        throw CompatibilityVideoPlayerError.unavailableOnMac
    }

    init(
        item: RemoteFileItem,
        service: any RemoteFileService,
        onTransfer: (@Sendable (Int) -> Void)? = nil
    ) throws {
        throw CompatibilityVideoPlayerError.unavailableOnMac
    }

    func play() {}
    func pause() {}
    func stop() {}
    func seek(to seconds: Double) {}

    @discardableResult
    func addExternalSubtitle(at url: URL) -> Bool { false }
}

struct CompatibilityVideoPlayerSurface: View {
    @ObservedObject var player: CompatibilityVideoPlayer
    var body: some View { Color.black }
}

struct CompatibilityVideoProgressBar: View {
    @ObservedObject var player: CompatibilityVideoPlayer
    var sourceLabel: String?
    var compact = false

    var body: some View {
        EmptyView()
    }
}

struct CompatibilityVideoMiniProgressLine: View {
    @ObservedObject var player: CompatibilityVideoPlayer
    var body: some View { Color.clear }
}

@MainActor
enum CompatibilityRemoteVideoThumbnailGenerator {
    static func generate(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        size: RemoteThumbnailSize,
        trafficBudget: RemoteVideoThumbnailTrafficBudget,
        mode: RemoteVideoThumbnailGenerationMode,
        timeout: Duration,
        progress: (@Sendable (Int64, Int64) -> Void)? = nil
    ) async throws -> RemoteVideoThumbnailGenerationResult {
        throw RemoteVideoThumbnailGenerationError.unsupportedSource
    }

    static func cancelAll() async {}
}
#endif
