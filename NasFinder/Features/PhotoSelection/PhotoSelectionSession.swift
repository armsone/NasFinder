import Foundation
import ImageIO
import Photos
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 사진 선별 입력 하나. 분석에 실패해도 목록에서 사라지지 않고 항목 오류와 다시 시도로 남는다.
struct PhotoSelectionItem: Identifiable {
    enum Source {
        case asset(String)
        case file(URL)
        /// 공유 확장이 App Group에 복사해 둔 입력. 선별을 마치거나 비울 때까지 유지한다.
        case staged(batchID: UUID, itemID: UUID, url: URL)

        var fileURL: URL? {
            switch self {
            case .asset: nil
            case let .file(url), let .staged(_, _, url): url
            }
        }
    }

    enum State: Equatable {
        case queued
        case analyzing
        case ready
        case failed(String)
    }

    let id: String
    let serial: Int
    var name: String
    let source: Source
    /// true면 이 앱이 만든 임시 파일이라 제거·비우기에서 지운다.
    var ownsFile: Bool
    var state: State = .queued
    var measurement: VideoTrailerPhotoQuality.Measurement?
    var thumbnail: UIImage?

    var isReady: Bool { state == .ready && measurement != nil }
}

/// 두 사진의 근접도 캐시와 측정값. 새 사진이 들어올 때 그 사진과의 쌍만 계산한다.
struct PhotoSelectionPairIndex: Sendable {
    struct Key: Hashable, Sendable {
        let low: Int
        let high: Int
        init(_ a: Int, _ b: Int) { low = min(a, b); high = max(a, b) }
    }

    private(set) var measurements: [Int: VideoTrailerPhotoQuality.Measurement] = [:]
    private var means: [Int: Double] = [:]
    private(set) var closeness: [Key: Double] = [:]

    /// 평균 휘도 차이가 28을 넘는 쌍은 어차피 기존 조건에서 탈락하므로 비교하지 않는다.
    mutating func insert(serial: Int, measurement: VideoTrailerPhotoQuality.Measurement) {
        guard measurements[serial] == nil else { return }
        let mean = VideoTrailerPhotoQuality.meanLuminance(of: measurement)
        for (other, otherMeasurement) in measurements {
            if Task.isCancelled { break }
            guard abs((means[other] ?? 0) - mean) <= 28 else { continue }
            if let value = VideoTrailerPhotoQuality.closeness(measurement, otherMeasurement) {
                closeness[Key(serial, other)] = value
            }
        }
        measurements[serial] = measurement
        means[serial] = mean
    }

    mutating func remove(serial: Int) {
        measurements[serial] = nil
        means[serial] = nil
        closeness = closeness.filter { $0.key.low != serial && $0.key.high != serial }
    }

    var serials: Set<Int> { Set(measurements.keys) }
}

enum PhotoSelectionAnalyzer {
    struct Analysis: Sendable {
        let measurement: VideoTrailerPhotoQuality.Measurement
        let thumbnail: UIImage?
    }

    static let analysisPixelSize: CGFloat = 768
    static let thumbnailPixelSize: CGFloat = 240

    /// 파일 입력: 기존 품질 분석기(선명도·노출·해상도, 가능하면 Vision 미적 점수, 지문).
    static func analyze(fileAt url: URL) async -> Result<Analysis, AnalysisFailure> {
        guard let measurement = await VideoTrailerPhotoQuality.measure(fileAt: url, maxPixelSize: analysisPixelSize) else {
            return .failure(.init(message: "이미지를 읽지 못했습니다. 손상되었거나 지원하지 않는 형식일 수 있습니다."))
        }
        return .success(Analysis(measurement: measurement, thumbnail: thumbnail(forFileAt: url)))
    }

    /// 사진 보관함 입력: 원본 전체를 내보내지 않고 시스템 축소 이미지로 같은 지표를 계산한다.
    @MainActor
    static func analyze(assetIdentifier: String) async -> Result<Analysis, AnalysisFailure> {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            return .failure(.init(message: "사진 보관함에서 이 항목을 찾지 못했습니다. 접근 권한이나 삭제 여부를 확인해 주세요."))
        }
        guard asset.mediaType == .image else {
            return .failure(.init(message: "이미지가 아닙니다."))
        }
        let image: UIImage
        switch await requestImage(for: asset) {
        case let .success(value): image = value
        case let .failure(failure): return .failure(failure)
        }
        guard let cgImage = image.cgImage else {
            return .failure(.init(message: "이미지를 읽지 못했습니다."))
        }
        let pixelCount = asset.pixelWidth * asset.pixelHeight
        guard let measurement = await VideoTrailerPhotoQuality.measure(cgImage: cgImage, originalPixelCount: pixelCount) else {
            return .failure(.init(message: "해상도를 확인하지 못했습니다."))
        }
        return .success(Analysis(measurement: measurement, thumbnail: downscaled(image, to: thumbnailPixelSize)))
    }

    struct AnalysisFailure: Error, Sendable {
        let message: String
    }

    @MainActor
    private static func requestImage(for asset: PHAsset) async -> Result<UIImage, AnalysisFailure> {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .exact
        options.isNetworkAccessAllowed = true
        options.isSynchronous = false
        let box = RequestBox()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Result<UIImage, AnalysisFailure>, Never>) in
                let requestID = PHImageManager.default().requestImage(
                    for: asset,
                    targetSize: CGSize(width: analysisPixelSize, height: analysisPixelSize),
                    contentMode: .aspectFit,
                    options: options
                ) { image, info in
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if degraded { return }
                    if let image {
                        box.finish(continuation, .success(image))
                    } else if (info?[PHImageCancelledKey] as? Bool) == true {
                        box.finish(continuation, .failure(.init(message: "분석이 취소되었습니다.")))
                    } else {
                        let message = (info?[PHImageErrorKey] as? NSError)?.localizedDescription
                            ?? "이미지를 불러오지 못했습니다. iCloud 다운로드와 사진 접근 권한을 확인해 주세요."
                        box.finish(continuation, .failure(.init(message: message)))
                    }
                }
                box.requestID = requestID
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// PhotoKit 콜백이 여러 번 와도 continuation을 한 번만 재개한다.
    private final class RequestBox: @unchecked Sendable {
        private let lock = NSLock()
        private var finished = false
        var requestID: PHImageRequestID = PHInvalidImageRequestID

        func finish(_ continuation: CheckedContinuation<Result<UIImage, AnalysisFailure>, Never>,
                    _ result: Result<UIImage, AnalysisFailure>) {
            lock.lock()
            let alreadyFinished = finished
            finished = true
            lock.unlock()
            if !alreadyFinished { continuation.resume(returning: result) }
        }

        func cancel() {
            lock.lock()
            let id = requestID
            lock.unlock()
            if id != PHInvalidImageRequestID { PHImageManager.default().cancelImageRequest(id) }
        }
    }

    static func thumbnail(forFileAt url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map { UIImage(cgImage: $0) }
    }

    static func downscaled(_ image: UIImage, to maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide, longest > 0 else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }
}

/// 화면이 pop·탭 전환으로 사라져도 입력·분석 결과·사용자가 정한 N을 유지하는 사진 선별 세션.
@MainActor
final class PhotoSelectionSession: ObservableObject {
    static let shared = PhotoSelectionSession()

    @Published private(set) var items: [PhotoSelectionItem] = []
    /// 동영상이라 선별에서 제외한 입력의 이름. 개수와 함께 화면에 계속 보인다.
    @Published private(set) var excludedVideoNames: [String] = []
    @Published private(set) var recommendation: PhotoSelectionRecommendation?
    @Published private(set) var outcome: Result<PhotoSelectionOutcome, PhotoSelectionError>?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var usedDINO = false
    @Published private(set) var skippedReasons: [String] = []
    @Published var notice: String?
    /// 사용자가 직접 정한 N. nil이면 추천값을 따른다. 추천이 바뀌어도 이 값은 절대 덮어쓰지 않는다.
    @Published private(set) var explicitCount: Int?

    private var nextSerial = 0
    private var pairIndex = PhotoSelectionPairIndex()
    private var dinoEmbeddings: [Int: [Float]] = [:]
    private var analysisTask: Task<Void, Never>?
    private var rerunRequested = false
    private var loadingInputs = 0

    var isLoadingInputs: Bool { loadingInputs > 0 }
    var readyItems: [PhotoSelectionItem] { items.filter(\.isReady) }
    var failedItems: [PhotoSelectionItem] { items.filter { if case .failed = $0.state { true } else { false } } }
    var effectiveCount: Int? { explicitCount ?? recommendation?.recommendedCount }

    // MARK: 입력 추가

    func addAssets(identifiers: [String]) {
        loadingInputs += 1
        defer { loadingInputs -= 1 }
        for identifier in identifiers {
            let key = "asset:\(identifier)"
            guard !items.contains(where: { $0.id == key }) else { continue }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                append(key: key, name: "사진 보관함 항목", source: .asset(identifier), ownsFile: false,
                       state: .failed("사진 보관함에서 이 항목을 찾지 못했습니다. 접근 권한을 확인해 주세요."))
                continue
            }
            let name = LocalPhotoLibraryCalendarService.originalFilename(for: asset) ?? "사진"
            if asset.mediaType == .video {
                excludedVideoNames.append(name)
                continue
            }
            append(key: key, name: name, source: .asset(identifier), ownsFile: false)
        }
        analyzePending()
    }

    func addPickerItems(_ pickerItems: [PhotosPickerItem]) async {
        loadingInputs += 1
        defer { loadingInputs -= 1 }
        let canReadAssets = LocalPhotoLibraryCalendarService.authorizationStatus == .authorized
            || LocalPhotoLibraryCalendarService.authorizationStatus == .limited
        for pickerItem in pickerItems {
            if let identifier = pickerItem.itemIdentifier, canReadAssets {
                addAssets(identifiers: [identifier])
                continue
            }
            do {
                let loaded = try await LocalPhotoLibrarySelectionLoader.load(item: pickerItem)
                if loaded.isVideo {
                    try? FileManager.default.removeItem(at: loaded.url)
                    excludedVideoNames.append(loaded.url.lastPathComponent)
                    continue
                }
                let key = "pick:\(UUID().uuidString)"
                append(key: key, name: "사진-\(items.count + 1).\(loaded.url.pathExtension)", source: .file(loaded.url), ownsFile: true)
            } catch {
                append(key: "pick:\(UUID().uuidString)", name: "선택한 사진", source: .asset(""), ownsFile: false,
                       state: .failed("사진을 불러오지 못했습니다. iCloud 다운로드와 사진 접근 권한을 확인해 주세요."))
            }
        }
        analyzePending()
    }

    func addFiles(_ urls: [URL]) async {
        loadingInputs += 1
        defer { loadingInputs -= 1 }
        for url in urls {
            let key = "file:" + url.standardizedFileURL.path
            guard !items.contains(where: { $0.id == key }) else { continue }
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true {
                excludedVideoNames.append(url.lastPathComponent)
                continue
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let destination = LocalPhotoLibrarySelectionLoader.temporaryURL(fileExtension: url.pathExtension)
            do {
                try FileManager.default.copyItem(at: url, to: destination)
                if type?.conforms(to: .image) == true {
                    append(key: key, name: url.lastPathComponent, source: .file(destination), ownsFile: true)
                } else {
                    try? FileManager.default.removeItem(at: destination)
                    append(key: key, name: url.lastPathComponent, source: .asset(""), ownsFile: false,
                           state: .failed("이미지 파일이 아닙니다."))
                }
            } catch {
                append(key: key, name: url.lastPathComponent, source: .asset(""), ownsFile: false,
                       state: .failed("파일을 가져오지 못했습니다: \(error.localizedDescription)"))
            }
        }
        analyzePending()
    }

    /// 공유 확장이 남긴 이미지 선별 배치를 입력에 올린다. 이미 올린 항목은 건너뛰고 동영상은 개수만 남긴다.
    @discardableResult
    func loadSharedBatches() -> Int {
        let before = items.count
        defer { analyzePending() }
        for batch in ShareIntentStaging.pendingBatches() where batch.intent == .photoSelect {
            for reason in batch.skippedReasons where !skippedReasons.contains(reason) { skippedReasons.append(reason) }
            var consumedVideos: Set<UUID> = []
            for item in batch.items {
                let key = "staged:\(batch.id.uuidString):\(item.id.uuidString)"
                guard !items.contains(where: { $0.id == key }) else { continue }
                if item.isVideo {
                    excludedVideoNames.append(item.originalFilename)
                    consumedVideos.insert(item.id)
                    continue
                }
                guard let url = try? ShareIntentStaging.fileURL(batchID: batch.id, item: item) else { continue }
                append(key: key, name: item.originalFilename,
                       source: .staged(batchID: batch.id, itemID: item.id, url: url), ownsFile: false)
            }
            // 쓰지 않는 동영상 복사본만 정리한다. 이미지 입력은 사용자가 마치거나 비울 때까지 남는다.
            if !consumedVideos.isEmpty { try? ShareIntentStaging.markConsumed(batchID: batch.id, itemIDs: consumedVideos) }
        }
        return items.count - before
    }

    private func append(key: String, name: String, source: PhotoSelectionItem.Source, ownsFile: Bool,
                        state: PhotoSelectionItem.State = .queued) {
        items.append(PhotoSelectionItem(id: key, serial: nextSerial, name: name, source: source, ownsFile: ownsFile, state: state))
        nextSerial += 1
    }

    // MARK: 분석

    func analyzePending() {
        guard analysisTask == nil else { rerunRequested = true; return }
        guard items.contains(where: { $0.state == .queued }) else {
            Task { await rebuildRecommendation() }
            return
        }
        isAnalyzing = true
        analysisTask = Task { [weak self] in
            guard let self else { return }
            await self.runAnalysis()
        }
    }

    /// 진행 중인 분석을 멈춘다. 분석하던 항목은 대기로 돌리고 입력·결과·N은 그대로 둔다.
    func cancelAnalysis() {
        analysisTask?.cancel()
    }

    private func runAnalysis() async {
        repeat {
            rerunRequested = false
            let targets = items.filter { $0.state == .queued }.map(\.id)
            for id in targets {
                if Task.isCancelled { break }
                await analyzeOne(id: id)
            }
            if Task.isCancelled { break }
            await rebuildRecommendation()
        } while rerunRequested && !Task.isCancelled
        for index in items.indices where items[index].state == .analyzing { items[index].state = .queued }
        isAnalyzing = false
        analysisTask = nil
        if Task.isCancelled { await rebuildRecommendation() }
    }

    private func analyzeOne(id: String) async {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].state == .queued else { return }
        items[index].state = .analyzing
        let source = items[index].source
        let result: Result<PhotoSelectionAnalyzer.Analysis, PhotoSelectionAnalyzer.AnalysisFailure>
        switch source {
        case let .asset(identifier):
            result = await PhotoSelectionAnalyzer.analyze(assetIdentifier: identifier)
        case let .file(url), let .staged(_, _, url):
            result = await PhotoSelectionAnalyzer.analyze(fileAt: url)
        }
        guard let current = items.firstIndex(where: { $0.id == id }) else { return }
        if Task.isCancelled {
            items[current].state = .queued
            return
        }
        switch result {
        case let .success(analysis):
            items[current].measurement = analysis.measurement
            items[current].thumbnail = analysis.thumbnail
            items[current].state = .ready
        case let .failure(failure):
            items[current].state = .failed(failure.message)
        }
    }

    func retry(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), case .failed = items[index].state else { return }
        items[index].state = .queued
        analyzePending()
    }

    func retryAllFailed() {
        for index in items.indices { if case .failed = items[index].state { items[index].state = .queued } }
        analyzePending()
    }

    // MARK: 추천과 선택

    private func rebuildRecommendation() async {
        let ready = readyItems
        var index = pairIndex
        let have = index.serials
        let readySerials = Set(ready.map(\.serial))
        for stale in have.subtracting(readySerials) { index.remove(serial: stale) }
        let additions = ready.compactMap { item -> (Int, VideoTrailerPhotoQuality.Measurement)? in
            guard !index.serials.contains(item.serial), let measurement = item.measurement else { return nil }
            return (item.serial, measurement)
        }
        if !additions.isEmpty || have != readySerials {
            let base = index
            index = await Task.detached(priority: .userInitiated) {
                var updated = base
                for (serial, measurement) in additions {
                    if Task.isCancelled { break }
                    updated.insert(serial: serial, measurement: measurement)
                }
                return updated
            }.value
        }
        pairIndex = index
        await refreshDINO(for: ready)
        recomputeRecommendation()
    }

    /// 모든 준비된 입력이 파일이고 DINO 모델이 있을 때만 DINO를 AND 조건으로 더한다. 하나라도 못 만들면 쓰지 않는다.
    private func refreshDINO(for ready: [PhotoSelectionItem]) async {
        usedDINO = false
        guard !ready.isEmpty, ready.allSatisfy({ $0.source.fileURL != nil }) else { return }
        guard #available(iOS 17, macOS 14, macCatalyst 17, *) else { return }
        let missing = ready.compactMap { item -> (id: Int, url: URL)? in
            guard dinoEmbeddings[item.serial] == nil, let url = item.source.fileURL else { return nil }
            return (item.serial, url)
        }
        if !missing.isEmpty {
            guard let computed = try? await VideoTrailerPhotoSimilarityGate.embeddings(for: missing) else { return }
            for (serial, vector) in computed { dinoEmbeddings[serial] = vector }
        }
        usedDINO = ready.allSatisfy { dinoEmbeddings[$0.serial] != nil }
    }

    private func engineInputs() -> (candidates: [PhotoSelectionCandidate], pairs: [PhotoSelectionPair]) {
        let ready = readyItems
        let candidates = ready.compactMap { item -> PhotoSelectionCandidate? in
            guard let m = item.measurement else { return nil }
            let aesthetics = m.rawAestheticsScore.flatMap { $0.isFinite ? min(1, max(0, ($0 + 1) / 2)) : nil }
            return PhotoSelectionCandidate(index: item.serial, sharpness: m.sharpnessScore, exposure: m.exposureScore,
                                           pixelCount: m.pixelCount, aesthetics: aesthetics)
        }
        let readySerials = Set(candidates.map(\.index))
        var pairs: [PhotoSelectionPair] = []
        for (key, closeness) in pairIndex.closeness where readySerials.contains(key.low) && readySerials.contains(key.high) {
            if usedDINO {
                guard let a = dinoEmbeddings[key.low], let b = dinoEmbeddings[key.high],
                      let distance = VideoTrailerPhotoSimilarityGate.cosineDistance(a, b),
                      distance <= VideoTrailerPhotoSimilarityGate.maximumCosineDistance else { continue }
            }
            pairs.append(PhotoSelectionPair(first: key.low, second: key.high, distance: 1 - closeness))
        }
        return (candidates, pairs)
    }

    private func recomputeRecommendation() {
        let inputs = engineInputs()
        recommendation = PhotoSelectionEngine.recommend(candidates: inputs.candidates, pairs: inputs.pairs)
        refreshOutcome()
    }

    private func refreshOutcome() {
        guard let count = effectiveCount, recommendation != nil else { outcome = nil; return }
        let inputs = engineInputs()
        outcome = PhotoSelectionEngine.select(candidates: inputs.candidates, pairs: inputs.pairs, count: count)
    }

    /// nil이면 추천값을 따른다. 사용자가 입력한 값은 이후 어떤 재분석에도 바뀌지 않는다.
    func setExplicitCount(_ value: Int?) {
        explicitCount = value
        refreshOutcome()
    }

    var selectedItems: [PhotoSelectionItem] {
        guard case let .success(result)? = outcome else { return [] }
        let selected = Set(result.selectedIndices)
        return readyItems.filter { selected.contains($0.serial) }
    }

    func role(of item: PhotoSelectionItem) -> PhotoSelectionRole? {
        guard case let .success(result)? = outcome else { return nil }
        return result.roleByIndex[item.serial]
    }

    func reason(for item: PhotoSelectionItem) -> String? {
        guard let recommendation else { return nil }
        guard let role = role(of: item) else { return nil }
        let group = recommendation.groups.first { $0.members.contains(item.serial) }
        let groupSize = group?.members.count ?? 1
        switch role {
        case .groupRepresentative:
            var text = groupSize > 1 ? "비슷한 사진 \(groupSize)장 중 품질이 가장 좋은 대표" : "다른 사진과 구분되는 장면"
            if group?.isLowQuality == true { text += " · 품질이 낮음" }
            return text
        case .extraFromSimilarGroup:
            return "비슷한 장면에서 추가로 고른 사진"
        }
    }

    // MARK: 제거와 비우기

    func remove(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: index)
        release(item)
        dinoEmbeddings[item.serial] = nil
        Task { await rebuildRecommendation() }
    }

    /// 명시적 비우기. 앱이 만든 임시 파일과 공유 대기 복사본을 지운다. 사진 보관함 원본은 건드리지 않는다.
    func clearAll() {
        analysisTask?.cancel()
        for item in items { release(item) }
        items = []
        excludedVideoNames = []
        skippedReasons = []
        pairIndex = PhotoSelectionPairIndex()
        dinoEmbeddings = [:]
        recommendation = nil
        outcome = nil
        explicitCount = nil
        usedDINO = false
    }

    private func release(_ item: PhotoSelectionItem) {
        switch item.source {
        case let .file(url):
            if item.ownsFile { try? FileManager.default.removeItem(at: url) }
        case let .staged(batchID, itemID, _):
            try? ShareIntentStaging.markConsumed(batchID: batchID, itemIDs: [itemID])
        case .asset:
            break
        }
    }
}
