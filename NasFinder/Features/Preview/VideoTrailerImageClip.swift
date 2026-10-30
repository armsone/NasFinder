import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
import Vision

/// Synthesizes a short, silent video clip from a still image so it can be
/// inserted into the trailer composition exactly like any other video source.
/// Applies deterministic, subject-safe horizontal/vertical motion using on-device
/// Vision face and saliency detection to ensure important subjects are not cropped.
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

    private static let workingThumbnailMaxPixelSize: CGFloat = 1024
    private static let renderMaxPixelSize: CGFloat = 2560

    private struct FileRevisionKey: Hashable, Sendable {
        let path: String
        let modificationDate: Date
        let fileSize: UInt64
    }

    private final class AnalysisCache: @unchecked Sendable {
        static let shared = AnalysisCache()
        private let lock = NSLock()
        private var cache: [FileRevisionKey: CGRect?] = [:]
        private var keys: [FileRevisionKey] = []
        private let maxEntries = 128

        func get(for key: FileRevisionKey) -> CGRect?? {
            lock.lock()
            defer { lock.unlock() }
            guard let value = cache[key] else { return nil }
            return .some(value)
        }

        func set(_ value: CGRect?, for key: FileRevisionKey) {
            lock.lock()
            defer { lock.unlock() }
            if cache[key] == nil && cache.count >= maxEntries, !keys.isEmpty {
                let oldest = keys.removeFirst()
                cache.removeValue(forKey: oldest)
            }
            cache.updateValue(value, forKey: key)
            keys.removeAll(where: { $0 == key })
            keys.append(key)
        }
    }

    private enum SubjectAnalysisResult {
        case subject(CGRect)
        case empty
        case failure
    }

    private enum MotionPlan {
        case fitted
        case manual(focal: CGPoint)
        case staticCrop(origin: CGPoint, size: CGSize)
        case motion(
            drawSize: CGSize,
            isHorizontal: Bool,
            moveStart: CGFloat,
            moveEnd: CGFloat,
            minBound: CGFloat,
            maxBound: CGFloat
        )
    }

    private static func loadSourceImage(at url: URL, maxPixelSize: CGFloat = renderMaxPixelSize) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
            return nil
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else {
            return nil
        }
        return UIImage(cgImage: cgImage)
    }

    static func imageSize(at url: URL) throws -> CGSize {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        if let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
           let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let widthNumber = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue
            let heightNumber = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue
            if let w = widthNumber, let h = heightNumber, w.isFinite, h.isFinite, w > 0, h > 0 {
                let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
                if (5...8).contains(orientation) {
                    return CGSize(width: CGFloat(h), height: CGFloat(w))
                } else {
                    return CGSize(width: CGFloat(w), height: CGFloat(h))
                }
            }
        }
        guard let image = loadSourceImage(at: url), image.size.width > 0, image.size.height > 0 else {
            throw ClipError.decodeFailed
        }
        return image.size
    }

    private static func analyzeSubjects(at imageURL: URL) throws -> SubjectAnalysisResult {
        try Task.checkCancellation()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions) else {
            return .failure
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingThumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions) else {
            return .failure
        }

        try Task.checkCancellation()
        let faceRequest = VNDetectFaceRectanglesRequest()
        let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
        let handler = VNImageRequestHandler(cgImage: cgThumb, orientation: .up, options: [:])
        do {
            try handler.perform([faceRequest, saliencyRequest])
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure
        }
        try Task.checkCancellation()

        guard let faces = faceRequest.results as? [VNFaceObservation],
              let saliencyObs = saliencyRequest.results as? [VNSaliencyImageObservation],
              !saliencyObs.isEmpty else {
            return .failure
        }

        var boxes: [CGRect] = []

        func isValidNormalizedBox(_ box: CGRect) -> Bool {
            guard box.origin.x.isFinite, box.origin.y.isFinite,
                  box.size.width.isFinite, box.size.height.isFinite,
                  box.size.width > 0, box.size.height > 0 else {
                return false
            }
            guard box.minX >= 0.0, box.minY >= 0.0,
                  box.maxX <= 1.0, box.maxY <= 1.0 else {
                return false
            }
            return true
        }

        for face in faces {
            let box = face.boundingBox
            guard isValidNormalizedBox(box) else {
                return .failure
            }
            // Convert Vision lower-left coordinates to top-left draw coordinates
            let converted = CGRect(
                x: box.origin.x,
                y: 1.0 - box.origin.y - box.size.height,
                width: box.size.width,
                height: box.size.height
            )
            boxes.append(converted)
        }

        for obs in saliencyObs {
            if let objects = obs.salientObjects {
                for obj in objects {
                    let box = obj.boundingBox
                    guard isValidNormalizedBox(box) else {
                        return .failure
                    }
                    let converted = CGRect(
                        x: box.origin.x,
                        y: 1.0 - box.origin.y - box.size.height,
                        width: box.size.width,
                        height: box.size.height
                    )
                    boxes.append(converted)
                }
            }
        }

        guard !boxes.isEmpty else {
            return .empty
        }

        var unionBox = boxes[0]
        for b in boxes.dropFirst() {
            unionBox = unionBox.union(b)
        }

        guard unionBox.origin.x.isFinite, unionBox.origin.y.isFinite,
              unionBox.size.width.isFinite, unionBox.size.height.isFinite,
              unionBox.size.width > 0, unionBox.size.height > 0 else {
            return .failure
        }

        // Pad for protection
        let padX = max(0.04, unionBox.width * 0.08)
        let padY = max(0.04, unionBox.height * 0.08)
        let minX = max(0.0, unionBox.minX - padX)
        let minY = max(0.0, unionBox.minY - padY)
        let maxX = min(1.0, unionBox.maxX + padX)
        let maxY = min(1.0, unionBox.maxY + padY)

        guard maxX > minX, maxY > minY else {
            return .failure
        }

        let protectedRect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        return .subject(protectedRect)
    }

    private static func subjectBounds(for imageURL: URL) throws -> (protectedRect: CGRect?, fallbackToFit: Bool) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: imageURL.path)
        let modDate = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let key = FileRevisionKey(path: imageURL.standardizedFileURL.path, modificationDate: modDate, fileSize: fileSize)

        if let cached = AnalysisCache.shared.get(for: key) {
            return (protectedRect: cached, fallbackToFit: false)
        }

        let result = try analyzeSubjects(at: imageURL)
        switch result {
        case .subject(let rect):
            AnalysisCache.shared.set(rect, for: key)
            return (protectedRect: rect, fallbackToFit: false)
        case .empty:
            AnalysisCache.shared.set(nil, for: key)
            return (protectedRect: nil, fallbackToFit: false)
        case .failure:
            // Do not permanently cache failures/partial results
            return (protectedRect: nil, fallbackToFit: true)
        }
    }

    private static func stableDirectionIsForward(for string: String) -> Bool {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return (hash & 1) == 0
    }

    /// - Parameter seed: stable per-clip seed kept for signature compatibility. Direction is deterministic from source identity.
    static func render(imageURL: URL, duration: Double, renderSize: CGSize, outputURL: URL, seed: Int, framing: Framing? = nil) throws {
        try Task.checkCancellation()
        guard let source = loadSourceImage(at: imageURL), source.size.width > 0, source.size.height > 0 else {
            throw ClipError.decodeFailed
        }
        try Task.checkCancellation()

        let imageSize = source.size
        let sourceAspect = imageSize.width / imageSize.height
        let renderAspect = renderSize.width / renderSize.height

        let motionPlan: MotionPlan
        if let framing {
            if framing.fitsFrame {
                motionPlan = .fitted
            } else {
                motionPlan = .manual(focal: CGPoint(x: -framing.offsetX, y: -framing.offsetY))
            }
        } else {
            let analysis = try subjectBounds(for: imageURL)
            try Task.checkCancellation()

            if analysis.fallbackToFit {
                motionPlan = .fitted
            } else {
                let protectedRect = analysis.protectedRect

                if sourceAspect > renderAspect {
                    // Wide image: crop slides horizontally (X)
                    let viewportW = renderAspect / sourceAspect
                    let maxSpan = 1.0 - viewportW

                    if maxSpan <= 1e-6 {
                        motionPlan = .fitted
                    } else {
                        let uMin: CGFloat
                        let uMax: CGFloat
                        if let protectedRect {
                            uMin = max(0.0, protectedRect.maxX - viewportW)
                            uMax = min(maxSpan, protectedRect.minX)
                        } else {
                            uMin = 0.0
                            uMax = maxSpan
                        }

                        if uMin > uMax {
                            // Invalid reversed interval: protected union cannot fit without cropping subject
                            motionPlan = .fitted
                        } else {
                            let fillScale = renderSize.height / imageSize.height
                            let drawSize = CGSize(width: imageSize.width * fillScale, height: renderSize.height)

                            if duration <= 1.0 {
                                // Short <= 1s scenes use protected static crop
                                let staticU: CGFloat
                                if let protectedRect {
                                    let pCenterX = (protectedRect.minX + protectedRect.maxX) / 2.0
                                    staticU = min(uMax, max(uMin, pCenterX - viewportW / 2.0))
                                } else {
                                    staticU = (uMin + uMax) / 2.0
                                }
                                let origin = CGPoint(x: -staticU * drawSize.width, y: 0)
                                motionPlan = .staticCrop(origin: origin, size: drawSize)
                            } else {
                                let span = uMax - uMin
                                if span <= 1e-6 {
                                    let origin = CGPoint(x: -uMin * drawSize.width, y: 0)
                                    motionPlan = .staticCrop(origin: origin, size: drawSize)
                                } else {
                                    // Smooth easing and duration-limited movement in viewport units/sec accounting for easing peak speed (peak factor 1.5)
                                    let maxPeakSpeedViewport: CGFloat = 0.15
                                    let maxTravelViewport = (maxPeakSpeedViewport * CGFloat(duration)) / 1.5
                                    let maxTravelSource = maxTravelViewport * viewportW
                                    let travel = min(span, maxTravelSource)

                                    let mid = (uMin + uMax) / 2.0
                                    let startU = mid - travel / 2.0
                                    let endU = mid + travel / 2.0

                                    let forward = stableDirectionIsForward(for: imageURL.lastPathComponent)

                                    let moveStart = forward ? startU : endU
                                    let moveEnd = forward ? endU : startU

                                    motionPlan = .motion(
                                        drawSize: drawSize,
                                        isHorizontal: true,
                                        moveStart: moveStart,
                                        moveEnd: moveEnd,
                                        minBound: uMin,
                                        maxBound: uMax
                                    )
                                }
                            }
                        }
                    }
                } else if sourceAspect < renderAspect {
                    // Tall image: crop slides vertically (Y)
                    let viewportH = sourceAspect / renderAspect
                    let maxSpan = 1.0 - viewportH

                    if maxSpan <= 1e-6 {
                        motionPlan = .fitted
                    } else {
                        let vMin: CGFloat
                        let vMax: CGFloat
                        if let protectedRect {
                            vMin = max(0.0, protectedRect.maxY - viewportH)
                            vMax = min(maxSpan, protectedRect.minY)
                        } else {
                            vMin = 0.0
                            vMax = maxSpan
                        }

                        if vMin > vMax {
                            // Invalid reversed interval: protected union cannot fit without cropping subject
                            motionPlan = .fitted
                        } else {
                            let fillScale = renderSize.width / imageSize.width
                            let drawSize = CGSize(width: renderSize.width, height: imageSize.height * fillScale)

                            if duration <= 1.0 {
                                // Short <= 1s scenes use protected static crop
                                let staticV: CGFloat
                                if let protectedRect {
                                    let pCenterY = (protectedRect.minY + protectedRect.maxY) / 2.0
                                    staticV = min(vMax, max(vMin, pCenterY - viewportH / 2.0))
                                } else {
                                    staticV = (vMin + vMax) / 2.0
                                }
                                let origin = CGPoint(x: 0, y: -staticV * drawSize.height)
                                motionPlan = .staticCrop(origin: origin, size: drawSize)
                            } else {
                                let span = vMax - vMin
                                if span <= 1e-6 {
                                    let origin = CGPoint(x: 0, y: -vMin * drawSize.height)
                                    motionPlan = .staticCrop(origin: origin, size: drawSize)
                                } else {
                                    let maxPeakSpeedViewport: CGFloat = 0.15
                                    let maxTravelViewport = (maxPeakSpeedViewport * CGFloat(duration)) / 1.5
                                    let maxTravelSource = maxTravelViewport * viewportH
                                    let travel = min(span, maxTravelSource)

                                    let mid = (vMin + vMax) / 2.0
                                    let startV = mid - travel / 2.0
                                    let endV = mid + travel / 2.0

                                    let forward = stableDirectionIsForward(for: imageURL.lastPathComponent)

                                    let moveStart = forward ? startV : endV
                                    let moveEnd = forward ? endV : startV

                                    motionPlan = .motion(
                                        drawSize: drawSize,
                                        isHorizontal: false,
                                        moveStart: moveStart,
                                        moveEnd: moveEnd,
                                        minBound: vMin,
                                        maxBound: vMax
                                    )
                                }
                            }
                        }
                    }
                } else {
                    // Equal aspect ratio: static crop
                    let fillScale = max(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
                    let size = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
                    let origin = CGPoint(x: (renderSize.width - size.width) / 2.0, y: (renderSize.height - size.height) / 2.0)
                    motionPlan = .staticCrop(origin: origin, size: size)
                }
            }
        }

        try Task.checkCancellation()
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        do {
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
            guard writer.canAdd(input) else { throw writer.error ?? ClipError.writeFailed }
            writer.add(input)
            guard writer.startWriting() else { throw writer.error ?? ClipError.writeFailed }
            writer.startSession(atSourceTime: .zero)

            let fps: Int32 = 30
            let frameDuration = CMTime(value: 1, timescale: fps)
            let totalFrames = max(1, Int((duration * Double(fps) - 0.000001).rounded(.up)))

            for frame in 0..<totalFrames {
                try Task.checkCancellation()
                while !input.isReadyForMoreMediaData {
                    try Task.checkCancellation()
                    if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? ClipError.writeFailed }
                    Thread.sleep(forTimeInterval: 0.002)
                }
                let t = totalFrames > 1 ? Double(frame) / Double(totalFrames - 1) : 0.0
                let drawOrigin: CGPoint
                let drawSize: CGSize

                switch motionPlan {
                case .fitted:
                    let fillScale = min(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
                    drawSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
                    drawOrigin = CGPoint(x: (renderSize.width - drawSize.width) / 2.0, y: (renderSize.height - drawSize.height) / 2.0)

                case .manual(let focal):
                    let fillScale = max(renderSize.width / imageSize.width, renderSize.height / imageSize.height)
                    drawSize = CGSize(width: imageSize.width * fillScale, height: imageSize.height * fillScale)
                    let marginX = max(0, (drawSize.width - renderSize.width) / 2.0)
                    let marginY = max(0, (drawSize.height - renderSize.height) / 2.0)
                    drawOrigin = CGPoint(
                        x: (renderSize.width - drawSize.width) / 2.0 + focal.x * marginX,
                        y: (renderSize.height - drawSize.height) / 2.0 + focal.y * marginY
                    )

                case .staticCrop(let origin, let size):
                    drawOrigin = origin
                    drawSize = size

                case .motion(let size, let isHorizontal, let moveStart, let moveEnd, let minBound, let maxBound):
                    drawSize = size
                    let easedT = CGFloat(t * t * (3.0 - 2.0 * t))
                    let pos = min(maxBound, max(minBound, moveStart + (moveEnd - moveStart) * easedT))
                    if isHorizontal {
                        drawOrigin = CGPoint(x: -pos * size.width, y: 0)
                    } else {
                        drawOrigin = CGPoint(x: 0, y: -pos * size.height)
                    }
                }

                guard let pixelBuffer = Self.pixelBuffer(
                    for: source,
                    renderSize: renderSize,
                    drawOrigin: drawOrigin,
                    drawSize: drawSize,
                    pool: adaptor.pixelBufferPool
                ) else {
                    throw ClipError.writeFailed
                }
                let time = CMTimeMultiply(frameDuration, multiplier: Int32(frame))
                guard adaptor.append(pixelBuffer, withPresentationTime: time) else { throw writer.error ?? ClipError.writeFailed }
            }

            input.markAsFinished()
            let semaphore = DispatchSemaphore(value: 0)
            writer.finishWriting { semaphore.signal() }
            while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
                try Task.checkCancellation()
                if writer.status == .failed || writer.status == .cancelled { throw writer.error ?? ClipError.writeFailed }
            }
            guard writer.status == .completed else { throw writer.error ?? ClipError.writeFailed }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

    private static func pixelBuffer(
        for image: UIImage,
        renderSize: CGSize,
        drawOrigin: CGPoint,
        drawSize: CGSize,
        pool: CVPixelBufferPool?
    ) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault,
                Int(renderSize.width),
                Int(renderSize.height),
                kCVPixelFormatType_32ARGB,
                nil,
                &buffer
            )
        }
        guard let pixelBuffer = buffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: Int(renderSize.width),
            height: Int(renderSize.height),
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
        ) else { return nil }

        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: 1, y: -1)
        UIGraphicsPushContext(context)
        context.clear(CGRect(origin: .zero, size: renderSize))
        image.draw(in: CGRect(origin: drawOrigin, size: drawSize))
        UIGraphicsPopContext()
        return pixelBuffer
    }
}
