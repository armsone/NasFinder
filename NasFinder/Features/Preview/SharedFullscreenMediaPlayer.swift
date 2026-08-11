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

struct SharedVideoProgressBar: View {
    let player: AVPlayer
    var compact = false

    @State private var currentSeconds = 0.0
    @State private var durationSeconds = 0.0
    @State private var timeObserver: Any?

    var body: some View {
        HStack(spacing: compact ? 5 : 10) {
            Text(formattedTime(currentSeconds))
                .frame(width: compact ? 34 : 42, alignment: .trailing)

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

            Text(formattedTime(durationSeconds))
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
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white.opacity(0.9))
            .frame(width: 44, height: 44)
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
