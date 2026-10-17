import AVFoundation
import CoreGraphics
import CryptoKit
import UIKit
import XCTest
@testable import NasFinder
import HanAIApple

/// 실제 iPhone 기기에서 TM이 미리 복사해 둔 bounded fixture(`manifest.json` +
/// 그 파일들만)로 production 사진/영상 품질·유사도 경로를 그대로 호출해 수치만
/// 모아 `result.json`으로 남긴다. 어떤 사진/영상 경로나 원문도 로그·단언·첨부에
/// 넣지 않는다 — 모든 보고는 id와 수치뿐이다.
final class HanYangDeviceEvaluationTests: XCTestCase {
    private struct ManifestPhoto: Decodable { let id: Int; let file: String }
    private struct ManifestVideo: Decodable { let id: Int; let file: String; let anchorSeconds: Double }
    private struct Manifest: Decodable {
        let schemaVersion: Int
        let photos: [ManifestPhoto]
        let videos: [ManifestVideo]
    }

    private enum EvaluationError: Error, CustomStringConvertible {
        case manifestTooLarge
        case manifestInvalid
        case tooManyItems
        case duplicateOrNegativeID
        case fixtureNameInvalid
        case fixtureNotRegularFile
        case anchorOutOfRange

        var description: String {
            switch self {
            case .manifestTooLarge: return "manifest.json exceeds the 256KB bound"
            case .manifestInvalid: return "manifest.json failed schema validation"
            case .tooManyItems: return "manifest exceeds the maximum of 64 photos / 64 videos"
            case .duplicateOrNegativeID: return "manifest ids must be unique and nonnegative"
            case .fixtureNameInvalid: return "a manifest file entry is not a bare leaf name"
            case .fixtureNotRegularFile: return "a manifest file entry is not an existing regular file under the task root"
            case .anchorOutOfRange: return "a video anchorSeconds value is not finite within [0, duration)"
            }
        }
    }

    private struct PhotoResult: Codable {
        let id: Int
        let measurementStatus: String
        let qualityScore: Double?
        let sharpnessScore: Double?
        let exposureScore: Double?
        let aspectRatio: Double?
        let fingerprint: [UInt8]?
        let oldDurationRatio: Double?
        let newDurationRatio: Double?
        let embeddingDimension: Int
        let embedding: [Float]?
    }

    private struct VideoResult: Codable {
        let id: Int
        let anchorSeconds: Double
        let durationSeconds: Double?
        let baselineSharpness: Double?
        let newSharpness: Double?
        let baselineActualTimeSeconds: Double?
        let newActualTimeSeconds: Double?
        let newTimeStatus: String
        let baselinePixelHash: String?
        let newPixelHash: String?
        let baselineMilliseconds: Double
        let newMilliseconds: Double
        let status: String
    }

    private struct ControlsResult: Codable {
        let singleBadFixtureStatus: String
        let mixedGoodBadFixtureStatus: String
        let cancellationStatus: String
        let modelAvailability: String
    }

    private struct SummaryResult: Codable {
        let photoCount: Int
        let videoCount: Int
        let photoMeasurementFailureCount: Int
        let videoSharpnessIncreasedCount: Int
        let videoSharpnessEqualCount: Int
        let videoSharpnessDecreasedCount: Int
    }

    private struct TimingsResult: Codable {
        let totalEmbeddingGateMilliseconds: Double?
        let photoMeasurementMilliseconds: [String: Double]
        let videoBaselineMilliseconds: [String: Double]
        let videoNewMilliseconds: [String: Double]
    }

    private struct DeviceInfo: Codable {
        let systemVersion: String
        let model: String
        let appVersion: String?
        let appBuild: String?
    }

    private struct Report: Codable {
        let schemaVersion: Int
        let photos: [PhotoResult]
        let videos: [VideoResult]
        let controls: ControlsResult
        let summary: SummaryResult
        let timings: TimingsResult
        let device: DeviceInfo
    }

    private static let taskRootName = "HanYangDeviceEvaluation-202610170824"
    private static let maximumItemCount = 64
    private static let maximumManifestBytes = 256 * 1024

    func testRunDeviceEvaluation() async throws {
        guard #available(iOS 17, *) else {
            throw XCTSkip("iOS 17 이상에서만 평가를 실행합니다.")
        }

        let fileManager = FileManager.default
        guard let cachesRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            throw XCTSkip("캐시 디렉터리를 사용할 수 없어 평가를 건너뜁니다.")
        }
        let taskRoot = cachesRoot.appendingPathComponent(Self.taskRootName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: taskRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("고정 fixture 루트가 이 기기에 없어 평가를 건너뜁니다.")
        }
        let taskRootResourceValues = try taskRoot.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard taskRootResourceValues.isSymbolicLink != true else {
            throw EvaluationError.fixtureNotRegularFile
        }
        let manifestURL = taskRoot.appendingPathComponent("manifest.json", isDirectory: false)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw XCTSkip("manifest.json이 없어 평가를 건너뜁니다.")
        }
        let manifestResourceValues = try manifestURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard manifestResourceValues.isSymbolicLink != true, manifestResourceValues.isRegularFile == true else {
            throw EvaluationError.fixtureNotRegularFile
        }

        let manifest = try loadManifest(at: manifestURL, fileManager: fileManager)

        var photoResults: [PhotoResult] = []
        var photoMeasurementMilliseconds: [String: Double] = [:]
        var measurementByID: [Int: VideoTrailerPhotoQuality.Measurement] = [:]
        var resolvedPhotoURLByID: [Int: URL] = [:]

        for photo in manifest.photos {
            try Task.checkCancellation()
            let resolvedURL = try resolvedFixtureURL(leaf: photo.file, root: taskRoot, fileManager: fileManager)
            resolvedPhotoURLByID[photo.id] = resolvedURL
            let start = CFAbsoluteTimeGetCurrent()
            let measurement = await VideoTrailerPhotoQuality.measure(fileAt: resolvedURL)
            let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
            photoMeasurementMilliseconds[String(photo.id)] = finiteOrNil(elapsedMilliseconds) ?? -1
            if let measurement {
                measurementByID[photo.id] = measurement
            }
            try Task.checkCancellation()
        }

        let photoItemsForRatios = manifest.photos.map { photo in
            (id: photo.id, measurement: measurementByID[photo.id])
        }
        let oldDurationRatios = VideoTrailerPhotoQuality.durationRatios(for: photoItemsForRatios)

        let embeddingItems = manifest.photos.compactMap { photo -> (id: Int, url: URL)? in
            guard let url = resolvedPhotoURLByID[photo.id] else { return nil }
            return (id: photo.id, url: url)
        }
        let gateStart = CFAbsoluteTimeGetCurrent()
        let flattenedEmbeddings: [Int: [Float]]?
        do {
            flattenedEmbeddings = try await VideoTrailerPhotoSimilarityGate.embeddings(for: embeddingItems)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            flattenedEmbeddings = nil
        }
        let gateElapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - gateStart) * 1000

        let newDurationRatios = VideoTrailerPhotoQuality.durationRatios(
            for: photoItemsForRatios, dinoEmbeddings: flattenedEmbeddings
        )

        var photoMeasurementFailureCount = 0
        for photo in manifest.photos {
            let measurement = measurementByID[photo.id]
            let embedding = flattenedEmbeddings?[photo.id]
            if measurement == nil { photoMeasurementFailureCount += 1 }
            photoResults.append(PhotoResult(
                id: photo.id,
                measurementStatus: measurement == nil ? "measurement-failed" : "ok",
                qualityScore: finiteOrNil(measurement?.qualityScore),
                sharpnessScore: finiteOrNil(measurement?.sharpnessScore),
                exposureScore: finiteOrNil(measurement?.exposureScore),
                aspectRatio: finiteOrNil(measurement?.aspectRatio),
                fingerprint: measurement?.fingerprint,
                oldDurationRatio: finiteOrNil(oldDurationRatios[photo.id]),
                newDurationRatio: finiteOrNil(newDurationRatios[photo.id]),
                embeddingDimension: embedding?.count ?? 0,
                embedding: embedding
            ))
        }

        var videoResults: [VideoResult] = []
        var videoBaselineMilliseconds: [String: Double] = [:]
        var videoNewMilliseconds: [String: Double] = [:]
        var increasedCount = 0
        var equalCount = 0
        var decreasedCount = 0

        for video in manifest.videos {
            try Task.checkCancellation()
            let resolvedURL = try resolvedFixtureURL(leaf: video.file, root: taskRoot, fileManager: fileManager)
            let result = try await evaluateVideo(id: video.id, anchorSeconds: video.anchorSeconds, fileURL: resolvedURL)
            videoBaselineMilliseconds[String(video.id)] = result.baselineMilliseconds
            videoNewMilliseconds[String(video.id)] = result.newMilliseconds
            switch result.status {
            case "increased": increasedCount += 1
            case "equal": equalCount += 1
            case "decreased": decreasedCount += 1
            default: break
            }
            videoResults.append(result)
            try Task.checkCancellation()
        }

        let controls = try await runControls(
            taskRoot: taskRoot,
            fileManager: fileManager,
            goodPhotoItem: embeddingItems.first,
            mainBatchModelAvailable: flattenedEmbeddings != nil
        )

        let device = await MainActor.run {
            DeviceInfo(
                systemVersion: UIDevice.current.systemVersion,
                model: UIDevice.current.model,
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                appBuild: Bundle.main.infoDictionary?["CFBundleVersion"] as? String
            )
        }

        let report = Report(
            schemaVersion: 1,
            photos: photoResults,
            videos: videoResults,
            controls: controls,
            summary: SummaryResult(
                photoCount: manifest.photos.count,
                videoCount: manifest.videos.count,
                photoMeasurementFailureCount: photoMeasurementFailureCount,
                videoSharpnessIncreasedCount: increasedCount,
                videoSharpnessEqualCount: equalCount,
                videoSharpnessDecreasedCount: decreasedCount
            ),
            timings: TimingsResult(
                totalEmbeddingGateMilliseconds: finiteOrNil(gateElapsedMilliseconds),
                photoMeasurementMilliseconds: photoMeasurementMilliseconds,
                videoBaselineMilliseconds: videoBaselineMilliseconds,
                videoNewMilliseconds: videoNewMilliseconds
            ),
            device: device
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let reportData = try encoder.encode(report)

        let resultURL = taskRoot.appendingPathComponent("result.json", isDirectory: false)
        try reportData.write(to: resultURL, options: .atomic)

        let attachment = XCTAttachment(data: reportData, uniformTypeIdentifier: "public.json")
        attachment.name = "HanYangDeviceEvaluationResult.json"
        attachment.lifetime = .keepAlways
        add(attachment)

        XCTAssertEqual(photoResults.count, manifest.photos.count)
        XCTAssertEqual(videoResults.count, manifest.videos.count)
        if decreasedCount > 0 {
            XCTFail("영상 대표 프레임 선명도가 기존 방식보다 낮아진 항목이 \(decreasedCount)건 있습니다 (증가 \(increasedCount), 동일 \(equalCount)).")
        }

        if !manifest.photos.isEmpty {
            XCTAssertNotNil(flattenedEmbeddings, "사진이 있는데 main batch embeddings가 nil입니다.")
            for photo in photoResults {
                guard let embedding = photo.embedding else { continue }
                XCTAssertEqual(embedding.count, 384, "photo \(photo.id) embedding 차원이 384가 아닙니다.")
                XCTAssertTrue(embedding.allSatisfy { $0.isFinite }, "photo \(photo.id) embedding에 non-finite 값이 있습니다.")
            }
            let actualMeasurementSuccessCount = photoResults.filter { $0.measurementStatus == "ok" }.count
            XCTAssertEqual(
                actualMeasurementSuccessCount, manifest.photos.count - photoMeasurementFailureCount,
                "실제 측정 성공 수가 요약과 일치하지 않습니다."
            )
        }
        if !manifest.videos.isEmpty {
            let videoSuccessCount = videoResults.filter { $0.baselineSharpness != nil && $0.newSharpness != nil }.count
            XCTAssertEqual(videoSuccessCount, manifest.videos.count, "모든 영상에서 baseline/new 선명도 측정이 성공해야 합니다.")
            let proxyFiniteCount = videoResults.filter { $0.baselinePixelHash != nil && $0.newPixelHash != nil }.count
            XCTAssertEqual(proxyFiniteCount, manifest.videos.count, "모든 영상에서 proxy 해시가 존재해야 합니다.")
        }
        XCTAssertEqual(oldDurationRatios.count, manifest.photos.count, "old duration ratio가 모든 사진에 대해 존재해야 합니다.")
        XCTAssertEqual(newDurationRatios.count, manifest.photos.count, "new duration ratio가 모든 사진에 대해 존재해야 합니다.")

        XCTAssertTrue(
            controls.singleBadFixtureStatus == "nil-as-expected" || controls.singleBadFixtureStatus == "bad-fixture-setup-failed",
            "singleBadFixtureStatus가 예상된 nil/실패 경로가 아닙니다: \(controls.singleBadFixtureStatus)"
        )
        XCTAssertTrue(
            ["nil-as-expected", "bad-fixture-setup-failed", "skipped-no-good-photo-fixture"]
                .contains(controls.mixedGoodBadFixtureStatus),
            "mixedGoodBadFixtureStatus가 예상된 경로가 아닙니다: \(controls.mixedGoodBadFixtureStatus)"
        )
        XCTAssertTrue(
            controls.cancellationStatus == "cancelled-as-expected" || controls.cancellationStatus == "skipped-no-good-photo-fixture",
            "cancellationStatus가 예상된 값이 아닙니다: \(controls.cancellationStatus)"
        )
    }

    // MARK: - Manifest loading and validation

    private func loadManifest(at url: URL, fileManager: FileManager) throws -> Manifest {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? Int) ?? Int.max
        guard size <= Self.maximumManifestBytes else { throw EvaluationError.manifestTooLarge }
        let data = try Data(contentsOf: url)
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: data)
        } catch {
            throw EvaluationError.manifestInvalid
        }
        guard manifest.schemaVersion == 1 else { throw EvaluationError.manifestInvalid }
        guard manifest.photos.count <= Self.maximumItemCount, manifest.videos.count <= Self.maximumItemCount else {
            throw EvaluationError.tooManyItems
        }
        let photoIDs = manifest.photos.map(\.id)
        let videoIDs = manifest.videos.map(\.id)
        guard Set(photoIDs).count == photoIDs.count, photoIDs.allSatisfy({ $0 >= 0 }) else {
            throw EvaluationError.duplicateOrNegativeID
        }
        guard Set(videoIDs).count == videoIDs.count, videoIDs.allSatisfy({ $0 >= 0 }) else {
            throw EvaluationError.duplicateOrNegativeID
        }
        guard manifest.videos.allSatisfy({ $0.anchorSeconds.isFinite && $0.anchorSeconds >= 0 }) else {
            throw EvaluationError.anchorOutOfRange
        }
        return manifest
    }

    /// `leaf`는 반드시 슬래시가 없는 단일 파일명이어야 하고, task root 바로
    /// 아래의 기존 일반 파일(심볼릭 링크 제외)만 가리킬 수 있다.
    private func resolvedFixtureURL(leaf: String, root: URL, fileManager: FileManager) throws -> URL {
        guard !leaf.isEmpty, leaf != ".", leaf != "..",
              !leaf.contains("/"), !leaf.contains("\\"), !leaf.contains(":")
        else { throw EvaluationError.fixtureNameInvalid }
        let candidate = root.appendingPathComponent(leaf, isDirectory: false)
        let resourceValues = try candidate.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resourceValues.isSymbolicLink != true, resourceValues.isRegularFile == true else {
            throw EvaluationError.fixtureNotRegularFile
        }
        return candidate
    }

    private func finiteOrNil(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    // MARK: - Video evaluation

    private func evaluateVideo(id: Int, anchorSeconds: Double, fileURL: URL) async throws -> VideoResult {
        let asset = AVURLAsset(url: fileURL)
        let durationSeconds: Double?
        do {
            durationSeconds = try await asset.load(.duration).seconds
        } catch {
            durationSeconds = nil
        }
        guard let durationSeconds, durationSeconds.isFinite, durationSeconds > 0,
              anchorSeconds >= 0, anchorSeconds < durationSeconds
        else {
            throw EvaluationError.anchorOutOfRange
        }

        let maximumSize = CGSize(width: 240, height: 240)

        try Task.checkCancellation()
        let baselineStart = CFAbsoluteTimeGetCurrent()
        var baselineImage: CGImage?
        var baselineActualTimeSeconds: Double?
        autoreleasepool {
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = maximumSize
            var actualTime = CMTime.zero
            if let image = try? generator.copyCGImage(
                at: CMTime(seconds: anchorSeconds, preferredTimescale: 600), actualTime: &actualTime
            ) {
                baselineImage = image
                if actualTime.isValid, actualTime.isNumeric, actualTime.seconds.isFinite {
                    baselineActualTimeSeconds = actualTime.seconds
                }
            }
        }
        let baselineMilliseconds = (CFAbsoluteTimeGetCurrent() - baselineStart) * 1000

        try Task.checkCancellation()
        let newStart = CFAbsoluteTimeGetCurrent()
        let newImage: CGImage? = try? await RepresentativeVideoFrame.extract(
            asset: asset, anchor: anchorSeconds, appliesPreferredTrackTransform: true, maximumSize: maximumSize
        )
        let newMilliseconds = (CFAbsoluteTimeGetCurrent() - newStart) * 1000

        let baselineGray = baselineImage.flatMap(Self.renderGray64)
        let newGray = newImage.flatMap(Self.renderGray64)
        let baselineSharpness = baselineGray.flatMap { Self.laplacianVariance($0.pixels, width: $0.width, height: $0.height) }
        let newSharpness = newGray.flatMap { Self.laplacianVariance($0.pixels, width: $0.width, height: $0.height) }

        var status = "unavailable"
        if let baselineSharpness, let newSharpness {
            if newSharpness > baselineSharpness { status = "increased" }
            else if newSharpness < baselineSharpness { status = "decreased" }
            else { status = "equal" }
        }

        return VideoResult(
            id: id,
            anchorSeconds: anchorSeconds,
            durationSeconds: finiteOrNil(durationSeconds),
            baselineSharpness: finiteOrNil(baselineSharpness),
            newSharpness: finiteOrNil(newSharpness),
            baselineActualTimeSeconds: finiteOrNil(baselineActualTimeSeconds),
            newActualTimeSeconds: nil,
            newTimeStatus: "not-exposed-by-production-api",
            baselinePixelHash: baselineGray.map { Self.sha256Hex($0.pixels) },
            newPixelHash: newGray.map { Self.sha256Hex($0.pixels) },
            baselineMilliseconds: finiteOrNil(baselineMilliseconds) ?? -1,
            newMilliseconds: finiteOrNil(newMilliseconds) ?? -1,
            status: status
        )
    }

    private struct GrayRender { let pixels: [UInt8]; let width: Int; let height: Int }

    /// 장축을 64px로 맞춘 aspect-preserving DeviceGray 렌더. 선명도 비교와
    /// 이미지 해시 모두 이 동일한 버퍼에서 파생된다.
    private static func renderGray64(_ image: CGImage) -> GrayRender? {
        guard image.width > 0, image.height > 0 else { return nil }
        let longSide = max(image.width, image.height)
        let scale = 64.0 / Double(longSide)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        guard width > 2, height > 2 else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height)
        let didDraw = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(
                data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }
        return GrayRender(pixels: pixels, width: width, height: height)
    }

    private static func laplacianVariance(_ gray: [UInt8], width: Int, height: Int) -> Double? {
        guard width > 2, height > 2 else { return nil }
        var sum = 0.0
        var sumSquares = 0.0
        var count = 0
        for y in 1..<(height - 1) {
            let row = y * width
            let previousRow = row - width
            let nextRow = row + width
            for x in 1..<(width - 1) {
                let laplacian = Int(gray[row + x]) * 4
                    - Int(gray[row + x - 1]) - Int(gray[row + x + 1])
                    - Int(gray[previousRow + x]) - Int(gray[nextRow + x])
                let value = Double(laplacian)
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        guard count > 0 else { return nil }
        let mean = sum / Double(count)
        return sumSquares / Double(count) - mean * mean
    }

    private static func sha256Hex(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Bounded failure / cancellation controls

    private func runControls(
        taskRoot: URL,
        fileManager: FileManager,
        goodPhotoItem: (id: Int, url: URL)?,
        mainBatchModelAvailable: Bool
    ) async throws -> ControlsResult {
        let controlDirectory = taskRoot.appendingPathComponent("control-scratch", isDirectory: true)
        try? fileManager.createDirectory(at: controlDirectory, withIntermediateDirectories: true)
        let badFixtureURL = controlDirectory.appendingPathComponent(UUID().uuidString + ".bin", isDirectory: false)
        defer { try? fileManager.removeItem(at: badFixtureURL) }

        var singleBadFixtureStatus = "not-run"
        var mixedGoodBadFixtureStatus = "not-run"
        var cancellationStatus = "not-run"

        do {
            try Data([0x00, 0x01, 0x02, 0x03]).write(to: badFixtureURL, options: .withoutOverwriting)

            let singleBadResult = try? await VideoTrailerPhotoSimilarityGate.embeddings(
                for: [(id: -1, url: badFixtureURL)]
            )
            singleBadFixtureStatus = (singleBadResult ?? nil) == nil ? "nil-as-expected" : "unexpected-non-nil"

            if let goodPhotoItem {
                let mixedResult = try? await VideoTrailerPhotoSimilarityGate.embeddings(
                    for: [goodPhotoItem, (id: -2, url: badFixtureURL)]
                )
                mixedGoodBadFixtureStatus = (mixedResult ?? nil) == nil ? "nil-as-expected" : "unexpected-non-nil"
            } else {
                mixedGoodBadFixtureStatus = "skipped-no-good-photo-fixture"
            }
        } catch {
            singleBadFixtureStatus = "bad-fixture-setup-failed"
            mixedGoodBadFixtureStatus = "bad-fixture-setup-failed"
        }

        if let goodPhotoItem {
            let cancellationTask = Task {
                try await VideoTrailerPhotoSimilarityGate.embeddings(for: [goodPhotoItem])
            }
            cancellationTask.cancel()
            do {
                _ = try await cancellationTask.value
                cancellationStatus = "cancellation-not-observed"
            } catch is CancellationError {
                cancellationStatus = "cancelled-as-expected"
            } catch {
                cancellationStatus = "cancellation-not-observed"
            }
        } else {
            cancellationStatus = "skipped-no-good-photo-fixture"
        }

        if cancellationStatus == "cancellation-not-observed" {
            XCTFail("즉시 취소한 Task에서 CancellationError가 관찰되지 않았습니다.")
        }

        return ControlsResult(
            singleBadFixtureStatus: singleBadFixtureStatus,
            mixedGoodBadFixtureStatus: mixedGoodBadFixtureStatus,
            cancellationStatus: cancellationStatus,
            modelAvailability: mainBatchModelAvailable ? "available" : "unavailable"
        )
    }
}
