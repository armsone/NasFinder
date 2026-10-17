import Foundation

/// An additional AND-gate on top of `VideoTrailerPhotoQuality`'s own aligned-luminance
/// fingerprint similarity check, using HanAI's DINOv2 image embedding. Never decides
/// similarity by itself: a pair must already pass the fingerprint thresholds before this
/// embedding distance is even consulted. Computes nothing beyond the embedding vectors
/// themselves — no caching, logging or persistence of any photo's bytes or features.
enum VideoTrailerPhotoSimilarityGate {
    /// Cosine distance at or below this, on a pair that already passed the fingerprint
    /// gate, counts the pair as the same scene for duration-ratio dampening.
    static let maximumCosineDistance = 0.06911703708590078

    /// nil when either vector is empty, mismatched in length, or either has zero norm.
    static func cosineDistance(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard !lhs.isEmpty, lhs.count == rhs.count else { return nil }
        var dot = 0.0
        var lhsNormSquared = 0.0
        var rhsNormSquared = 0.0
        for index in lhs.indices {
            let l = Double(lhs[index])
            let r = Double(rhs[index])
            dot += l * r
            lhsNormSquared += l * l
            rhsNormSquared += r * r
        }
        guard lhsNormSquared > 0, rhsNormSquared > 0 else { return nil }
        let cosine = dot / (lhsNormSquared.squareRoot() * rhsNormSquared.squareRoot())
        return 1 - max(-1, min(1, cosine))
    }
}

#if canImport(CoreML) && canImport(ImageIO) && canImport(CoreGraphics)
import CoreML
import HanAIApple

@available(iOS 17, macOS 14, macCatalyst 17, *)
extension VideoTrailerPhotoSimilarityGate {
    private static let compiledModelName = "HanAIDino"
    private static let compiledModelExtension = "mlmodelc"
    private static let expectedDimension = 384

    /// One DINOv2 embedding per item, keyed by its source id. Returns nil as a whole
    /// (never a partial map) when the bundled model is missing, or any single photo's
    /// embedding could not be produced — a batch this gate cannot fully vouch for leaves
    /// `VideoTrailerPhotoQuality.durationRatios` to its existing fingerprint-only behaviour.
    static func embeddings(for items: [(id: Int, url: URL)]) async throws -> [Int: [Float]]? {
        guard !items.isEmpty else { return [:] }
        guard let modelURL = Bundle.main.url(forResource: compiledModelName, withExtension: compiledModelExtension) else {
            return nil
        }
        try Task.checkCancellation()
        let handle = Task.detached(priority: .userInitiated) { () throws -> [Int: [Float]]? in
            try computeAll(items: items, modelURL: modelURL)
        }
        return try await withTaskCancellationHandler {
            try await handle.value
        } onCancel: {
            handle.cancel()
        }
    }

    /// Runs entirely off the main actor. One sequential pass: the compiled model loads
    /// once for the whole batch, then every photo is decoded (ImageIO, same bounded-memory
    /// original-size path `DinoImageSource` always uses — never a UI thumbnail), preprocessed
    /// and embedded one at a time, each step checking cancellation before and after.
    private static func computeAll(items: [(id: Int, url: URL)], modelURL: URL) throws -> [Int: [Float]]? {
        guard Set(items.map(\.id)).count == items.count else { return nil }
        try Task.checkCancellation()
        let features: DinoImageFeatures
        do {
            features = try DinoImageFeatures(compiledModelURL: modelURL, computeUnits: .cpuOnly)
        } catch {
            try Task.checkCancellation()
            return nil
        }
        try Task.checkCancellation()

        var result: [Int: [Float]] = [:]
        for item in items {
            try Task.checkCancellation()
            let decoded: DinoImageSource.DecodedImage
            do {
                decoded = try DinoImageSource.decode(contentsOf: item.url)
            } catch {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()

            let normalized: [Float]
            do {
                normalized = try DinoImagePreprocessor.normalizedInput(
                    rgb: decoded.rgb, width: decoded.width, height: decoded.height)
            } catch {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()

            let embedding: [Float]
            do {
                embedding = try features.embedding(preprocessedPixels: normalized)
            } catch {
                try Task.checkCancellation()
                return nil
            }
            try Task.checkCancellation()

            guard embedding.count == expectedDimension else { return nil }
            var normSquared: Float = 0
            for value in embedding {
                guard value.isFinite else { return nil }
                normSquared += value * value
            }
            guard normSquared.isFinite, normSquared > 0 else { return nil }
            result[item.id] = embedding
        }
        try Task.checkCancellation()
        return result
    }
}
#endif
