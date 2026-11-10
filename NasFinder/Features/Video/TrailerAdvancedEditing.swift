import CoreGraphics
import CoreMedia
import Foundation

// MARK: - Timed Caption Cues

/// Timed caption cue representing a caption segment tied to a source video clip.
struct TrailerTimedCaptionCue: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { stableID }
    var stableID: UUID
    var sourceID: Int
    var sourceStart: Double
    var sourceEnd: Double
    var text: String
    var style: TrailerCaption
    var origin: Origin
    var manuallyEdited: Bool

    enum Origin: String, Codable, Equatable, Sendable, CaseIterable {
        case manual = "manual"
        case generated = "generated"

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let raw = (try? container.decode(String.self)) ?? ""
            if let matched = Origin(rawValue: raw.lowercased()) {
                self = matched
            } else {
                // Unknown enum strings safely fallback rather than decode crash
                self = .manual
            }
        }
    }

    var sourceDuration: Double {
        max(0.0, sourceEnd - sourceStart)
    }

    init(
        stableID: UUID = UUID(),
        sourceID: Int = 0,
        sourceStart: Double = 0.0,
        sourceEnd: Double = 0.0,
        text: String = "",
        style: TrailerCaption = TrailerCaption(),
        origin: Origin = .manual,
        manuallyEdited: Bool = false
    ) {
        self.stableID = stableID
        self.sourceID = sourceID
        let sStart = sourceStart.isFinite ? max(0.0, sourceStart) : 0.0
        let sEnd = sourceEnd.isFinite ? max(sStart, sourceEnd) : sStart
        self.sourceStart = sStart
        self.sourceEnd = sEnd
        self.text = text
        self.style = style
        self.origin = origin
        self.manuallyEdited = manuallyEdited
    }

    enum CodingKeys: String, CodingKey {
        case stableID, id, sourceID, sourceStart, sourceEnd, text, style, origin, manuallyEdited
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? c.decodeIfPresent(UUID.self, forKey: .stableID))
            ?? (try? c.decodeIfPresent(UUID.self, forKey: .id))
            ?? UUID()
        let decodedSourceID = (try? c.decodeIfPresent(Int.self, forKey: .sourceID)) ?? 0
        let rawStart = (try? c.decodeIfPresent(Double.self, forKey: .sourceStart)) ?? 0.0
        let rawEnd = (try? c.decodeIfPresent(Double.self, forKey: .sourceEnd)) ?? 0.0
        let decodedText = (try? c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        let decodedStyle = (try? c.decodeIfPresent(TrailerCaption.self, forKey: .style)) ?? TrailerCaption()
        let decodedOrigin = (try? c.decodeIfPresent(Origin.self, forKey: .origin)) ?? .manual
        let decodedEdited = (try? c.decodeIfPresent(Bool.self, forKey: .manuallyEdited)) ?? false

        self.init(
            stableID: decodedID,
            sourceID: decodedSourceID,
            sourceStart: rawStart,
            sourceEnd: rawEnd,
            text: decodedText,
            style: decodedStyle,
            origin: decodedOrigin,
            manuallyEdited: decodedEdited
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(sourceID, forKey: .sourceID)
        try container.encode(sourceStart, forKey: .sourceStart)
        try container.encode(sourceEnd, forKey: .sourceEnd)
        try container.encode(text, forKey: .text)
        try container.encode(style, forKey: .style)
        try container.encode(origin, forKey: .origin)
        try container.encode(manuallyEdited, forKey: .manuallyEdited)
    }

    /// Merges existing cues with newly generated cues.
    /// - Reuses matching existing generated IDs by source/time identity.
    /// - Manual-owned edited cues persist and block overlapping generated candidates.
    /// - Suppressions block generated cues in their range (manual cues remain exempt).
    /// - Returns a deterministic, sorted, deduplicated cue list.
    static func merge(
        existingCues: [TrailerTimedCaptionCue],
        newGeneratedCues: [TrailerTimedCaptionCue],
        suppressions: [TrailerCueSuppression] = []
    ) -> [TrailerTimedCaptionCue] {
        var manualCues: [TrailerTimedCaptionCue] = []
        var existingGeneratedCues: [TrailerTimedCaptionCue] = []

        for cue in existingCues {
            if cue.origin == .manual || cue.manuallyEdited {
                var preserved = cue
                preserved.origin = .manual
                preserved.manuallyEdited = true
                manualCues.append(preserved)
            } else {
                existingGeneratedCues.append(cue)
            }
        }

        var acceptedGeneratedCues: [TrailerTimedCaptionCue] = []

        for candidate in newGeneratedCues {
            let cStart = candidate.sourceStart
            let cEnd = candidate.sourceEnd
            guard cEnd > cStart else { continue }

            // Suppressions block generated cues only
            let isSuppressed = suppressions.contains { sup in
                sup.overlaps(sourceID: candidate.sourceID, start: cStart, end: cEnd)
            }
            if isSuppressed { continue }

            // Manual-owned cues block overlapping generated candidates
            let overlapsManual = manualCues.contains { manual in
                manual.sourceID == candidate.sourceID &&
                    max(manual.sourceStart, cStart) < min(manual.sourceEnd, cEnd)
            }
            if overlapsManual { continue }

            // Reuse matching existing generated ID by source/time identity (within 0.1s tolerance)
            var matchedID = candidate.stableID
            if let matchingExisting = existingGeneratedCues.first(where: { existing in
                existing.sourceID == candidate.sourceID &&
                    abs(existing.sourceStart - cStart) < 0.1 &&
                    abs(existing.sourceEnd - cEnd) < 0.1
            }) {
                matchedID = matchingExisting.stableID
            }

            var finalCue = candidate
            finalCue.stableID = matchedID
            finalCue.origin = .generated
            finalCue.manuallyEdited = false
            acceptedGeneratedCues.append(finalCue)
        }

        var combined = manualCues + acceptedGeneratedCues

        // Strict deterministic sorting: exact numeric time order then UUID (never tolerance comparisons)
        combined.sort { lhs, rhs in
            if lhs.sourceID != rhs.sourceID {
                return lhs.sourceID < rhs.sourceID
            }
            if lhs.sourceStart != rhs.sourceStart {
                return lhs.sourceStart < rhs.sourceStart
            }
            if lhs.sourceEnd != rhs.sourceEnd {
                return lhs.sourceEnd < rhs.sourceEnd
            }
            return lhs.stableID.uuidString < rhs.stableID.uuidString
        }

        // Deduplicate identical IDs
        var deduplicated: [TrailerTimedCaptionCue] = []
        var seenIDs = Set<UUID>()
        for cue in combined {
            if !seenIDs.contains(cue.stableID) {
                seenIDs.insert(cue.stableID)
                deduplicated.append(cue)
            }
        }
        return deduplicated
    }
}

// MARK: - Cue Suppression Tombstone

/// Tombstone indicating an auto-deleted cue range that should stay deleted during regeneration.
struct TrailerCueSuppression: Identifiable, Codable, Equatable, Sendable {
    var id: String { "\(sourceID):\(sourceStart)-\(sourceEnd)" }
    var sourceID: Int
    var sourceStart: Double
    var sourceEnd: Double

    init(sourceID: Int, sourceStart: Double, sourceEnd: Double) {
        self.sourceID = sourceID
        let start = sourceStart.isFinite ? max(0.0, sourceStart) : 0.0
        let end = sourceEnd.isFinite ? max(start, sourceEnd) : start
        self.sourceStart = start
        self.sourceEnd = end
    }

    enum CodingKeys: String, CodingKey {
        case sourceID, sourceStart, sourceEnd
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let sID = (try? c.decodeIfPresent(Int.self, forKey: .sourceID)) ?? 0
        let start = (try? c.decodeIfPresent(Double.self, forKey: .sourceStart)) ?? 0.0
        let end = (try? c.decodeIfPresent(Double.self, forKey: .sourceEnd)) ?? 0.0
        self.init(sourceID: sID, sourceStart: start, sourceEnd: end)
    }

    func overlaps(sourceID: Int, start: Double, end: Double) -> Bool {
        guard self.sourceID == sourceID else { return false }
        let s = start.isFinite ? max(0.0, start) : 0.0
        let e = end.isFinite ? max(s, end) : s
        return max(self.sourceStart, s) < min(self.sourceEnd, e)
    }
}

// MARK: - Voiceover Take

/// Voiceover audio track take for a trailer project.
struct TrailerVoiceoverTake: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { stableID }
    var stableID: UUID
    var relativeFile: String
    var outputStart: Double
    var sourceIn: Double
    var sourceOut: Double
    var volume: Double

    /// Effective timeline placement intersected with project duration.
    struct EffectivePlacement: Equatable, Sendable {
        var outputStart: Double
        var outputDuration: Double
        var sourceIn: Double
        var sourceOut: Double
        var volume: Double

        init(
            outputStart: Double,
            outputDuration: Double,
            sourceIn: Double,
            sourceOut: Double,
            volume: Double
        ) {
            self.outputStart = outputStart
            self.outputDuration = outputDuration
            self.sourceIn = sourceIn
            self.sourceOut = sourceOut
            self.volume = volume
        }
    }

    static func isValidRelativeFilePath(_ path: String) -> Bool {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        guard !trimmed.hasPrefix("/") else { return false }
        let components = trimmed.components(separatedBy: "/")
        for component in components {
            if component == ".." || component == "." {
                return false
            }
        }
        return true
    }

    init(
        stableID: UUID = UUID(),
        relativeFile: String,
        outputStart: Double = 0.0,
        sourceIn: Double = 0.0,
        sourceOut: Double = 0.0,
        volume: Double = 1.0
    ) {
        self.stableID = stableID
        self.relativeFile = Self.isValidRelativeFilePath(relativeFile) ? relativeFile : ""
        self.outputStart = outputStart.isFinite ? max(0.0, outputStart) : 0.0
        let sIn = sourceIn.isFinite ? max(0.0, sourceIn) : 0.0
        let sOut = sourceOut.isFinite ? max(sIn, sourceOut) : sIn
        self.sourceIn = sIn
        self.sourceOut = sOut
        let vol = volume.isFinite ? min(2.0, max(0.0, volume)) : 1.0
        self.volume = vol
    }

    enum CodingKeys: String, CodingKey {
        case stableID, id, relativeFile, outputStart, sourceIn, sourceOut, volume
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? c.decodeIfPresent(UUID.self, forKey: .stableID))
            ?? (try? c.decodeIfPresent(UUID.self, forKey: .id))
            ?? UUID()
        let relFile = (try? c.decodeIfPresent(String.self, forKey: .relativeFile)) ?? ""
        let outStart = (try? c.decodeIfPresent(Double.self, forKey: .outputStart)) ?? 0.0
        let sIn = (try? c.decodeIfPresent(Double.self, forKey: .sourceIn)) ?? 0.0
        let sOut = (try? c.decodeIfPresent(Double.self, forKey: .sourceOut)) ?? 0.0
        let vol = (try? c.decodeIfPresent(Double.self, forKey: .volume)) ?? 1.0
        self.init(
            stableID: decodedID,
            relativeFile: relFile,
            outputStart: outStart,
            sourceIn: sIn,
            sourceOut: sOut,
            volume: vol
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(relativeFile, forKey: .relativeFile)
        try container.encode(outputStart, forKey: .outputStart)
        try container.encode(sourceIn, forKey: .sourceIn)
        try container.encode(sourceOut, forKey: .sourceOut)
        try container.encode(volume, forKey: .volume)
    }

    /// Hard timeline range required by this voiceover take before any project duration clipping.
    /// Returns nil if relativeFile is invalid or if source range is empty/invalid.
    /// Never quietly hides manual tail.
    var hardOutputRange: Range<Double>? {
        guard Self.isValidRelativeFilePath(relativeFile) else { return nil }
        guard outputStart.isFinite && outputStart >= 0.0 else { return nil }
        guard sourceIn.isFinite && sourceOut.isFinite && sourceOut > sourceIn else { return nil }
        let duration = sourceOut - sourceIn
        let end = outputStart + duration
        guard end.isFinite else { return nil }
        return outputStart..<end
    }

    /// Hard required output end timestamp on the timeline before project duration clipping.
    /// Returns nil if relativeFile is invalid or source range is invalid.
    var requiredOutputEnd: Double? {
        hardOutputRange?.upperBound
    }

    /// Computes effective intersected placement with project duration WITHOUT mutating stored take.
    ///
    /// NOTE: Callers budgeting or extending the timeline must extend the project duration
    /// to at least `requiredOutputEnd` (or the hard end of `hardOutputRange`) unless the user has
    /// explicitly trimmed or overridden the duration, so that manual voiceover tails are never quietly truncated.
    func effectivePlacement(projectDuration: Double) -> EffectivePlacement? {
        guard Self.isValidRelativeFilePath(relativeFile) else { return nil }
        guard projectDuration.isFinite && projectDuration > 0.0 else { return nil }
        guard sourceIn.isFinite && sourceOut.isFinite && sourceOut > sourceIn else { return nil }
        let takeDuration = sourceOut - sourceIn
        let takeOutputEnd = outputStart + takeDuration
        guard takeOutputEnd.isFinite else { return nil }

        guard outputStart < projectDuration && takeOutputEnd > 0.0 else { return nil }

        let effectiveStart = max(0.0, outputStart)
        let offsetFromTakeStart = effectiveStart - outputStart
        let effectiveSourceIn = sourceIn + offsetFromTakeStart

        let effectiveEnd = min(projectDuration, takeOutputEnd)
        let effectiveDuration = max(0.0, effectiveEnd - effectiveStart)
        guard effectiveDuration > 0.0001 else { return nil }
        let effectiveSourceOut = effectiveSourceIn + effectiveDuration

        return EffectivePlacement(
            outputStart: effectiveStart,
            outputDuration: effectiveDuration,
            sourceIn: effectiveSourceIn,
            sourceOut: effectiveSourceOut,
            volume: volume
        )
    }
}

// MARK: - Color Adjustment

/// Color adjustments for brightness, contrast, and saturation.
struct TrailerColorAdjustment: Codable, Equatable, Sendable {
    var brightness: Double // neutral 0.0, clamp [-1.0, 1.0]
    var contrast: Double   // neutral 1.0, clamp [0.25, 4.0]
    var saturation: Double // neutral 1.0, clamp [0.0, 3.0]

    static let neutral = TrailerColorAdjustment()

    var isNeutral: Bool {
        abs(brightness) < 0.0001 && abs(contrast - 1.0) < 0.0001 && abs(saturation - 1.0) < 0.0001
    }

    init(
        brightness: Double = 0.0,
        contrast: Double = 1.0,
        saturation: Double = 1.0
    ) {
        let b = brightness.isFinite ? min(1.0, max(-1.0, brightness)) : 0.0
        let c = contrast.isFinite ? min(4.0, max(0.25, contrast)) : 1.0
        let s = saturation.isFinite ? min(3.0, max(0.0, saturation)) : 1.0
        self.brightness = b
        self.contrast = c
        self.saturation = s
    }

    enum CodingKeys: String, CodingKey {
        case brightness, contrast, saturation
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let b = (try? container.decodeIfPresent(Double.self, forKey: .brightness)) ?? 0.0
        let c = (try? container.decodeIfPresent(Double.self, forKey: .contrast)) ?? 1.0
        let s = (try? container.decodeIfPresent(Double.self, forKey: .saturation)) ?? 1.0
        self.init(brightness: b, contrast: c, saturation: s)
    }
}

// MARK: - Framing & Opacity Keyframes

/// Keyframe for source-time spatial framing (offset, scale) and opacity.
struct TrailerTransformKeyframe: Identifiable, Codable, Equatable, Sendable {
    var id: UUID { stableID }
    var stableID: UUID
    var sourceTime: Double
    var offsetX: Double // normalized [-1.0, 1.0]
    var offsetY: Double // normalized [-1.0, 1.0]
    var scale: Double   // positive default 1.0, bounded [0.1, 10.0]
    var opacity: Double // [0.0, 1.0]

    struct InterpolatedTransform: Equatable, Sendable {
        var offsetX: Double
        var offsetY: Double
        var scale: Double
        var opacity: Double

        static let identity = InterpolatedTransform(offsetX: 0.0, offsetY: 0.0, scale: 1.0, opacity: 1.0)

        init(offsetX: Double, offsetY: Double, scale: Double, opacity: Double) {
            self.offsetX = offsetX
            self.offsetY = offsetY
            self.scale = scale
            self.opacity = opacity
        }
    }

    init(
        stableID: UUID = UUID(),
        sourceTime: Double,
        offsetX: Double = 0.0,
        offsetY: Double = 0.0,
        scale: Double = 1.0,
        opacity: Double = 1.0
    ) {
        self.stableID = stableID
        self.sourceTime = sourceTime.isFinite ? max(0.0, sourceTime) : 0.0
        self.offsetX = offsetX.isFinite ? min(1.0, max(-1.0, offsetX)) : 0.0
        self.offsetY = offsetY.isFinite ? min(1.0, max(-1.0, offsetY)) : 0.0
        self.scale = scale.isFinite ? min(10.0, max(0.1, scale)) : 1.0
        self.opacity = opacity.isFinite ? min(1.0, max(0.0, opacity)) : 1.0
    }

    enum CodingKeys: String, CodingKey {
        case stableID, id, sourceTime, offsetX, offsetY, scale, opacity
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedID = (try? c.decodeIfPresent(UUID.self, forKey: .stableID))
            ?? (try? c.decodeIfPresent(UUID.self, forKey: .id))
            ?? UUID()
        let sTime = (try? c.decodeIfPresent(Double.self, forKey: .sourceTime)) ?? 0.0
        let offX = (try? c.decodeIfPresent(Double.self, forKey: .offsetX)) ?? 0.0
        let offY = (try? c.decodeIfPresent(Double.self, forKey: .offsetY)) ?? 0.0
        let sc = (try? c.decodeIfPresent(Double.self, forKey: .scale)) ?? 1.0
        let op = (try? c.decodeIfPresent(Double.self, forKey: .opacity)) ?? 1.0
        self.init(
            stableID: decodedID,
            sourceTime: sTime,
            offsetX: offX,
            offsetY: offY,
            scale: sc,
            opacity: op
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stableID, forKey: .stableID)
        try container.encode(sourceTime, forKey: .sourceTime)
        try container.encode(offsetX, forKey: .offsetX)
        try container.encode(offsetY, forKey: .offsetY)
        try container.encode(scale, forKey: .scale)
        try container.encode(opacity, forKey: .opacity)
    }

    /// Sorts keyframes deterministically by sourceTime then UUID.
    /// Deduplicates exact equal timestamps for render interpolation without mutating stored keyframes.
    static func sanitizeAndSort(_ keyframes: [TrailerTransformKeyframe]) -> [TrailerTransformKeyframe] {
        var sorted = keyframes
        sorted.sort { lhs, rhs in
            if lhs.sourceTime != rhs.sourceTime {
                return lhs.sourceTime < rhs.sourceTime
            }
            return lhs.stableID.uuidString < rhs.stableID.uuidString
        }
        var result: [TrailerTransformKeyframe] = []
        for kf in sorted {
            if let last = result.last, last.sourceTime == kf.sourceTime {
                continue
            }
            result.append(kf)
        }
        return result
    }

    /// Common linear interpolation between keyframes with endpoint clamping. Returns identity if keyframes empty.
    static func interpolate(keyframes: [TrailerTransformKeyframe], at sourceTime: Double) -> InterpolatedTransform {
        guard !keyframes.isEmpty else { return .identity }
        let sorted = sanitizeAndSort(keyframes)
        guard !sorted.isEmpty else { return .identity }
        if sorted.count == 1 || sourceTime <= sorted.first!.sourceTime {
            let first = sorted.first!
            return InterpolatedTransform(offsetX: first.offsetX, offsetY: first.offsetY, scale: first.scale, opacity: first.opacity)
        }
        if sourceTime >= sorted.last!.sourceTime {
            let last = sorted.last!
            return InterpolatedTransform(offsetX: last.offsetX, offsetY: last.offsetY, scale: last.scale, opacity: last.opacity)
        }
        for i in 0 ..< sorted.count - 1 {
            let k0 = sorted[i]
            let k1 = sorted[i + 1]
            if sourceTime >= k0.sourceTime && sourceTime <= k1.sourceTime {
                let span = k1.sourceTime - k0.sourceTime
                guard span > 0.00001 else {
                    return InterpolatedTransform(offsetX: k0.offsetX, offsetY: k0.offsetY, scale: k0.scale, opacity: k0.opacity)
                }
                let t = (sourceTime - k0.sourceTime) / span
                let ox = k0.offsetX + t * (k1.offsetX - k0.offsetX)
                let oy = k0.offsetY + t * (k1.offsetY - k0.offsetY)
                let sc = k0.scale + t * (k1.scale - k0.scale)
                let op = k0.opacity + t * (k1.opacity - k0.opacity)
                return InterpolatedTransform(offsetX: ox, offsetY: oy, scale: sc, opacity: op)
            }
        }
        return .identity
    }
}

// MARK: - Transitions

/// Transition configuration for clip boundaries.
struct TrailerTransition: Codable, Equatable, Sendable {
    var dissolveDuration: Double // default 0.0 (cut)

    static let cut = TrailerTransition(dissolveDuration: 0.0)

    init(dissolveDuration: Double = 0.0) {
        self.dissolveDuration = dissolveDuration.isFinite ? max(0.0, dissolveDuration) : 0.0
    }

    enum CodingKeys: String, CodingKey {
        case dissolveDuration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let duration = (try? c.decodeIfPresent(Double.self, forKey: .dissolveDuration)) ?? 0.0
        self.init(dissolveDuration: duration)
    }
}

// MARK: - Clip Adjustments Bundle

/// Stored adjustments for an individual clip.
/// Note: Keyframe presence (keyframes.isEmpty == false) disables auto framing for this clip at integration.
/// Does not mutate raw sourceStart/length or manual protection fields.
struct TrailerClipAdjustments: Codable, Equatable, Sendable {
    var rate: Double
    var color: TrailerColorAdjustment?
    var keyframes: [TrailerTransformKeyframe]
    var transition: TrailerTransition?
    var cues: [TrailerTimedCaptionCue]
    var suppressions: [TrailerCueSuppression]

    init(
        rate: Double = 1.0,
        color: TrailerColorAdjustment? = nil,
        keyframes: [TrailerTransformKeyframe] = [],
        transition: TrailerTransition? = nil,
        cues: [TrailerTimedCaptionCue] = [],
        suppressions: [TrailerCueSuppression] = []
    ) {
        let safeRate = (rate.isFinite && rate >= 0.25 && rate <= 4.0) ? rate : 1.0
        self.rate = safeRate
        self.color = color
        self.keyframes = keyframes
        self.transition = transition
        self.cues = cues
        self.suppressions = suppressions
    }

    enum CodingKeys: String, CodingKey {
        case rate, color, keyframes, transition, cues, suppressions
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let r = (try? container.decodeIfPresent(Double.self, forKey: .rate)) ?? 1.0
        let safeRate = (r.isFinite && r >= 0.25 && r <= 4.0) ? r : 1.0
        self.rate = safeRate
        self.color = try? container.decodeIfPresent(TrailerColorAdjustment.self, forKey: .color)
        self.keyframes = (try? container.decodeIfPresent([TrailerTransformKeyframe].self, forKey: .keyframes)) ?? []
        self.transition = try? container.decodeIfPresent(TrailerTransition.self, forKey: .transition)
        self.cues = (try? container.decodeIfPresent([TrailerTimedCaptionCue].self, forKey: .cues)) ?? []
        self.suppressions = (try? container.decodeIfPresent([TrailerCueSuppression].self, forKey: .suppressions)) ?? []
    }

    /// Source time ranges of manual cues (origin == .manual OR manuallyEdited == true) in this clip,
    /// without clipping them to current trim or modifying stored values.
    /// Callers must preserve their inclusion intent when budgeting or determining clip duration.
    var manualCueSourceRanges: [Range<Double>] {
        cues.compactMap { cue in
            guard cue.origin == .manual || cue.manuallyEdited else { return nil }
            guard cue.sourceEnd > cue.sourceStart else { return nil }
            return cue.sourceStart..<cue.sourceEnd
        }
    }

    /// All requested keyframe source timestamps, strictly in source time order,
    /// without clipping them to current trim or modifying stored values.
    var requestedKeyframeSourceTimes: [Double] {
        keyframes.map(\.sourceTime).sorted()
    }

    /// The source time envelope spanning from the earliest to latest requested keyframe,
    /// or nil if no keyframes exist.
    /// Without clipping to current trim or modifying stored values.
    var keyframeSourceEnvelope: ClosedRange<Double>? {
        guard let first = keyframes.min(by: { $0.sourceTime < $1.sourceTime })?.sourceTime,
              let last = keyframes.max(by: { $0.sourceTime < $1.sourceTime })?.sourceTime else {
            return nil
        }
        return first...last
    }
}

// MARK: - Timeline Clip Mapping

/// Derived timeline mapping for a clip. Not stored persistently; built from canonical clip parameters.
struct TrailerClipTimeMapping: Codable, Equatable, Sendable {
    var sceneID: Int
    var sourceID: Int
    var sourceStart: Double
    var sourceLength: Double
    var rate: Double
    var outputStart: Double
    var outputDuration: Double
    var incomingOverlap: Double
    var outgoingOverlap: Double

    init(
        sceneID: Int,
        sourceID: Int,
        sourceStart: Double,
        sourceLength: Double,
        rate: Double,
        outputStart: Double,
        outputDuration: Double,
        incomingOverlap: Double = 0.0,
        outgoingOverlap: Double = 0.0
    ) {
        self.sceneID = sceneID
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceLength = sourceLength
        self.rate = rate
        self.outputStart = outputStart
        self.outputDuration = outputDuration
        self.incomingOverlap = incomingOverlap
        self.outgoingOverlap = outgoingOverlap
    }

    func outputTime(forSourceTime sourceTime: Double) -> Double {
        outputStart + (sourceTime - sourceStart) / rate
    }

    func sourceTime(forOutputTime outputTime: Double) -> Double {
        sourceStart + (outputTime - outputStart) * rate
    }

    /// Maps and clips a caption cue to this clip's current playback boundaries for rendering.
    ///
    /// NOTE: This method is rendering-only and clips cues to the currently budgeted source start and length.
    /// Callers budgeting timeline clips must first inspect `manualCueSourceRanges` (and keyframe envelopes)
    /// to inform automatic trim and length calculations so that user-authored cues are not inadvertently clipped.
    func mapAndClipCue(_ cue: TrailerTimedCaptionCue) -> (outputStart: Double, outputEnd: Double)? {
        guard cue.sourceID == self.sourceID else { return nil }
        let effStart = max(cue.sourceStart, self.sourceStart)
        let effEnd = min(cue.sourceEnd, self.sourceStart + self.sourceLength)
        guard effEnd > effStart else { return nil }
        return (outputTime(forSourceTime: effStart), outputTime(forSourceTime: effEnd))
    }
}

// MARK: - Global Timeline Mapping Factory

/// Concrete input parameters for building timeline mappings.
struct TrailerClipInput: Equatable, Sendable {
    var sceneID: Int
    var sourceID: Int
    var sourceStart: Double
    var sourceLength: Double
    var rate: Double
    var requestedOutgoingOverlap: Double

    init(
        sceneID: Int,
        sourceID: Int,
        sourceStart: Double,
        sourceLength: Double,
        rate: Double = 1.0,
        requestedOutgoingOverlap: Double = 0.0
    ) {
        self.sceneID = sceneID
        self.sourceID = sourceID
        self.sourceStart = sourceStart
        self.sourceLength = sourceLength
        self.rate = rate
        self.requestedOutgoingOverlap = requestedOutgoingOverlap
    }
}

/// Errors raised when building timeline mappings.
enum TrailerTimeMappingError: Error, LocalizedError, Equatable, Sendable {
    case emptyClips
    case invalidSourceRange(sceneID: Int, sourceStart: Double, sourceLength: Double)
    case nonFiniteInput(sceneID: Int, description: String)

    var errorDescription: String? {
        switch self {
        case .emptyClips:
            return "Cannot build timeline mappings from an empty clips list."
        case let .invalidSourceRange(sceneID, start, len):
            return "Invalid source range for sceneID \(sceneID): start=\(start), length=\(len). Length must be positive."
        case let .nonFiniteInput(sceneID, desc):
            return "Non-finite input parameter in sceneID \(sceneID): \(desc)."
        }
    }
}

/// Factory constructing global derived timeline mappings with overlap clamping.
enum TrailerClipTimeMappingFactory {
    /// Builds concrete derived timeline mappings for sequential clips.
    /// Clamps requested overlaps to prevent triple-overlap (incoming + outgoing <= duration)
    /// and adjacent duration limits (0 <= o_i < min(d_i, d_(i+1))).
    /// Uses O_0 = 0, O_(i+1) = O_i + d_i - o_i.
    static func buildTimelineMappings(
        clips: [TrailerClipInput]
    ) throws -> [TrailerClipTimeMapping] {
        guard !clips.isEmpty else {
            throw TrailerTimeMappingError.emptyClips
        }

        struct ValidatedClip {
            let input: TrailerClipInput
            let safeRate: Double
            let outputDuration: Double
        }

        var validated: [ValidatedClip] = []
        validated.reserveCapacity(clips.count)

        for clip in clips {
            guard clip.sourceStart.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: clip.sceneID, description: "sourceStart is non-finite")
            }
            guard clip.sourceLength.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: clip.sceneID, description: "sourceLength is non-finite")
            }
            guard clip.rate.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: clip.sceneID, description: "rate is non-finite")
            }
            guard clip.requestedOutgoingOverlap.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: clip.sceneID, description: "requestedOutgoingOverlap is non-finite")
            }
            guard clip.sourceStart >= 0.0 && clip.sourceLength > 0.0001 else {
                throw TrailerTimeMappingError.invalidSourceRange(
                    sceneID: clip.sceneID,
                    sourceStart: clip.sourceStart,
                    sourceLength: clip.sourceLength
                )
            }
            let safeRate = (clip.rate >= 0.25 && clip.rate <= 4.0) ? clip.rate : 1.0
            let outputDuration = clip.sourceLength / safeRate
            guard outputDuration.isFinite && outputDuration > 0.0 else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: clip.sceneID, description: "outputDuration is non-finite or overflowed")
            }
            validated.append(ValidatedClip(input: clip, safeRate: safeRate, outputDuration: outputDuration))
        }

        var effectiveOverlaps: [Double] = Array(repeating: 0.0, count: max(0, validated.count - 1))

        for i in 0 ..< effectiveOverlaps.count {
            let dCurr = validated[i].outputDuration
            let dNext = validated[i + 1].outputDuration
            let incomingCurr = (i > 0) ? effectiveOverlaps[i - 1] : 0.0

            let rawOverlap = validated[i].input.requestedOutgoingOverlap
            let safeRawOverlap = (rawOverlap > 0.0) ? rawOverlap : 0.0

            // Clamping rules:
            // 1. incoming + outgoing <= d_curr (no triple-overlap)
            // 2. outgoing < min(d_curr, d_next)
            let maxAllowedByCurrent = max(0.0, dCurr - incomingCurr)
            let maxAdjacentLimit = max(0.0, min(dCurr, dNext) - 0.001)
            let clamped = min(safeRawOverlap, maxAllowedByCurrent, maxAdjacentLimit)
            guard clamped.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: validated[i].input.sceneID, description: "clamped overlap is non-finite")
            }
            effectiveOverlaps[i] = clamped
        }

        var mappings: [TrailerClipTimeMapping] = []
        mappings.reserveCapacity(validated.count)

        var currentOutputStart = 0.0
        for i in 0 ..< validated.count {
            let v = validated[i]
            let incoming = (i > 0) ? effectiveOverlaps[i - 1] : 0.0
            let outgoing = (i < effectiveOverlaps.count) ? effectiveOverlaps[i] : 0.0

            guard currentOutputStart.isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: v.input.sceneID, description: "outputStart is non-finite")
            }

            let mapping = TrailerClipTimeMapping(
                sceneID: v.input.sceneID,
                sourceID: v.input.sourceID,
                sourceStart: v.input.sourceStart,
                sourceLength: v.input.sourceLength,
                rate: v.safeRate,
                outputStart: currentOutputStart,
                outputDuration: v.outputDuration,
                incomingOverlap: incoming,
                outgoingOverlap: outgoing
            )
            mappings.append(mapping)
            let advance = v.outputDuration - outgoing
            guard advance.isFinite && (currentOutputStart + advance).isFinite else {
                throw TrailerTimeMappingError.nonFiniteInput(sceneID: v.input.sceneID, description: "outputStart arithmetic overflow")
            }
            currentOutputStart += advance
        }

        return mappings
    }
}
