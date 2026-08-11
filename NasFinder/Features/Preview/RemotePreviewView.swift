import AVFoundation
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
    @State private var areControlsVisible = true
    @State private var controlsHideTask: Task<Void, Never>?
    @State private var videoZoomScale: CGFloat = 1
    @State private var videoMagnificationStartScale: CGFloat = 1
    @State private var videoZoomOffset = CGSize.zero
    @State private var videoPanStartOffset = CGSize.zero
    @State private var videoDragVolume: Float?
    @State private var volumeDragStart: Float?
    @State private var systemVolumeSlider: UISlider?

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

                previewChrome(
                    safeAreaInsets: geometry.safeAreaInsets,
                    viewportSize: geometry.size
                )

                if let seekText = viewModel.seekHUDText {
                    seekHUD(text: seekText)
                        .transition(.scale.combined(with: .opacity))
                }

                if let volume = videoDragVolume {
                    volumeHUD(volume)
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
        .onChange(of: viewModel.isPlaying) { _, isPlaying in
            if isPlaying {
                revealControls()
            } else {
                controlsHideTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    areControlsVisible = true
                }
            }
        }
        .onChange(of: viewModel.currentItem.id) { _, _ in
            resetVideoTransform()
            revealControls()
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
            controlsHideTask?.cancel()
            viewModel.tearDown()
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
        switch RemotePreviewContentKind.resolve(
            isImage: viewModel.currentItem.isImage,
            isVideo: viewModel.currentItem.isVideo,
            hasImage: viewModel.image != nil,
            hasPlayer: viewModel.player != nil,
            hasLocalURL: viewModel.localURL != nil,
            hasError: viewModel.errorMessage != nil
        ) {
        case .error:
            if let errorMessage = viewModel.errorMessage {
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
            } else {
                remoteLoadingView
            }
        case .image:
            if let image = viewModel.image {
                ZoomableMediaImageView(
                    image: image,
                    onDismiss: { dismiss() },
                    onNavigate: { offset in
                        viewModel.navigate(by: offset)
                    }
                )
            } else {
                remoteLoadingView
            }
        case .video:
            if let player = viewModel.player {
                ZStack {
                    SharedSystemVolumeView { slider in
                        systemVolumeSlider = slider
                    }
                    .frame(width: 1, height: 1)
                    .opacity(0.001)
                    .allowsHitTesting(false)

                    SharedVideoPlayerSurface(
                        player: player,
                        videoGravity: .resizeAspect
                    )
                        .background(Color.black)
                        .scaleEffect(videoZoomScale)
                        .offset(videoZoomOffset)
                        .offset(y: videoVerticalOffset)
                        .opacity(videoDismissOpacity)
                        .contentShape(Rectangle())
                        .simultaneousGesture(videoDragGesture(in: geometry.size))
                        .simultaneousGesture(videoMagnificationGesture(in: geometry.size))
                        .simultaneousGesture(videoTapGesture)
                        .accessibilityLabel("공용 동영상 플레이어")
                        .accessibilityHint(
                            "한 번 탭하면 재생하거나 일시 정지하고, 두 번 탭하면 화면 크기를 초기화합니다."
                        )

                    if !areControlsVisible {
                        SharedVideoMiniProgressLine(player: player)
                            .frame(height: 2)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .allowsHitTesting(false)
                    }

                    if viewModel.isPreparingVideo {
                        remoteLoadingView
                            .allowsHitTesting(false)
                    }
                }
            } else {
                remoteLoadingView
            }
        case .quickLook:
            if let url = viewModel.localURL {
                QuickLookPreview(url: url)
            } else {
                remoteLoadingView
            }
        case .loading:
            remoteLoadingView
        }
    }

    private var remoteLoadingView: some View {
        VStack(spacing: 14) {
            if let progress = viewModel.downloadProgress,
               let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .tint(.white)
                    .frame(maxWidth: 260)
                Text(downloadProgressDescription(progress))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.72))
            } else {
                ProgressView()
                    .tint(.white)
            }

            Text(
                viewModel.currentItem.isVideo && viewModel.downloadProgress == nil
                    ? "영상을 준비하는 중…"
                    : "원격 파일을 내려받는 중…"
            )
            .foregroundStyle(.white.opacity(0.7))
        }
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func downloadProgressDescription(_ progress: RemoteDownloadProgress) -> String {
        let completed = ByteCountFormatter.string(
            fromByteCount: progress.completedByteCount,
            countStyle: .file
        )
        guard let total = progress.totalByteCount, total > 0 else {
            return "\(completed) 내려받음"
        }
        let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        let percent = progress.fractionCompleted.map { Int(($0 * 100).rounded()) } ?? 0
        return "\(completed) / \(totalText) • \(percent)%"
    }

    private func previewChrome(
        safeAreaInsets: EdgeInsets,
        viewportSize: CGSize
    ) -> some View {
        VStack(spacing: 0) {
            topBar(showsPosition: viewportSize.width <= viewportSize.height)
                .padding(.top, max(safeAreaInsets.top, 8) + 8)

            Spacer(minLength: 72)

            if viewModel.currentItem.isImage || viewModel.currentItem.isVideo {
                bottomControls(isLandscape: viewportSize.width > viewportSize.height)
                    .padding(.bottom, max(safeAreaInsets.bottom, 8) + 10)
            }
        }
        .padding(.leading, max(safeAreaInsets.leading, 8) + 8)
        .padding(.trailing, max(safeAreaInsets.trailing, 8) + 8)
        .ignoresSafeArea()
        .opacity(areControlsVisible ? 1 : 0)
        .allowsHitTesting(areControlsVisible)
        .animation(.easeInOut(duration: 0.2), value: areControlsVisible)
    }

    private func topBar(showsPosition: Bool) -> some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                SharedPlayerCircleLabel(systemImage: "xmark")
            }
            .accessibilityLabel("미리보기 닫기")

            VStack(spacing: 2) {
                Text(viewModel.currentItem.name)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .multilineTextAlignment(.center)

                if showsPosition,
                   viewModel.currentItem.isImage || viewModel.currentItem.isVideo {
                    positionLabel
                }
            }
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
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
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

    private func bottomControls(isLandscape: Bool) -> some View {
        VStack(spacing: 10) {
            if viewModel.currentItem.isVideo, let player = viewModel.player {
                SharedVideoProgressBar(player: player)
            }

            if isLandscape {
                HStack(spacing: 12) {
                    transportControls
                    Spacer(minLength: 32)
                    playbackStatusControls
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(spacing: 12) {
                    transportControls
                    Spacer(minLength: 8)
                    playbackModeControl
                }
            }
        }
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.38), radius: 10, y: 4)
    }

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.navigate(by: -1)
                revealControls()
            } label: {
                SharedPlayerCircleLabel(systemImage: "backward.end.fill")
            }
            .disabled(viewModel.itemsCount < 2)
            .accessibilityLabel("이전 미디어")

            Button {
                viewModel.navigate(by: 1)
                revealControls()
            } label: {
                SharedPlayerCircleLabel(systemImage: "forward.end.fill")
            }
            .disabled(viewModel.itemsCount < 2)
            .accessibilityLabel("다음 미디어")

            Button {
                viewModel.togglePlayback()
                revealControls()
            } label: {
                SharedPlayerCircleLabel(
                    systemImage: viewModel.isPlaying ? "pause.fill" : "play.fill"
                )
            }
            .accessibilityLabel(viewModel.isPlaying ? "일시 정지" : "재생")
        }
    }

    private var playbackStatusControls: some View {
        HStack(spacing: 12) {
            positionLabel
            playbackModeControl
        }
    }

    private var positionLabel: some View {
        Text("\(viewModel.currentIndex + 1) / \(viewModel.itemsCount)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.72))
            .frame(minWidth: 42)
            .accessibilityLabel(
                "전체 \(viewModel.itemsCount)개 중 \(viewModel.currentIndex + 1)번째"
            )
    }

    private var playbackModeControl: some View {
        Menu {
            Section("재생 모드") {
                ForEach(PreviewPlaybackMode.allCases) { mode in
                    Button {
                        viewModel.setPlaybackMode(mode)
                        revealControls()
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
                        revealControls()
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
            SharedPlayerCircleLabel(
                systemImage: viewModel.playbackMode.systemImage,
                isActive: viewModel.playbackMode != .repeatAll
            )
        }
        .accessibilityLabel(
            "재생 모드: \(viewModel.playbackMode.title), 사진 \(viewModel.photoAdvanceInterval.title)"
        )
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

    private func volumeHUD(_ volume: Float) -> some View {
        HStack(spacing: 9) {
            Image(systemName: volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
            Text("\(Int((volume * 100).rounded()))%")
                .monospacedDigit()
        }
        .font(.system(size: 17, weight: .bold, design: .rounded))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func videoDragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .local)
            .onChanged { value in
                if videoDragAxis == nil {
                    let horizontalDistance = abs(value.translation.width)
                    let verticalDistance = abs(value.translation.height)
                    guard max(horizontalDistance, verticalDistance) >= 12 else { return }

                    if videoZoomScale > 1.01 {
                        videoDragAxis = .pan
                        videoPanStartOffset = videoZoomOffset
                    } else {
                        videoDragAxis = horizontalDistance > verticalDistance
                            ? .horizontal
                            : .vertical
                    }

                    if videoDragAxis == .horizontal {
                        viewModel.beginVideoScrub()
                    }
                }

                switch videoDragAxis {
                case .horizontal:
                    viewModel.updateVideoScrub(
                        horizontalTranslation: value.translation.width,
                        viewWidth: max(size.width, 1)
                    )
                case .vertical:
                    if value.translation.height < 0 {
                        if volumeDragStart == nil {
                            volumeDragStart = AVAudioSession.sharedInstance().outputVolume
                        }
                        let start = volumeDragStart ?? 0
                        let target = min(max(start - Float(value.translation.height / 360), 0), 1)
                        videoDragVolume = target
                        systemVolumeSlider?.setValue(target, animated: false)
                        systemVolumeSlider?.sendActions(for: .valueChanged)
                    } else {
                        videoVerticalOffset = max(0, value.translation.height)
                    }
                case .pan:
                    videoZoomOffset = clampedVideoOffset(
                        CGSize(
                            width: videoPanStartOffset.width + value.translation.width,
                            height: videoPanStartOffset.height + value.translation.height
                        ),
                        in: size
                    )
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
                    volumeDragStart = nil
                    videoDragVolume = nil
                case .pan:
                    videoZoomOffset = clampedVideoOffset(videoZoomOffset, in: size)
                    videoPanStartOffset = videoZoomOffset
                case nil:
                    break
                }
            }
    }

    private func videoMagnificationGesture(in size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                videoZoomScale = min(
                    max(videoMagnificationStartScale * value.magnification, 0.5),
                    4
                )
                if videoZoomScale <= 1.01 { videoZoomOffset = .zero }
            }
            .onEnded { _ in
                videoMagnificationStartScale = videoZoomScale
                if videoZoomScale > 1.01 {
                    videoZoomOffset = clampedVideoOffset(videoZoomOffset, in: size)
                } else {
                    videoZoomOffset = .zero
                    videoPanStartOffset = .zero
                }
                revealControls()
            }
    }

    private var videoTapGesture: some Gesture {
        TapGesture(count: 2)
            .exclusively(before: TapGesture(count: 1))
            .onEnded { value in
                switch value {
                case .first:
                    guard abs(videoZoomScale - 1) > 0.01 else { return }
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.86)) {
                        resetVideoTransform()
                    }
                    revealControls()
                case .second:
                    viewModel.togglePlayback()
                    revealControls()
                }
            }
    }

    private func clampedVideoOffset(_ offset: CGSize, in size: CGSize) -> CGSize {
        let extra = max(videoZoomScale - 1, 0)
        return CGSize(
            width: min(max(offset.width, -size.width * extra / 2), size.width * extra / 2),
            height: min(max(offset.height, -size.height * extra / 2), size.height * extra / 2)
        )
    }

    private func resetVideoTransform() {
        videoZoomScale = 1
        videoMagnificationStartScale = 1
        videoZoomOffset = .zero
        videoPanStartOffset = .zero
        videoVerticalOffset = 0
    }

    private func revealControls() {
        controlsHideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) { areControlsVisible = true }
        guard viewModel.isPlaying else { return }
        controlsHideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, viewModel.isPlaying else { return }
            withAnimation(.easeInOut(duration: 0.2)) { areControlsVisible = false }
        }
    }
}

enum RemotePreviewContentKind: Equatable {
    case loading
    case error
    case image
    case video
    case quickLook

    static func resolve(
        isImage: Bool,
        isVideo: Bool,
        hasImage: Bool,
        hasPlayer: Bool,
        hasLocalURL: Bool,
        hasError: Bool
    ) -> Self {
        if hasError { return .error }
        if isImage, hasImage { return .image }
        if isVideo, hasPlayer { return .video }
        if !isImage, !isVideo, hasLocalURL { return .quickLook }
        return .loading
    }
}

enum RemoteVideoLoadStrategy: Equatable {
    case fullDownload
    case rangeStreaming

    static func resolve(
        supportsRangeStreaming: Bool,
        fileSize: Int64?
    ) -> Self {
        guard supportsRangeStreaming,
              let fileSize,
              fileSize > 0 else {
            return .fullDownload
        }
        return .rangeStreaming
    }
}

private enum PreviewDragAxis {
    case horizontal
    case vertical
    case pan
}

enum PreviewPlaybackMode: String, CaseIterable, Identifiable {
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

enum PhotoAdvanceInterval: Int, CaseIterable, Identifiable {
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
final class RemotePreviewViewModel: ObservableObject {
    @Published private(set) var currentIndex: Int
    @Published private(set) var localURL: URL?
    @Published private(set) var image: UIImage?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isLoading = false
    @Published private(set) var isPreparingVideo = false
    @Published private(set) var downloadProgress: RemoteDownloadProgress?
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
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var videoPreparationTimeoutTask: Task<Void, Never>?
    private var videoMetadataTask: Task<Void, Never>?
    private var activeDownloadTask: Task<URL, Error>?
    private var activeDownloadGeneration: UUID?
    private var downloadInactivityTask: Task<Void, Never>?
    private var downloadInactivityGeneration: UUID?
    private var lastDownloadActivity: ContinuousClock.Instant?
    private let downloadInactivityTimeout: Duration
    private let downloadInactivityPollInterval: Duration

    private static let photoAdvanceIntervalDefaultsKey = "previewPhotoAdvanceIntervalSeconds"
    private static let playbackModeDefaultsKey = "previewPlaybackMode"

    var currentItem: RemoteFileItem { items[currentIndex] }
    var itemsCount: Int { items.count }

    init(
        items: [RemoteFileItem],
        initialItemID: RemoteFileItem.ID,
        service: any RemoteFileService,
        downloadInactivityTimeout: Duration = .seconds(20),
        downloadInactivityPollInterval: Duration = .seconds(1)
    ) {
        precondition(!items.isEmpty)
        self.items = items
        self.service = service
        self.downloadInactivityTimeout = downloadInactivityTimeout
        self.downloadInactivityPollInterval = downloadInactivityPollInterval
        currentIndex = items.firstIndex(where: { $0.id == initialItemID }) ?? 0
        let savedInterval = UserDefaults.standard.integer(
            forKey: Self.photoAdvanceIntervalDefaultsKey
        )
        photoAdvanceInterval = PhotoAdvanceInterval(rawValue: savedInterval) ?? .fiveSeconds
        playbackMode = PreviewPlaybackMode(
            rawValue: UserDefaults.standard.string(forKey: Self.playbackModeDefaultsKey) ?? ""
        ) ?? .repeatAll
    }

    func loadCurrentItem(forceFullDownload: Bool = false) async {
        let requestedItem = currentItem
        guard !isLoading else { return }
        let generation = UUID()
        activeLoadGeneration = generation

        isLoading = true
        errorMessage = nil
        player?.pause()
        player = nil
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        videoPreparationTimeoutTask?.cancel()
        videoPreparationTimeoutTask = nil
        videoMetadataTask?.cancel()
        videoMetadataTask = nil
        cancelActiveDownload()
        stopDownloadInactivityWatchdog()
        isPreparingVideo = false
        streamingLoader?.cancel()
        streamingLoader = nil
        localURL = nil
        image = nil
        downloadProgress = nil
        loadedVideoDurationSeconds = nil
        defer {
            cancelActiveDownload(generation: generation)
            stopDownloadInactivityWatchdog(generation: generation)
            if isCurrentLoad(generation, itemID: requestedItem.id) {
                isLoading = false
                activeLoadGeneration = nil
            }
        }

        do {
            if requestedItem.isVideo,
               !forceFullDownload,
               RemoteVideoLoadStrategy.resolve(
                    supportsRangeStreaming: service.supportsRangeStreaming,
                    fileSize: requestedItem.size
               ) == .rangeStreaming {
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
                installPlayer(newPlayer, for: requestedItem.id)
                downloadProgress = nil
                if isPlaying {
                    SharedMediaAudioSession.activatePlayback()
                    newPlayer.play()
                }
                return
            }

            let url: URL
            if let cachedURL = downloadedURLs[requestedItem.id],
               FileManager.default.fileExists(atPath: cachedURL.path) {
                url = cachedURL
            } else {
                beginDownloadInactivityWatchdog(
                    generation: generation,
                    itemID: requestedItem.id
                )
                let service = service
                let downloadTask = Task {
                    try await service.download(requestedItem) { [weak self] progress in
                        await self?.updateDownloadProgress(
                            progress,
                            generation: generation,
                            itemID: requestedItem.id
                        )
                    }
                }
                activeDownloadTask = downloadTask
                activeDownloadGeneration = generation
                url = try await withTaskCancellationHandler {
                    try await downloadTask.value
                } onCancel: {
                    downloadTask.cancel()
                }
                clearActiveDownload(generation: generation)
                stopDownloadInactivityWatchdog(generation: generation)
                guard isCurrentLoad(generation, itemID: requestedItem.id) else {
                    throw CancellationError()
                }
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
                downloadProgress = nil
                schedulePhotoAdvance()
            } else if requestedItem.isVideo {
                let asset = AVURLAsset(url: url)
                guard isCurrentLoad(generation, itemID: requestedItem.id) else { return }

                let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                installPlayer(newPlayer, for: requestedItem.id)
                downloadProgress = nil
                if isPlaying {
                    SharedMediaAudioSession.activatePlayback()
                    newPlayer.play()
                }
                videoMetadataTask = Task { [weak self, weak newPlayer] in
                    let duration = try? await asset.load(.duration)
                    guard !Task.isCancelled,
                          let self,
                          let newPlayer,
                          self.player === newPlayer,
                          self.currentItem.id == requestedItem.id,
                          let duration,
                          duration.seconds.isFinite else { return }
                    self.loadedVideoDurationSeconds = duration.seconds
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
                SharedMediaAudioSession.activatePlayback()
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
        UserDefaults.standard.set(mode.rawValue, forKey: Self.playbackModeDefaultsKey)
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
            SharedMediaAudioSession.activatePlayback()
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

    func tearDown() {
        pauseForLifecycle()
        streamingLoader?.cancel()
        streamingLoader = nil
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        videoPreparationTimeoutTask?.cancel()
        videoPreparationTimeoutTask = nil
        videoMetadataTask?.cancel()
        videoMetadataTask = nil
        cancelActiveDownload()
        stopDownloadInactivityWatchdog()
        activeLoadGeneration = nil
        isLoading = false
        isPreparingVideo = false
        downloadProgress = nil
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
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        videoPreparationTimeoutTask?.cancel()
        videoPreparationTimeoutTask = nil
        videoMetadataTask?.cancel()
        videoMetadataTask = nil
        cancelActiveDownload()
        stopDownloadInactivityWatchdog()
        isPreparingVideo = false
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
        downloadProgress = nil
        errorMessage = nil
        isLoading = false
        currentIndex = index
    }

    private func updateDownloadProgress(
        _ progress: RemoteDownloadProgress,
        generation: UUID,
        itemID: RemoteFileItem.ID
    ) {
        guard isCurrentLoad(generation, itemID: itemID) else { return }
        downloadProgress = progress
        lastDownloadActivity = ContinuousClock.now
    }

    private func installPlayer(
        _ newPlayer: AVPlayer,
        for itemID: RemoteFileItem.ID
    ) {
        playerItemStatusObservation?.invalidate()
        videoPreparationTimeoutTask?.cancel()
        player = newPlayer
        isPreparingVideo = true
        playerItemStatusObservation = newPlayer.currentItem?.observe(
            \.status,
            options: [.initial, .new]
        ) { [weak self] playerItem, _ in
            Task { @MainActor [weak self] in
                guard let self,
                      self.currentItem.id == itemID,
                      self.player?.currentItem === playerItem else { return }
                switch playerItem.status {
                case .readyToPlay:
                    self.isPreparingVideo = false
                    self.videoPreparationTimeoutTask?.cancel()
                    self.videoPreparationTimeoutTask = nil
                case .failed:
                    let message = playerItem.error?.localizedDescription
                        ?? "지원하지 않는 영상 형식이거나 원격 데이터를 읽지 못했습니다."
                    self.handleVideoPreparationFailure(message, itemID: itemID)
                case .unknown:
                    self.isPreparingVideo = true
                @unknown default:
                    self.isPreparingVideo = true
                }
            }
        }
        videoPreparationTimeoutTask = Task { [weak self, weak newPlayer] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled,
                  let self,
                  let newPlayer,
                  self.player === newPlayer,
                  self.currentItem.id == itemID,
                  self.isPreparingVideo else { return }
            self.handleVideoPreparationFailure(
                "원격 영상 준비 시간이 너무 오래 걸립니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요.",
                itemID: itemID
            )
        }
    }

    private func handleVideoPreparationFailure(
        _ message: String,
        itemID: RemoteFileItem.ID
    ) {
        guard currentItem.id == itemID else { return }
        guard streamingLoader != nil else {
            failVideoPreparation(message, itemID: itemID)
            return
        }

        videoPreparationTimeoutTask?.cancel()
        videoPreparationTimeoutTask = nil
        playerItemStatusObservation?.invalidate()
        playerItemStatusObservation = nil
        player?.pause()
        player = nil
        streamingLoader?.cancel()
        streamingLoader = nil
        isPreparingVideo = false
        activeLoadGeneration = nil
        isLoading = false
        errorMessage = nil

        Task { [weak self] in
            await Task.yield()
            guard let self, self.currentItem.id == itemID else { return }
            await self.loadCurrentItem(forceFullDownload: true)
        }
    }

    private func failVideoPreparation(_ message: String, itemID: RemoteFileItem.ID) {
        guard currentItem.id == itemID else { return }
        videoPreparationTimeoutTask?.cancel()
        videoPreparationTimeoutTask = nil
        videoMetadataTask?.cancel()
        videoMetadataTask = nil
        isPreparingVideo = false
        player?.pause()
        streamingLoader?.cancel()
        streamingLoader = nil
        errorMessage = "영상을 재생하지 못했습니다: \(message)"
        downloadProgress = nil
    }

    private func beginDownloadInactivityWatchdog(
        generation: UUID,
        itemID: RemoteFileItem.ID
    ) {
        stopDownloadInactivityWatchdog()
        downloadInactivityGeneration = generation
        lastDownloadActivity = ContinuousClock.now
        let pollInterval = downloadInactivityPollInterval
        let inactivityTimeout = downloadInactivityTimeout
        downloadInactivityTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval)
                guard !Task.isCancelled, let self else { return }
                guard self.isCurrentLoad(generation, itemID: itemID),
                      self.downloadInactivityGeneration == generation,
                      let lastActivity = self.lastDownloadActivity else { return }
                if lastActivity.duration(to: ContinuousClock.now)
                    >= inactivityTimeout {
                    self.cancelActiveDownload(generation: generation)
                    self.downloadInactivityGeneration = nil
                    self.lastDownloadActivity = nil
                    self.downloadInactivityTask = nil
                    self.activeLoadGeneration = nil
                    self.isLoading = false
                    self.downloadProgress = nil
                    self.errorMessage = "20초 동안 다운로드가 진행되지 않았습니다. 네트워크 상태를 확인한 뒤 다시 시도해 주세요."
                    return
                }
            }
        }
    }

    private func stopDownloadInactivityWatchdog(generation: UUID? = nil) {
        if let generation, downloadInactivityGeneration != generation { return }
        downloadInactivityTask?.cancel()
        downloadInactivityTask = nil
        downloadInactivityGeneration = nil
        lastDownloadActivity = nil
    }

    private func clearActiveDownload(generation: UUID) {
        guard activeDownloadGeneration == generation else { return }
        activeDownloadTask = nil
        activeDownloadGeneration = nil
    }

    private func cancelActiveDownload(generation: UUID? = nil) {
        if let generation, activeDownloadGeneration != generation { return }
        activeDownloadTask?.cancel()
        activeDownloadTask = nil
        activeDownloadGeneration = nil
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
            SharedMediaAudioSession.activatePlayback()
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
