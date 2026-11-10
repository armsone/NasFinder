import AVFoundation
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation

// MARK: - Composition Layer

/// A concrete visual layer participating in custom video composition (1..2 layers per instruction).
struct TrailerCompositionLayer: Equatable, Sendable {
    var sourceTrackID: CMPersistentTrackID
    var mapping: TrailerClipTimeMapping
    var baseTransform: CGAffineTransform
    var colorAdjustment: TrailerColorAdjustment?
    var keyframes: [TrailerTransformKeyframe]
    var opacity: Double
    var effectiveOutputStart: Double
    var effectiveOutputDuration: Double
    var outgoingOverlapWeight: Double?
    var incomingOverlapWeight: Double?

    init(
        sourceTrackID: CMPersistentTrackID,
        mapping: TrailerClipTimeMapping,
        baseTransform: CGAffineTransform = .identity,
        colorAdjustment: TrailerColorAdjustment? = nil,
        keyframes: [TrailerTransformKeyframe] = [],
        opacity: Double = 1.0,
        effectiveOutputStart: Double,
        effectiveOutputDuration: Double,
        outgoingOverlapWeight: Double? = nil,
        incomingOverlapWeight: Double? = nil
    ) {
        self.sourceTrackID = sourceTrackID
        self.mapping = mapping
        self.baseTransform = baseTransform
        self.colorAdjustment = colorAdjustment
        self.keyframes = keyframes
        self.opacity = opacity.isFinite ? min(1.0, max(0.0, opacity)) : 1.0
        self.effectiveOutputStart = effectiveOutputStart
        self.effectiveOutputDuration = effectiveOutputDuration
        self.outgoingOverlapWeight = outgoingOverlapWeight
        self.incomingOverlapWeight = incomingOverlapWeight
    }

    func isActive(at outputTime: Double) -> Bool {
        outputTime >= effectiveOutputStart && outputTime <= (effectiveOutputStart + effectiveOutputDuration + 0.0001)
    }
}

// MARK: - Bitmap Caption Cue

/// Pre-rendered immutable bitmap caption cue for video frame overlay.
struct TrailerBitmapCaptionCue: @unchecked Sendable {
    var outputStartTime: Double
    var outputEndTime: Double
    var image: CGImage
    var frame: CGRect
    var opacity: Double
    var layerTrackID: CMPersistentTrackID?

    init(
        outputStartTime: Double,
        outputEndTime: Double,
        image: CGImage,
        frame: CGRect = .zero,
        opacity: Double = 1.0,
        layerTrackID: CMPersistentTrackID? = nil
    ) {
        self.outputStartTime = outputStartTime
        self.outputEndTime = outputEndTime
        self.image = image
        self.frame = frame
        self.opacity = opacity.isFinite ? min(1.0, max(0.0, opacity)) : 1.0
        self.layerTrackID = layerTrackID
    }

    func isActive(at outputTime: Double) -> Bool {
        outputTime >= outputStartTime && outputTime < outputEndTime
    }
}

// MARK: - Custom Video Composition Instruction

/// Immutable AVVideoCompositionInstruction subclass directing custom frame composition.
final class TrailerVideoCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing: Bool
    let containsTweening: Bool
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID: CMPersistentTrackID

    let renderSize: CGSize
    let layers: [TrailerCompositionLayer]
    let captionCues: [TrailerBitmapCaptionCue]
    let transitionDuration: Double

    init(
        timeRange: CMTimeRange,
        renderSize: CGSize,
        layers: [TrailerCompositionLayer],
        captionCues: [TrailerBitmapCaptionCue] = [],
        transitionDuration: Double = 0.0,
        containsTweening: Bool? = nil
    ) {
        self.timeRange = timeRange
        self.enablePostProcessing = false
        self.passthroughTrackID = kCMPersistentTrackID_Invalid
        self.renderSize = renderSize
        self.layers = layers
        self.captionCues = captionCues
        self.transitionDuration = transitionDuration.isFinite ? max(0.0, transitionDuration) : 0.0

        let trackIDs = layers.map { NSNumber(value: $0.sourceTrackID) as NSValue }
        self.requiredSourceTrackIDs = trackIDs.isEmpty ? nil : trackIDs

        if let explicitTweening = containsTweening {
            self.containsTweening = explicitTweening
        } else {
            let hasKeyframes = layers.contains { !$0.keyframes.isEmpty }
            let hasDissolve = layers.count > 1 && transitionDuration > 0.0001
            let hasFadingCues = !captionCues.isEmpty
            self.containsTweening = hasKeyframes || hasDissolve || hasFadingCues
        }

        super.init()
    }
}

// MARK: - Compositor Errors

enum TrailerCompositorError: Error, LocalizedError, Equatable, Sendable {
    case missingSourceFrame(trackID: CMPersistentTrackID)
    case invalidInstruction(String)
    case allocationFailed
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case let .missingSourceFrame(trackID):
            return "Compositor missing required source frame for trackID \(trackID)."
        case let .invalidInstruction(desc):
            return "Invalid composition instruction: \(desc)."
        case .allocationFailed:
            return "Failed to allocate new pixel buffer from renderContext."
        case let .renderFailed(desc):
            return "CIContext rendering failed: \(desc)."
        }
    }
}

// MARK: - Visual Compositor

/// Concrete AVVideoCompositing implementation performing SDR sRGB composition with CoreImage.
///
/// Geometric and Coordinate Convention:
/// - CoreImage coordinates place (0, 0) at the bottom-left corner of the render bounds.
/// - Integration supplies `baseTransform` already mapping raw buffer coordinates to canvas dimensions
///   (including aspect fit/fill and source preferred orientation).
/// - Normalized keyframe offsets `offsetX`, `offsetY` are in range `[-1.0, 1.0]`.
///   `+1.0` in `offsetX` shifts horizontally by `+0.5 * renderSize.width`.
///   `+1.0` in `offsetY` shifts vertically by `+0.5 * renderSize.height` (positive upward).
///   Scale is centered about the render canvas center `(renderSize.width / 2, renderSize.height / 2)`.
final class TrailerVisualCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private final class RequestTicket {
        let id: ObjectIdentifier
        let request: AVAsynchronousVideoCompositionRequest
        let generation: UInt64
        var isFinished: Bool = false

        init(request: AVAsynchronousVideoCompositionRequest, generation: UInt64) {
            self.id = ObjectIdentifier(request)
            self.request = request
            self.generation = generation
        }
    }

    private enum FinishAction {
        case success(CVPixelBuffer)
        case error(Error)
        case cancel
    }

    private let renderQueue = DispatchQueue(label: "com.nasfinder.trailer.renderQueue", qos: .userInteractive)
    private static let queueKey = DispatchSpecificKey<Void>()

    private let stateLock = NSRecursiveLock()
    private var generation: UInt64 = 0
    private var currentRenderContext: AVVideoCompositionRenderContext?
    private var pendingTickets: [ObjectIdentifier: RequestTicket] = [:]

    private let ciContext: CIContext

    override init() {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            .useSoftwareRenderer: false
        ]
        self.ciContext = CIContext(options: options)
        super.init()
        self.renderQueue.setSpecific(key: Self.queueKey, value: ())
    }

    // MARK: - AVVideoCompositing Protocol Properties

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [
            kCVPixelBufferPixelFormatTypeKey as String: [
                kCVPixelFormatType_32BGRA,
                kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ] as [UInt32]
        ]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
    }

    var supportsHDRSourceFrames: Bool {
        false
    }

    var supportsWideColorSourceFrames: Bool {
        false
    }

    // MARK: - One-Shot Atomic Completion Gate

    private func finishRequest(ticket: RequestTicket, action: FinishAction) {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard ticket.generation == self.generation && !ticket.isFinished else {
            return
        }
        ticket.isFinished = true
        pendingTickets.removeValue(forKey: ticket.id)

        switch action {
        case let .success(buffer):
            ticket.request.finish(withComposedVideoFrame: buffer)
        case let .error(error):
            ticket.request.finish(with: error)
        case .cancel:
            ticket.request.finishCancelledRequest()
        }
    }

    // MARK: - Context & Cancellation Lifecycle

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        currentRenderContext = newRenderContext
        let ticketsToCancel = Array(pendingTickets.values)
        pendingTickets.removeAll()
        for ticket in ticketsToCancel where !ticket.isFinished {
            ticket.isFinished = true
            ticket.request.finishCancelledRequest()
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        stateLock.lock()
        defer { stateLock.unlock() }
        generation &+= 1
        let ticketsToCancel = Array(pendingTickets.values)
        pendingTickets.removeAll()
        for ticket in ticketsToCancel where !ticket.isFinished {
            ticket.isFinished = true
            ticket.request.finishCancelledRequest()
        }
    }

    // MARK: - Request Dispatching

    func startRequest(_ asyncVideoCompositionRequest: AVAsynchronousVideoCompositionRequest) {
        stateLock.lock()
        let currentGen = self.generation
        let ticket = RequestTicket(request: asyncVideoCompositionRequest, generation: currentGen)
        pendingTickets[ticket.id] = ticket
        stateLock.unlock()

        renderQueue.async {
            self.processRequest(ticket)
        }
    }

    // MARK: - Rendering Pipeline

    private func processRequest(_ ticket: RequestTicket) {
        stateLock.lock()
        let isValid = (ticket.generation == self.generation && !ticket.isFinished)
        stateLock.unlock()
        guard isValid else { return }

        let request = ticket.request

        do {
            guard let instruction = request.videoCompositionInstruction as? TrailerVideoCompositionInstruction else {
                throw TrailerCompositorError.invalidInstruction(
                    "Expected TrailerVideoCompositionInstruction, received \(type(of: request.videoCompositionInstruction))"
                )
            }

            let composedBuffer = try self.renderFrame(for: request, instruction: instruction)
            self.finishRequest(ticket: ticket, action: .success(composedBuffer))
        } catch {
            self.finishRequest(ticket: ticket, action: .error(error))
        }
    }

    private func renderFrame(
        for request: AVAsynchronousVideoCompositionRequest,
        instruction: TrailerVideoCompositionInstruction
    ) throws -> CVPixelBuffer {
        let outputTime = CMTimeGetSeconds(request.compositionTime)
        let renderSize = instruction.renderSize
        guard renderSize.width.isFinite && renderSize.height.isFinite && renderSize.width > 0 && renderSize.height > 0 else {
            throw TrailerCompositorError.invalidInstruction("Invalid renderSize \(renderSize)")
        }
        let renderBounds = CGRect(origin: .zero, size: renderSize)

        guard instruction.layers.count <= 2 else {
            throw TrailerCompositorError.invalidInstruction("Instruction layer count (\(instruction.layers.count)) exceeds maximum supported 2.")
        }

        func renderLayerImage(layer: TrailerCompositionLayer) throws -> CIImage {
            guard let sourcePixelBuffer = request.sourceFrame(byTrackID: layer.sourceTrackID) else {
                throw TrailerCompositorError.missingSourceFrame(trackID: layer.sourceTrackID)
            }
            var image = CIImage(cvPixelBuffer: sourcePixelBuffer)

            // Step 1: CIColorControls
            if let color = layer.colorAdjustment, !color.isNeutral {
                image = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: NSNumber(value: color.brightness),
                    kCIInputContrastKey: NSNumber(value: color.contrast),
                    kCIInputSaturationKey: NSNumber(value: color.saturation)
                ])
            }

            // Step 2: Apply supplied baseTransform and source-time interpolated normalized scale/offset
            let sourceTime = layer.mapping.sourceTime(forOutputTime: outputTime)
            let interpolated = TrailerTransformKeyframe.interpolate(keyframes: layer.keyframes, at: sourceTime)

            let cx = renderSize.width * 0.5
            let cy = renderSize.height * 0.5
            let dx = CGFloat(interpolated.offsetX) * (renderSize.width * 0.5)
            let dy = CGFloat(interpolated.offsetY) * (renderSize.height * 0.5)
            let scale = CGFloat(interpolated.scale)

            let toCenter = CGAffineTransform(translationX: -cx, y: -cy)
            let scaleTransform = CGAffineTransform(scaleX: scale, y: scale)
            let fromCenter = CGAffineTransform(translationX: cx + dx, y: cy + dy)
            let userTransform = toCenter.concatenating(scaleTransform).concatenating(fromCenter)

            let totalTransform = layer.baseTransform.concatenating(userTransform)
            image = image.transformed(by: totalTransform)

            // Step 3: Crop to render bounds
            image = image.cropped(to: renderBounds)

            // Step 4: Layer Opacity
            let effectiveLayerOpacity = layer.opacity * interpolated.opacity
            if effectiveLayerOpacity < 0.9999 {
                let alpha = CGFloat(max(0.0, min(1.0, effectiveLayerOpacity)))
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
            }

            return image
        }

        var composedImage: CIImage
        var transitionProgress: Float = 0.0
        var active0 = false
        var active1 = false

        if instruction.layers.isEmpty {
            // 영상보다 긴 음성 해설 꼬리 구간: 검은 화면(자막 큐는 아래에서 그대로 올라간다).
            composedImage = CIImage(color: CIColor.black).cropped(to: renderBounds)
        } else if instruction.layers.count == 1 {
            let layer = instruction.layers[0]
            guard layer.isActive(at: outputTime) else {
                throw TrailerCompositorError.invalidInstruction("Single visual layer is not active at outputTime \(outputTime).")
            }
            active0 = true
            composedImage = try renderLayerImage(layer: layer)
        } else {
            let layer0 = instruction.layers[0]
            let layer1 = instruction.layers[1]

            active0 = layer0.isActive(at: outputTime)
            active1 = layer1.isActive(at: outputTime)

            guard active0 || active1 else {
                throw TrailerCompositorError.invalidInstruction("No visual layer is active at outputTime \(outputTime).")
            }

            if active0 && active1 {
                let startSeconds = CMTimeGetSeconds(instruction.timeRange.start)
                let elapsed = outputTime - startSeconds
                if instruction.transitionDuration > 0.0001 {
                    let progress = elapsed / instruction.transitionDuration
                    transitionProgress = Float(min(1.0, max(0.0, progress)))
                } else {
                    transitionProgress = 1.0
                }

                let img0 = try renderLayerImage(layer: layer0)
                let img1 = try renderLayerImage(layer: layer1)

                guard let dissolveFilter = CIFilter(name: "CIDissolveTransition") else {
                    throw TrailerCompositorError.renderFailed("CIDissolveTransition filter could not be created.")
                }
                dissolveFilter.setValue(img0, forKey: kCIInputImageKey)
                dissolveFilter.setValue(img1, forKey: kCIInputTargetImageKey)
                dissolveFilter.setValue(NSNumber(value: transitionProgress), forKey: kCIInputTimeKey)
                guard let output = dissolveFilter.outputImage else {
                    throw TrailerCompositorError.renderFailed("CIDissolveTransition produced no output image.")
                }
                composedImage = output
            } else if active0 {
                composedImage = try renderLayerImage(layer: layer0)
            } else {
                composedImage = try renderLayerImage(layer: layer1)
            }
        }

        // Step 5: Bitmap cues sourceOver overlay
        let isTwoActiveOverlap = (instruction.layers.count == 2 && active0 && active1 && instruction.transitionDuration > 0.0001)

        for cue in instruction.captionCues {
            guard cue.isActive(at: outputTime) else { continue }
            var cueImage = CIImage(cgImage: cue.image)

            // Geometry: frame is explicit destination rect; scale bitmap to its size then translate (zero means native/full canvas as documented)
            if cue.frame != .zero {
                let imgWidth = CGFloat(cue.image.width)
                let imgHeight = CGFloat(cue.image.height)
                if imgWidth > 0 && imgHeight > 0 {
                    let scaleX = cue.frame.width / imgWidth
                    let scaleY = cue.frame.height / imgHeight
                    let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleY)
                    let translationTransform = CGAffineTransform(translationX: cue.frame.origin.x, y: cue.frame.origin.y)
                    cueImage = cueImage.transformed(by: scaleTransform.concatenating(translationTransform))
                }
            }

            var effectiveCueOpacity = cue.opacity

            // Clip-owned caption follows owner's active state, keyframed opacity, base opacity, and effective dissolve weighting
            if let ownedTrackID = cue.layerTrackID,
               let ownerLayer = instruction.layers.first(where: { $0.sourceTrackID == ownedTrackID }) {
                guard ownerLayer.isActive(at: outputTime) else {
                    continue
                }
                let ownerSourceTime = ownerLayer.mapping.sourceTime(forOutputTime: outputTime)
                let ownerKeyframe = TrailerTransformKeyframe.interpolate(keyframes: ownerLayer.keyframes, at: ownerSourceTime)
                effectiveCueOpacity *= (ownerLayer.opacity * ownerKeyframe.opacity)

                // Dissolve weighting applies ONLY during actual two-active overlap; never outside (no transition fade when only one layer active)
                if isTwoActiveOverlap {
                    if ownedTrackID == instruction.layers[0].sourceTrackID {
                        effectiveCueOpacity *= Double(1.0 - transitionProgress)
                    } else if ownedTrackID == instruction.layers[1].sourceTrackID {
                        effectiveCueOpacity *= Double(transitionProgress)
                    }
                }
            }

            guard effectiveCueOpacity > 0.0001 else { continue }

            if effectiveCueOpacity < 0.9999 {
                let alpha = CGFloat(max(0.0, min(1.0, effectiveCueOpacity)))
                cueImage = cueImage.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: alpha, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: alpha, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: alpha, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: alpha)
                ])
            }

            composedImage = cueImage.composited(over: composedImage)
        }

        // Step 6: Composite over opaque black background
        let blackBackground = CIImage(color: CIColor.black).cropped(to: renderBounds)
        let finalRenderImage = composedImage.composited(over: blackBackground)

        // Step 7: Allocate output pixel buffer and render via CIContext
        guard let outputPixelBuffer = request.renderContext.newPixelBuffer() else {
            throw TrailerCompositorError.allocationFailed
        }

        let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        ciContext.render(finalRenderImage, to: outputPixelBuffer, bounds: renderBounds, colorSpace: sRGBColorSpace)

        return outputPixelBuffer
    }
}
