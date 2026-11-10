import AVFoundation
import CoreImage
import UIKit

// MARK: - 중립 판정과 고정 기준점

extension TrailerClipAdjustments {
    /// 배속 1, 중립 색상, 키프레임·디졸브·자막 큐 없음. 이 값이면 기존(레거시) 렌더 경로와 같은 결과다.
    var isNeutral: Bool {
        rate == 1 && (color?.isNeutral ?? true) && keyframes.isEmpty
            && (transition?.dissolveDuration ?? 0) <= 0.0001 && cues.isEmpty
    }
    var isAdvanced: Bool { !isNeutral }

    /// 원본 시간 `windowStart...windowEnd` 안에 있는 직접 놓은 자막 구간과 키프레임을 하나로 묶은 하드 앵커 구간.
    /// 자동 길이·예산·박자가 창을 줄이거나 옮길 때 이 구간은 남아야 한다. 창 밖의 점은 저장만 되고 여기서 빠진다(되돌리면 다시 나타남).
    /// 창 전체를 고정하지는 않는다: 앵커 둘레의 문맥은 계속 줄이고 추천할 수 있다.
    func anchorSpan(windowStart: Double, windowEnd: Double) -> (start: Double, end: Double)? {
        guard windowStart.isFinite, windowEnd.isFinite, windowEnd >= windowStart else { return nil }
        var lower = Double.infinity
        var upper = -Double.infinity
        for range in manualCueSourceRanges where range.lowerBound < windowEnd && range.upperBound > windowStart {
            lower = min(lower, max(range.lowerBound, windowStart))
            upper = max(upper, min(range.upperBound, windowEnd))
        }
        let inside = keyframes.map(\.sourceTime).filter { $0 >= windowStart - 1e-6 && $0 <= windowEnd + 1e-6 }
        if let first = inside.min(), let last = inside.max() {
            lower = min(lower, first)
            upper = max(upper, last)
        }
        guard lower.isFinite, upper.isFinite, upper >= lower else { return nil }
        // 한 점뿐이어도 보이는 프레임 하나(1/30초)는 지킨다.
        return (lower, max(upper, lower + 1.0 / 30.0))
    }
}

// MARK: - 합성 입력/결과

/// 최종 타임라인의 한 클립. 복구된 입력이면 `url`/`localStart`가 원본 원본시간 → 대체 클립 지역시간 대응을 가진다.
struct TrailerComposerClip {
    var scene: VideoTrailerScene
    /// 실제로 읽는 미디어(원본 영상, 사진을 만든 정지 클립, 복구 대체 클립, 카드 클립).
    var url: URL
    /// `url` 안에서 `scene.start`(원본 시간)에 해당하는 지역 시각.
    var localStart: Double
    /// 정지 화면(사진·복구 대체·카드)이면 원본 소리와 기본 프레이밍 규칙을 쓰지 않는다.
    var isStill: Bool
    var hasSound: Bool
    var isCard = false
}

struct TrailerComposerVoice {
    var take: TrailerVoiceoverTake
    var url: URL
}

struct TrailerComposerMusic {
    var selection: TrailerMusicSelection?
    var track: AVAssetTrack
    var range: CMTimeRange
}

struct TrailerComposed {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix?
    let duration: CMTime
    /// 모든 구간(미리보기·내보내기·자막·소리)이 같이 쓰는 출력 시간표.
    let mappings: [TrailerClipTimeMapping]
    let originalSound: [TrailerMusicDucking.Clip]
    let musicPieces: Int
    let duckRamps: Int
}

enum TrailerComposerError: LocalizedError {
    case clipUnavailable
    /// 직접 놓은 음성 해설을 읽을 수 없거나 요청한 구간이 파일에 없다. 해설 파일은 그대로 두고 성공으로 넘기지 않는다.
    case voiceUnavailable
    var errorDescription: String? {
        switch self {
        case .clipUnavailable: return "영상 구성을 만들 수 없습니다."
        case .voiceUnavailable: return "음성 해설 파일을 읽을 수 없거나 정해 둔 구간이 파일에 없습니다. 해설은 그대로 보관되어 있습니다."
        }
    }
}

// MARK: - 자막 비트맵 (바운디드 캐시)

/// 자막 한 장을 글자가 있는 영역만 잘라 둔 투명 비트맵. 전체 화면 비트맵을 큐마다 들고 있지 않는다.
private final class TrailerTightCaption {
    let image: CGImage
    /// 위쪽이 0인 캔버스 좌표의 위치.
    let topLeftRect: CGRect
    init(image: CGImage, topLeftRect: CGRect) { self.image = image; self.topLeftRect = topLeftRect }
}

@MainActor
private enum TrailerCaptionBitmapCache {
    static let cache: NSCache<NSString, TrailerTightCaption> = {
        let cache = NSCache<NSString, TrailerTightCaption>()
        cache.countLimit = 48
        return cache
    }()

    static func key(_ caption: TrailerCaption, renderSize: CGSize) -> String {
        "\(caption.text)|\(caption.fontName)|\(caption.captionSize)|\(caption.colorHex)|\(caption.hasShadow)|"
            + "\(caption.shadowColorHex)|\(caption.shadowOpacity)|\(caption.lineSpacing)|\(caption.column)|\(caption.row)|"
            + "\(Int(renderSize.width))x\(Int(renderSize.height))"
    }

    static func bitmap(for caption: TrailerCaption, renderSize: CGSize) -> TrailerTightCaption? {
        let key = key(caption, renderSize: renderSize) as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let image = TrailerCaptionRenderer.renderImage(
            text: caption.text, fontName: caption.fontName, captionSize: caption.captionSize,
            textColorHex: caption.colorHex, hasShadow: caption.hasShadow, shadowColorHex: caption.shadowColorHex,
            shadowOpacity: caption.shadowOpacity, lineSpacing: caption.lineSpacing,
            column: caption.column, row: caption.row, renderSize: renderSize)?.cgImage,
            let tight = tighten(image) else { return nil }
        cache.setObject(tight, forKey: key)
        return tight
    }

    /// 투명하지 않은 픽셀의 경계 상자만 새 비트맵으로 복사한다(원래 전체 화면 비트맵은 바로 풀린다).
    private static func tighten(_ image: CGImage) -> TrailerTightCaption? {
        let width = image.width, height = image.height
        guard width > 0, height > 0 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            let row = y * width * 4
            for x in 0..<width where pixels[row + x * 4 + 3] != 0 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                maxY = y
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        // 그림자 번짐을 위해 여백을 둔다.
        let pad = 2
        let rect = CGRect(x: max(0, minX - pad), y: max(0, minY - pad),
                          width: min(width, maxX + pad + 1) - max(0, minX - pad),
                          height: min(height, maxY + pad + 1) - max(0, minY - pad))
        guard let cropped = image.cropping(to: rect),
              let context = CGContext(data: nil, width: cropped.width, height: cropped.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: cropped.width, height: cropped.height))
        guard let copy = context.makeImage() else { return nil }
        return TrailerTightCaption(image: copy, topLeftRect: rect)
    }
}

// MARK: - 캐노니컬 합성기

/// 미리보기와 내보내기가 같이 쓰는 단 하나의 타임라인 합성기. 클립·배속·디졸브·색·키프레임·자막 큐·음성 해설·음악을
/// 한 번에 AVMutableComposition + 사용자 지정 컴포지터 지시로 만든다. 같은 입력이면 같은 시간표와 같은 지시가 나온다.
@MainActor
enum TrailerAdvancedComposer {
    private static let timescale: CMTimeScale = 600

    private static func ticks(_ seconds: Double) -> Int64 { Int64((seconds * Double(timescale)).rounded()) }
    private static func time(_ ticks: Int64) -> CMTime { CMTime(value: ticks, timescale: timescale) }

    /// 원본 소리가 합쳐질 때의 A/B 트랙 한 쌍의 음량 이벤트.
    private struct VolumeEvent {
        enum Kind { case set(Float), ramp(Float, Float, Int64) }
        let at: Int64
        let kind: Kind
    }

    static func build(
        clips: [TrailerComposerClip],
        renderSize: CGSize,
        music: TrailerComposerMusic?,
        voices: [TrailerComposerVoice],
        activity: [Int: AudioActivityEnvelope],
        isCancelled: @MainActor () -> Bool = { Task.isCancelled }
    ) async throws -> TrailerComposed {
        guard !clips.isEmpty, renderSize.width > 0, renderSize.height > 0 else { throw TrailerComposerError.clipUnavailable }

        // 1) 자산·트랙을 읽고, 실제 있는 범위로 길이를 맞춘다.
        struct Loaded {
            var asset: AVURLAsset
            var video: AVAssetTrack
            var natural: CGSize
            var preferred: CGAffineTransform
            var audio: AVAssetTrack?
            var audioRange: CMTimeRange
            var localRange: CMTimeRange
            var scene: VideoTrailerScene
        }
        var assets: [URL: AVURLAsset] = [:]
        var loaded: [Loaded] = []
        for clip in clips {
            if isCancelled() { throw CancellationError() }
            let asset = assets[clip.url] ?? AVURLAsset(url: clip.url)
            assets[clip.url] = asset
            guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MediaError.videoTrackUnavailable }
            let natural = try await video.load(.naturalSize)
            let preferred = try await video.load(.preferredTransform)
            guard natural.width > 0, natural.height > 0 else { throw MediaError.videoTrackUnavailable }
            let available = try await video.load(.timeRange)
            let wanted = CMTimeRange(start: time(ticks(clip.localStart)), duration: time(ticks(clip.scene.length)))
            var range = CMTimeRangeGetIntersection(wanted, otherRange: available)
            guard range.duration.isNumeric, range.duration.seconds > 0.0001 else { throw MediaError.videoTrackUnavailable }
            range = CMTimeRange(start: range.start, duration: range.duration)
            var audio: AVAssetTrack?
            var audioRange = CMTimeRange.zero
            if clip.hasSound, !clip.isStill, !clip.scene.muted,
               let track = try await asset.loadTracks(withMediaType: .audio).first,
               try await track.load(.isDecodable) {
                audio = track
                audioRange = try await track.load(.timeRange)
            }
            var scene = clip.scene
            // 실제로 있는 길이(원본 시간)로 맞춘다. 시작은 그대로다.
            scene = VideoTrailerScene(id: scene.id, start: scene.start, length: range.duration.seconds)
            scene.sourceID = clip.scene.sourceID
            scene.muted = clip.scene.muted
            scene.fitsFrame = clip.scene.fitsFrame
            scene.volume = clip.scene.volume
            scene.offsetX = clip.scene.offsetX
            scene.offsetY = clip.scene.offsetY
            scene.caption = clip.scene.caption
            scene.adjustments = clip.scene.adjustments
            loaded.append(Loaded(asset: asset, video: video, natural: natural, preferred: preferred, audio: audio,
                                 audioRange: audioRange, localRange: range, scene: scene))
        }

        // 2) 공통 시간표. 이후 모든 시각은 이 표의 600분의 1초 정수에서 나온다.
        let inputs = loaded.enumerated().map { index, item in
            TrailerClipInput(sceneID: index, sourceID: item.scene.sourceID, sourceStart: item.scene.start,
                             sourceLength: item.scene.length, rate: item.scene.adjustments?.rate ?? 1,
                             requestedOutgoingOverlap: item.scene.adjustments?.transition?.dissolveDuration ?? 0)
        }
        let raw = try TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs)
        var startTicks: [Int64] = []
        var durationTicks: [Int64] = []
        var outgoingTicks: [Int64] = []
        var cursorTicks: Int64 = 0
        for (index, map) in raw.enumerated() {
            let duration = max(1, ticks(map.outputDuration))
            let outgoing = index < raw.count - 1 ? min(ticks(map.outgoingOverlap), duration - 1) : 0
            startTicks.append(cursorTicks)
            durationTicks.append(duration)
            outgoingTicks.append(max(0, outgoing))
            cursorTicks += duration - max(0, outgoing)
        }
        // 인접한 중첩이 앞 클립의 입장에서도 들어맞도록 들어오는 중첩을 이웃의 나가는 중첩으로 둔다.
        var incomingTicks: [Int64] = [0] + outgoingTicks.dropLast()
        for index in incomingTicks.indices {
            // 한 클립의 들어오는+나가는 중첩이 길이를 넘지 않는다(삼중 중첩 금지).
            let limit = durationTicks[index] - 1
            if incomingTicks[index] + outgoingTicks[index] > limit {
                outgoingTicks[index] = max(0, limit - incomingTicks[index])
                if index + 1 < incomingTicks.count { incomingTicks[index + 1] = outgoingTicks[index] }
            }
        }
        // 중첩을 줄였다면 시작 시각도 다시 센다.
        cursorTicks = 0
        for index in startTicks.indices {
            startTicks[index] = cursorTicks
            cursorTicks += durationTicks[index] - outgoingTicks[index]
        }
        let bodyEndTicks = startTicks[startTicks.count - 1] + durationTicks[durationTicks.count - 1]
        var mappings: [TrailerClipTimeMapping] = []
        for (index, map) in raw.enumerated() {
            mappings.append(TrailerClipTimeMapping(
                sceneID: map.sceneID, sourceID: map.sourceID, sourceStart: map.sourceStart, sourceLength: map.sourceLength,
                rate: map.rate, outputStart: Double(startTicks[index]) / Double(timescale),
                outputDuration: Double(durationTicks[index]) / Double(timescale),
                incomingOverlap: Double(incomingTicks[index]) / Double(timescale),
                outgoingOverlap: Double(outgoingTicks[index]) / Double(timescale)))
        }

        // 음성 해설이 요구하는 출력 끝은 바닥값이다. 영상이 더 짧아도 해설을 자르지 않는다.
        let voiceFloorTicks = voices.compactMap { $0.take.requiredOutputEnd }.map { ticks($0) }.max() ?? 0
        let totalTicks = max(bodyEndTicks, voiceFloorTicks)

        // 3) 트랙을 놓는다. 영상·원본 소리는 A/B 번갈아, 정확히 같은 시각에 놓고 배속은 놓은 구간만 늘이거나 줄인다.
        let composition = AVMutableComposition()
        var videoTracks: [AVMutableCompositionTrack] = []
        var audioTracks: [AVMutableCompositionTrack?] = [nil, nil]
        for _ in 0..<min(2, clips.count) {
            guard let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TrailerError2.exportUnavailable
            }
            videoTracks.append(track)
        }
        var volumeEvents: [[VolumeEvent]] = [[], []]
        var ducking: [TrailerMusicDucking.Clip] = []

        for (index, item) in loaded.enumerated() {
            if isCancelled() { throw CancellationError() }
            let lane = index % 2
            let track = videoTracks[min(lane, videoTracks.count - 1)]
            let start = time(startTicks[index])
            let rate = item.scene.adjustments?.rate ?? 1
            try track.insertTimeRange(item.localRange, of: item.video, at: start)
            if rate != 1 {
                track.scaleTimeRange(CMTimeRange(start: start, duration: item.localRange.duration), toDuration: time(durationTicks[index]))
            }
            guard let audio = item.audio else { continue }
            let overlap = CMTimeRangeGetIntersection(item.localRange, otherRange: item.audioRange)
            guard overlap.duration.isNumeric, overlap.duration.seconds > 0 else { continue }
            if audioTracks[lane] == nil {
                audioTracks[lane] = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let audioTrack = audioTracks[lane] else { continue }
            let offset = CMTimeSubtract(overlap.start, item.localRange.start)
            let audioStart = CMTimeAdd(start, CMTimeMultiplyByFloat64(offset, multiplier: 1 / rate))
            try audioTrack.insertTimeRange(overlap, of: audio, at: audioStart)
            if rate != 1 {
                audioTrack.scaleTimeRange(CMTimeRange(start: audioStart, duration: overlap.duration),
                                          toDuration: CMTimeMultiplyByFloat64(overlap.duration, multiplier: 1 / rate))
            }
            let volume = Float(min(1, max(0, item.scene.volume)))
            let incoming = incomingTicks[index], outgoing = outgoingTicks[index]
            if incoming > 0 {
                volumeEvents[lane].append(.init(at: startTicks[index], kind: .ramp(0, volume, incoming)))
            }
            volumeEvents[lane].append(.init(at: startTicks[index] + incoming, kind: .set(volume)))
            if outgoing > 0 {
                volumeEvents[lane].append(.init(at: startTicks[index] + durationTicks[index] - outgoing, kind: .ramp(volume, 0, outgoing)))
            }
            ducking.append(.init(outputStart: Double(startTicks[index]) / Double(timescale), sourceStart: item.scene.start,
                                 length: Double(durationTicks[index]) / Double(timescale),
                                 envelope: activity[item.scene.sourceID]))
        }

        // 4) 영상 지시. 중첩 경계에서 나눠 한 번에 최대 두 층, 모든 구간이 빈틈없이 이어진다.
        func baseTransform(_ index: Int) -> CGAffineTransform {
            let item = loaded[index]
            let clip = clips[index]
            let natural = item.natural
            let top: CGAffineTransform
            if clip.isStill {
                top = CGAffineTransform(scaleX: renderSize.width / natural.width, y: renderSize.height / natural.height)
            } else if item.scene.fitsFrame {
                top = TrailerOutputRenderer.aspectFitTransform(naturalSize: natural, preferredTransform: item.preferred, renderSize: renderSize)
            } else {
                top = TrailerOutputRenderer.aspectFillTransform(naturalSize: natural, preferredTransform: item.preferred, renderSize: renderSize,
                                                                offsetX: item.scene.offsetX, offsetY: item.scene.offsetY)
            }
            // AVFoundation(위쪽이 0)의 변환을 CoreImage(아래쪽이 0) 좌표로 바꾼다.
            let flipSource = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: natural.height)
            let flipCanvas = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: renderSize.height)
            return flipSource.concatenating(top).concatenating(flipCanvas)
        }
        func layer(_ index: Int) -> TrailerCompositionLayer {
            let item = loaded[index]
            let adjustments = item.scene.adjustments
            return TrailerCompositionLayer(
                sourceTrackID: videoTracks[min(index % 2, videoTracks.count - 1)].trackID,
                mapping: mappings[index], baseTransform: baseTransform(index),
                colorAdjustment: adjustments?.color,
                keyframes: adjustments?.keyframes ?? [],
                effectiveOutputStart: mappings[index].outputStart, effectiveOutputDuration: mappings[index].outputDuration)
        }

        // 자막 큐: 장면의 큐를 원본 시간에서 출력 시간으로 옮기고 장면 안만 남긴다. 큐가 없으면 기존 장면 자막 한 장을 그 장면 길이만큼 쓴다.
        struct CueSpec {
            var start: Double
            var end: Double
            var bitmap: TrailerTightCaption
            var trackID: CMPersistentTrackID
        }
        var cueSpecs: [CueSpec] = []
        for index in loaded.indices where !clips[index].isCard {
            let item = loaded[index]
            let trackID = videoTracks[min(index % 2, videoTracks.count - 1)].trackID
            let cues = item.scene.adjustments?.cues ?? []
            // 직접 넣은 클립 자막은 시간별 자막이 생겨도 사라지지 않는다: 그 클립 길이만큼 계속 그린다.
            if let caption = item.scene.caption, !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let bitmap = TrailerCaptionBitmapCache.bitmap(for: caption, renderSize: renderSize) {
                cueSpecs.append(CueSpec(start: mappings[index].outputStart,
                                        end: mappings[index].outputStart + mappings[index].outputDuration,
                                        bitmap: bitmap, trackID: trackID))
            }
            for cue in cues {
                guard let mapped = mappings[index].mapAndClipCue(cue),
                      !cue.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      let bitmap = TrailerCaptionBitmapCache.bitmap(for: cue.style.withText(cue.text), renderSize: renderSize) else { continue }
                cueSpecs.append(CueSpec(start: mapped.outputStart, end: mapped.outputEnd, bitmap: bitmap, trackID: trackID))
            }
        }
        func cues(in range: Range<Double>) -> [TrailerBitmapCaptionCue] {
            cueSpecs.filter { $0.start < range.upperBound && $0.end > range.lowerBound }.map { spec in
                let top = spec.bitmap.topLeftRect
                let frame = CGRect(x: top.minX, y: renderSize.height - top.maxY, width: top.width, height: top.height)
                return TrailerBitmapCaptionCue(outputStartTime: spec.start, outputEndTime: spec.end, image: spec.bitmap.image,
                                               frame: frame, layerTrackID: spec.trackID)
            }
        }

        var instructions: [TrailerVideoCompositionInstruction] = []
        func append(_ from: Int64, _ to: Int64, layers: [TrailerCompositionLayer], dissolve: Double = 0) {
            guard to > from else { return }
            let range = Double(from) / Double(timescale)..<Double(to) / Double(timescale)
            instructions.append(TrailerVideoCompositionInstruction(
                timeRange: CMTimeRange(start: time(from), duration: time(to - from)), renderSize: renderSize,
                layers: layers, captionCues: cues(in: range), transitionDuration: dissolve))
        }
        for index in loaded.indices {
            append(startTicks[index] + incomingTicks[index], startTicks[index] + durationTicks[index] - outgoingTicks[index],
                   layers: [layer(index)])
            if index + 1 < loaded.count, outgoingTicks[index] > 0 {
                append(startTicks[index + 1], startTicks[index] + durationTicks[index],
                       layers: [layer(index), layer(index + 1)], dissolve: Double(outgoingTicks[index]) / Double(timescale))
            }
        }
        // 음성 해설이 영상보다 길면 남는 구간은 검은 화면으로 잇는다(해설을 자르지 않는다).
        append(bodyEndTicks, totalTicks, layers: [])

        // 5) 음성 해설: 출력 시간에 놓는 독립 레인. 영상 배속과 무관하다.
        var voiceParameters: [AVMutableAudioMixInputParameters] = []
        for voice in voices {
            if isCancelled() { throw CancellationError() }
            // 해설은 직접 정한 요청이다: 읽지 못하거나 요청 구간이 파일에 없으면 조용히 빼지 않고 오류로 알린다.
            guard let placement = voice.take.effectivePlacement(projectDuration: Double(totalTicks) / Double(timescale)) else {
                throw TrailerComposerError.voiceUnavailable
            }
            let asset = assets[voice.url] ?? AVURLAsset(url: voice.url)
            guard let source = try? await asset.loadTracks(withMediaType: .audio).first,
                  (try? await source.load(.isDecodable)) == true,
                  let available = try? await source.load(.timeRange) else { throw TrailerComposerError.voiceUnavailable }
            let wanted = CMTimeRange(start: time(ticks(placement.sourceIn)), duration: time(ticks(placement.outputDuration)))
            let range = CMTimeRangeGetIntersection(wanted, otherRange: available)
            // 요청한 길이의 거의 전부가 파일에 있어야 한다(끝 프레임 반올림 여유 1프레임).
            guard range.duration.isNumeric, range.duration.seconds > 0.0001,
                  range.duration.seconds + 1.0 / 30.0 >= wanted.duration.seconds,
                  let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TrailerComposerError.voiceUnavailable
            }
            let at = CMTimeAdd(time(ticks(placement.outputStart)), CMTimeSubtract(range.start, wanted.start))
            try track.insertTimeRange(range, of: source, at: at)
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.setVolume(Float(min(2, max(0, placement.volume))), at: .zero)
            voiceParameters.append(parameters)
        }

        // 6) 음악은 최종 길이(해설 바닥 포함)까지 깐다.
        var originalParameters: [AVMutableAudioMixInputParameters] = []
        for lane in 0..<2 {
            guard let track = audioTracks[lane], !track.segments.isEmpty else { continue }
            let events = volumeEvents[lane].sorted { $0.at < $1.at }
            guard events.contains(where: { if case .ramp = $0.kind { return true }; if case .set(let v) = $0.kind { return v != 1 }; return false }) else { continue }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            for event in events {
                switch event.kind {
                case .set(let volume): parameters.setVolume(volume, at: time(event.at))
                case .ramp(let from, let to, let length):
                    parameters.setVolumeRamp(fromStartVolume: from, toEndVolume: to,
                                             timeRange: CMTimeRange(start: time(event.at), duration: time(length)))
                }
            }
            originalParameters.append(parameters)
        }
        for lane in 0..<2 {
            if let track = audioTracks[lane], track.segments.isEmpty { composition.removeTrack(track) }
        }

        var musicParameters: [AVMutableAudioMixInputParameters] = []
        var pieces = 0
        var ramps = 0
        if let music {
            guard let musicTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw TrailerError2.exportUnavailable
            }
            let placed = try TrailerMusicMix.insertPieces(into: musicTrack, source: music.track, range: music.range,
                                                          total: time(totalTicks), policy: music.selection?.policy ?? .single)
            pieces = placed.pieces
            let built = TrailerMusicMix.audioMix(for: musicTrack, selection: music.selection, originalSound: ducking,
                                                 musicEnd: placed.end.seconds)
            ramps = built.ramps
            musicParameters = built.mix.inputParameters.compactMap { $0 as? AVMutableAudioMixInputParameters }
        }
        let parameters = originalParameters + voiceParameters + musicParameters
        var mix: AVMutableAudioMix?
        if !parameters.isEmpty {
            let built = AVMutableAudioMix()
            built.inputParameters = parameters
            mix = built
        }

        // 영상 지시 구간은 최종 길이(`totalTicks`)까지 빈틈없이 덮어야 한다. 배속으로 늘린 소리 트랙이 600분의 1초 단위로 조금 더 길거나 짧으면
        // 합성 길이가 지시 구간과 어긋나 내보내기가 잘못된 영상 합성(-11841)으로 멈추므로 합성을 정확히 최종 길이로 맞춘다.
        let finalDuration = time(totalTicks)
        if composition.duration > finalDuration {
            composition.removeTimeRange(CMTimeRange(start: finalDuration, end: composition.duration))
        } else if composition.duration < finalDuration {
            composition.insertEmptyTimeRange(CMTimeRange(start: composition.duration, end: finalDuration))
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.customVideoCompositorClass = TrailerVisualCompositor.self
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)
        videoComposition.instructions = instructions

        return TrailerComposed(composition: composition, videoComposition: videoComposition, audioMix: mix,
                               duration: time(totalTicks), mappings: mappings, originalSound: ducking,
                               musicPieces: pieces, duckRamps: ramps)
    }
}

extension TrailerAdvancedComposer {
    /// 타임라인 구간 목록에 실제로 겹치는 길이(디졸브)를 채운다. 합성기와 같은 시간표 팩토리를 쓴다.
    static func annotatingOverlaps(_ segments: [TrailerTimelineSegment]) -> [TrailerTimelineSegment] {
        guard segments.contains(where: { ($0.adjustments?.transition?.dissolveDuration ?? 0) > 0.0001 }) else { return segments }
        let inputs = segments.enumerated().map { index, segment in
            TrailerClipInput(sceneID: index, sourceID: segment.sourceID ?? -1, sourceStart: segment.start,
                             sourceLength: max(0.001, segment.length), rate: segment.rate,
                             requestedOutgoingOverlap: segment.adjustments?.transition?.dissolveDuration ?? 0)
        }
        guard let maps = try? TrailerClipTimeMappingFactory.buildTimelineMappings(clips: inputs) else { return segments }
        var result = segments
        for index in result.indices { result[index].incomingOverlap = maps[index].incomingOverlap }
        return result
    }

    /// 사진 한 장면의 정지 클립(같은 설정이면 캐시 재사용). 키프레임이 있으면 자동 움직임 없이 고정 구성만 구워,
    /// 키프레임이 유일한 움직임이 되게 한다. 만든 파일은 `created`에 기록한다.
    static func photoClip(
        id: Int, length: Double, fitsFrame: Bool, offsetX: Double, offsetY: Double, hasKeyframes: Bool,
        source: VideoTrailerSource, renderSize: CGSize, directory: URL,
        cache: inout [String: URL], created: inout [URL]
    ) async throws -> URL {
        let photoSize = VideoTrailerModel.photoRenderSize(for: renderSize)
        let framing: VideoTrailerImageClip.Framing? = (fitsFrame || offsetX != 0 || offsetY != 0 || hasKeyframes)
            ? .init(fitsFrame: fitsFrame, offsetX: offsetX, offsetY: offsetY) : nil
        let framingKey = framing.map { "\($0.fitsFrame ? "fit" : "fill")\($0.offsetX),\($0.offsetY)" } ?? "auto"
        let cacheKey = "\(source.id):\(source.name):\(Int64((length * 600).rounded())):\(Int(photoSize.width))x\(Int(photoSize.height)):\(framingKey)"
        if let cached = cache[cacheKey], FileManager.default.fileExists(atPath: cached.path) { return cached }
        let clipURL = directory.appendingPathComponent("image-clip-\(id)-\(UUID().uuidString).mov")
        created.append(clipURL)
        let name = source.name
        let url = source.url
        let seed = VideoTrailerImageClip.stableSeedInt(for: source.name)
        let renderTask = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            try VideoTrailerImageClip.render(imageURL: url, duration: length, renderSize: photoSize, outputURL: clipURL,
                                             seed: seed, framing: framing, sourceIdentity: name)
        }
        do {
            try await withTaskCancellationHandler { try await renderTask.value } onCancel: { renderTask.cancel() }
        } catch {
            try? FileManager.default.removeItem(at: clipURL)
            throw error
        }
        cache[cacheKey] = clipURL
        return clipURL
    }
}

private extension TrailerCaption {
    func withText(_ value: String) -> TrailerCaption {
        var copy = self
        copy.text = value
        return copy
    }
}

/// `TrailerError`가 파일 전용(private)이라 합성기에서 쓰는 최소 오류.
private enum TrailerError2: LocalizedError {
    case exportUnavailable
    var errorDescription: String? { "이 영상 형식으로 예고편을 만들 수 없습니다." }
}

// MARK: - 미리보기: 내보내기와 같은 합성기를 AVPlayer에 연결

/// 고급 편집(배속·색상·키프레임·디졸브·자막 큐·음성 해설)이 있을 때만 쓰는 미리보기 플레이어.
/// `TrailerAdvancedComposer.build`가 내보내기와 똑같은 시간표·지시를 만들고, 이 드라이버는 그것을 AVPlayerItem에 올릴 뿐이다.
/// 소스·음악 시계를 따로 계산하지 않는다: 재생 위치의 기준은 이 플레이어이고 타임라인 시계가 그것을 따라간다.
/// 자체 플레이어를 만들지 않는다: 초안 미리보기가 이미 가진 `TrailerDraftVideoDriver`의 AVPlayer를 `attach`로 받아 그 하나만 쓴다
/// (기본/고급 두 방식이 서로 다른 플레이어 둘을 동시에 들고 있지 않는다).
@MainActor
final class TrailerAdvancedPreviewDriver: ObservableObject {
    private var attached: AVPlayer?
    private var player: AVPlayer { attached ?? placeholder }
    /// `attach` 전에 잘못 불려도 아무 것도 재생하지 않는 빈 플레이어(항목을 올리지 않는다).
    private let placeholder = AVPlayer()
    /// 실제 합성 길이(초). 준비되기 전에는 0.
    @Published private(set) var duration = 0.0
    @Published private(set) var isPreparing = false
    @Published private(set) var failure: String?
    private var preparedKey: String?
    private var generation = 0
    private var prepareTask: Task<Void, Never>?
    /// 이 드라이버가 만든 사진·카드 정지 클립 폴더. 사용자 미디어는 두지 않고 `stop`/해제 때 폴더째 지운다.
    private var ownedFolder: URL?
    private var clipCache: [String: URL] = [:]
    private var envelopes: [Int: AudioActivityEnvelope] = [:]
    private var heldAssets: [AVURLAsset] = []
    private var lastPublished = 0.0

    var isReady: Bool { attached != nil && preparedKey != nil && duration > 0 && player.currentItem != nil }

    /// 기존 초안 미리보기 플레이어를 이 드라이버가 쓰게 한다(여러 번 불러도 같다).
    func attach(player: AVPlayer) {
        guard attached !== player else { return }
        attached = player
        player.actionAtItemEnd = .pause
    }

    deinit {
        if let folder = ownedFolder { try? FileManager.default.removeItem(at: folder) }
    }

    private func folder() throws -> URL {
        if let ownedFolder { return ownedFolder }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("NasFinderTrailerPreview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        ownedFolder = url
        return url
    }

    /// 입력이 바뀔 때마다 부른다(이전 준비는 취소된다). `key`가 같으면 다시 만들지 않는다.
    func prepare(input: TrailerDraftPreviewInput, key: String, renderSize: CGSize,
                 introImage: UIImage?, outroImage: UIImage?, resumeAt seconds: Double) async {
        guard attached != nil else { return }
        if preparedKey == key, player.currentItem != nil { return }
        prepareTask?.cancel()
        generation += 1
        let mine = generation
        isPreparing = true
        failure = nil
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let built = try await self.compose(input: input, renderSize: renderSize, introImage: introImage, outroImage: outroImage)
                guard !Task.isCancelled, self.generation == mine else { return }
                let item = AVPlayerItem(asset: built.composition)
                item.videoComposition = built.videoComposition
                item.audioMix = built.audioMix
                item.audioTimePitchAlgorithm = .spectral
                // 내보내기와 같은 최종 길이에서 멈춘다(배속 소리의 늘이기 지연이 끝에 남지 않는다).
                item.forwardPlaybackEndTime = built.duration
                let wasPlaying = self.player.timeControlStatus != .paused
                self.player.replaceCurrentItem(with: item)
                self.duration = built.duration.seconds
                self.preparedKey = key
                // 일시정지 중에도 바뀐 값이 보이도록 같은 위치를 다시 요청한다.
                let target = min(max(0, seconds), max(0, self.duration - 0.01))
                await self.player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                guard !Task.isCancelled, self.generation == mine else { return }
                self.lastPublished = target
                if wasPlaying { self.player.play() }
                self.isPreparing = false
            } catch is CancellationError {
                if self.generation == mine { self.isPreparing = false }
            } catch {
                guard self.generation == mine else { return }
                self.isPreparing = false
                self.failure = (error as? LocalizedError)?.errorDescription ?? "미리보기를 만들 수 없습니다."
            }
        }
        prepareTask = task
        await task.value
    }

    private func compose(input: TrailerDraftPreviewInput, renderSize full: CGSize,
                         introImage: UIImage?, outroImage: UIImage?) async throws -> TrailerComposed {
        let scale = min(1, 960 / max(full.width, full.height))
        let size = CGSize(width: max(4, (full.width * scale / 4).rounded() * 4), height: max(4, (full.height * scale / 4).rounded() * 4))
        // 사본 파일을 찾지 못한 직접 놓은 해설을 빼고 성공처럼 보이게 하지 않는다.
        if input.missingVoiceCount > 0 { throw TrailerComposerError.voiceUnavailable }
        let directory = try folder()
        var created: [URL] = []
        let byID = Dictionary(input.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var clips: [TrailerComposerClip] = []
        for (index, segment) in input.segments.enumerated() {
            try Task.checkCancellation()
            switch segment.kind {
            case .intro, .outro:
                guard let image = segment.kind == .intro ? introImage : outroImage, let png = image.pngData() else { continue }
                let key = "card:\(segment.kind == .intro):\(Int(size.width))x\(Int(size.height)):\(segment.length):\(png.count):\(png.prefix(64).hashValue)"
                var url = clipCache[key]
                if url == nil || !FileManager.default.fileExists(atPath: url!.path) {
                    let imageURL = directory.appendingPathComponent("card-\(UUID().uuidString).png")
                    let clipURL = directory.appendingPathComponent("card-\(UUID().uuidString).mov")
                    try png.write(to: imageURL)
                    let length = segment.length
                    try await Task.detached(priority: .userInitiated) {
                        try VideoTrailerImageClip.render(imageURL: imageURL, duration: length, renderSize: size, outputURL: clipURL,
                                                         seed: 1, framing: .init(fitsFrame: true, offsetX: 0, offsetY: 0))
                    }.value
                    try? FileManager.default.removeItem(at: imageURL)
                    clipCache[key] = clipURL
                    url = clipURL
                }
                var scene = VideoTrailerScene(id: -(index + 1), start: 0, length: segment.length)
                scene.sourceID = segment.kind == .intro ? -1 : -2
                clips.append(TrailerComposerClip(scene: scene, url: url!, localStart: 0, isStill: true, hasSound: false, isCard: true))
            case .clip:
                guard let id = segment.sourceID, let source = byID[id] else { continue }
                // 사진은 논리 사진 시간 0부터 시작하는 정지 클립이다.
                var scene = VideoTrailerScene(id: index, start: source.isImage ? 0 : segment.start, length: segment.length)
                scene.sourceID = id
                scene.muted = segment.muted
                scene.fitsFrame = segment.fitsFrame
                scene.offsetX = segment.offsetX
                scene.offsetY = segment.offsetY
                scene.volume = segment.volume
                scene.caption = input.captions[segment.id]
                scene.adjustments = segment.adjustments?.isNeutral == true ? nil : segment.adjustments
                if source.isImage {
                    var cache = clipCache
                    let url = try await TrailerAdvancedComposer.photoClip(
                        id: index, length: segment.length, fitsFrame: segment.fitsFrame, offsetX: segment.offsetX,
                        offsetY: segment.offsetY, hasKeyframes: !(segment.adjustments?.keyframes.isEmpty ?? true),
                        source: source, renderSize: size, directory: directory, cache: &cache, created: &created)
                    clipCache = cache
                    clips.append(TrailerComposerClip(scene: scene, url: url, localStart: 0, isStill: true, hasSound: false))
                } else {
                    clips.append(TrailerComposerClip(scene: scene, url: source.url, localStart: segment.start, isStill: false, hasSound: true))
                }
            }
        }

        var musicInput: TrailerComposerMusic?
        var held: [AVURLAsset] = []
        if let music = input.music {
            let asset = AVURLAsset(url: music.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let track = try await asset.loadTracks(withMediaType: .audio).first,
                  try await track.load(.isDecodable) else { throw TrailerMusicError.unreadable }
            let range = try await track.load(.timeRange)
            try TrailerMusic.validate(duration: range.duration.seconds)
            musicInput = TrailerComposerMusic(selection: music, track: track, range: range)
            held.append(asset)
            let videoIDs = Set(clips.compactMap { $0.hasSound && !$0.scene.muted ? $0.scene.sourceID : nil })
            for source in input.sources where !source.isImage && videoIDs.contains(source.id) && envelopes[source.id] == nil {
                envelopes[source.id] = try? await AudioAnalysisService.activityEnvelope(url: source.url)
                try Task.checkCancellation()
            }
        }
        heldAssets = held
        return try await TrailerAdvancedComposer.build(clips: clips, renderSize: size, music: musicInput,
                                                       voices: input.voices, activity: envelopes)
    }

    /// 타임라인 시계를 이 플레이어에 맞춘다(33ms마다). 재생 중이면 플레이어 위치를 시계에 쓰고,
    /// 멈춰 있거나 사용자가 옮겼으면 플레이어를 시계에 맞춘다.
    func follow(_ bridge: TrailerTimelineBridge) {
        guard isReady else { return }
        let total = duration
        func seek(_ seconds: Double) {
            player.seek(to: CMTime(seconds: min(max(0, seconds), total), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if bridge.isPlaying {
            if abs(bridge.currentSeconds - lastPublished) > 0.25 {
                seek(bridge.currentSeconds)
                lastPublished = bridge.currentSeconds
                return
            }
            if player.timeControlStatus == .paused {
                if bridge.currentSeconds >= total - 0.02 { seek(0) }
                SharedMediaAudioSession.activatePlayback()
                player.play()
            }
            let now = player.currentTime().seconds
            if now >= total - 0.03 {
                player.pause()
                bridge.currentSeconds = total
                bridge.isPlaying = false
                lastPublished = total
            } else if now.isFinite {
                bridge.currentSeconds = now
                lastPublished = now
            }
        } else {
            if player.timeControlStatus != .paused { player.pause() }
            if abs(player.currentTime().seconds - bridge.currentSeconds) > 0.03 { seek(bridge.currentSeconds) }
            lastPublished = bridge.currentSeconds
        }
    }

    /// 이 드라이버가 만든 임시 결과만 지운다(사용자 미디어·프로젝트 파일은 건드리지 않는다).
    func stop() {
        generation += 1
        prepareTask?.cancel()
        prepareTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        preparedKey = nil
        duration = 0
        isPreparing = false
        heldAssets = []
        clipCache = [:]
        if let folder = ownedFolder { try? FileManager.default.removeItem(at: folder); ownedFolder = nil }
    }
}
