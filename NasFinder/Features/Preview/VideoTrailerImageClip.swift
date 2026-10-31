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
    struct Framing: Equatable, Sendable {
        var fitsFrame: Bool
        /// -1...1. 0이 가운데이고 사진이 화면을 넘치는 방향으로만 움직인다.
        var offsetX: Double
        var offsetY: Double
    }

    /// 단일 프레임(또는 미리보기 시점 `progress in 0...1`)에서의 사진 렌더링 샘플.
    /// 내보내기(`AVAssetWriter`)와 실시간 편집기 미리보기(`TrailerWorkspacePreview`)가 동일 수식을 공유한다.
    struct CameraFrameSample: Equatable, Sendable {
        let drawOrigin: CGPoint
        let drawSize: CGSize
        /// 기본 FILL 배율 대비 추가 확대 배율(자동/수동 FILL에서는 항상 >= 1.0).
        let zoomScale: CGFloat
        /// 정규화 이미지 좌표(0...1, 좌상단 원점) 기준 현재 초점 중심.
        let focusCenter: CGPoint
        let fitsFrame: Bool
    }

    /// 온디바이스 Vision 분석으로 찾은 피사체 초점 대상(좌상단 정규화 좌표 0...1).
    struct SubjectFocusTarget: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case faceCluster
            case salientObject
        }
        let kind: Kind
        /// 가장 중요한 단일 피사체(가장 큰 얼굴/머리 보호 박스 또는 대표 현저성 객체).
        let primaryBox: CGRect
        /// 대표 피사체를 중심으로 묶인 주 군집 박스.
        let clusterBox: CGRect
        /// 긴 장면(>3초) 패닝 시 보조 피사체 방향을 결정하기 위한 전체 피사체 범위.
        let fullSpanBox: CGRect
    }

    /// 사진 장면의 카메라 모션 계획. 미리보기와 최종 렌더링이 동일한 계획을 샘플링한다.
    struct CameraMotionPlan: Equatable, Sendable {
        enum Mode: Equatable, Sendable {
            case fitted
            case manual(offsetX: CGFloat, offsetY: CGFloat)
            case automatic
        }

        enum FocusSource: Equatable, Sendable {
            case faceCluster
            case salientObject
            case deterministicRandom
            case manual
            case fitted
        }

        let mode: Mode
        let focusSource: FocusSource
        let imageSize: CGSize
        let renderSize: CGSize
        let duration: Double
        /// 기본 FILL 스케일 대비 시작·종료 줌 배율(자동 FILL에서는 항상 >= 1.0).
        let startZoom: CGFloat
        let endZoom: CGFloat
        /// 정규화 이미지 좌표(0...1, 좌상단 원점) 기준 시작·종료 초점 중심.
        /// 3초 이하 장면에서는 `startFocus == endFocus`로 고정되어 독립 패닝이 발생하지 않는다.
        let startFocus: CGPoint
        let endFocus: CGPoint
        /// 긴 장면(>3초)에서 시작·끝 구간에 미세하게 머무르는 비율.
        let holdFraction: CGFloat

        /// 주어진 진행률(`0...1`)과 대상 뷰포트 크기(`viewportSize`)에 대한 정확한 그리기 좌표를 계산한다.
        func sample(at progress: Double, in viewportSize: CGSize? = nil) -> CameraFrameSample {
            let targetSize = viewportSize ?? renderSize
            let safeViewport = CGSize(width: max(1.0, targetSize.width), height: max(1.0, targetSize.height))
            let safeImage = CGSize(width: max(1.0, imageSize.width), height: max(1.0, imageSize.height))

            switch mode {
            case .fitted:
                let fitScale = min(safeViewport.width / safeImage.width, safeViewport.height / safeImage.height)
                let drawSize = CGSize(width: safeImage.width * fitScale, height: safeImage.height * fitScale)
                let drawOrigin = CGPoint(
                    x: (safeViewport.width - drawSize.width) / 2.0,
                    y: (safeViewport.height - drawSize.height) / 2.0
                )
                return CameraFrameSample(
                    drawOrigin: drawOrigin,
                    drawSize: drawSize,
                    zoomScale: 1.0,
                    focusCenter: CGPoint(x: 0.5, y: 0.5),
                    fitsFrame: true
                )

            case .manual(let offsetX, let offsetY):
                let fillScale = max(safeViewport.width / safeImage.width, safeViewport.height / safeImage.height)
                let drawSize = CGSize(width: safeImage.width * fillScale, height: safeImage.height * fillScale)
                let marginX = max(0.0, (drawSize.width - safeViewport.width) / 2.0)
                let marginY = max(0.0, (drawSize.height - safeViewport.height) / 2.0)
                let focalX = -min(1.0, max(-1.0, offsetX))
                let focalY = -min(1.0, max(-1.0, offsetY))
                let rawOriginX = (safeViewport.width - drawSize.width) / 2.0 + focalX * marginX
                let rawOriginY = (safeViewport.height - drawSize.height) / 2.0 + focalY * marginY
                let clampedX = min(0.0, max(safeViewport.width - drawSize.width, rawOriginX))
                let clampedY = min(0.0, max(safeViewport.height - drawSize.height, rawOriginY))
                let centerX = drawSize.width > 0 ? (safeViewport.width / 2.0 - clampedX) / drawSize.width : 0.5
                let centerY = drawSize.height > 0 ? (safeViewport.height / 2.0 - clampedY) / drawSize.height : 0.5
                return CameraFrameSample(
                    drawOrigin: CGPoint(x: clampedX, y: clampedY),
                    drawSize: drawSize,
                    zoomScale: 1.0,
                    focusCenter: CGPoint(x: centerX, y: centerY),
                    fitsFrame: false
                )

            case .automatic:
                let t = CGFloat(min(1.0, max(0.0, progress.isFinite ? progress : 0.0)))
                let zoomEased = t * t * (3.0 - 2.0 * t)
                let zoom = max(1.0, startZoom + (endZoom - startZoom) * zoomEased)

                let panT: CGFloat
                if holdFraction > 0.0, holdFraction < 0.45 {
                    let u = min(1.0, max(0.0, (t - holdFraction) / (1.0 - 2.0 * holdFraction)))
                    panT = u * u * (3.0 - 2.0 * u)
                } else {
                    panT = zoomEased
                }

                let focusX = startFocus.x + (endFocus.x - startFocus.x) * panT
                let focusY = startFocus.y + (endFocus.y - startFocus.y) * panT

                let fillScale = max(safeViewport.width / safeImage.width, safeViewport.height / safeImage.height)
                let totalScale = fillScale * zoom
                let drawSize = CGSize(width: safeImage.width * totalScale, height: safeImage.height * totalScale)
                let rawOriginX = safeViewport.width / 2.0 - focusX * drawSize.width
                let rawOriginY = safeViewport.height / 2.0 - focusY * drawSize.height
                // 모든 줌·패닝 시점에서 출력 화면이 빈 여백 없이 100% 덮이도록 경계를 보장한다.
                let clampedX = min(0.0, max(safeViewport.width - drawSize.width, rawOriginX))
                let clampedY = min(0.0, max(safeViewport.height - drawSize.height, rawOriginY))
                return CameraFrameSample(
                    drawOrigin: CGPoint(x: clampedX, y: clampedY),
                    drawSize: drawSize,
                    zoomScale: zoom,
                    focusCenter: CGPoint(x: focusX, y: focusY),
                    fitsFrame: false
                )
            }
        }
    }

    private static let workingThumbnailMaxPixelSize: CGFloat = 1024
    private static let renderMaxPixelSize: CGFloat = 2560
    /// 짧은 장면과 긴 장면을 나누는 기준 시간(초). 3초 이하는 고정 초점 + 약한 줌, 3초 초과는 속도 제한 패닝 + 줌.
    static let shortClipThresholdSeconds: Double = 3.0

    private struct FileRevisionKey: Hashable, Sendable {
        let path: String
        let modificationDate: Date
        let fileSize: UInt64
    }

    private final class AnalysisCache: @unchecked Sendable {
        static let shared = AnalysisCache()
        private let lock = NSLock()
        private var cache: [FileRevisionKey: SubjectFocusTarget?] = [:]
        private var keys: [FileRevisionKey] = []
        private let maxEntries = 128

        func get(for key: FileRevisionKey) -> SubjectFocusTarget?? {
            lock.lock()
            defer { lock.unlock() }
            guard let value = cache[key] else { return nil }
            return .some(value)
        }

        func set(_ value: SubjectFocusTarget?, for key: FileRevisionKey) {
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

    private enum SubjectAnalysisOutcome {
        case target(SubjectFocusTarget)
        case empty
        case transientFailure
    }

    /// 프로세스 재시작과 무관하게 동일한 입력에 대해 100% 동일한 난수열을 만드는 SplitMix64 생성기.
    private struct DeterministicRNG: Sendable {
        private var state: UInt64

        init(seed: UInt64) {
            self.state = seed != 0 ? seed : 0x9e3779b97f4a7c15
            _ = nextUInt64()
        }

        mutating func nextUInt64() -> UInt64 {
            state &+= 0x9e3779b97f4a7c15
            var z = state
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }

        mutating func nextBool() -> Bool {
            (nextUInt64() >> 63) == 1
        }

        mutating func nextUnitCGFloat() -> CGFloat {
            let bits = nextUInt64() >> 11
            return CGFloat(Double(bits) / Double(1 << 53))
        }
    }

    /// Swift.hashValue(프로세스별 랜덤 시드)를 절대 사용하지 않고,
    /// 원본 파일명/식별자에서 FNV-1a + SplitMix64 눈사태(avalanche) 믹싱으로 안정된 64비트 시드를 생성한다.
    static func stableSeed(sourceIdentity: String? = nil, imageURL: URL? = nil, fallbackSeed: Int = 0) -> UInt64 {
        let trimmedIdentity = sourceIdentity?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveIdentity: String
        if !trimmedIdentity.isEmpty {
            effectiveIdentity = trimmedIdentity
        } else if let urlName = imageURL?.lastPathComponent,
                  !urlName.isEmpty,
                  !urlName.hasPrefix("source-"),
                  !urlName.hasPrefix("recovered-still-") {
            effectiveIdentity = urlName
        } else if let imageURL,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: imageURL.path),
                  let fileSize = (attrs[.size] as? NSNumber)?.uint64Value,
                  fileSize > 0 {
            effectiveIdentity = "filesize-\(fileSize)-\(imageURL.pathExtension.lowercased())"
        } else {
            effectiveIdentity = "seed-\(fallbackSeed)"
        }

        var hash: UInt64 = 0xcbf29ce484222325
        for byte in effectiveIdentity.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        if trimmedIdentity.isEmpty, fallbackSeed != 0 {
            hash ^= UInt64(bitPattern: Int64(fallbackSeed)) &* 0x9e3779b97f4a7c15
        }
        hash = (hash ^ (hash >> 30)) &* 0xbf58476d1ce4e5b9
        hash = (hash ^ (hash >> 27)) &* 0x94d049bb133111eb
        return hash ^ (hash >> 31)
    }

    static func stableSeedInt(for identity: String) -> Int {
        Int(bitPattern: UInt(truncatingIfNeeded: stableSeed(sourceIdentity: identity)))
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

    private static func isValidNormalizedBox(_ box: CGRect) -> Bool {
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

    /// Vision 하단-좌측 원점 정규화 박스를 상단-좌측 원점(0...1) 박스로 변환한다.
    private static func convertVisionBoxToTopLeft(_ box: CGRect) -> CGRect? {
        guard isValidNormalizedBox(box) else { return nil }
        let converted = CGRect(
            x: box.origin.x,
            y: 1.0 - box.origin.y - box.size.height,
            width: box.size.width,
            height: box.size.height
        )
        guard isValidNormalizedBox(converted) else { return nil }
        return converted
    }

    /// 얼굴 박스를 정수리(머리 위)·턱·양옆 여유분까지 포함한 머리 보호 박스로 확장한다.
    private static func expandFaceToHeadProtectedBox(_ face: CGRect) -> CGRect {
        let sidePad = max(0.02, face.width * 0.18)
        let topPad = max(0.03, face.height * 0.35)
        let bottomPad = max(0.02, face.height * 0.14)
        let minX = max(0.0, face.minX - sidePad)
        let maxX = min(1.0, face.maxX + sidePad)
        let minY = max(0.0, face.minY - topPad)
        let maxY = min(1.0, face.maxY + bottomPad)
        return CGRect(x: minX, y: minY, width: max(1e-4, maxX - minX), height: max(1e-4, maxY - minY))
    }

    private static func padNormalizedBox(_ box: CGRect, ratioX: CGFloat = 0.06, ratioY: CGFloat = 0.06, minPad: CGFloat = 0.025) -> CGRect {
        let padX = max(minPad, box.width * ratioX)
        let padY = max(minPad, box.height * ratioY)
        let minX = max(0.0, box.minX - padX)
        let maxX = min(1.0, box.maxX + padX)
        let minY = max(0.0, box.minY - padY)
        let maxY = min(1.0, box.maxY + padY)
        return CGRect(x: minX, y: minY, width: max(1e-4, maxX - minX), height: max(1e-4, maxY - minY))
    }

    /// 검출된 박스들에서 가장 큰 대표 피사체와 인접 주 군집(primary cluster) 및 전체 범위를 구성한다.
    static func buildSubjectFocusTarget(
        faceBoxesTopLeft: [CGRect],
        salientBoxesTopLeft: [CGRect]
    ) -> SubjectFocusTarget? {
        let validFaces = faceBoxesTopLeft.filter(isValidNormalizedBox)
        if !validFaces.isEmpty {
            let headBoxes = validFaces.map(expandFaceToHeadProtectedBox)
            let sortedHeads = headBoxes.sorted { lhs, rhs in
                let areaL = lhs.width * lhs.height
                let areaR = rhs.width * rhs.height
                if abs(areaL - areaR) > 1e-6 { return areaL > areaR }
                let distL = hypot(lhs.midX - 0.5, lhs.midY - 0.45)
                let distR = hypot(rhs.midX - 0.5, rhs.midY - 0.45)
                return distL < distR
            }

            // 인접한 얼굴/머리 박스끼리 연결 군집을 형성하고 가장 면적 가중치가 큰 군집을 주 군집으로 선택한다.
            var visited = Array(repeating: false, count: sortedHeads.count)
            var bestCluster: [CGRect] = [sortedHeads[0]]
            var bestScore: CGFloat = -1.0

            func areNeighbors(_ a: CGRect, _ b: CGRect) -> Bool {
                let reachX = max(a.width, b.width) * 0.65
                let reachY = max(a.height, b.height) * 0.55
                let expandedA = a.insetBy(dx: -reachX, dy: -reachY)
                return expandedA.intersects(b)
            }

            for i in sortedHeads.indices where !visited[i] {
                visited[i] = true
                var queue = [i]
                var cluster: [CGRect] = []
                while let current = queue.first {
                    queue.removeFirst()
                    let rect = sortedHeads[current]
                    cluster.append(rect)
                    for j in sortedHeads.indices where !visited[j] && areNeighbors(rect, sortedHeads[j]) {
                        visited[j] = true
                        queue.append(j)
                    }
                }
                let totalArea = cluster.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
                let maxSingleArea = cluster.map { $0.width * $0.height }.max() ?? 0
                let score = totalArea + maxSingleArea * 0.5
                if score > bestScore {
                    bestScore = score
                    bestCluster = cluster
                }
            }

            let primaryHead = bestCluster[0]
            var compactCluster = primaryHead
            for member in bestCluster.dropFirst() {
                let candidate = compactCluster.union(member)
                if candidate.width <= 0.72 && candidate.height <= 0.72 {
                    compactCluster = candidate
                }
            }

            var fullSpan = sortedHeads[0]
            for rect in sortedHeads.dropFirst() {
                fullSpan = fullSpan.union(rect)
            }

            return SubjectFocusTarget(
                kind: .faceCluster,
                primaryBox: padNormalizedBox(primaryHead, ratioX: 0.04, ratioY: 0.04, minPad: 0.015),
                clusterBox: padNormalizedBox(compactCluster, ratioX: 0.05, ratioY: 0.05, minPad: 0.02),
                fullSpanBox: padNormalizedBox(fullSpan, ratioX: 0.04, ratioY: 0.04, minPad: 0.015)
            )
        }

        let validSalient = salientBoxesTopLeft.filter(isValidNormalizedBox)
        guard !validSalient.isEmpty else { return nil }

        let sortedSalient = validSalient.sorted { lhs, rhs in
            let areaL = lhs.width * lhs.height
            let areaR = rhs.width * rhs.height
            if abs(areaL - areaR) > 1e-6 { return areaL > areaR }
            let distL = hypot(lhs.midX - 0.5, lhs.midY - 0.5)
            let distR = hypot(rhs.midX - 0.5, rhs.midY - 0.5)
            return distL < distR
        }

        let primaryObject = sortedSalient[0]
        var compactSalient = primaryObject
        for obj in sortedSalient.dropFirst() {
            let candidate = compactSalient.union(obj)
            if candidate.width <= 0.75 && candidate.height <= 0.75 {
                compactSalient = candidate
            }
        }

        var fullSpan = sortedSalient[0]
        for obj in sortedSalient.dropFirst() {
            fullSpan = fullSpan.union(obj)
        }

        return SubjectFocusTarget(
            kind: .salientObject,
            primaryBox: padNormalizedBox(primaryObject, ratioX: 0.06, ratioY: 0.06, minPad: 0.03),
            clusterBox: padNormalizedBox(compactSalient, ratioX: 0.06, ratioY: 0.06, minPad: 0.03),
            fullSpanBox: padNormalizedBox(fullSpan, ratioX: 0.05, ratioY: 0.05, minPad: 0.025)
        )
    }

    private static func analyzeSubjects(at imageURL: URL) throws -> SubjectAnalysisOutcome {
        try Task.checkCancellation()
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, sourceOptions) else {
            return .transientFailure
        }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: workingThumbnailMaxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary
        guard let cgThumb = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, thumbOptions) else {
            return .transientFailure
        }

        try Task.checkCancellation()
        let handler = VNImageRequestHandler(cgImage: cgThumb, orientation: .up, options: [:])

        // 얼굴 요청과 현저성 요청을 독립 실행하여, 현저성 요청이 실패하거나 비어 있어도 검출된 얼굴을 보존한다.
        var faceBoxes: [CGRect] = []
        var faceSucceeded = false
        let faceRequest = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faceRequest])
            faceSucceeded = true
            if let faces = faceRequest.results {
                for face in faces {
                    // 개별 박스가 유효하지 않으면 해당 박스만 건너뛰고 전체 결과를 버리지 않는다.
                    if let converted = convertVisionBoxToTopLeft(face.boundingBox) {
                        faceBoxes.append(converted)
                    }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled { throw CancellationError() }
        }

        try Task.checkCancellation()

        var salientBoxes: [CGRect] = []
        var saliencySucceeded = false
        if faceBoxes.isEmpty {
            let saliencyRequest = VNGenerateObjectnessBasedSaliencyImageRequest()
            do {
                try handler.perform([saliencyRequest])
                saliencySucceeded = true
                if let observations = saliencyRequest.results {
                    for obs in observations {
                        if let objects = obs.salientObjects {
                            for obj in objects {
                                if let converted = convertVisionBoxToTopLeft(obj.boundingBox) {
                                    salientBoxes.append(converted)
                                }
                            }
                        }
                    }
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if Task.isCancelled { throw CancellationError() }
            }
        }

        try Task.checkCancellation()

        if let target = buildSubjectFocusTarget(
            faceBoxesTopLeft: faceBoxes,
            salientBoxesTopLeft: salientBoxes
        ) {
            return .target(target)
        }

        // 두 요청이 모두 런타임 오류로 실패한 경우에는 영구 부정 캐시에 넣지 않는다.
        guard faceSucceeded || saliencySucceeded else {
            return .transientFailure
        }
        return .empty
    }

    private static func subjectFocusTarget(for imageURL: URL) throws -> SubjectFocusTarget? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: imageURL.path)
        let modDate = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)
        let fileSize = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        let key = FileRevisionKey(path: imageURL.standardizedFileURL.path, modificationDate: modDate, fileSize: fileSize)

        if let cached = AnalysisCache.shared.get(for: key) {
            return cached
        }

        let outcome = try analyzeSubjects(at: imageURL)
        switch outcome {
        case .target(let target):
            AnalysisCache.shared.set(target, for: key)
            return target
        case .empty:
            AnalysisCache.shared.set(nil, for: key)
            return nil
        case .transientFailure:
            // 일시적 분석 실패는 영구 캐싱하지 않으며, 호출부는 결정적 합법 랜덤 초점 FILL로 진행한다.
            return nil
        }
    }

    /// Vision 분석 결과(`target`)와 사진/출력 크기·길이·시드·수동 프레이밍으로부터 카메라 모션 계획을 생성한다.
    /// 어떤 경우에도 자동 모드(`framing == nil` 또는 `framing.fitsFrame == false`)는 `.fitted`로 후퇴하지 않는다.
    static func makeCameraMotionPlan(
        imageSize: CGSize,
        duration: Double,
        renderSize: CGSize,
        target: SubjectFocusTarget?,
        seed: UInt64,
        framing: Framing? = nil
    ) -> CameraMotionPlan {
        let safeImage = CGSize(width: max(1.0, imageSize.width), height: max(1.0, imageSize.height))
        let safeRender = CGSize(width: max(1.0, renderSize.width), height: max(1.0, renderSize.height))
        let safeDuration = duration.isFinite && duration > 0 ? duration : 0.0

        if let framing {
            if framing.fitsFrame {
                return CameraMotionPlan(
                    mode: .fitted,
                    focusSource: .fitted,
                    imageSize: safeImage,
                    renderSize: safeRender,
                    duration: safeDuration,
                    startZoom: 1.0,
                    endZoom: 1.0,
                    startFocus: CGPoint(x: 0.5, y: 0.5),
                    endFocus: CGPoint(x: 0.5, y: 0.5),
                    holdFraction: 0.0
                )
            } else {
                let clampedOffsetX = CGFloat(min(1.0, max(-1.0, framing.offsetX)))
                let clampedOffsetY = CGFloat(min(1.0, max(-1.0, framing.offsetY)))
                let imageAspect = safeImage.width / safeImage.height
                let renderAspect = safeRender.width / safeRender.height
                let baseCropW: CGFloat = imageAspect >= renderAspect ? min(1.0, renderAspect / imageAspect) : 1.0
                let baseCropH: CGFloat = imageAspect < renderAspect ? min(1.0, imageAspect / renderAspect) : 1.0
                let marginX = (1.0 - baseCropW) / 2.0
                let marginY = (1.0 - baseCropH) / 2.0
                let manualCenter = CGPoint(
                    x: 0.5 + clampedOffsetX * marginX,
                    y: 0.5 + clampedOffsetY * marginY
                )
                return CameraMotionPlan(
                    mode: .manual(offsetX: clampedOffsetX, offsetY: clampedOffsetY),
                    focusSource: .manual,
                    imageSize: safeImage,
                    renderSize: safeRender,
                    duration: safeDuration,
                    startZoom: 1.0,
                    endZoom: 1.0,
                    startFocus: manualCenter,
                    endFocus: manualCenter,
                    holdFraction: 0.0
                )
            }
        }

        let imageAspect = safeImage.width / safeImage.height
        let renderAspect = safeRender.width / safeRender.height
        // 기본 FILL(zoom = 1.0)에서 보이는 가장 넓은 크롭 창 크기(정규화 이미지 좌표 0...1).
        let baseCropW: CGFloat = imageAspect >= renderAspect ? min(1.0, renderAspect / imageAspect) : 1.0
        let baseCropH: CGFloat = imageAspect < renderAspect ? min(1.0, imageAspect / renderAspect) : 1.0

        // 가장 넓은 크롭(zoom = 1.0)에서도 화면 밖 여백이 절대 노출되지 않는 합법 중심 범위.
        // 이 범위 안의 중심점은 모든 줌 배율(zoom >= 1.0)에서도 항상 합법 중심이다.
        let minCenterX = baseCropW / 2.0
        let maxCenterX = 1.0 - baseCropW / 2.0
        let minCenterY = baseCropH / 2.0
        let maxCenterY = 1.0 - baseCropH / 2.0

        func resolveSubjectCenter(cluster: CGRect, primary: CGRect, cropW: CGFloat, cropH: CGFloat) -> (center: CGPoint, protectedBox: CGRect) {
            let lowX = max(minCenterX, cluster.maxX - cropW / 2.0)
            let highX = min(maxCenterX, cluster.minX + cropW / 2.0)
            let fitsClusterX = lowX <= highX + 1e-6
            let cx: CGFloat
            if fitsClusterX {
                cx = min(highX, max(lowX, cluster.midX))
            } else {
                let pLowX = max(minCenterX, primary.maxX - cropW / 2.0)
                let pHighX = min(maxCenterX, primary.minX + cropW / 2.0)
                if pLowX <= pHighX + 1e-6 {
                    cx = min(pHighX, max(pLowX, primary.midX))
                } else {
                    cx = min(maxCenterX, max(minCenterX, primary.midX))
                }
            }

            let lowY = max(minCenterY, cluster.maxY - cropH / 2.0)
            let highY = min(maxCenterY, cluster.minY + cropH / 2.0)
            let fitsClusterY = lowY <= highY + 1e-6
            let cy: CGFloat
            if fitsClusterY {
                cy = min(highY, max(lowY, cluster.midY))
            } else {
                let pLowY = max(minCenterY, primary.maxY - cropH / 2.0)
                let pHighY = min(maxCenterY, primary.minY + cropH / 2.0)
                if pLowY <= pHighY + 1e-6 {
                    cy = min(pHighY, max(pLowY, primary.midY))
                } else {
                    let headBiasedY = primary.minY + primary.height * 0.42
                    cy = min(maxCenterY, max(minCenterY, headBiasedY))
                }
            }

            let activeBox = (fitsClusterX && fitsClusterY) ? cluster : primary
            return (CGPoint(x: cx, y: cy), activeBox)
        }

        func safeZoomAmplitude(requested: CGFloat, center: CGPoint, protectedBox: CGRect?) -> CGFloat {
            guard requested > 0 else { return 0.0 }
            guard let protectedBox else { return requested }
            let reqHalfW = max(0.0, center.x - protectedBox.minX, protectedBox.maxX - center.x)
            let reqHalfH = max(0.0, center.y - protectedBox.minY, protectedBox.maxY - center.y)
            let availHalfW = baseCropW / 2.0
            let availHalfH = baseCropH / 2.0
            // 이미 피사체가 기본 크롭 창을 가득 채우거나 넘치면 얼굴이 잘리지 않도록 추가 줌을 멈춘다.
            if reqHalfW > availHalfW + 1e-6 || reqHalfH > availHalfH + 1e-6 {
                return 0.0
            }
            let maxZoomX = reqHalfW > 1e-6 ? availHalfW / reqHalfW : 2.0
            let maxZoomY = reqHalfH > 1e-6 ? availHalfH / reqHalfH : 2.0
            let maxSafeZoom = max(1.0, min(maxZoomX, maxZoomY))
            return min(requested, max(0.0, maxSafeZoom - 1.0))
        }

        var rng = DeterministicRNG(seed: seed)
        let zoomsIn = rng.nextBool()
        let randX = rng.nextUnitCGFloat()
        let randY = rng.nextUnitCGFloat()
        let panForward = rng.nextBool()

        let focusSource: CameraMotionPlan.FocusSource
        if let target {
            focusSource = target.kind == .faceCluster ? .faceCluster : .salientObject
        } else {
            focusSource = .deterministicRandom
        }

        // 1) 짧은 장면 (duration <= 3.0s): 독립 패닝 없이 고정 초점(startFocus == endFocus) 유지,
        //    장면 길이에 비례한 약한 줌인 또는 줌아웃(3초에서 최대 4%, 얼굴 안전 클램프 적용).
        if safeDuration <= shortClipThresholdSeconds {
            let fixedFocus: CGPoint
            let protectedBox: CGRect?
            if let target {
                let resolved = resolveSubjectCenter(
                    cluster: target.clusterBox,
                    primary: target.primaryBox,
                    cropW: baseCropW,
                    cropH: baseCropH
                )
                fixedFocus = resolved.center
                protectedBox = resolved.protectedBox
            } else {
                let spanX = max(0.0, maxCenterX - minCenterX)
                let spanY = max(0.0, maxCenterY - minCenterY)
                let cx = min(maxCenterX, max(minCenterX, minCenterX + spanX * (0.15 + 0.70 * randX)))
                let cy = min(maxCenterY, max(minCenterY, minCenterY + spanY * (0.15 + 0.70 * randY)))
                fixedFocus = CGPoint(x: cx, y: cy)
                protectedBox = nil
            }

            let timeScale = CGFloat(min(1.0, max(0.0, safeDuration / shortClipThresholdSeconds)))
            let requestedAmp: CGFloat = 0.04 * timeScale
            let amp = safeZoomAmplitude(requested: requestedAmp, center: fixedFocus, protectedBox: protectedBox)
            let startZoom: CGFloat = zoomsIn ? 1.0 : (1.0 + amp)
            let endZoom: CGFloat = zoomsIn ? (1.0 + amp) : 1.0

            return CameraMotionPlan(
                mode: .automatic,
                focusSource: focusSource,
                imageSize: safeImage,
                renderSize: safeRender,
                duration: safeDuration,
                startZoom: startZoom,
                endZoom: endZoom,
                startFocus: fixedFocus,
                endFocus: fixedFocus,
                holdFraction: 0.0
            )
        }

        // 2) 긴 장면 (duration > 3.0s): 시간·속도 예산이 제한된 카메라형 완만한 줌 + 가로 또는 세로 패닝.
        let holdFraction: CGFloat = safeDuration >= 4.5 ? 0.07 : 0.05
        let extraTimeProgress = CGFloat(min(1.0, max(0.0, (safeDuration - shortClipThresholdSeconds) / 5.0)))
        let requestedZoomAmp: CGFloat = 0.04 + 0.035 * extraTimeProgress

        let isHorizontalPan = imageAspect >= renderAspect
        let effectivePanSeconds = max(0.5, CGFloat(safeDuration) * (1.0 - 2.0 * holdFraction))
        let maxPeakSpeedViewport: CGFloat = 0.12
        let maxTravelViewport = (maxPeakSpeedViewport * effectivePanSeconds) / 1.5
        // 최대 확대에서는 화면에 보이는 폭이 1/zoom로 줄어 같은 이동도 더 빠르게 보인다.
        // 그래서 이동 예산은 가장 좁은(최대 확대) 화면 폭 기준으로 잡는다. 확대 폭 자체는 늘리지 않는다.
        func travelLimits(maxZoom: CGFloat) -> (x: CGFloat, y: CGFloat) {
            let zoom = max(1.0, maxZoom)
            return (maxTravelViewport * baseCropW / zoom, maxTravelViewport * baseCropH / zoom)
        }
        // 시작점은 예산 안에서 결정적 랜덤 거리(60~100%)만큼 떨어진 곳, 끝점은 늘 주 피사체다.
        let startDistanceFraction: CGFloat = 0.6 + 0.4 * randX

        if let target {
            let resolved = resolveSubjectCenter(
                cluster: target.clusterBox,
                primary: target.primaryBox,
                cropW: baseCropW,
                cropH: baseCropH
            )
            let primaryCenter = resolved.center
            let amp = safeZoomAmplitude(requested: requestedZoomAmp, center: primaryCenter, protectedBox: resolved.protectedBox)
            let maxZoom = 1.0 + amp
            let tightCropW = baseCropW / maxZoom
            let tightCropH = baseCropH / maxZoom
            let limits = travelLimits(maxZoom: maxZoom)
            let maxTravelX = limits.x
            let maxTravelY = limits.y

            let startFocus: CGPoint
            // 끝은 주 피사체(머리 보호 중심). 머리를 포함한 보호 상자는 `resolveSubjectCenter`가 이미 반영했다.
            let endFocus = primaryCenter

            if isHorizontalPan {
                let lowX = max(minCenterX, target.clusterBox.maxX - tightCropW / 2.0)
                let highX = min(maxCenterX, target.clusterBox.minX + tightCropW / 2.0)
                if lowX <= highX + 1e-6, target.fullSpanBox.width <= target.clusterBox.width + 0.06 {
                    // 주 군집이 한 화면에 들어오고 멀리 있는 보조 피사체가 없으면, 군집이 계속 보이는 범위 안에서 출발한다.
                    let travel = min(max(0.0, highX - lowX), maxTravelX) * startDistanceFraction
                    let raw = panForward ? (primaryCenter.x - travel) : (primaryCenter.x + travel)
                    let x0 = min(highX, max(lowX, raw))
                    startFocus = CGPoint(x: min(maxCenterX, max(minCenterX, x0)), y: primaryCenter.y)
                } else {
                    // 보조 피사체가 멀거나(16:9 -> 9:16 등) 모두를 담을 수 없으면 보조 피사체 쪽에서 출발해
                    // 시간·속도 예산 안에서 주 피사체로 들어온다.
                    let leftTarget = max(minCenterX, target.fullSpanBox.minX + baseCropW / 2.0)
                    let rightTarget = min(maxCenterX, target.fullSpanBox.maxX - baseCropW / 2.0)
                    let otherX = abs(rightTarget - primaryCenter.x) >= abs(primaryCenter.x - leftTarget) ? rightTarget : leftTarget
                    let delta = min(maxTravelX, max(-maxTravelX, otherX - primaryCenter.x)) * startDistanceFraction
                    startFocus = CGPoint(x: min(maxCenterX, max(minCenterX, primaryCenter.x + delta)), y: primaryCenter.y)
                }
            } else {
                let lowY = max(minCenterY, target.clusterBox.maxY - tightCropH / 2.0)
                let highY = min(maxCenterY, target.clusterBox.minY + tightCropH / 2.0)
                if lowY <= highY + 1e-6, target.fullSpanBox.height <= target.clusterBox.height + 0.06 {
                    let travel = min(max(0.0, highY - lowY), maxTravelY) * startDistanceFraction
                    let raw = panForward ? (primaryCenter.y - travel) : (primaryCenter.y + travel)
                    let y0 = min(highY, max(lowY, raw))
                    startFocus = CGPoint(x: primaryCenter.x, y: min(maxCenterY, max(minCenterY, y0)))
                } else {
                    let topTarget = max(minCenterY, target.fullSpanBox.minY + baseCropH / 2.0)
                    let bottomTarget = min(maxCenterY, target.fullSpanBox.maxY - baseCropH / 2.0)
                    let otherY = abs(bottomTarget - primaryCenter.y) >= abs(primaryCenter.y - topTarget) ? bottomTarget : topTarget
                    let delta = min(maxTravelY, max(-maxTravelY, otherY - primaryCenter.y)) * startDistanceFraction
                    startFocus = CGPoint(x: primaryCenter.x, y: min(maxCenterY, max(minCenterY, primaryCenter.y + delta)))
                }
            }

            let startZoom: CGFloat = zoomsIn ? 1.0 : (1.0 + amp)
            let endZoom: CGFloat = zoomsIn ? (1.0 + amp) : 1.0
            return CameraMotionPlan(
                mode: .automatic,
                focusSource: focusSource,
                imageSize: safeImage,
                renderSize: safeRender,
                duration: safeDuration,
                startZoom: startZoom,
                endZoom: endZoom,
                startFocus: startFocus,
                endFocus: endFocus,
                holdFraction: holdFraction
            )
        } else {
            // 피사체가 없는 경우: 합법 크롭 영역 내 결정적 랜덤 초점 + 속도 제한 패닝 + 완만한 줌.
            let spanX = max(0.0, maxCenterX - minCenterX)
            let spanY = max(0.0, maxCenterY - minCenterY)
            let startFocus: CGPoint
            let endFocus: CGPoint
            let limits = travelLimits(maxZoom: 1.0 + requestedZoomAmp)
            let maxTravelX = limits.x
            let maxTravelY = limits.y

            if isHorizontalPan {
                let travel = min(spanX * 0.75, maxTravelX)
                let availMidSpan = max(0.0, spanX - travel)
                let midX = minCenterX + travel / 2.0 + availMidSpan * (0.15 + 0.70 * randX)
                let fixedY = minCenterY + spanY * (0.20 + 0.60 * randY)
                let x0 = panForward ? (midX - travel / 2.0) : (midX + travel / 2.0)
                let x1 = panForward ? (midX + travel / 2.0) : (midX - travel / 2.0)
                startFocus = CGPoint(
                    x: min(maxCenterX, max(minCenterX, x0)),
                    y: min(maxCenterY, max(minCenterY, fixedY))
                )
                endFocus = CGPoint(
                    x: min(maxCenterX, max(minCenterX, x1)),
                    y: min(maxCenterY, max(minCenterY, fixedY))
                )
            } else {
                let travel = min(spanY * 0.75, maxTravelY)
                let availMidSpan = max(0.0, spanY - travel)
                let fixedX = minCenterX + spanX * (0.20 + 0.60 * randX)
                let midY = minCenterY + travel / 2.0 + availMidSpan * (0.15 + 0.70 * randY)
                let y0 = panForward ? (midY - travel / 2.0) : (midY + travel / 2.0)
                let y1 = panForward ? (midY + travel / 2.0) : (midY - travel / 2.0)
                startFocus = CGPoint(
                    x: min(maxCenterX, max(minCenterX, fixedX)),
                    y: min(maxCenterY, max(minCenterY, y0))
                )
                endFocus = CGPoint(
                    x: min(maxCenterX, max(minCenterX, fixedX)),
                    y: min(maxCenterY, max(minCenterY, y1))
                )
            }

            let startZoom: CGFloat = zoomsIn ? 1.0 : (1.0 + requestedZoomAmp)
            let endZoom: CGFloat = zoomsIn ? (1.0 + requestedZoomAmp) : 1.0
            return CameraMotionPlan(
                mode: .automatic,
                focusSource: .deterministicRandom,
                imageSize: safeImage,
                renderSize: safeRender,
                duration: safeDuration,
                startZoom: startZoom,
                endZoom: endZoom,
                startFocus: startFocus,
                endFocus: endFocus,
                holdFraction: holdFraction
            )
        }
    }

    /// Vision 분석이 완료되기 전 첫 프레임에서 즉시 사용할 수 있는 합법 FILL 폴백 계획.
    static func fallbackCameraMotionPlan(
        imageSize: CGSize,
        duration: Double,
        renderSize: CGSize,
        seed: Int = 0,
        sourceIdentity: String? = nil,
        framing: Framing? = nil
    ) -> CameraMotionPlan {
        let resolvedSeed = stableSeed(sourceIdentity: sourceIdentity, imageURL: nil, fallbackSeed: seed)
        return makeCameraMotionPlan(
            imageSize: imageSize,
            duration: duration,
            renderSize: renderSize,
            target: nil,
            seed: resolvedSeed,
            framing: framing
        )
    }

    /// 내보내기와 편집기 실시간 미리보기 양쪽에서 공통으로 호출하는 카메라 모션 계획 생성 진입점.
    static func cameraMotionPlan(
        imageURL: URL,
        imageSize: CGSize? = nil,
        duration: Double,
        renderSize: CGSize,
        seed: Int = 0,
        sourceIdentity: String? = nil,
        framing: Framing? = nil
    ) throws -> CameraMotionPlan {
        try Task.checkCancellation()
        let resolvedImageSize: CGSize
        if let imageSize, imageSize.width > 0, imageSize.height > 0 {
            resolvedImageSize = imageSize
        } else {
            resolvedImageSize = try Self.imageSize(at: imageURL)
        }
        let resolvedSeed = stableSeed(sourceIdentity: sourceIdentity, imageURL: imageURL, fallbackSeed: seed)
        if let framing {
            return makeCameraMotionPlan(
                imageSize: resolvedImageSize,
                duration: duration,
                renderSize: renderSize,
                target: nil,
                seed: resolvedSeed,
                framing: framing
            )
        }
        let target = try subjectFocusTarget(for: imageURL)
        try Task.checkCancellation()
        return makeCameraMotionPlan(
            imageSize: resolvedImageSize,
            duration: duration,
            renderSize: renderSize,
            target: target,
            seed: resolvedSeed,
            framing: nil
        )
    }

    /// - Parameters:
    ///   - seed: 호환성을 위해 유지되는 클립 시드. `sourceIdentity` 또는 원본 파일 식별자와 결합해 항상 결정적 플랜을 만든다.
    ///   - sourceIdentity: 스테이징 임시 파일명(`source-<UUID>`) 대신 원본 파일명(`source.name`)을 전달하면 재열기·미리보기·내보내기에서 100% 동일한 시드를 유지한다.
    static func render(
        imageURL: URL,
        duration: Double,
        renderSize: CGSize,
        outputURL: URL,
        seed: Int,
        framing: Framing? = nil,
        sourceIdentity: String? = nil
    ) throws {
        try Task.checkCancellation()
        guard let source = loadSourceImage(at: imageURL), source.size.width > 0, source.size.height > 0 else {
            throw ClipError.decodeFailed
        }
        try Task.checkCancellation()

        let motionPlan = try cameraMotionPlan(
            imageURL: imageURL,
            imageSize: source.size,
            duration: duration,
            renderSize: renderSize,
            seed: seed,
            sourceIdentity: sourceIdentity,
            framing: framing
        )

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
                let sample = motionPlan.sample(at: t, in: renderSize)

                guard let pixelBuffer = Self.pixelBuffer(
                    for: source,
                    renderSize: renderSize,
                    drawOrigin: sample.drawOrigin,
                    drawSize: sample.drawSize,
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
