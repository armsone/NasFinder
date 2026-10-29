import CoreImage
import Foundation
import ImageIO
import Vision

/// On-device, bounded-memory photo quality and similarity analysis that decides each
/// photo's own scene duration for the trailer: the formulas mirror HanAI/HanClip's own
/// verified photo-quality picker (sharpness/exposure/resolution, optional iOS18 Vision
/// aesthetics) and similarity grouping (16×16 aligned luminance fingerprint), reused here
/// rather than re-derived. Never touches the network, and a photo that fails to decode is
/// given a neutral middle duration instead of a invented score.
enum VideoTrailerPhotoQuality {
    struct Measurement {
        let qualityScore: Double
        let fingerprint: [UInt8]
        let aspectRatio: Double
        let sharpnessScore: Double
        let exposureScore: Double
        /// 원본 해상도(가로×세로). 사진 선별의 해상도 항에 쓴다.
        var pixelCount: Int = 0
        /// Vision 미적 점수 원값(-1...1). 없으면 nil. 사진 선별은 (raw+1)/2로 0...1로 바꿔 쓴다.
        var rawAestheticsScore: Double? = nil
    }

    /// Photos look alike enough to shorten the later one's own scene, within [0, 1]: 0 at
    /// the similarity threshold itself, 1 for a near-exact duplicate.
    private static let ordinaryMinimumRatio = 0.10
    private static let ordinaryMaximumRatio = 0.95
    /// A near-duplicate's floor: short enough to read as a flash, never zero.
    private static let extremeDuplicateFloorRatio = 0.01
    private static let neutralRatio = 0.55
    private static let analysisMaxPixelSize: CGFloat = 768

    /// V1 정책(0.35...0.75)의 비율을 V2 정책(0.10...0.95)으로 1회 마이그레이션한다.
    static func migrateV1ToV2Ratio(_ r: Double) -> Double {
        guard r.isFinite, r > 0 else { return neutralRatio }
        if r < 0.35 {
            return max(0.01, r * (0.10 / 0.35))
        } else {
            let clamped = min(0.75, max(0.35, r))
            return 0.10 + (clamped - 0.35) * (0.85 / 0.40)
        }
    }

    /// nil only when the photo could not be decoded at all.
    static func measure(fileAt url: URL, maxPixelSize: CGFloat = analysisMaxPixelSize, includeAesthetics: Bool = true) async -> Measurement? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let pixelCount = originalPixelCount(source)
        guard pixelCount > 0 else { return nil }
        return await measure(cgImage: cgImage, originalPixelCount: pixelCount, includeAesthetics: includeAesthetics)
    }

    /// 이미 디코드한 축소 이미지로 같은 지표를 계산한다. `originalPixelCount`는 원본 해상도(가로×세로)다.
    static func measure(cgImage: CGImage, originalPixelCount pixelCount: Int, includeAesthetics: Bool = true) async -> Measurement? {
        guard pixelCount > 0 else { return nil }
        let ciImage = CIImage(cgImage: cgImage)
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let sharpness = sharpnessScore(for: ciImage, context: context)
        let exposure = exposureScore(for: ciImage, context: context)
        let aesthetics: Double?
        if includeAesthetics { aesthetics = await aestheticsScore(for: cgImage) }
        else { aesthetics = nil }
        let base = sharpness * 0.4 + exposure * 0.2 + log(Double(pixelCount)) / 100
        let quality = aesthetics.map { base * 0.4 + $0 * 0.6 } ?? base
        let aspectRatio = Double(cgImage.width) / Double(max(1, cgImage.height))
        return Measurement(qualityScore: quality, fingerprint: PhotoFingerprint.make(from: cgImage), aspectRatio: aspectRatio,
            sharpnessScore: sharpness, exposureScore: exposure, pixelCount: pixelCount, rawAestheticsScore: aesthetics)
    }

    /// 사진 선별용: 두 측정이 "비슷한 장면"인지 0...1 근접도로 돌려준다. 기존 가로세로비·지문 통과 조건을 그대로 쓰고,
    /// 하나라도 넘기면 nil(비슷하지 않음). 1에 가까울수록 거의 같은 사진이다.
    static func closeness(_ lhs: Measurement, _ rhs: Measurement) -> Double? {
        guard abs(lhs.aspectRatio - rhs.aspectRatio) <= 0.06 else { return nil }
        return PhotoFingerprint.similarityCloseness(lhs.fingerprint, rhs.fingerprint)
    }

    /// 지문의 평균 휘도(0...255). 비슷한 후보만 비교하도록 정렬 창을 만들 때 쓴다.
    static func meanLuminance(of measurement: Measurement) -> Double {
        guard !measurement.fingerprint.isEmpty else { return 0 }
        return measurement.fingerprint.reduce(0.0) { $0 + Double($1) } / Double(measurement.fingerprint.count)
    }

    /// The scene-duration ratio (fraction of the configured clip length) for every photo
    /// supplied, keyed by its source id. A photo whose measurement is `nil` (decode
    /// failure) gets the neutral middle of the ordinary range, never a fabricated score.
    /// The best-quality photo in each group of alike photos keeps its full quality-ranked
    /// ratio; the more the others resemble it, the shorter their own ratio becomes, down
    /// to a short, still-visible floor for near-exact duplicates.
    ///
    /// `dinoEmbeddings`, when supplied, adds an AND condition on top of the existing
    /// fingerprint similarity check: a pair only counts as alike when it already passes
    /// the fingerprint thresholds below AND its DINO cosine distance is within
    /// `VideoTrailerPhotoSimilarityGate.maximumCosineDistance`. `nil` keeps this exactly
    /// as it already behaves with the fingerprint check alone.
    static func durationRatios(
        for items: [(id: Int, measurement: Measurement?)],
        dinoEmbeddings: [Int: [Float]]? = nil
    ) -> [Int: Double] {
        guard !items.isEmpty else { return [:] }
        let effectiveDinoEmbeddings = Self.validatedEmbeddings(dinoEmbeddings, for: items)
        var baseRatio: [Int: Double] = [:]
        for item in items where item.measurement == nil {
            baseRatio[item.id] = neutralRatio
        }
        let measuredScoreByID: [Int: Double] = Dictionary(uniqueKeysWithValues: items.compactMap { item in
            item.measurement.map { (item.id, $0.qualityScore) }
        })
        let ranked = measuredScoreByID.sorted { lhs, rhs in
            lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
        }.map(\.key)
        let count = ranked.count

        let sortedScores = measuredScoreByID.values.sorted()
        let median: Double
        if sortedScores.isEmpty {
            median = 0
        } else {
            median = sortedScores[sortedScores.count / 2]
        }

        for (position, id) in ranked.enumerated() {
            let normalized = count > 1 ? Double(count - 1 - position) / Double(count - 1) : 1.0
            var ratio = 0.10 + 0.85 * normalized
            if normalized >= 0.9, let quality = measuredScoreByID[id] {
                let diff = quality - median - 0.15
                if diff > 0 {
                    let bonus = 0.30 * min(1.0, max(0.0, diff / 0.35))
                    ratio += bonus
                }
            }
            baseRatio[id] = ratio
        }
        let fingerprinted = items.compactMap { item -> (id: Int, measurement: Measurement)? in
            guard let measurement = item.measurement else { return nil }
            return (item.id, measurement)
        }
        // For every pair that passes the similarity thresholds, only the lower-ranked
        // (quality) photo of the two is dampened, so the group's representative always
        // keeps its own full quality-ranked weight.
        var closeness: [Int: Double] = [:]
        for lhs in fingerprinted {
            for rhs in fingerprinted where rhs.id != lhs.id {
                guard let lhsBase = baseRatio[lhs.id], let rhsBase = baseRatio[rhs.id] else { continue }
                let rhsIsRepresentative = rhsBase > lhsBase || (rhsBase == lhsBase && rhs.id < lhs.id)
                guard rhsIsRepresentative else { continue }
                guard abs(lhs.measurement.aspectRatio - rhs.measurement.aspectRatio) <= 0.06 else { continue }
                guard let similarity = PhotoFingerprint.similarityCloseness(
                    lhs.measurement.fingerprint, rhs.measurement.fingerprint
                ) else { continue }
                if let effectiveDinoEmbeddings {
                    guard let lhsEmbedding = effectiveDinoEmbeddings[lhs.id], let rhsEmbedding = effectiveDinoEmbeddings[rhs.id],
                          let distance = VideoTrailerPhotoSimilarityGate.cosineDistance(lhsEmbedding, rhsEmbedding),
                          distance <= VideoTrailerPhotoSimilarityGate.maximumCosineDistance
                    else { continue }
                }
                closeness[lhs.id] = max(closeness[lhs.id] ?? 0, similarity)
            }
        }
        var result: [Int: Double] = [:]
        for (id, base) in baseRatio {
            guard let similarity = closeness[id], similarity > 0 else { result[id] = base; continue }
            result[id] = max(extremeDuplicateFloorRatio, base * (1 - similarity))
        }
        return result
    }

    /// Validates the whole supplied map at once — ids unique, keyset an exact match to
    /// `items`, every vector a finite, nonzero-norm 384-dim embedding — rather than
    /// falling back pair-by-pair. Any single invalid or missing entry drops the entire
    /// map back to the existing fingerprint-only behaviour.
    private static func validatedEmbeddings(
        _ dinoEmbeddings: [Int: [Float]]?, for items: [(id: Int, measurement: Measurement?)]
    ) -> [Int: [Float]]? {
        guard let dinoEmbeddings else { return nil }
        let itemIDs = Set(items.map(\.id))
        guard itemIDs.count == items.count else { return nil }
        guard Set(dinoEmbeddings.keys) == itemIDs else { return nil }
        for vector in dinoEmbeddings.values {
            guard vector.count == 384 else { return nil }
            var normSquared: Float = 0
            for value in vector {
                guard value.isFinite else { return nil }
                normSquared += value * value
            }
            guard normSquared.isFinite, normSquared > 0 else { return nil }
        }
        return dinoEmbeddings
    }

    private static func originalPixelCount(_ source: CGImageSource) -> Int {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return 0 }
        return width * height
    }

    private static func sharpnessScore(for image: CIImage, context: CIContext) -> Double {
        let width = Int(image.extent.width)
        let height = Int(image.extent.height)
        guard width > 2, height > 2 else { return 0 }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4,
            bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        func luminance(_ x: Int, _ y: Int) -> Double {
            let offset = (y * width + x) * 4
            return (0.2126 * Double(pixels[offset]) + 0.7152 * Double(pixels[offset + 1])
                + 0.0722 * Double(pixels[offset + 2])) / 255
        }
        var sum = 0.0
        var sumSquares = 0.0
        let count = Double((width - 2) * (height - 2))
        for y in 1..<(height - 1) {
            for x in 1..<(width - 1) {
                let value = luminance(x - 1, y) + luminance(x + 1, y)
                    + luminance(x, y - 1) + luminance(x, y + 1) - 4 * luminance(x, y)
                sum += value
                sumSquares += value * value
            }
        }
        let variance = max(0, sumSquares / count - pow(sum / count, 2))
        return min(1, variance * 20)
    }

    private static func exposureScore(for image: CIImage, context: CIContext) -> Double {
        guard let brightness = averagePixelValue(of: image, context: context) else { return 0.5 }
        return max(0, 1 - abs(brightness - 0.5) * 2)
    }

    private static func averagePixelValue(of image: CIImage, context: CIContext) -> Double? {
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [
            kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: image.extent)
        ]), let output = filter.outputImage else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(output, toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / 3 / 255
    }

    private static func aestheticsScore(for cgImage: CGImage) async -> Double? {
        guard #available(iOS 18.0, *) else { return nil }
        do {
            let request = CalculateImageAestheticsScoresRequest()
            let observation = try await request.perform(on: cgImage, orientation: nil)
            return Double(observation.overallScore)
        } catch {
            return nil
        }
    }
}

/// 16×16 aligned luminance fingerprint and distance metrics, the same shape and
/// thresholds HanClip's own near-duplicate grouping uses. No face-count check: the
/// trailer only ever analyses a staged photo, never a Photos asset.
private enum PhotoFingerprint {
    private static let dimension = 16

    static func make(from cgImage: CGImage) -> [UInt8] {
        let bytesPerPixel = 4
        var rgba = [UInt8](repeating: 0, count: dimension * dimension * bytesPerPixel)
        let didRender = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: dimension, height: dimension,
                bitsPerComponent: 8, bytesPerRow: dimension * bytesPerPixel,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: dimension, height: dimension))
            return true
        }
        guard didRender else { return [] }
        let pixelCount = dimension * dimension
        var luminance: [UInt8] = []
        luminance.reserveCapacity(pixelCount)
        for index in 0..<pixelCount {
            let offset = index * bytesPerPixel
            let value = Double(rgba[offset]) * 0.299 + Double(rgba[offset + 1]) * 0.587 + Double(rgba[offset + 2]) * 0.114
            luminance.append(UInt8(value.rounded()))
        }
        return luminance
    }

    /// nil when the pair does not clear every similarity threshold; otherwise how close
    /// they are within the passing range, from just-over-threshold (near 0) to a
    /// near-exact duplicate (near 1).
    static func similarityCloseness(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double? {
        guard lhs.count == rhs.count, lhs.count == dimension * dimension else { return nil }
        let luminanceDistance = alignedDistance(lhs, rhs)
        guard luminanceDistance <= 28 else { return nil }
        let structureDistance = structureDistance(lhs, rhs)
        guard structureDistance <= 30 else { return nil }
        let meanDifference = abs(mean(lhs) - mean(rhs))
        guard meanDifference <= 28 else { return nil }
        let normalized = (luminanceDistance / 28 + structureDistance / 30 + meanDifference / 28) / 3
        return max(0, min(1, 1 - normalized))
    }

    private static func alignedDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        translatedDistance(lhs, rhs, subtractingMean: false)
    }

    private static func structureDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        translatedDistance(lhs, rhs, subtractingMean: true)
    }

    private static func translatedDistance(_ lhs: [UInt8], _ rhs: [UInt8], subtractingMean: Bool) -> Double {
        let lhsMean = subtractingMean ? mean(lhs) : 0
        let rhsMean = subtractingMean ? mean(rhs) : 0
        var bestDistance = zip(lhs, rhs).reduce(0.0) { partial, values in
            partial + abs((Double(values.0) - lhsMean) - (Double(values.1) - rhsMean))
        } / Double(lhs.count)
        // A two-cell translation at 16×16 absorbs normal hand-held framing movement while
        // the structure threshold still rejects a genuinely changed angle.
        for yOffset in -2...2 {
            for xOffset in -2...2 where xOffset != 0 || yOffset != 0 {
                var total = 0.0
                var comparedPixelCount = 0
                for y in 0..<dimension {
                    for x in 0..<dimension {
                        let shiftedX = x + xOffset
                        let shiftedY = y + yOffset
                        guard shiftedX >= 0, shiftedX < dimension, shiftedY >= 0, shiftedY < dimension else { continue }
                        let lhsValue = Double(lhs[y * dimension + x]) - lhsMean
                        let rhsValue = Double(rhs[shiftedY * dimension + shiftedX]) - rhsMean
                        total += abs(lhsValue - rhsValue)
                        comparedPixelCount += 1
                    }
                }
                if comparedPixelCount > 0 { bestDistance = min(bestDistance, total / Double(comparedPixelCount)) }
            }
        }
        return bestDistance
    }

    private static func mean(_ values: [UInt8]) -> Double {
        values.reduce(0.0) { $0 + Double($1) } / Double(values.count)
    }
}
