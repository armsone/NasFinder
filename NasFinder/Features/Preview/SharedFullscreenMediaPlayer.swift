import AVFoundation
import MediaPlayer
import SwiftUI
import UIKit

enum SharedMediaAudioSession {
    @discardableResult
    static func activatePlayback() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            if session.category != .playback || session.mode != .moviePlayback {
                try session.setCategory(.playback, mode: .moviePlayback)
            }
            try session.setActive(true)
            return true
        } catch {
            return false
        }
    }
}

/// HanClip의 전체 화면 플레이어와 같은 화면 계층을 사용하는 공용 비디오 표면입니다.
/// 재생 소스는 호출자가 소유하므로 NAS의 range streaming AVPlayer도 그대로 연결할 수 있습니다.
struct SharedVideoPlayerSurface: UIViewRepresentable {
    let player: AVPlayer
    let videoGravity: AVLayerVideoGravity

    func makeUIView(context: Context) -> SharedVideoPlayerSurfaceView {
        let view = SharedVideoPlayerSurfaceView()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = videoGravity
        return view
    }

    func updateUIView(
        _ uiView: SharedVideoPlayerSurfaceView,
        context: Context
    ) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = videoGravity
    }
}

final class SharedVideoPlayerSurfaceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        backgroundColor = .black
        playerLayer.backgroundColor = UIColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
    }
}

#if targetEnvironment(macCatalyst)
struct SharedVideoProgressBar: View {
    let player: AVPlayer
    var sourceLabel: String?
    var compact = false

    @State private var currentSeconds = 0.0
    @State private var durationSeconds = 0.0
    @State private var scrubSeconds = 0.0
    @State private var isEditing = false
    @State private var isSeekPending = false
    @State private var wasPlayingBeforeScrub = false
    @State private var priorRate: Float = 1.0
    @State private var seekGeneration = 0
    @State private var isViewActive = false
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: ui(compact ? 5 : 10)) {
            Text(formattedTime(displayedSeconds))
                .frame(width: ui(compact ? 34 : 42), alignment: .trailing)

            VStack(spacing: ui(-4)) {
                if let sourceLabel {
                    Text(sourceLabel)
                        .font(PorcelainTypeface.font(size: ui(11), weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Slider(
                    value: Binding(
                        get: { min(displayedSeconds, sliderMaximum) },
                        set: { handleSliderValueChange($0) }
                    ),
                    in: 0...sliderMaximum,
                    onEditingChanged: { editing in
                        handleEditingChanged(editing)
                    }
                )
                .tint(.white)
                .accessibilityLabel("재생 위치")
                .accessibilityValue(
                    "\(formattedTime(displayedSeconds)) / \(formattedTime(durationSeconds))"
                )
            }

            Text(formattedTime(durationSeconds))
                .frame(width: ui(compact ? 34 : 42), alignment: .leading)
        }
        .font(.system(size: ui(11), weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, ui(compact ? 8 : 14))
        .frame(height: ui(44))
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .onAppear(perform: startObserving)
        .onDisappear(perform: stopObserving)
        .accessibilityElement(children: .contain)
    }

    private var sliderMaximum: Double { max(durationSeconds, 0.1) }

    private var displayedSeconds: Double {
        if isEditing || isSeekPending {
            return scrubSeconds
        }
        return currentSeconds
    }

    private func beginScrubSessionIfNeeded() {
        guard !isEditing && !isSeekPending else { return }
        wasPlayingBeforeScrub = (player.timeControlStatus == .playing || player.rate > 0)
        priorRate = player.rate > 0 ? player.rate : 1.0
        scrubSeconds = currentSeconds
        if wasPlayingBeforeScrub {
            player.pause()
        }
    }

    private func handleEditingChanged(_ editing: Bool) {
        if editing {
            guard !isEditing else { return }
            beginScrubSessionIfNeeded()
            isEditing = true
            seekGeneration += 1
        } else {
            guard isEditing else { return }
            isEditing = false
            performSeek(to: scrubSeconds, shouldResume: wasPlayingBeforeScrub, targetRate: priorRate)
        }
    }

    private func handleSliderValueChange(_ newValue: Double) {
        let clamped = min(max(newValue, 0), sliderMaximum)
        if isEditing {
            scrubSeconds = clamped
            return
        }
        beginScrubSessionIfNeeded()
        performSeek(to: clamped, shouldResume: wasPlayingBeforeScrub, targetRate: priorRate)
    }

    private func performSeek(to seconds: Double, shouldResume: Bool, targetRate: Float) {
        let targetSeconds = min(max(seconds, 0), sliderMaximum)
        seekGeneration += 1
        let thisGeneration = seekGeneration
        isSeekPending = true
        currentSeconds = targetSeconds
        scrubSeconds = targetSeconds

        let targetTime = CMTime(seconds: targetSeconds, preferredTimescale: 600)
        player.seek(
            to: targetTime,
            toleranceBefore: .zero,
            toleranceAfter: .zero
        ) { [player] finished in
            Task { @MainActor in
                guard isViewActive else { return }
                guard thisGeneration == seekGeneration else { return }
                isSeekPending = false
                currentSeconds = targetSeconds
                scrubSeconds = targetSeconds
                guard finished else { return }
                guard player.currentItem != nil else { return }
                if shouldResume {
                    if targetRate > 0 && targetRate != 1.0 {
                        player.rate = targetRate
                    } else {
                        player.play()
                    }
                }
            }
        }
    }

    private func startObserving() {
        isViewActive = true
        guard timeObserver == nil else { return }
        let currentItem = player.currentItem
        if let initialDuration = currentItem?.duration.seconds, initialDuration.isFinite, initialDuration > 0 {
            durationSeconds = initialDuration
        }
        let initialSeconds = player.currentTime().seconds
        if initialSeconds.isFinite && initialSeconds > 0 {
            currentSeconds = max(0, initialSeconds)
            scrubSeconds = currentSeconds
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            let duration = player.currentItem?.duration.seconds
            let callbackGeneration = seekGeneration
            Task { @MainActor in
                guard isViewActive else { return }
                if let duration, duration.isFinite, duration > 0 {
                    durationSeconds = duration
                }
                guard !isEditing && !isSeekPending else { return }
                guard callbackGeneration == seekGeneration else { return }
                if seconds.isFinite {
                    let validSeconds = max(0, seconds)
                    currentSeconds = validSeconds
                    scrubSeconds = validSeconds
                }
            }
        }
    }

    private func stopObserving() {
        isViewActive = false
        seekGeneration += 1
        isSeekPending = false
        isEditing = false
        wasPlayingBeforeScrub = false
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#else
struct SharedVideoProgressBar: View {
    let player: AVPlayer
    var sourceLabel: String?
    var compact = false

    @State private var currentSeconds = 0.0
    @State private var durationSeconds = 0.0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: ui(compact ? 5 : 10)) {
            Text(formattedTime(currentSeconds))
                .frame(width: ui(compact ? 34 : 42), alignment: .trailing)

            VStack(spacing: ui(-4)) {
                if let sourceLabel {
                    Text(sourceLabel)
                        .font(PorcelainTypeface.font(size: ui(11), weight: .regular))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(1)
                }

                Slider(
                    value: Binding(
                        get: { min(currentSeconds, sliderMaximum) },
                        set: { seek(to: $0) }
                    ),
                    in: 0...sliderMaximum
                )
                .tint(.white)
                .accessibilityLabel("재생 위치")
                .accessibilityValue(
                    "\(formattedTime(currentSeconds)) / \(formattedTime(durationSeconds))"
                )
            }

            Text(formattedTime(durationSeconds))
                .frame(width: ui(compact ? 34 : 42), alignment: .leading)
        }
        .font(.system(size: ui(11), weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.9))
        .padding(.horizontal, ui(compact ? 8 : 14))
        .frame(height: ui(44))
        .background(Color.black.opacity(0.28), in: Capsule())
        .overlay {
            Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1)
        }
        .onAppear(perform: startObserving)
        .onDisappear(perform: stopObserving)
        .accessibilityElement(children: .contain)
    }

    private var sliderMaximum: Double { max(durationSeconds, 0.1) }

    private func seek(to seconds: Double) {
        currentSeconds = min(max(seconds, 0), sliderMaximum)
        player.seek(
            to: CMTime(seconds: currentSeconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }

    private func startObserving() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            let duration = player.currentItem?.duration.seconds
            Task { @MainActor in
                if seconds.isFinite { currentSeconds = max(0, seconds) }
                if let duration, duration.isFinite, duration > 0 {
                    durationSeconds = duration
                }
            }
        }
    }

    private func stopObserving() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func formattedTime(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3_600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
#endif

struct SharedVideoMiniProgressLine: View {
    let player: AVPlayer

    @State private var currentSeconds = 0.0
    @State private var durationSeconds = 0.0
    @State private var timeObserver: Any?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.22))
                Rectangle()
                    .fill(Color.white.opacity(0.92))
                    .frame(width: proxy.size.width * progress)
            }
        }
        .onAppear(perform: startObserving)
        .onDisappear(perform: stopObserving)
        .accessibilityHidden(true)
    }

    private var progress: CGFloat {
        guard durationSeconds > 0 else { return 0 }
        return CGFloat(min(1, max(0, currentSeconds / durationSeconds)))
    }

    private func startObserving() {
        guard timeObserver == nil else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { time in
            let seconds = time.seconds
            let duration = player.currentItem?.duration.seconds
            Task { @MainActor in
                if seconds.isFinite { currentSeconds = max(seconds, 0) }
                if let duration, duration.isFinite, duration > 0 {
                    durationSeconds = duration
                }
            }
        }
    }

    private func stopObserving() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }
}

struct SharedPlayerCircleLabel: View {
    let systemImage: String
    var isActive = false

    var body: some View {
        InterfaceIcon(systemName: systemImage, size: ui(22))
            .font(.system(size: ui(16), weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: ui(44), height: ui(44))
            .background(
                isActive ? Color.white.opacity(0.16) : Color.black.opacity(0.28),
                in: Circle()
            )
            .overlay {
                Circle().stroke(
                    Color.white.opacity(isActive ? 0.38 : 0.18),
                    lineWidth: 1
                )
            }
    }
}

struct SharedSystemVolumeView: UIViewRepresentable {
    let onSliderReady: (UISlider) -> Void

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        resolveSlider(in: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        resolveSlider(in: uiView)
    }

    private func resolveSlider(in view: MPVolumeView) {
        DispatchQueue.main.async {
            if let slider = view.subviews.compactMap({ $0 as? UISlider }).first {
                onSliderReady(slider)
            }
        }
    }
}
