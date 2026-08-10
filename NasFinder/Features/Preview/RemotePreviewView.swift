import AVFoundation
import AVKit
import ImageIO
import QuickLook
import SwiftUI
import UIKit

struct RemotePreviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var viewModel: RemotePreviewViewModel
    @StateObject private var shareCoordinator = PreviewShareCoordinator()
    @State private var videoDragAxis: PreviewDragAxis?
    @State private var videoVerticalOffset: CGFloat = 0

    init(
        item: RemoteFileItem,
        sequentialItems: [RemoteFileItem],
        service: any RemoteFileService
    ) {
        let orderedItems: [RemoteFileItem]
        if item.isImage || item.isVideo {
            let mediaItems = sequentialItems.filter { $0.isImage || $0.isVideo }
            orderedItems = mediaItems.contains(where: { $0.id == item.id })
                ? mediaItems
                : [item]
        } else {
            orderedItems = [item]
        }

        _viewModel = StateObject(
            wrappedValue: RemotePreviewViewModel(
                items: orderedItems,
                initialItemID: item.id,
                service: service
            )
        )
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()

                previewContent(in: geometry)
                    .id(viewModel.currentItem.id)
                    .transition(.opacity)

                previewChrome(safeAreaInsets: geometry.safeAreaInsets)

                if let seekText = viewModel.seekHUDText {
                    seekHUD(text: seekText)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: viewModel.currentItem.id)
        }
        .background(Color.black.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: viewModel.currentItem.id) {
            await viewModel.loadCurrentItem()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                viewModel.pauseForLifecycle()
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: UIApplication.didEnterBackgroundNotification
            )
        ) { _ in
            viewModel.pauseForLifecycle()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVPlayerItem.didPlayToEndTimeNotification
            )
        ) { notification in
            guard let endedItem = notification.object as? AVPlayerItem,
                  endedItem === viewModel.player?.currentItem else { return }
            viewModel.videoDidFinish()
        }
        .onDisappear {
            viewModel.pauseForLifecycle()
            shareCoordinator.cancelAndCleanUp()
        }
        .sheet(
            item: $shareCoordinator.preparedShare,
            onDismiss: shareCoordinator.shareSheetDidDismiss
        ) { prepared in
            PreviewActivityView(fileURL: prepared.fileURL)
        }
        .alert("파일을 공유할 수 없습니다", isPresented: shareErrorBinding) {
            Button("확인", role: .cancel) {
                shareCoordinator.errorMessage = nil
            }
        } message: {
            Text(shareCoordinator.errorMessage ?? "")
        }
    }

    @ViewBuilder
    private func previewContent(in geometry: GeometryProxy) -> some View {
        if viewModel.isLoading || (
            viewModel.localURL == nil && viewModel.errorMessage == nil
        ) {
            VStack(spacing: 14) {
                ProgressView()
                    .tint(.white)
                Text("원격 파일을 내려받는 중…")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorMessage = viewModel.errorMessage {
            ContentUnavailableView {
                Label(
                    "미리보기를 열 수 없습니다",
                    systemImage: "exclamationmark.triangle"
                )
            } description: {
                Text(errorMessage)
            } actions: {
                Button("다시 시도") {
                    Task { await viewModel.retryCurrentItem() }
                }
                .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white)
        } else if viewModel.currentItem.isImage,
                  let image = viewModel.image {
            ZoomableMediaImageView(
                image: image,
                onDismiss: { dismiss() },
                onNavigate: { offset in
                    viewModel.navigate(by: offset)
                }
            )
        } else if viewModel.currentItem.isVideo,
                  let player = viewModel.player {
            VideoPlayer(player: player)
                .background(Color.black)
                .offset(y: videoVerticalOffset)
                .opacity(videoDismissOpacity)
                .contentShape(Rectangle())
                .simultaneousGesture(videoDragGesture(in: geometry.size.width))
        } else if let url = viewModel.localURL {
            QuickLookPreview(url: url)
        }
    }

    private func previewChrome(safeAreaInsets: EdgeInsets) -> some View {
        VStack(spacing: 0) {
            topBar
                .padding(.top, max(safeAreaInsets.top, 8) + 8)

            Spacer(minLength: 72)

            if viewModel.currentItem.isImage || viewModel.currentItem.isVideo {
                bottomControls
                    .padding(.bottom, max(safeAreaInsets.bottom, 8) + 10)
            }
        }
        .padding(.leading, max(safeAreaInsets.leading, 8) + 8)
        .padding(.trailing, max(safeAreaInsets.trailing, 8) + 8)
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.58), in: Circle())
            }
            .accessibilityLabel("미리보기 닫기")

            Text(viewModel.currentItem.name)
                .font(.headline)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 4)

            Group {
                if let url = viewModel.localURL {
                    Button {
                        shareCoordinator.prepare(
                            cachedURL: url,
                            originalFilename: viewModel.currentItem.name
                        )
                    } label: {
                        Group {
                            if shareCoordinator.isPreparing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "square.and.arrow.up")
                            }
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.58), in: Circle())
                    }
                    .disabled(shareCoordinator.isPreparing)
                    .accessibilityLabel("현재 파일 공유")
                } else {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.35), in: Circle())
                        .foregroundStyle(.white.opacity(0.35))
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 42, height: 42)
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
    }

    private var shareErrorBinding: Binding<Bool> {
        Binding(
            get: { shareCoordinator.errorMessage != nil },
            set: { if !$0 { shareCoordinator.errorMessage = nil } }
        )
    }

    private var bottomControls: some View {
        HStack(spacing: 18) {
            Button {
                viewModel.navigate(by: -1)
            } label: {
                Image(systemName: "backward.end.fill")
                    .frame(width: 34, height: 34)
            }
            .disabled(viewModel.itemsCount < 2)
            .accessibilityLabel("이전 미디어")

            Button {
                viewModel.togglePlayback()
            } label: {
                Image(systemName: viewModel.isPlaying ? "pause.fill" : "play.fill")
                    .font(.title3)
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel(viewModel.isPlaying ? "일시 정지" : "재생")

            Button {
                viewModel.navigate(by: 1)
            } label: {
                Image(systemName: "forward.end.fill")
                    .frame(width: 34, height: 34)
            }
            .disabled(viewModel.itemsCount < 2)
            .accessibilityLabel("다음 미디어")

            Text("\(viewModel.currentIndex + 1) / \(viewModel.itemsCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.72))
                .frame(minWidth: 42)

            Menu {
                Section("재생 모드") {
                    ForEach(PreviewPlaybackMode.allCases) { mode in
                        Button {
                            viewModel.setPlaybackMode(mode)
                        } label: {
                            Label(
                                mode.title,
                                systemImage: viewModel.playbackMode == mode
                                    ? "checkmark"
                                    : mode.systemImage
                            )
                        }
                    }
                }

                Section("사진 전환 간격") {
                    ForEach(PhotoAdvanceInterval.allCases) { interval in
                        Button {
                            viewModel.setPhotoAdvanceInterval(interval)
                        } label: {
                            Label(
                                interval.title,
                                systemImage: viewModel.photoAdvanceInterval == interval
                                    ? "checkmark"
                                    : "timer"
                            )
                        }
                    }
                }
            } label: {
                Image(systemName: viewModel.playbackMode.systemImage)
                    .frame(width: 34, height: 34)
            }
            .accessibilityLabel(
                "재생 모드: \(viewModel.playbackMode.title), 사진 \(viewModel.photoAdvanceInterval.title)"
            )
        }
        .font(.system(size: 17, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.black.opacity(0.62), in: Capsule())
        .overlay {
            Capsule()
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        }
        .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
    }

    private func seekHUD(text: String) -> some View {
        VStack(spacing: 5) {
            Text(text)
                .font(.title3.monospacedDigit().weight(.semibold))
            Text("좌우로 움직여 시간 조절")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 13)
        .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .stroke(.white.opacity(0.13), lineWidth: 0.5)
        }
    }

    private var videoDismissOpacity: Double {
        let progress = min(max(videoVerticalOffset / 360, 0), 0.45)
        return 1 - Double(progress)
    }

    private func videoDragGesture(in width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                if videoDragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 12 else { return }

                    videoDragAxis = horizontalDistance > verticalDistance
                        ? .horizontal
                        : .vertical

                    if videoDragAxis == .horizontal {
                        viewModel.beginVideoScrub()
                    }
                }

                switch videoDragAxis {
                case .horizontal:
                    viewModel.updateVideoScrub(
                        horizontalTranslation: value.translation.width,
                        viewWidth: max(width, 1)
                    )
                case .vertical:
                    videoVerticalOffset = max(0, value.translation.height)
                case nil:
                    break
                }
            }
            .onEnded { value in
                defer { videoDragAxis = nil }

                switch videoDragAxis {
                case .horizontal:
                    viewModel.endVideoScrub()
                case .vertical:
                    let isDownwardDominant = value.translation.height > 0
                        && abs(value.translation.height) > abs(value.translation.width)
                    if isDownwardDominant && value.translation.height >= 120 {
                        viewModel.pauseForLifecycle()
                        dismiss()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                            videoVerticalOffset = 0
                        }
                    }
                case nil:
                    break
                }
            }
    }
}

private enum PreviewDragAxis {
    case horizontal
    case vertical
}

private enum PreviewPlaybackMode: String, CaseIterable, Identifiable {
    case repeatAll
    case shuffle
    case repeatOne

    var id: Self { self }

    var title: String {
        switch self {
        case .repeatAll: "전체 미디어 반복"
        case .shuffle: "임의 재생"
        case .repeatOne: "한 항목 반복"
        }
    }

    var systemImage: String {
        switch self {
        case .repeatAll: "repeat"
        case .shuffle: "shuffle"
        case .repeatOne: "repeat.1"
        }
    }
}

private enum PhotoAdvanceInterval: Int, CaseIterable, Identifiable {
    case twoSeconds = 2
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case fifteenSeconds = 15
    case thirtySeconds = 30

    var id: Int { rawValue }
    var title: String { "\(rawValue)초" }
}

@MainActor
private final class RemotePreviewViewModel: ObservableObject {
    @Published private(set) var currentIndex: Int
    @Published private(set) var localURL: URL?
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var isPlaying = false
    @Published private(set) var playbackMode: PreviewPlaybackMode = .repeatAll
    @Published private(set) var photoAdvanceInterval: PhotoAdvanceInterval
    @Published private(set) var seekHUDText: String?
    @Published var errorMessage: String?

    let items: [RemoteFileItem]

    private let service: any RemoteFileService
    private var downloadedURLs: [RemoteFileItem.ID: URL] = [:]
    private var photoAdvanceTask: Task<Void, Never>?
    private var seekHUDDismissTask: Task<Void, Never>?
    private var scrubStartSeconds: Double?
    private var loadedVideoDurationSeconds: Double?
    private var activeLoadGeneration: UUID?
    private var streamingLoader: RemoteVideoStreamingLoader?

    private static let photoAdvanceIntervalDefaultsKey = "previewPhotoAdvanceIntervalSeconds"

    var currentItem: RemoteFileItem { items[currentIndex] }
    var itemsCount: Int { items.count }

    init(
        items: [RemoteFileItem],
        initialItemID: RemoteFileItem.ID,
        service: any RemoteFileService
    ) {
        precondition(!items.isEmpty)
        self.items = items
        self.service = service
        currentIndex = items.firstIndex(where: { $0.id == initialItemID }) ?? 0
        let savedInterval = UserDefaults.standard.integer(
            forKey: Self.photoAdvanceIntervalDefaultsKey
        )
        photoAdvanceInterval = PhotoAdvanceInterval(rawValue: savedInterval) ?? .fiveSeconds
    }

    func loadCurrentItem() async {
        let requestedItem = currentItem
        guard !isLoading else { return }
        let generation = UUID()
        activeLoadGeneration = generation

        isLoading = true
        errorMessage = nil
        localURL = nil
        image = nil
        loadedVideoDurationSeconds = nil
        defer {
            if isCurrentLoad(generation, itemID: requestedItem.id) {
                isLoading = false
                activeLoadGeneration = nil
            }
        }

        do {
            if requestedItem.isVideo,
               service.supportsRangeStreaming,
               let size = requestedItem.size,
               size > 0 {
                streamingLoader?.cancel()
                let loader = RemoteVideoStreamingLoader(
                    item: requestedItem,
                    service: service
                )
                streamingLoader = loader
                let newPlayer = AVPlayer(
                    playerItem: AVPlayerItem(asset: loader.asset)
                )
                guard isCurrentLoad(generation, itemID: requestedItem.id) else {
                    loader.cancel()
                    return
                }
                player = newPlayer
                if isPlaying {
                    newPlayer.play()
                }
                return
            }

            let url: URL
            if let cachedURL = downloadedURLs[requestedItem.id],
               FileManager.default.fileExists(atPath: cachedURL.path) {
                url = cachedURL
            } else {
                url = try await service.download(requestedItem)
                downloadedURLs[requestedItem.id] = url
            }

            guard isCurrentLoad(generation, itemID: requestedItem.id) else { return }
            localURL = url

            if requestedItem.isImage {
                let decodedImage = try await RemoteImageDecoder.downsample(
                    fileURL: url,
                    maximumPixelSize: 4_096
                )
                guard isCurrentLoad(generation, itemID: requestedItem.id) else { return }
                image = UIImage(cgImage: decodedImage.image)
                schedulePhotoAdvance()
            } else if requestedItem.isVideo {
                let asset = AVURLAsset(url: url)
                let duration = try? await asset.load(.duration)
                guard isCurrentLoad(generation, itemID: requestedItem.id) else { return }

                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                player = newPlayer
                if let duration, duration.seconds.isFinite {
                    loadedVideoDurationSeconds = duration.seconds
                }
                if isPlaying {
                    newPlayer.play()
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard isCurrentLoad(generation, itemID: requestedItem.id) else { return }
            errorMessage = error.localizedDescription
        }
    }

    func retryCurrentItem() async {
        errorMessage = nil
        await loadCurrentItem()
    }

    func navigate(by offset: Int) {
        guard items.count > 1, offset != 0 else { return }

        let count = items.count
        let nextIndex = (currentIndex + offset % count + count) % count
        move(to: nextIndex)
    }

    func togglePlayback() {
        isPlaying.toggle()

        if currentItem.isVideo {
            if isPlaying {
                player?.play()
            } else {
                player?.pause()
            }
        } else if currentItem.isImage {
            if isPlaying {
                schedulePhotoAdvance()
            } else {
                photoAdvanceTask?.cancel()
                photoAdvanceTask = nil
            }
        }
    }

    func setPlaybackMode(_ mode: PreviewPlaybackMode) {
        playbackMode = mode
        if currentItem.isImage, isPlaying {
            schedulePhotoAdvance()
        }
    }

    func setPhotoAdvanceInterval(_ interval: PhotoAdvanceInterval) {
        photoAdvanceInterval = interval
        UserDefaults.standard.set(
            interval.rawValue,
            forKey: Self.photoAdvanceIntervalDefaultsKey
        )
        if currentItem.isImage, isPlaying {
            schedulePhotoAdvance()
        }
    }

    func videoDidFinish() {
        guard currentItem.isVideo else { return }

        switch playbackMode {
        case .repeatOne:
            replayCurrentVideo()
        case .repeatAll:
            if items.count == 1 {
                replayCurrentVideo()
            } else {
                move(to: (currentIndex + 1) % items.count)
            }
        case .shuffle:
            if let randomIndex = randomNextIndex() {
                move(to: randomIndex)
            } else {
                replayCurrentVideo()
            }
        }
    }

    func beginVideoScrub() {
        guard currentItem.isVideo,
              let player,
              let currentSeconds = finiteSeconds(player.currentTime()) else { return }

        scrubStartSeconds = currentSeconds
        seekHUDDismissTask?.cancel()
        player.pause()
    }

    func updateVideoScrub(horizontalTranslation: CGFloat, viewWidth: CGFloat) {
        guard let player,
              let startSeconds = scrubStartSeconds,
              let durationSeconds = videoDurationSeconds else { return }

        let delta = Double(horizontalTranslation / viewWidth) * durationSeconds
        let targetSeconds = min(max(startSeconds + delta, 0), durationSeconds)
        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(to: targetTime, toleranceBefore: .zero, toleranceAfter: .zero)
        seekHUDText = "\(formatTime(targetSeconds)) / \(formatTime(durationSeconds))"
    }

    func endVideoScrub() {
        guard scrubStartSeconds != nil else { return }
        scrubStartSeconds = nil

        if isPlaying {
            player?.play()
        }

        seekHUDDismissTask?.cancel()
        seekHUDDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(750))
            guard !Task.isCancelled else { return }
            self?.seekHUDText = nil
        }
    }

    func pauseForLifecycle() {
        isPlaying = false
        photoAdvanceTask?.cancel()
        photoAdvanceTask = nil
        seekHUDDismissTask?.cancel()
        seekHUDDismissTask = nil
        seekHUDText = nil
        scrubStartSeconds = nil
        player?.pause()
    }

    private func move(to index: Int) {
        guard items.indices.contains(index), index != currentIndex else {
            if currentItem.isImage, isPlaying {
                schedulePhotoAdvance()
            }
            return
        }

        player?.pause()
        player = nil
        streamingLoader?.cancel()
        streamingLoader = nil
        photoAdvanceTask?.cancel()
        photoAdvanceTask = nil
        seekHUDDismissTask?.cancel()
        seekHUDDismissTask = nil
        seekHUDText = nil
        scrubStartSeconds = nil
        loadedVideoDurationSeconds = nil
        activeLoadGeneration = nil
        localURL = nil
        image = nil
        errorMessage = nil
        isLoading = false
        currentIndex = index
    }

    private func schedulePhotoAdvance() {
        photoAdvanceTask?.cancel()
        photoAdvanceTask = nil

        guard currentItem.isImage, image != nil, isPlaying else { return }
        let expectedItemID = currentItem.id
        let interval = photoAdvanceInterval

        photoAdvanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval.rawValue))
            guard !Task.isCancelled,
                  let self,
                  self.currentItem.id == expectedItemID,
                  self.isPlaying else { return }
            self.photoDidFinish()
        }
    }

    private func photoDidFinish() {
        switch playbackMode {
        case .repeatOne:
            schedulePhotoAdvance()
        case .repeatAll:
            if items.count == 1 {
                schedulePhotoAdvance()
            } else {
                move(to: (currentIndex + 1) % items.count)
            }
        case .shuffle:
            if let randomIndex = randomNextIndex() {
                move(to: randomIndex)
            } else {
                schedulePhotoAdvance()
            }
        }
    }

    private func randomNextIndex() -> Int? {
        guard items.count > 1 else { return nil }
        var candidate = currentIndex
        while candidate == currentIndex {
            candidate = Int.random(in: items.indices)
        }
        return candidate
    }

    private func replayCurrentVideo() {
        guard let player else { return }
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        if isPlaying {
            player.play()
        }
    }

    private var videoDurationSeconds: Double? {
        if let loadedVideoDurationSeconds, loadedVideoDurationSeconds > 0 {
            return loadedVideoDurationSeconds
        }
        guard let player,
              let duration = finiteSeconds(player.currentItem?.duration ?? .invalid),
              duration > 0 else { return nil }
        return duration
    }

    private func finiteSeconds(_ time: CMTime) -> Double? {
        let seconds = time.seconds
        return seconds.isFinite && !seconds.isNaN ? seconds : nil
    }

    private func isCurrentLoad(
        _ generation: UUID,
        itemID: RemoteFileItem.ID
    ) -> Bool {
        activeLoadGeneration == generation && currentItem.id == itemID
    }

    private func formatTime(_ seconds: Double) -> String {
        let value = max(Int(seconds.rounded(.down)), 0)
        let hours = value / 3_600
        let minutes = (value % 3_600) / 60
        let remainingSeconds = value % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage
}

private enum RemoteImageDecoder {
    static func downsample(
        fileURL: URL,
        maximumPixelSize: Int
    ) async throws -> SendableCGImage {
        let decodeTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try autoreleasepool {
                let sourceOptions = [
                    kCGImageSourceShouldCache: false
                ] as CFDictionary
                guard let source = CGImageSourceCreateWithURL(
                    fileURL as CFURL,
                    sourceOptions
                ) else {
                    throw PreviewImageError.invalidImage
                }

                let thumbnailOptions = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maximumPixelSize
                ] as CFDictionary
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                    source,
                    0,
                    thumbnailOptions
                ) else {
                    throw PreviewImageError.cannotCreateThumbnail
                }

                return SendableCGImage(image: thumbnail)
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

private enum PreviewImageError: LocalizedError, Sendable {
    case invalidImage
    case cannotCreateThumbnail

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "지원되지 않거나 손상된 이미지입니다."
        case .cannotCreateThumbnail:
            "이미지 미리보기를 만들 수 없습니다."
        }
    }
}

@MainActor
private final class PreviewShareCoordinator: ObservableObject {
    @Published var preparedShare: PreviewPreparedShare?
    @Published var errorMessage: String?
    @Published private(set) var isPreparing = false

    private var task: Task<Void, Never>?
    private var operationID: UUID?

    func prepare(cachedURL: URL, originalFilename: String) {
        guard task == nil, preparedShare == nil else { return }
        let currentOperationID = UUID()
        operationID = currentOperationID
        isPreparing = true
        errorMessage = nil

        task = Task { [weak self] in
            do {
                let prepared = try await Self.stage(
                    cachedURL: cachedURL,
                    originalFilename: originalFilename,
                    operationID: currentOperationID
                )
                guard let self,
                      self.operationID == currentOperationID else {
                    await Self.removeDirectory(prepared.temporaryDirectoryURL)
                    return
                }
                self.preparedShare = prepared
                self.finish(operationID: currentOperationID)
            } catch is CancellationError {
                self?.finish(operationID: currentOperationID)
            } catch {
                guard let self,
                      self.operationID == currentOperationID else { return }
                self.errorMessage = error.localizedDescription
                self.finish(operationID: currentOperationID)
            }
        }
    }

    func shareSheetDidDismiss() {
        guard let directory = preparedShare?.temporaryDirectoryURL else { return }
        preparedShare = nil
        Task { await Self.removeDirectory(directory) }
    }

    func cancelAndCleanUp() {
        operationID = nil
        task?.cancel()
        task = nil
        isPreparing = false
        if let directory = preparedShare?.temporaryDirectoryURL {
            preparedShare = nil
            Task { await Self.removeDirectory(directory) }
        }
    }

    private func finish(operationID completedID: UUID) {
        guard operationID == completedID else { return }
        operationID = nil
        task = nil
        isPreparing = false
    }

    private static func stage(
        cachedURL: URL,
        originalFilename: String,
        operationID: UUID
    ) async throws -> PreviewPreparedShare {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let fileManager = FileManager.default
            guard cachedURL.isFileURL,
                  fileManager.fileExists(atPath: cachedURL.path) else {
                throw PreviewShareError.cachedFileMissing
            }

            let root = fileManager.temporaryDirectory
                .appending(path: "NasFinderPreviewShares", directoryHint: .isDirectory)
                .appending(path: operationID.uuidString, directoryHint: .isDirectory)
            try fileManager.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [
                    .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
                ]
            )
            do {
                let filename = safeFilename(originalFilename, fallbackURL: cachedURL)
                let stagedURL = root.appending(path: filename, directoryHint: .notDirectory)
                do {
                    try fileManager.linkItem(at: cachedURL, to: stagedURL)
                } catch {
                    let source = try FileHandle(forReadingFrom: cachedURL)
                    defer { try? source.close() }
                    guard fileManager.createFile(atPath: stagedURL.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    let destination = try FileHandle(forWritingTo: stagedURL)
                    defer { try? destination.close() }
                    while true {
                        try Task.checkCancellation()
                        let data = try source.read(upToCount: 1_024 * 1_024) ?? Data()
                        guard !data.isEmpty else { break }
                        try destination.write(contentsOf: data)
                    }
                    try destination.synchronize()
                }
                try Task.checkCancellation()
                return PreviewPreparedShare(
                    fileURL: stagedURL,
                    temporaryDirectoryURL: root
                )
            } catch {
                try? fileManager.removeItem(at: root)
                throw error
            }
        }

        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    private static func removeDirectory(_ url: URL) async {
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: url)
        }.value
    }

    private nonisolated static func safeFilename(
        _ filename: String,
        fallbackURL: URL
    ) -> String {
        let basename = (filename as NSString).lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !basename.isEmpty, basename != ".", basename != ".." {
            return basename
        }
        let fallback = fallbackURL.lastPathComponent
        return fallback.isEmpty ? "NasFinder File" : fallback
    }
}

private struct PreviewPreparedShare: Identifiable, Sendable {
    let id = UUID()
    let fileURL: URL
    let temporaryDirectoryURL: URL
}

private enum PreviewShareError: LocalizedError, Sendable {
    case cachedFileMissing

    var errorDescription: String? {
        "공유할 파일을 찾을 수 없습니다. 다시 시도해 주세요."
    }
}

private struct PreviewActivityView: UIViewControllerRepresentable {
    let fileURL: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(
            activityItems: [fileURL],
            applicationActivities: nil
        )
    }

    func updateUIViewController(
        _ uiViewController: UIActivityViewController,
        context: Context
    ) {}
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
