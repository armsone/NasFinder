import AVFoundation
import UIKit

/// Synthesizes a short, silent video clip from a still image so it can be
/// inserted into the trailer composition exactly like any other video source.
/// Applies a Ken Burns style zoom (1.10<->1.00) around a focal point that is
/// sampled once per clip and held fixed, with the pan amount derived from the
/// current zoom level so the crop never exposes empty borders.
enum VideoTrailerImageClip {
    enum ClipError: LocalizedError {
        case decodeFailed, writeFailed
        var errorDescription: String? {
            switch self {
            case .decodeFailed: "사진을 불러오지 못했습니다."
            case .writeFailed: "사진으로 장면을 만들지 못했습니다."
            }
        }
    }

    /// 사용자가 직접 정한 화면 구성. 있으면 자동 확대·이동 효과 없이 고른 상태 그대로 그린다.
    /// `fitsFrame`는 사진 전체를 보여 주고 남는 곳을 검게 두며, 아니면 화면을 채우고 `offset`만큼 위치를 옮긴다.
    struct Framing: Equatable {
        var fitsFrame: Bool
        /// -1...1. 0이 가운데이고 사진이 화면을 넘치는 방향으로만 움직인다.
        var offsetX: Double
        var offsetY: Double
    }

    static func imageSize(at url: URL) throws -> CGSize {
        guard let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 else {
            throw ClipError.decodeFailed
        }
        return image.size
    }

    /// - Parameter seed: stable per-clip seed so zoom direction and focal point are sampled once, not per frame.
    static func render(imageURL: URL, duration: Double, renderSize: CGSize, outputURL: URL, seed: Int, framing: Framing? = nil) throws {
        guard let source = UIImage(contentsOfFile: imageURL.path), source.size.width > 0, source.size.height > 0 else {
            throw ClipError.decodeFailed
        }
        var generator = SplitMix64(seed: UInt64(bitPattern: Int64(seed)))
        let zoomsIn = generator.next() % 2 == 0
        let focal = CGPoint(x: generator.nextUnit() * 2 - 1, y: generator.nextUnit() * 2 - 1)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(renderSize.width),
            AVVideoHeightKey: Int(renderSize.height)
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
            kCVPixelBufferWidthKey as String: Int(renderSize.width),
            kCVPixelBufferHeightKey as String: Int(renderSize.height)
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
        guard writer.canAdd(input) else { throw ClipError.writeFailed }
        writer.add(input)
        guard writer.startWriting() else { throw ClipError.writeFailed }
        writer.startSession(atSourceTime: .zero)

        let fps: Int32 = 30
        let frameDuration = CMTime(value: 1, timescale: fps)
        // Rounded up so a fractional length such as 0.75s is always fully covered by frames.
        let totalFrames = max(1, Int((duration * Double(fps) - 0.000001).rounded(.up)))

        for frame in 0..<totalFrames {
            while !input.isReadyForMoreMediaData {
                Thread.sleep(forTimeInterval: 0.002)
            }
            let t = totalFrames > 1 ? Double(frame) / Double(totalFrames - 1) : 1
            let scale = framing != nil ? 1.0 : (zoomsIn ? 1.0 + 0.10 * t : 1.10 - 0.10 * t)
            let chosenFocal = framing.map { CGPoint(x: -$0.offsetX, y: -$0.offsetY) } ?? focal
            guard let pixelBuffer = Self.pixelBuffer(for: source, renderSize: renderSize, scale: scale, focal: chosenFocal,
                                                     fitsFrame: framing?.fitsFrame ?? false, pool: adaptor.pixelBufferPool) else {
                throw ClipError.writeFailed
            }
            let time = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
            guard adaptor.append(pixelBuffer, withPresentationTime: time) else { throw ClipError.writeFailed }
        }
        input.markAsFinished()
        let semaphore = DispatchSemaphore(value: 0)
        writer.finishWriting { semaphore.signal() }
        semaphore.wait()
        guard writer.status == .completed else { throw writer.error ?? ClipError.writeFailed }
    }

    private static func pixelBuffer(for image: UIImage, renderSize: CGSize, scale: CGFloat, focal: CGPoint, fitsFrame: Bool = false, pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(kCFAllocatorDefault, Int(renderSize.width), Int(renderSize.height),
                                 kCVPixelFormatType_32ARGB, nil, &buffer)
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(renderSize.width), height: Int(renderSize.height),
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        context.clear(CGRect(origin: .zero, size: renderSize))
        let imageSize = image.size
        let fillScale = fitsFrame
            ? min(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
            : max(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
        let baseSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
        let size = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
        let marginX = max(0, (size.width - renderSize.width) / 2)
        let marginY = max(0, (size.height - renderSize.height) / 2)
        let originX = (renderSize.width - size.width) / 2 + focal.x * marginX
        let originY = (renderSize.height - size.height) / 2 + focal.y * marginY
        image.draw(in: CGRect(x: originX, y: originY, width: size.width, height: size.height))
        UIGraphicsPopContext()
        return pixelBuffer
    }
}

/// Small deterministic PRNG so the per-clip random direction/focal point only
/// depends on a stable seed, never on per-frame timing.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func nextUnit() -> CGFloat {
        CGFloat(next() % 1_000_000) / 1_000_000
    }
}
