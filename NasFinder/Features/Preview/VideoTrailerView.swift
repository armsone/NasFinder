import AVFoundation
import SwiftUI
import UIKit

// Adapter for the two analysis sources shared directly with HanClip.
enum MediaError: LocalizedError {
    case videoTrackUnavailable
    var errorDescription: String? { "분석할 수 있는 영상 트랙이 없습니다." }
}

private enum TrailerError: LocalizedError {
    case exportUnavailable, exportFailed
    var errorDescription: String? {
        switch self {
        case .exportUnavailable: "이 영상 형식으로 예고편을 만들 수 없습니다."
        case .exportFailed: "예고편을 만들지 못했습니다. 다시 시도해 주세요."
        }
    }
}

struct VideoTrailerView: View {
    let items: [RemoteFileItem]
    let service: any RemoteFileService
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var inboxStore: SharedInboxStore
    @StateObject private var model = VideoTrailerModel()
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                if let output = model.outputURL {
                    let previewService = TrailerOutputFileService(url: output)
                    RemotePreviewView(item: previewService.item, sequentialItems: [previewService.item],
                        service: previewService, accessoryControls: AnyView(trailerControls),
                        onClose: { model.stop(); dismiss() },
                        playbackSuspended: showingSettings || model.isBusy)
                        .id(output)
                    if model.isBusy || model.error != nil {
                        VStack {
                            Spacer()
                            if model.isBusy { ProgressView().tint(.white) }
                            Text(model.error ?? model.status).font(.footnote).foregroundStyle(.white)
                                .padding(12).background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .padding(.bottom, 150)
                    }
                } else {
                    VStack(spacing: 16) {
                        Spacer()
                        if model.isBusy { ProgressView(); Text(model.status).foregroundStyle(.secondary) }
                        if let error = model.error {
                            Text(error).font(.footnote).foregroundStyle(.red)
                            Button("다시 시도") { model.start(items: items, service: service) }.disabled(model.isBusy)
                        }
                        Spacer()
                        Text("기기에서 분석합니다. 원본은 변경하지 않습니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .padding().navigationTitle("예고편 보기").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("취소") { model.stop(); dismiss() }
                        }
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                VideoTrailerSettings(sources: model.sources,
                    total: model.scenes.reduce(0) { $0 + $1.length },
                    clipLength: model.scenes.first?.length ?? model.recommendedClipLength,
                    aspectRatio: model.aspectRatio) { sources, total, length, aspect in
                    showingSettings = false
                    model.start(items: items, service: service, sourceOrder: sources.map(\.id),
                                total: total, clipLength: length, aspectRatio: aspect)
                }
            }
            .task { if model.sources.isEmpty { model.start(items: items, service: service) } }
        }
    }

    private var trailerControls: some View {
        HStack(spacing: 8) {
            Button {
                model.save(to: inboxStore, filename: items.count == 1 ? items[0].name : "모음-\(items.count)개영상")
            } label: {
                SharedPlayerCircleLabel(systemImage: model.isSaved ? "checkmark.circle" : "square.and.arrow.down")
            }
            .accessibilityLabel(model.isSaved ? "폰하드에 저장됨" : "폰하드에 저장")
            .disabled(model.isBusy || model.isSaved)
            Button { showingSettings = true } label: {
                SharedPlayerCircleLabel(systemImage: "slider.horizontal.3")
            }
            .accessibilityLabel("예고편 조절").disabled(model.isBusy)
        }
    }
}

private struct TrailerOutputFileService: RemoteFileService {
    let url: URL
    let connection = RemoteConnection(id: UUID(uuidString: "8409962E-C55D-4B8E-92C9-876708AD3945")!,
        name: "예고편", kind: .synology, host: "localhost", username: "")
    var item: RemoteFileItem {
        RemoteFileItem(connectionID: connection.id, path: url.path, name: "예고편.mp4", kind: .file,
            size: (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init),
            modifiedAt: nil, contentTypeIdentifier: "public.mpeg-4")
    }
    func list(directory path: String?) async throws -> [RemoteFileItem] { [item] }
    func download(_ item: RemoteFileItem) async throws -> URL {
        guard item.path == url.path, FileManager.default.fileExists(atPath: url.path) else { throw TrailerError.exportFailed }
        return url
    }
    func testConnection() async throws { _ = try await download(item) }
}

private struct VideoTrailerSettings: View {
    @State var sources: [VideoTrailerSource]
    @State var total: Double
    @State var clipLength: Double
    @State var aspectRatio: OutputAspectRatio?
    let regenerate: ([VideoTrailerSource], Double, Double, OutputAspectRatio?) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDuration = false
    @State private var showingClipLength = false
    @State private var draggedSourceID: Int?
    @State private var dragLocation = CGPoint.zero
    @State private var dragAnchor = CGSize.zero
    @State private var sourceFrames: [Int: CGRect] = [:]
    @State private var sourceImages: [Int: UIImage] = [:]

    private var originalTotal: Double { sources.reduce(0) { $0 + $1.duration } }
    private var proposal: [VideoTrailerScene] { VideoTrailerBatchPlan.proposal(sources: sources, total: total, clipLength: clipLength) }
    private var actualTotal: Double { proposal.reduce(0) { $0 + $1.length } }
    private var percent: Double { originalTotal > 0 ? actualTotal / originalTotal * 100 : 0 }
    private var maximumClipLength: Double { min(30, sources.map(\.duration).max() ?? 30) }
    private var excludedCount: Int { sources.filter { source in !proposal.contains { $0.sourceID == source.id } }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(trailerDurationTitle(actualTotal)).font(.title2.weight(.semibold)).monospacedDigit()
                            Spacer()
                            Text("\(proposal.count)장면 · \(clipLength.formatted(.number.precision(.fractionLength(0...1))))초씩")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Text("원본 \(trailerDurationTitle(originalTotal)) 중 \(percent.formatted(.number.precision(.fractionLength(1))))%")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Divider()
                    VStack(alignment: .leading, spacing: 4) {
                        Text("얼마나 길게 볼까요?").font(.subheadline.weight(.semibold))
                        HStack(spacing: 5) {
                            ForEach([30.0, 60, 120, 180, 300], id: \.self) { value in
                                TrailerChoiceButton(title: trailerDurationTitle(value), selected: abs(total - value) < 0.01) {
                                    total = value
                                    showingDuration = false
                                }
                                .disabled(value > originalTotal)
                                .opacity(value > originalTotal ? 0.35 : 1)
                            }
                        }
                        otherLengthButton(value: trailerDurationTitle(total), expanded: showingDuration) { showingDuration.toggle() }
                        if showingDuration, originalTotal > 1 {
                            Slider(value: $total, in: 1...originalTotal, step: 1)
                                .accessibilityLabel("예고편 총길이")
                                .accessibilityValue(trailerDurationTitle(total))
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("한 장면은 얼마나 볼까요?").font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            ForEach([2.0, 4, 6, 8].filter { $0 <= maximumClipLength }, id: \.self) { value in
                                TrailerChoiceButton(title: "\(Int(value))초", selected: abs(clipLength - value) < 0.01) {
                                    clipLength = value
                                    showingClipLength = false
                                }
                            }
                        }
                        otherLengthButton(value: "\(clipLength.formatted(.number.precision(.fractionLength(0...1))))초", expanded: showingClipLength) { showingClipLength.toggle() }
                        if showingClipLength, maximumClipLength > 1 {
                            Slider(value: $clipLength, in: 1...maximumClipLength, step: 1)
                                .accessibilityLabel("공통 장면 길이")
                                .accessibilityValue("\(Int(clipLength))초")
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("화면 모양").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(aspectRatio?.title ?? "첫 영상 비율").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack(spacing: 4) {
                            Button { aspectRatio = nil } label: {
                                Text("원본").font(.caption2.weight(.semibold))
                                    .frame(width: 32, height: 32)
                                    .background(aspectRatio == nil ? Color.accentColor.opacity(0.14) : Color.clear,
                                                in: RoundedRectangle(cornerRadius: 8))
                                    .overlay { RoundedRectangle(cornerRadius: 8).stroke(aspectRatio == nil ? Color.accentColor : Color.secondary.opacity(0.72), lineWidth: aspectRatio == nil ? 2 : 1) }
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("첫 영상 화면 비율")
                            .accessibilityAddTraits(aspectRatio == nil ? .isSelected : [])
                            ForEach(OutputAspectRatio.allCases) { ratio in
                                Button { aspectRatio = ratio } label: {
                                    TrailerAspectRatioIcon(ratio: ratio, isSelected: aspectRatio == ratio)
                                        .frame(maxWidth: .infinity, minHeight: 44)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(ratio.title)
                                .accessibilityAddTraits(aspectRatio == ratio ? .isSelected : [])
                            }
                        }
                    }
                    if sources.count > 1 {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("영상 순서").font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("누른 채 옮기세요").font(.caption).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                                    TrailerSourceThumbnail(source: source, number: index + 1, image: thumbnailImage(for: source.id))
                                        .frame(height: 60).clipped()
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(key: TrailerSourceFramesKey.self,
                                                    value: [source.id: geometry.frame(in: .named("trailerOrder"))])
                                            }
                                        }
                                        .opacity(draggedSourceID == source.id ? 0.25 : 1)
                                        .highPriorityGesture(
                                            DragGesture(minimumDistance: 5, coordinateSpace: .named("trailerOrder"))
                                                .onChanged { value in
                                                    if draggedSourceID == nil, let frame = sourceFrames[source.id] {
                                                        draggedSourceID = source.id
                                                        dragAnchor = CGSize(width: value.startLocation.x - frame.midX,
                                                                            height: value.startLocation.y - frame.midY)
                                                    }
                                                    guard draggedSourceID == source.id else { return }
                                                    dragLocation = value.location
                                                    if let target = sources.first(where: {
                                                        $0.id != source.id && sourceFrames[$0.id]?.contains(value.location) == true
                                                    }), let from = sources.firstIndex(where: { $0.id == source.id }),
                                                       let to = sources.firstIndex(where: { $0.id == target.id }) {
                                                        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.12)) {
                                                            sources.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
                                                        }
                                                    }
                                                }
                                                .onEnded { _ in draggedSourceID = nil }
                                        )
                                        .accessibilityAction(named: "앞으로 이동") { if index > 0 { sources.swapAt(index, index - 1) } }
                                        .accessibilityAction(named: "뒤로 이동") { if index + 1 < sources.count { sources.swapAt(index, index + 1) } }
                                }
                            }
                            .overlay(alignment: .topLeading) {
                                if let id = draggedSourceID, let source = sources.first(where: { $0.id == id }), let frame = sourceFrames[id] {
                                    TrailerSourceThumbnail(source: source, number: (sources.firstIndex(where: { $0.id == id }) ?? 0) + 1, image: thumbnailImage(for: id))
                                        .frame(width: frame.width, height: 60).clipped()
                                        .shadow(radius: 6)
                                        .position(x: dragLocation.x - dragAnchor.width, y: dragLocation.y - dragAnchor.height)
                                        .allowsHitTesting(false)
                                }
                            }
                            .coordinateSpace(name: "trailerOrder")
                            .onPreferenceChange(TrailerSourceFramesKey.self) { sourceFrames = $0 }
                        }
                    }
                    if abs(total - actualTotal) >= 0.5 {
                        Text("선택한 \(trailerDurationTitle(total))에 가장 가까운 길이로 맞췄어요")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if excludedCount > 0 {
                        Text("\(excludedCount)개 영상은 담기지 않아요. 총길이를 늘리거나 장면 길이를 줄여보세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button("자동 추천으로 되돌리기") {
                        clipLength = VideoTrailerModel.recommendedLength(sources)
                        total = sources.reduce(0) { $0 + $1.plan.recommendedTotal }
                        showingDuration = false
                        showingClipLength = false
                    }
                    .font(.caption).frame(minHeight: 30)
                }
                .padding(16)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
            }
            .safeAreaInset(edge: .bottom) {
                Button { regenerate(sources, total, clipLength, aspectRatio) } label: {
                    Text("\(trailerDurationTitle(actualTotal)) 예고편 만들기").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).disabled(proposal.isEmpty)
                .padding(.horizontal).padding(.vertical, 8).background(.bar)
            }
            .navigationTitle("예고편 조절").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
        }
    }

    private func thumbnailImage(for id: Int) -> Binding<UIImage?> {
        Binding(get: { sourceImages[id] }, set: { sourceImages[id] = $0 })
    }

    private func otherLengthButton(value: String, expanded: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text("다른 길이")
                Spacer()
                Text(value).foregroundStyle(.secondary)
                Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption2)
            }
            .font(.caption).frame(minHeight: 30).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct TrailerSourceFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private func trailerDurationTitle(_ seconds: Double) -> String {
    let value = max(0, Int(seconds.rounded()))
    let hours = value / 3600
    let minutes = value / 60 % 60
    let seconds = value % 60
    return [hours > 0 ? "\(hours)시간" : nil, minutes > 0 ? "\(minutes)분" : nil,
            seconds > 0 || value == 0 ? "\(seconds)초" : nil].compactMap { $0 }.joined(separator: " ")
}

private struct TrailerChoiceButton: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if selected { Image(systemName: "checkmark").font(.caption2) }
            }
            .font(.footnote.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.clear, lineWidth: 1) }
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.accentColor : Color.primary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// Shape proportions, 32pt frame and selected outline imported from HanClip's AspectRatioIcon.
private struct TrailerAspectRatioIcon: View {
    let ratio: OutputAspectRatio
    let isSelected: Bool
    private var rectangleSize: CGSize {
        let aspect = ratio.renderSize.width / ratio.renderSize.height
        return aspect >= 1 ? CGSize(width: 24, height: 24 / aspect) : CGSize(width: 24 * aspect, height: 24)
    }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
            RoundedRectangle(cornerRadius: 2)
                .stroke(isSelected ? Color.accentColor : Color.secondary, lineWidth: 2)
                .frame(width: rectangleSize.width, height: rectangleSize.height)
        }
        .frame(width: 32, height: 32)
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor : Color.secondary.opacity(0.72), lineWidth: isSelected ? 2 : 1)
        }
    }
}

private struct TrailerSourceThumbnail: View {
    let source: VideoTrailerSource
    let number: Int
    @Binding var image: UIImage?
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(uiColor: .tertiarySystemFill)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.white)
                .padding(6).background(.black.opacity(0.65), in: Circle()).padding(5)
        }
        .frame(height: 60).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .accessibilityLabel("\(number)번째 영상, \(source.name)")
        .accessibilityValue("원본 \(trailerDurationTitle(source.duration))")
        .task(id: source.id) {
            guard image == nil else { return }
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: source.url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 240, height: 240)
            do {
                let frame = try await generator.image(at: CMTime(seconds: source.plan.analysis.peakTime, preferredTimescale: 600))
                if !Task.isCancelled { image = UIImage(cgImage: frame.image) }
            } catch { }
        }
    }
}

@MainActor
private final class VideoTrailerModel: ObservableObject {
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false
    @Published private(set) var error: String?
    @Published private(set) var sources: [VideoTrailerSource] = []
    @Published private(set) var scenes: [VideoTrailerScene] = []
    @Published private(set) var outputURL: URL?
    @Published private(set) var isSaved = false
    @Published private(set) var aspectRatio: OutputAspectRatio?
    private var task: Task<Void, Never>?
    private var directory: URL?
    private var exporter: AVAssetExportSession?
    private var awakeActivityID: UUID?

    var recommendedClipLength: Double { Self.recommendedLength(sources) }
    static func recommendedLength(_ sources: [VideoTrailerSource]) -> Double {
        let lengths = sources.map { $0.plan.recommendedClipLength }.sorted()
        return min(sources.map(\.duration).min() ?? 4, lengths.isEmpty ? 4 : lengths[lengths.count / 2])
    }

    deinit {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func start(items: [RemoteFileItem], service: any RemoteFileService,
               sourceOrder: [Int]? = nil, total: Double? = nil,
               clipLength: Double? = nil, aspectRatio: OutputAspectRatio? = nil) {
        guard !isBusy, !items.isEmpty else { return }
        isBusy = true
        error = nil
        task = Task {
            let activityID = UUID()
            awakeActivityID = activityID
            ScreenAwakeController.shared.beginActivity(activityID)
            defer {
                ScreenAwakeController.shared.finishActivity(activityID)
                awakeActivityID = nil
                isBusy = false
                task = nil
            }
            do {
                if directory == nil {
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("NasFinderTrailer-\(UUID().uuidString)", isDirectory: true)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    directory = folder
                }
                guard let directory else { throw TrailerError.exportFailed }
                for (index, item) in items.enumerated() where !sources.contains(where: { $0.id == index }) {
                    status = "\(index + 1)/\(items.count) · \(item.name) · 영상을 받는 중…"
                    await DownloadCache.shared.protect(item)
                    let staged: URL
                    do {
                        let downloaded = try await service.download(item)
                        try Task.checkCancellation()
                        staged = directory.appendingPathComponent("source-\(UUID().uuidString)")
                            .appendingPathExtension(downloaded.pathExtension)
                        try await Task.detached(priority: .userInitiated) {
                            try FileManager.default.copyItem(at: downloaded, to: staged)
                        }.value
                        try Task.checkCancellation()
                    } catch {
                        await DownloadCache.shared.release(item)
                        throw error
                    }
                    await DownloadCache.shared.release(item)
                    let asset = AVURLAsset(url: staged)
                    let duration = try await asset.load(.duration).seconds
                    guard duration.isFinite, duration > 0,
                          try await asset.loadTracks(withMediaType: .video).first != nil else {
                        throw MediaError.videoTrackUnavailable
                    }
                    status = "\(index + 1)/\(items.count) · \(item.name) · 한양으로 장면을 고르는 중…"
                    let buckets = max(192, min(2048, Int(min(1024, duration) * 2)))
                    let analysis = try await AudioAnalysisService.analyze(url: staged, bucketCount: buckets)
                    try Task.checkCancellation()
                    sources.append(VideoTrailerSource(id: index, name: item.name, url: staged,
                                                       plan: VideoTrailerPlan(analysis: analysis, duration: duration)))
                }
                if let sourceOrder {
                    let byID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                    guard sourceOrder.count == sources.count, Set(sourceOrder).count == sources.count else {
                        throw TrailerError.exportFailed
                    }
                    sources = try sourceOrder.map { id in
                        guard let source = byID[id] else { throw TrailerError.exportFailed }
                        return source
                    }
                }
                let selected = VideoTrailerBatchPlan.proposal(sources: sources,
                    total: total ?? sources.reduce(0) { $0 + $1.plan.recommendedTotal },
                    clipLength: clipLength ?? recommendedClipLength)
                guard !selected.isEmpty else { throw TrailerError.exportFailed }
                status = "선택한 장면을 이어 붙이는 중…"
                let composition = AVMutableComposition()
                guard let outputVideo = composition.addMutableTrack(withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid) else { throw TrailerError.exportUnavailable }
                let outputAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                let sourceByID = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, $0) })
                var cursor = CMTime.zero
                var instructions: [AVMutableVideoCompositionInstruction] = []
                var renderSize = aspectRatio?.renderSize
                for segment in selected {
                    try Task.checkCancellation()
                    guard let source = sourceByID[segment.sourceID] else { throw TrailerError.exportFailed }
                    let asset = AVURLAsset(url: source.url)
                    guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.videoTrackUnavailable }
                    let naturalSize = try await video.load(.naturalSize)
                    let transform = try await video.load(.preferredTransform)
                    if renderSize == nil {
                        let oriented = CGRect(origin: .zero, size: naturalSize).applying(transform)
                        renderSize = OutputAspectRatio.renderSize(for: CGSize(width: abs(oriented.width), height: abs(oriented.height)))
                    }
                    guard let renderSize, naturalSize.width > 0, naturalSize.height > 0 else { throw TrailerError.exportUnavailable }
                    let range = CMTimeRange(start: CMTime(seconds: segment.start, preferredTimescale: 600),
                                            duration: CMTime(seconds: segment.length, preferredTimescale: 600))
                    try outputVideo.insertTimeRange(range, of: video, at: cursor)
                    if let audio = try await asset.loadTracks(withMediaType: .audio).first, let outputAudio {
                        let audioRange = try await audio.load(.timeRange)
                        let overlap = CMTimeRangeGetIntersection(range, otherRange: audioRange)
                        if overlap.duration.seconds > 0 {
                            try outputAudio.insertTimeRange(overlap, of: audio,
                                at: CMTimeAdd(cursor, CMTimeSubtract(overlap.start, range.start)))
                        }
                    }
                    let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: outputVideo)
                    layer.setTransform(TrailerOutputRenderer.aspectFillTransform(naturalSize: naturalSize,
                        preferredTransform: transform, renderSize: renderSize), at: cursor)
                    let instruction = AVMutableVideoCompositionInstruction()
                    instruction.timeRange = CMTimeRange(start: cursor, duration: range.duration)
                    instruction.layerInstructions = [layer]
                    instruction.backgroundColor = UIColor.black.cgColor
                    instructions.append(instruction)
                    cursor = CMTimeAdd(cursor, range.duration)
                }
                guard let renderSize else { throw TrailerError.exportUnavailable }
                let videoComposition = AVMutableVideoComposition()
                videoComposition.renderSize = renderSize
                videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
                videoComposition.instructions = instructions
                guard let session = AVAssetExportSession(asset: composition,
                    presetName: AVAssetExportPresetHighestQuality) else { throw TrailerError.exportUnavailable }
                let output = directory.appendingPathComponent("trailer-\(UUID().uuidString).mp4")
                session.videoComposition = videoComposition
                session.outputURL = output
                session.outputFileType = .mp4
                session.shouldOptimizeForNetworkUse = true
                exporter = session
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    session.exportAsynchronously { continuation.resume() }
                }
                try Task.checkCancellation()
                guard session.status == .completed else { throw session.error ?? TrailerError.exportFailed }
                exporter = nil
                let outputAsset = AVURLAsset(url: output)
                guard try await outputAsset.load(.isPlayable) else { throw TrailerError.exportFailed }
                guard SharedMediaAudioSession.activatePlayback() else { throw TrailerError.exportFailed }
                let previousOutput = outputURL
                outputURL = output
                isSaved = false
                self.aspectRatio = aspectRatio
                scenes = selected
                if let previousOutput { try? FileManager.default.removeItem(at: previousOutput) }
                let originalTotal = sources.reduce(0) { $0 + $1.duration }
                status = "원본 \(videoTrailerTime(originalTotal)) → 예고편 \(videoTrailerTime(cursor.seconds)) · \(selected.count)개 클립"
            } catch is CancellationError {
                cleanup()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func save(to store: SharedInboxStore, filename: String) {
        guard let outputURL, !isBusy, !isSaved else { return }
        isBusy = true
        error = nil
        task = Task {
            do {
                let base = (filename as NSString).deletingPathExtension
                _ = try await store.importDownloadedFile(at: outputURL,
                    originalFilename: "\(base)-예고편.mp4", contentTypeIdentifier: "public.mpeg-4")
                isSaved = true
                status = "폰하드에 저장했습니다."
            } catch {
                self.error = "폰하드에 저장하지 못했습니다: \(error.localizedDescription)"
            }
            if Task.isCancelled { cleanup() }
            isBusy = false
            task = nil
        }
    }

    func stop() {
        if let awakeActivityID { ScreenAwakeController.shared.finishActivity(awakeActivityID) }
        task?.cancel()
        exporter?.cancelExport()
        if task == nil { cleanup() }
    }

    private func cleanup() {
        exporter = nil
        sources = []
        scenes = []
        outputURL = nil
        if let directory { try? FileManager.default.removeItem(at: directory) }
        directory = nil
    }
}
