// Shared trailer analysis, copied from HanClip for an independent NasFinder build.
import Foundation

enum AudioImpactSensitivity: Equatable, Sendable {
    case noisy
    case normal
    case quiet
    case automatic
}

struct AudioImpactMetrics: Sendable {
    let rms: Double
    let peak: Double
    let crossingRate: Double

    var impactScore: Double {
        let highFrequencyWeight = min(1, crossingRate * 10)
        return min(
            1,
            rms * 0.55
                + peak * 0.45
                + highFrequencyWeight * rms * 0.35
        )
    }
}

struct AudioImpactFrame: Sendable {
    let time: Double
    let metrics: AudioImpactMetrics
}

struct AudioImpactDecision: Sendable {
    let isTriggered: Bool
    let confidence: Double
}

enum GolfSwingMotionPhase: Equatable, Sendable {
    case seekingAddress
    case addressed
    case backswing
    case downswing
}

struct GolfSwingVisualSample: Sendable {
    let time: Double
    let localMotion: Double
    let globalMotion: Double
    let widespreadMotion: Double
    let concentration: Double
    let brightnessChange: Double
    let dominantRegion: Int
}

struct GolfSwingMotionSignal: Sendable {
    let phase: GolfSwingMotionPhase
    let confidence: Double
    let impactTime: Double?

    var isImpactWindow: Bool {
        phase == .downswing && impactTime != nil
    }
}

struct GolfSwingMotionAnalyzer: Sendable {
    private(set) var phase = GolfSwingMotionPhase.seekingAddress

    private var quietSince: Double?
    private var motionCandidateSince: Double?
    private var motionCandidateCount = 0
    private var backswingStart: Double?
    private var backswingPeak = 0.0
    private var backswingSamples = 0
    private var previousMotion = 0.0
    private var lockedRegion: Int?
    private var downswingTime: Double?
    private var globalMotionCount = 0

    mutating func reset() {
        phase = .seekingAddress
        quietSince = nil
        motionCandidateSince = nil
        motionCandidateCount = 0
        backswingStart = nil
        backswingPeak = 0
        backswingSamples = 0
        previousMotion = 0
        lockedRegion = nil
        downswingTime = nil
        globalMotionCount = 0
    }

    mutating func observe(
        _ sample: GolfSwingVisualSample
    ) -> GolfSwingMotionSignal {
        let isGlobalChange = sample.globalMotion >= 0.16
            || sample.widespreadMotion >= 0.68
            || sample.brightnessChange >= 0.14
        if isGlobalChange {
            globalMotionCount += 1
            if globalMotionCount >= 2 {
                reset()
            }
            return currentSignal(at: sample.time)
        }
        globalMotionCount = 0

        switch phase {
        case .seekingAddress:
            let isQuiet = sample.localMotion <= 0.075
                && sample.globalMotion <= 0.08
                && sample.widespreadMotion <= 0.32
            if isQuiet {
                quietSince = quietSince ?? sample.time
                if sample.time - (quietSince ?? sample.time) >= 0.55 {
                    phase = .addressed
                    motionCandidateSince = nil
                    motionCandidateCount = 0
                }
            } else {
                quietSince = nil
            }

        case .addressed:
            let isBackswingCandidate = sample.localMotion >= 0.12
                && sample.concentration >= 0.38
                && sample.widespreadMotion >= 0.04
                && sample.widespreadMotion <= 0.58
            if isBackswingCandidate {
                if let since = motionCandidateSince,
                   sample.time - since <= 0.35,
                   abs((lockedRegion ?? sample.dominantRegion)
                       - sample.dominantRegion) <= 1 {
                    motionCandidateCount += 1
                } else {
                    motionCandidateSince = sample.time
                    motionCandidateCount = 1
                    lockedRegion = sample.dominantRegion
                }

                if motionCandidateCount >= 2 {
                    phase = .backswing
                    backswingStart = motionCandidateSince
                    backswingPeak = sample.localMotion
                    backswingSamples = motionCandidateCount
                    previousMotion = sample.localMotion
                }
            } else if sample.localMotion <= 0.085 {
                motionCandidateSince = nil
                motionCandidateCount = 0
                lockedRegion = nil
            }

        case .backswing:
            guard let backswingStart else {
                reset()
                return currentSignal(at: sample.time)
            }
            let elapsed = sample.time - backswingStart
            let movedToAnotherRegion = abs(
                (lockedRegion ?? sample.dominantRegion)
                    - sample.dominantRegion
            ) > 1
                && sample.localMotion >= 0.18
            if elapsed > 1.8 || movedToAnotherRegion {
                reset()
                return currentSignal(at: sample.time)
            }

            if sample.localMotion >= 0.10 {
                backswingSamples += 1
            }
            let acceleration = sample.localMotion - previousMotion
            let previousPeak = backswingPeak
            let isDownswing = elapsed >= 0.18
                && backswingSamples >= 3
                && sample.localMotion >= 0.20
                && (acceleration >= 0.035
                    || sample.localMotion >= max(0.26, previousPeak * 1.15))
            backswingPeak = max(backswingPeak, sample.localMotion)
            previousMotion = sample.localMotion

            if isDownswing {
                phase = .downswing
                downswingTime = sample.time
            }

        case .downswing:
            if let downswingTime, sample.time - downswingTime > 0.42 {
                reset()
            }
        }

        return currentSignal(at: sample.time)
    }

    func currentSignal(at time: Double) -> GolfSwingMotionSignal {
        switch phase {
        case .downswing:
            guard let downswingTime,
                  time - downswingTime <= 0.42
            else {
                return GolfSwingMotionSignal(
                    phase: .seekingAddress,
                    confidence: 0,
                    impactTime: nil
                )
            }
            let confidence = max(
                0.72,
                min(1, 0.62 + backswingPeak * 0.95)
            )
            return GolfSwingMotionSignal(
                phase: .downswing,
                confidence: confidence,
                impactTime: downswingTime
            )
        case .backswing:
            return GolfSwingMotionSignal(
                phase: .backswing,
                confidence: min(0.7, 0.34 + backswingPeak),
                impactTime: nil
            )
        case .addressed:
            return GolfSwingMotionSignal(
                phase: .addressed,
                confidence: 0.28,
                impactTime: nil
            )
        case .seekingAddress:
            return GolfSwingMotionSignal(
                phase: .seekingAddress,
                confidence: 0,
                impactTime: nil
            )
        }
    }
}

enum GolfSwingPosePhase: Equatable, Sendable {
    case seekingAddress
    case addressed
    case backswing
    case impactWindow
}

struct GolfSwingPoseSample: Sendable {
    let time: Double
    let handX: Double
    let handY: Double
    let coreX: Double
    let coreY: Double
    let bodyScale: Double
    let confidence: Double
}

struct GolfSwingPoseSignal: Sendable {
    let phase: GolfSwingPosePhase
    let confidence: Double
    let impactWindowStart: Double?
    let impactWindowEnd: Double?

    func isImpactWindow(at time: Double) -> Bool {
        guard phase == .impactWindow,
              let impactWindowStart,
              let impactWindowEnd
        else { return false }
        return time >= impactWindowStart && time <= impactWindowEnd
    }
}

struct GolfSwingPoseAnalyzer: Sendable {
    private(set) var phase = GolfSwingPosePhase.seekingAddress

    private var quietSince: Double?
    private var addressX = 0.0
    private var addressY = 0.0
    private var addressSamples = 0
    private var previousSample: GolfSwingPoseSample?
    private var backswingDirectionX = 0.0
    private var backswingDirectionY = 0.0
    private var backswingStart: Double?
    private var peakProgress = 0.0
    private var previousProgress = 0.0
    private var downswingSamples = 0
    private var impactWindowStart: Double?
    private var impactWindowEnd: Double?
    private var latestConfidence = 0.0

    mutating func reset() {
        phase = .seekingAddress
        quietSince = nil
        addressX = 0
        addressY = 0
        addressSamples = 0
        previousSample = nil
        backswingDirectionX = 0
        backswingDirectionY = 0
        backswingStart = nil
        peakProgress = 0
        previousProgress = 0
        downswingSamples = 0
        impactWindowStart = nil
        impactWindowEnd = nil
        latestConfidence = 0
    }

    mutating func observe(
        _ sample: GolfSwingPoseSample
    ) -> GolfSwingPoseSignal {
        guard sample.confidence >= 0.45,
              sample.bodyScale >= 0.04
        else {
            return currentSignal(at: sample.time)
        }
        latestConfidence = sample.confidence

        if let previousSample {
            let sampleGap = sample.time - previousSample.time
            let scaleChange = abs(sample.bodyScale - previousSample.bodyScale)
                / max(0.001, previousSample.bodyScale)
            if sampleGap <= 0 || sampleGap > 0.6 || scaleChange > 0.25 {
                reset()
            }
        }

        let previous = previousSample
        defer { previousSample = sample }

        switch phase {
        case .seekingAddress:
            guard let previous else {
                beginAddressAverage(with: sample)
                return currentSignal(at: sample.time)
            }
            let handSpeed = distance(
                x1: sample.handX,
                y1: sample.handY,
                x2: previous.handX,
                y2: previous.handY
            ) / max(0.05, sample.time - previous.time)
            let coreSpeed = distance(
                x1: sample.coreX,
                y1: sample.coreY,
                x2: previous.coreX,
                y2: previous.coreY
            ) / max(0.05, sample.time - previous.time)
                / max(0.04, sample.bodyScale)
            if handSpeed <= 0.22 && coreSpeed <= 0.20 {
                quietSince = quietSince ?? previous.time
                addToAddressAverage(sample)
                if sample.time - (quietSince ?? sample.time) >= 0.55,
                   addressSamples >= 3 {
                    phase = .addressed
                }
            } else {
                quietSince = nil
                beginAddressAverage(with: sample)
            }

        case .addressed:
            let dx = sample.handX - addressX
            let dy = sample.handY - addressY
            let displacement = hypot(dx, dy)
            if displacement >= 0.20 {
                backswingDirectionX = dx / displacement
                backswingDirectionY = dy / displacement
                backswingStart = sample.time
                peakProgress = displacement
                previousProgress = displacement
                downswingSamples = 0
                phase = .backswing
            }

        case .backswing:
            guard let backswingStart else {
                reset()
                return currentSignal(at: sample.time)
            }
            let elapsed = sample.time - backswingStart
            if elapsed > 1.8 {
                reset()
                return currentSignal(at: sample.time)
            }
            let progress = (sample.handX - addressX) * backswingDirectionX
                + (sample.handY - addressY) * backswingDirectionY
            peakProgress = max(peakProgress, progress)
            let deltaTime = max(
                0.05,
                sample.time - (previous?.time ?? sample.time - 0.2)
            )
            let returnSpeed = (previousProgress - progress) / deltaTime
            if elapsed >= 0.18,
               peakProgress >= 0.28,
               progress < previousProgress,
               returnSpeed >= 0.55 {
                downswingSamples += 1
            } else if progress >= previousProgress {
                downswingSamples = 0
            }
            previousProgress = progress

            let returnedEnough = peakProgress - progress
                >= max(0.18, peakProgress * 0.55)
            if downswingSamples >= 2 && returnedEnough {
                phase = .impactWindow
                impactWindowStart = sample.time - 0.45
                impactWindowEnd = sample.time + 0.30
            }

        case .impactWindow:
            if sample.time > (impactWindowEnd ?? sample.time) {
                reset()
            }
        }

        return currentSignal(at: sample.time)
    }

    func currentSignal(at time: Double) -> GolfSwingPoseSignal {
        switch phase {
        case .impactWindow:
            return GolfSwingPoseSignal(
                phase: .impactWindow,
                confidence: min(
                    latestConfidence,
                    min(1, 0.72 + peakProgress * 0.45)
                ),
                impactWindowStart: impactWindowStart,
                impactWindowEnd: impactWindowEnd
            )
        case .backswing:
            return GolfSwingPoseSignal(
                phase: .backswing,
                confidence: min(0.7, 0.35 + peakProgress),
                impactWindowStart: nil,
                impactWindowEnd: nil
            )
        case .addressed:
            return GolfSwingPoseSignal(
                phase: .addressed,
                confidence: 0.32,
                impactWindowStart: nil,
                impactWindowEnd: nil
            )
        case .seekingAddress:
            return GolfSwingPoseSignal(
                phase: .seekingAddress,
                confidence: 0,
                impactWindowStart: nil,
                impactWindowEnd: nil
            )
        }
    }

    private mutating func beginAddressAverage(
        with sample: GolfSwingPoseSample
    ) {
        addressX = sample.handX
        addressY = sample.handY
        addressSamples = 1
    }

    private mutating func addToAddressAverage(
        _ sample: GolfSwingPoseSample
    ) {
        addressSamples += 1
        let weight = 1.0 / Double(addressSamples)
        addressX += (sample.handX - addressX) * weight
        addressY += (sample.handY - addressY) * weight
    }

    private func distance(
        x1: Double,
        y1: Double,
        x2: Double,
        y2: Double
    ) -> Double {
        hypot(x1 - x2, y1 - y2)
    }
}

enum GolfPuttStrokePhase: Equatable, Sendable {
    case seekingAddress
    case addressed
    case backswing
    case forwardStroke
    case confirmedStroke
}

struct GolfPuttStrokeSignal: Sendable {
    let phase: GolfPuttStrokePhase
    let confidence: Double
    let strokeTime: Double?

    var isConfirmedStroke: Bool {
        phase == .confirmedStroke && strokeTime != nil
    }
}

struct GolfPuttStrokeAnalyzer: Sendable {
    private(set) var phase = GolfPuttStrokePhase.seekingAddress

    private var quietSince: Double?
    private var addressX = 0.0
    private var addressY = 0.0
    private var addressSamples = 0
    private var previousSample: GolfSwingPoseSample?
    private var directionX = 0.0
    private var directionY = 0.0
    private var backswingStart: Double?
    private var backswingSamples = 0
    private var peakProgress = 0.0
    private var previousProgress = 0.0
    private var forwardSamples = 0
    private var strokeTime: Double?
    private var minimumSequenceConfidence = 1.0
    private var lastConfirmedTime = -10.0

    mutating func reset() {
        phase = .seekingAddress
        quietSince = nil
        addressX = 0
        addressY = 0
        addressSamples = 0
        previousSample = nil
        directionX = 0
        directionY = 0
        backswingStart = nil
        backswingSamples = 0
        peakProgress = 0
        previousProgress = 0
        forwardSamples = 0
        strokeTime = nil
        minimumSequenceConfidence = 1
    }

    mutating func observe(
        _ sample: GolfSwingPoseSample
    ) -> GolfPuttStrokeSignal {
        guard sample.confidence >= 0.45,
              sample.bodyScale >= 0.04
        else {
            return currentSignal(at: sample.time)
        }

        if let previousSample {
            let sampleGap = sample.time - previousSample.time
            let scaleChange = abs(sample.bodyScale - previousSample.bodyScale)
                / max(0.001, previousSample.bodyScale)
            if sampleGap <= 0 || sampleGap > 0.6 || scaleChange > 0.25 {
                reset()
            }
        }
        if sample.time < lastConfirmedTime {
            lastConfirmedTime = -10
        }
        if sample.time - lastConfirmedTime < 2.0 {
            previousSample = sample
            return currentSignal(at: sample.time)
        }

        let previous = previousSample
        defer { previousSample = sample }

        if let previous, phase != .seekingAddress {
            let coreSpeed = hypot(
                sample.coreX - previous.coreX,
                sample.coreY - previous.coreY
            ) / max(0.05, sample.time - previous.time)
                / max(0.04, sample.bodyScale)
            if coreSpeed > 0.9 {
                reset()
                return currentSignal(at: sample.time)
            }
        }

        switch phase {
        case .seekingAddress:
            guard let previous else {
                beginAddressAverage(with: sample)
                return currentSignal(at: sample.time)
            }
            let deltaTime = max(0.05, sample.time - previous.time)
            let handSpeed = hypot(
                sample.handX - previous.handX,
                sample.handY - previous.handY
            ) / deltaTime
            let coreSpeed = hypot(
                sample.coreX - previous.coreX,
                sample.coreY - previous.coreY
            ) / deltaTime / max(0.04, sample.bodyScale)
            if handSpeed <= 0.25 && coreSpeed <= 0.20 {
                quietSince = quietSince ?? previous.time
                addToAddressAverage(sample)
                if sample.time - (quietSince ?? sample.time) >= 0.60,
                   addressSamples >= 3 {
                    phase = .addressed
                    minimumSequenceConfidence = sample.confidence
                }
            } else {
                quietSince = nil
                beginAddressAverage(with: sample)
            }

        case .addressed:
            minimumSequenceConfidence = min(
                minimumSequenceConfidence,
                sample.confidence
            )
            let dx = sample.handX - addressX
            let dy = sample.handY - addressY
            let displacement = hypot(dx, dy)
            if displacement >= 0.06 {
                directionX = dx / displacement
                directionY = dy / displacement
                backswingStart = sample.time
                backswingSamples = 0
                peakProgress = displacement
                previousProgress = displacement
                forwardSamples = 0
                phase = .backswing
            }

        case .backswing:
            guard let backswingStart else {
                reset()
                return currentSignal(at: sample.time)
            }
            minimumSequenceConfidence = min(
                minimumSequenceConfidence,
                sample.confidence
            )
            backswingSamples += 1
            let elapsed = sample.time - backswingStart
            let progress = (sample.handX - addressX) * directionX
                + (sample.handY - addressY) * directionY
            peakProgress = max(peakProgress, progress)
            if elapsed > 2.0 || peakProgress > 0.60 {
                reset()
                return currentSignal(at: sample.time)
            }
            let deltaTime = max(
                0.05,
                sample.time - (previous?.time ?? sample.time - 0.2)
            )
            let returnSpeed = (previousProgress - progress) / deltaTime
            let returnedThroughAddress = progress
                <= max(0.04, peakProgress * 0.30)
            if returnedThroughAddress && returnSpeed > 1.5 {
                reset()
                return currentSignal(at: sample.time)
            }
            if elapsed >= 0.15,
               backswingSamples >= 2,
               peakProgress >= 0.12,
               progress < previousProgress,
               returnSpeed >= 0.20,
               returnedThroughAddress {
                phase = .forwardStroke
                strokeTime = sample.time
                forwardSamples = 1
            }
            previousProgress = progress

        case .forwardStroke:
            guard let strokeTime else {
                reset()
                return currentSignal(at: sample.time)
            }
            minimumSequenceConfidence = min(
                minimumSequenceConfidence,
                sample.confidence
            )
            if sample.time - strokeTime > 0.9 {
                reset()
                return currentSignal(at: sample.time)
            }
            let progress = (sample.handX - addressX) * directionX
                + (sample.handY - addressY) * directionY
            let followThroughLimit = -max(0.30, peakProgress * 1.2)
            if progress <= followThroughLimit {
                reset()
                return currentSignal(at: sample.time)
            }
            let followThroughThreshold = -max(0.025, peakProgress * 0.15)
            if progress <= followThroughThreshold {
                forwardSamples += 1
                if forwardSamples >= 2 {
                    let confirmed = GolfPuttStrokeSignal(
                        phase: .confirmedStroke,
                        confidence: min(
                            minimumSequenceConfidence,
                            min(1, 0.62 + peakProgress * 0.9)
                        ),
                        strokeTime: strokeTime
                    )
                    reset()
                    lastConfirmedTime = sample.time
                    return confirmed
                }
            } else {
                reset()
            }

        case .confirmedStroke:
            reset()
        }

        return currentSignal(at: sample.time)
    }

    func currentSignal(at time: Double) -> GolfPuttStrokeSignal {
        switch phase {
        case .confirmedStroke:
            return GolfPuttStrokeSignal(
                phase: .confirmedStroke,
                confidence: min(
                    minimumSequenceConfidence,
                    min(1, 0.62 + peakProgress * 0.9)
                ),
                strokeTime: strokeTime
            )
        case .forwardStroke:
            return GolfPuttStrokeSignal(
                phase: .forwardStroke,
                confidence: min(0.7, 0.4 + peakProgress),
                strokeTime: nil
            )
        case .backswing:
            return GolfPuttStrokeSignal(
                phase: .backswing,
                confidence: min(0.6, 0.3 + peakProgress),
                strokeTime: nil
            )
        case .addressed:
            return GolfPuttStrokeSignal(
                phase: .addressed,
                confidence: 0.3,
                strokeTime: nil
            )
        case .seekingAddress:
            return GolfPuttStrokeSignal(
                phase: .seekingAddress,
                confidence: 0,
                strokeTime: nil
            )
        }
    }

    private mutating func beginAddressAverage(
        with sample: GolfSwingPoseSample
    ) {
        addressX = sample.handX
        addressY = sample.handY
        addressSamples = 1
    }

    private mutating func addToAddressAverage(
        _ sample: GolfSwingPoseSample
    ) {
        addressSamples += 1
        let weight = 1.0 / Double(addressSamples)
        addressX += (sample.handX - addressX) * weight
        addressY += (sample.handY - addressY) * weight
    }
}

enum GolfPuttFusionPolicy {
    static func shouldTrigger(
        stroke: GolfPuttStrokeSignal,
        poseObservationConfidence: Double,
        hasRecentPose: Bool,
        hasRecentVisualFrame: Bool,
        isSceneStable: Bool,
        isInsideReadyPromptWindow: Bool
    ) -> Bool {
        guard AudioImpactClassifier.currentModelVersion
            .supportsSoundlessPuttFallback
        else { return false }
        return stroke.isConfirmedStroke
            && stroke.confidence >= 0.72
            && poseObservationConfidence >= 0.72
            && hasRecentPose
            && hasRecentVisualFrame
            && isSceneStable
            && !isInsideReadyPromptWindow
    }
}

enum GolfSwingFusionPolicy {
    private static let weakImpactPeakFloor = 0.10
    private static let weakImpactScoreFloor = 0.065
    private static let weakImpactCrossingRateFloor = 0.08
    private static let weakImpactCrestFactorFloor = 3.5

    static func shouldTrigger(
        decision: AudioImpactDecision,
        metrics: AudioImpactMetrics,
        motion: GolfSwingMotionSignal,
        pose: GolfSwingPoseSignal? = nil,
        referenceTime: Double = 0,
        requiresPoseConfirmation: Bool = false,
        hasRecentVisualFrame: Bool,
        isInsideReadyPromptWindow: Bool
    ) -> Bool {
        guard hasRecentVisualFrame else {
            return decision.isTriggered
                && !AudioImpactClassifier.currentModelVersion.requiresVisualShotEvidence
                && !isInsideReadyPromptWindow
        }
        let hasMotionEvidence = motion.isImpactWindow
            && motion.confidence >= 0.72
            && (referenceTime - (motion.impactTime ?? referenceTime)) >= -0.20
            && (referenceTime - (motion.impactTime ?? referenceTime)) <= 0.32
        let hasPoseEvidence = pose?.confidence ?? 0 >= 0.72
            && pose?.isImpactWindow(at: referenceTime) == true
        let allowsPoseOnlyEvidence = AudioImpactClassifier
            .currentModelVersion.usesPoseBackedImpactEvidence
        let hasVisualEvidence = hasMotionEvidence
            || (allowsPoseOnlyEvidence && hasPoseEvidence)
        guard hasVisualEvidence,
              !requiresPoseConfirmation || hasPoseEvidence
        else { return false }

        if !decision.isTriggered {
            let crestFactor = metrics.peak / max(0.001, metrics.rms)
            guard AudioImpactClassifier.currentModelVersion
                .supportsVisualBackedWeakImpact,
                !isInsideReadyPromptWindow,
                metrics.peak >= weakImpactPeakFloor,
                metrics.impactScore >= weakImpactScoreFloor,
                metrics.crossingRate >= weakImpactCrossingRateFloor,
                crestFactor >= weakImpactCrestFactorFloor
            else { return false }
            return true
        }

        if isInsideReadyPromptWindow {
            return metrics.peak >= 0.16
                && metrics.impactScore >= 0.08
        }
        return true
    }
}

enum HanClipAiModelVersion: String, CaseIterable, Sendable {
    case v0_1_0 = "0.1.0"
    case v0_2_0 = "0.2.0"
    case v0_2_1 = "0.2.1"
    case v0_3_0 = "0.3.0"
    case v0_4_0 = "0.4.0"
    case v0_5_0 = "0.5.0"
    case v0_5_1 = "0.5.1"
    case v0_6_0 = "0.6.0"
    case v0_7_0 = "0.7.0"

    var title: String {
        switch self {
        case .v0_1_0:
            "소리 중심 Ai"
        case .v0_2_0:
            "소리 + 화면 보조 Ai"
        case .v0_2_1:
            "798 영상 보정 Ai"
        case .v0_3_0:
            "소리·화면 독립 Ai"
        case .v0_4_0:
            "골프 동작 결합 Ai"
        case .v0_5_0:
            "몸동작 인식 Ai"
        case .v0_5_1:
            "몸동작 근거 보강 Ai"
        case .v0_6_0:
            "무음 퍼팅 안전망 Ai"
        case .v0_7_0:
            "혼합 클럽 연속 동작 Ai"
        }
    }

    var releaseDate: String {
        switch self {
        case .v0_1_0:
            "2026.08.06"
        case .v0_2_0:
            "2026.08.06"
        case .v0_2_1:
            "2026.08.06"
        case .v0_3_0:
            "2026.08.20"
        case .v0_4_0, .v0_5_0:
            "2026.08.20"
        case .v0_5_1, .v0_6_0:
            "2026.08.24"
        case .v0_7_0:
            "2026.09.07"
        }
    }

    var featureSummary: String {
        switch self {
        case .v0_1_0:
            "소리의 피크, 갑작스러운 상승, 이어지는 반응을 중심으로 기억할 순간을 찾습니다."
        case .v0_2_0:
            "소리를 중심으로 보되, AiShot 촬영 중 화면의 움직임과 밝기 변화를 함께 참고해 더 좋은 순간을 찾습니다."
        case .v0_2_1:
            "798개 영상 공부 결과를 반영해, 소리의 피크보다 행복한 순간 뒤에 이어지는 반응과 화면 변화를 더 차분하게 함께 봅니다."
        case .v0_3_0:
            "소리가 없는 영상은 화면 움직임을 독립적으로 분석하고, 화면 변화가 적으면 중앙 구간을 정직하게 제안합니다."
        case .v0_4_0:
            "AiShot에서 정지 자세 뒤의 연속 스윙 움직임과 충격음을 함께 확인해, 준비 음성과 주변 타석 소리에 덜 반응합니다."
        case .v0_5_0:
            "기기 안에서 골퍼의 어깨·골반·팔 관절 흐름을 보조로 확인해, 단순 화면 변화보다 실제 몸동작이 있는 샷을 더 잘 구분합니다."
        case .v0_5_1:
            "화면 격자 움직임이 약해도 같은 순간의 몸동작 임팩트가 확실하면 시각 근거로 인정합니다. 충격음 판정은 항상 함께 요구하며, 자세를 충분히 보지 못하면 0.5.0과 같은 화면 움직임·소리 결합으로 판단합니다."
        case .v0_6_0:
            "타구음이 거의 없는 퍼팅을 위한 안전망을 더합니다. 준비 자세, 작은 백스윙, 전진 스트로크, 짧은 팔로스루가 시간 순서로 확인되고 화면이 안정적일 때만 소리 없이 촬영합니다. 일반 스윙의 충격음·몸동작 결합 판단은 0.5.1 그대로 유지합니다."
        case .v0_7_0:
            "드라이버부터 작은 어프로치까지 소리 크기보다 연속된 샷 동작을 함께 봅니다. 약한 접촉음도 동작과 맞으면 살리고, 화면 근거가 없는 소리만으로는 촬영하지 않습니다. 퍼팅 자세 근거는 조금 더 오래 유지합니다."
        }
    }

    var supportsRealtimeVisualAssist: Bool {
        switch self {
        case .v0_1_0:
            false
        case .v0_2_0, .v0_2_1, .v0_3_0, .v0_4_0, .v0_5_0, .v0_5_1, .v0_6_0, .v0_7_0:
            true
        }
    }

    var usesAudibleResponseWeight: Bool {
        switch self {
        case .v0_1_0:
            false
        case .v0_2_0, .v0_2_1, .v0_3_0, .v0_4_0, .v0_5_0, .v0_5_1, .v0_6_0, .v0_7_0:
            true
        }
    }

    var usesGolfSwingMotionFusion: Bool {
        self == .v0_4_0 || self == .v0_5_0 || self == .v0_5_1
            || self == .v0_6_0 || self == .v0_7_0
    }

    var usesBodyPoseAssist: Bool {
        self == .v0_5_0 || self == .v0_5_1 || self == .v0_6_0 || self == .v0_7_0
    }

    var usesPoseBackedImpactEvidence: Bool {
        self == .v0_5_1 || self == .v0_6_0 || self == .v0_7_0
    }

    var supportsSoundlessPuttFallback: Bool {
        self == .v0_6_0 || self == .v0_7_0
    }

    var requiresVisualShotEvidence: Bool { self == .v0_7_0 }
    var supportsVisualBackedWeakImpact: Bool { self == .v0_7_0 }
}

enum AudioImpactClassifier {
    static let currentModelVersion = HanClipAiModelVersion.v0_7_0
    static var modelVersion: String { currentModelVersion.rawValue }
    static var modelFeatureSummary: String {
        currentModelVersion.featureSummary
    }

    private struct Thresholds {
        let strongScoreFloor: Double
        let strongBaselineMultiplier: Double
        let strongPeakFloor: Double
        let strongPeakBaselineMultiplier: Double
        let strongRise: Double
        let strongCrossingRate: Double
        let strongCrestFactor: Double
        let distantScoreFloor: Double
        let distantBaselineMultiplier: Double
        let distantPeakFloor: Double
        let distantPeakBaselineMultiplier: Double
        let distantRise: Double
        let distantCrossingRate: Double
        let distantCrestFactor: Double
    }

    static func detectImpact(
        metrics: AudioImpactMetrics,
        baseline: Double,
        previousRecentLevel: Double,
        sensitivity: AudioImpactSensitivity
    ) -> AudioImpactDecision {
        let score = metrics.impactScore
        let referenceLevel = max(
            0.003,
            max(baseline, previousRecentLevel * 0.82)
        )
        let suddenRise = score / referenceLevel
        let crestFactor = metrics.peak / max(0.001, metrics.rms)
        let thresholds = thresholds(
            for: effectiveSensitivity(
                sensitivity,
                baseline: baseline
            )
        )

        let strongScoreRequirement = max(
            thresholds.strongScoreFloor,
            baseline * thresholds.strongBaselineMultiplier
        )
        let strongPeakRequirement = max(
            thresholds.strongPeakFloor,
            baseline * thresholds.strongPeakBaselineMultiplier
        )
        let isStrongImpact = score >= strongScoreRequirement
            && metrics.peak >= strongPeakRequirement
            && suddenRise >= thresholds.strongRise
            && metrics.crossingRate >= thresholds.strongCrossingRate
            && crestFactor >= thresholds.strongCrestFactor

        let distantScoreRequirement = max(
            thresholds.distantScoreFloor,
            baseline * thresholds.distantBaselineMultiplier
        )
        let distantPeakRequirement = max(
            thresholds.distantPeakFloor,
            baseline * thresholds.distantPeakBaselineMultiplier
        )
        let isDistantSharpImpact = score >= distantScoreRequirement
            && metrics.peak >= distantPeakRequirement
            && suddenRise >= thresholds.distantRise
            && metrics.crossingRate >= thresholds.distantCrossingRate
            && crestFactor >= thresholds.distantCrestFactor

        let isSpeechLikePrompt = metrics.rms >= 0.025
            && crestFactor < 3.15
            && metrics.crossingRate < 0.16
            && suddenRise < 4.8
            && score < 0.18

        let confidence = impactConfidence(
            score: score,
            peak: metrics.peak,
            suddenRise: suddenRise,
            crossingRate: metrics.crossingRate,
            crestFactor: crestFactor,
            thresholds: thresholds
        )
        return AudioImpactDecision(
            isTriggered: !isSpeechLikePrompt
                && (isStrongImpact || isDistantSharpImpact),
            confidence: isSpeechLikePrompt ? 0 : confidence
        )
    }

    static func rankedImpactTimes(
        frames: [AudioImpactFrame],
        duration: Double,
        limit: Int = 12
    ) -> [Double] {
        guard !frames.isEmpty else { return [] }

        var baseline = 0.008
        var recentLevel = 0.008
        var candidates: [(time: Double, score: Double)] = []
        var fallback: [(time: Double, score: Double)] = []

        for (index, frame) in frames.enumerated() {
            let metrics = frame.metrics
            let score = metrics.impactScore
            let previousRecentLevel = recentLevel
            let baselineSample = min(score, max(0.004, baseline * 1.35))
            baseline = baseline * 0.985
                + max(0.002, baselineSample) * 0.015
            recentLevel = recentLevel * 0.72 + max(0.002, score) * 0.28

            let decision = detectImpact(
                metrics: metrics,
                baseline: baseline,
                previousRecentLevel: previousRecentLevel,
                sensitivity: .automatic
            )
            let neighborhoodScore = localContrastScore(
                frames: frames,
                index: index
            )
            let highlightScore = generalHighlightScore(
                frames: frames,
                index: index
            )
            let memorableMomentScore = memorableMomentScore(
                frames: frames,
                index: index
            )
            let combinedScore = decision.confidence
                + neighborhoodScore * 0.45
                + highlightScore * 0.75
                + memorableMomentScore * 0.58
                + score * 0.12

            fallback.append((frame.time, combinedScore))
            if decision.isTriggered
                || highlightScore > 0.82
                || memorableMomentScore > 0.78
                || combinedScore > 1.02 {
                candidates.append((frame.time, combinedScore))
            }
        }

        if candidates.isEmpty {
            candidates = fallback
        }

        let minimumSeparation = max(0.45, duration / 160)
        var selected: [(time: Double, score: Double)] = []
        for candidate in candidates.sorted(by: { $0.score > $1.score }) {
            guard selected.allSatisfy({
                abs($0.time - candidate.time) >= minimumSeparation
            }) else { continue }
            selected.append(candidate)
            if selected.count >= limit {
                break
            }
        }
        return selected.map(\.time)
    }

    private static func effectiveSensitivity(
        _ sensitivity: AudioImpactSensitivity,
        baseline: Double
    ) -> AudioImpactSensitivity {
        guard sensitivity == .automatic else { return sensitivity }
        if baseline >= 0.026 {
            return .noisy
        } else if baseline <= 0.009 {
            return .quiet
        }
        return .normal
    }

    private static func thresholds(
        for sensitivity: AudioImpactSensitivity
    ) -> Thresholds {
        switch sensitivity {
        case .noisy:
            return Thresholds(
                strongScoreFloor: 0.10,
                strongBaselineMultiplier: 2.7,
                strongPeakFloor: 0.18,
                strongPeakBaselineMultiplier: 4.2,
                strongRise: 2.2,
                strongCrossingRate: 0.07,
                strongCrestFactor: 2.3,
                distantScoreFloor: 0.065,
                distantBaselineMultiplier: 3.4,
                distantPeakFloor: 0.12,
                distantPeakBaselineMultiplier: 5.0,
                distantRise: 3.0,
                distantCrossingRate: 0.10,
                distantCrestFactor: 3.5
            )
        case .normal, .automatic:
            return Thresholds(
                strongScoreFloor: 0.075,
                strongBaselineMultiplier: 2.3,
                strongPeakFloor: 0.13,
                strongPeakBaselineMultiplier: 3.5,
                strongRise: 1.8,
                strongCrossingRate: 0.05,
                strongCrestFactor: 2.0,
                distantScoreFloor: 0.045,
                distantBaselineMultiplier: 2.8,
                distantPeakFloor: 0.09,
                distantPeakBaselineMultiplier: 4.2,
                distantRise: 2.4,
                distantCrossingRate: 0.08,
                distantCrestFactor: 3.0
            )
        case .quiet:
            return Thresholds(
                strongScoreFloor: 0.055,
                strongBaselineMultiplier: 1.9,
                strongPeakFloor: 0.095,
                strongPeakBaselineMultiplier: 3.0,
                strongRise: 1.55,
                strongCrossingRate: 0.04,
                strongCrestFactor: 1.7,
                distantScoreFloor: 0.035,
                distantBaselineMultiplier: 2.3,
                distantPeakFloor: 0.07,
                distantPeakBaselineMultiplier: 3.4,
                distantRise: 2.0,
                distantCrossingRate: 0.065,
                distantCrestFactor: 2.5
            )
        }
    }

    private static func impactConfidence(
        score: Double,
        peak: Double,
        suddenRise: Double,
        crossingRate: Double,
        crestFactor: Double,
        thresholds: Thresholds
    ) -> Double {
        let scoreRatio = score / max(0.001, thresholds.distantScoreFloor)
        let peakRatio = peak / max(0.001, thresholds.distantPeakFloor)
        let riseRatio = suddenRise / max(0.001, thresholds.distantRise)
        let crossingRatio = crossingRate
            / max(0.001, thresholds.distantCrossingRate)
        let crestRatio = crestFactor
            / max(0.001, thresholds.distantCrestFactor)
        return scoreRatio * 0.28
            + peakRatio * 0.22
            + riseRatio * 0.24
            + min(crossingRatio, 1.8) * 0.13
            + min(crestRatio, 1.8) * 0.13
    }

    private static func localContrastScore(
        frames: [AudioImpactFrame],
        index: Int
    ) -> Double {
        let start = max(0, index - 5)
        let history = frames[start..<index].map { $0.metrics.impactScore }
        let baseline = history.reduce(0, +) / Double(max(1, history.count))
        let value = frames[index].metrics.impactScore
        let previous = index > 0 ? frames[index - 1].metrics.impactScore : 0
        let next = index + 1 < frames.count
            ? frames[index + 1].metrics.impactScore
            : 0
        let rise = max(0, value - baseline)
        let isLocalPeak = value >= previous && value >= next
        return rise * 5.0 + (isLocalPeak ? value * 0.65 : 0)
    }

    private static func generalHighlightScore(
        frames: [AudioImpactFrame],
        index: Int
    ) -> Double {
        let metrics = frames[index].metrics
        let value = metrics.impactScore
        let start = max(0, index - 10)
        let history = frames[start..<index]
        let historyCount = Double(max(1, history.count))
        let baselineScore = history
            .map(\.metrics.impactScore)
            .reduce(0, +) / historyCount
        let baselineRMS = history
            .map(\.metrics.rms)
            .reduce(0, +) / historyCount
        let baselinePeak = history
            .map(\.metrics.peak)
            .reduce(0, +) / historyCount
        let previous = index > 0 ? frames[index - 1].metrics.impactScore : 0
        let next = index + 1 < frames.count
            ? frames[index + 1].metrics.impactScore
            : 0
        let isLocalPeak = value >= previous && value >= next
        let scoreRiseRatio = value / max(0.006, baselineScore)
        let rmsRiseRatio = metrics.rms / max(0.004, baselineRMS)
        let peakRiseRatio = metrics.peak / max(0.012, baselinePeak)
        let directRise = max(0, value - previous)
        let sustainedEnergy = min(1.0, value * 1.25 + metrics.peak * 0.35)

        return min(
            1.6,
            max(0, scoreRiseRatio - 1.0) * 0.22
                + max(0, rmsRiseRatio - 1.0) * 0.16
                + max(0, peakRiseRatio - 1.0) * 0.14
                + directRise * 2.4
                + sustainedEnergy * 0.28
                + (isLocalPeak ? value * 0.45 : 0)
            )
    }

    private static func memorableMomentScore(
        frames: [AudioImpactFrame],
        index: Int
    ) -> Double {
        let frame = frames[index]
        let beforeStart = max(0, index - 8)
        let afterEnd = min(frames.count, index + 9)
        let before = frames[beforeStart..<index]
        let after = frames[(index + 1)..<afterEnd]
        guard before.count >= 2, after.count >= 2 else { return 0 }
        let beforeCount = Double(max(1, before.count))
        let afterCount = Double(max(1, after.count))
        let beforeEnergy = before.map(\.metrics.impactScore).reduce(0, +)
            / beforeCount
        let afterEnergy = after.map(\.metrics.impactScore).reduce(0, +)
            / afterCount
        let afterPeak = after.map(\.metrics.peak).max() ?? 0
        let currentEnergy = frame.metrics.impactScore
        let riseIntoMoment = max(0, currentEnergy - beforeEnergy)
        let heldExcitement = afterEnergy / max(0.008, beforeEnergy)
        let audibleResponseWeight = currentModelVersion.usesAudibleResponseWeight
            ? min(1, afterEnergy / 0.045)
            : 1
        let heldExcitementBonus = min(2.4, max(0, heldExcitement - 1))
            * audibleResponseWeight
        let responsePeak = max(0, afterPeak - frame.metrics.peak * 0.45)
        let crossingTexture = min(1, frame.metrics.crossingRate * 9)
        let distanceFromEdge = min(index, frames.count - 1 - index)
        let edgeConfidence = min(1, Double(distanceFromEdge) / 6.0)

        let score = min(
            1.5,
            riseIntoMoment * 2.2
                + heldExcitementBonus * 0.28
                + responsePeak * 0.45
                + currentEnergy * 0.34
                + crossingTexture * currentEnergy * 0.18
        )
        return score * edgeConfidence
    }
}
