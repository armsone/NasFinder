import AVFoundation
import Photos
import SwiftUI
import UIKit

/// 사진 목록과 달력의 PhotoKit 읽기 경로. 원본은 변경하지 않고 실제 작업 때만 복사한다.
enum LocalPhotoLibraryCalendarService {
    enum ServiceError: LocalizedError {
        case accessDenied
        case resourceUnavailable

        var errorDescription: String? {
            switch self {
            case .accessDenied:
                "사진 보관함 접근 권한이 없습니다."
            case .resourceUnavailable:
                "선택한 항목을 읽을 수 없습니다."
            }
        }
    }

    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    /// `.readOnly` 권한 단계가 없어 `.readWrite`를 요청하지만 모든 보관함 처리는 읽기만 한다.
    static func requestAccess() async -> PHAuthorizationStatus {
        let current = authorizationStatus
        guard current == .notDetermined else { return current }
        return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    static func mediaCounts(
        in month: Date,
        calendar: Calendar,
        progress: (@MainActor (Double) -> Void)? = nil
    ) -> [Date: Int] {
        guard let interval = calendar.dateInterval(of: .month, for: month)
        else { return [:] }

        let options = PHFetchOptions()
        options.predicate = mediaPredicate(from: interval.start, to: interval.end)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        let assets = PHAsset.fetchAssets(with: options)
        var counts: [Date: Int] = [:]
        let totalCount = max(assets.count, 1)
        assets.enumerateObjects { asset, index, _ in
            guard let creationDate = asset.creationDate else { return }
            let day = calendar.startOfDay(for: creationDate)
            counts[day, default: 0] += 1
            guard index % 25 == 0 || index == assets.count - 1 else { return }
            Task { @MainActor in progress?(Double(index + 1) / Double(totalCount)) }
        }
        if assets.count == 0 {
            Task { @MainActor in progress?(1) }
        }
        return counts
    }

    static func assets(on day: Date, calendar: Calendar) -> [PHAsset] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start)
        else { return [] }

        let options = PHFetchOptions()
        options.predicate = mediaPredicate(from: start, to: end)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]

        var assets: [PHAsset] = []
        PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    static func assets(withIdentifiers identifiers: [String]) -> [PHAsset] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        var result: [PHAsset] = []
        PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: options).enumerateObjects { asset, _, _ in
            if asset.mediaType == .image || asset.mediaType == .video { result.append(asset) }
        }
        return result
    }

    static func closestMediaDate(to targetDate: Date, calendar: Calendar) -> Date? {
        let target = calendar.startOfDay(for: targetDate)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: target) else { return nil }
        if mediaAssetDate(from: target, to: nextDay, ascending: true, calendar: calendar) != nil { return target }
        let previous = previousMediaDate(before: target, calendar: calendar)
        let next = mediaAssetDate(from: nextDay, to: .distantFuture, ascending: true, calendar: calendar)
        switch (previous, next) {
        case let (previous?, next?):
            return target.timeIntervalSince(previous) <= next.timeIntervalSince(target) ? previous : next
        case let (previous?, nil): return previous
        case let (nil, next?): return next
        default: return nil
        }
    }

    static func previousMediaDate(before date: Date, calendar: Calendar) -> Date? {
        mediaAssetDate(from: .distantPast, to: calendar.startOfDay(for: date), ascending: false, calendar: calendar)
    }

    private static func mediaAssetDate(from start: Date, to end: Date, ascending: Bool, calendar: Calendar) -> Date? {
        let options = PHFetchOptions()
        options.predicate = mediaPredicate(from: start, to: end)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: ascending)]
        options.fetchLimit = 1
        guard let date = PHAsset.fetchAssets(with: options).firstObject?.creationDate else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static func mediaPredicate(from start: Date, to end: Date) -> NSPredicate {
        NSPredicate(
            format: "creationDate >= %@ AND creationDate < %@ AND (mediaType == %d OR mediaType == %d)",
            start as NSDate,
            end as NSDate,
            PHAssetMediaType.image.rawValue,
            PHAssetMediaType.video.rawValue
        )
    }

    private static let imageManager = PHCachingImageManager()
    @MainActor private static let thumbnailCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 40 * 1024 * 1024
        return cache
    }()

    static func recentAssets() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: options)
    }

    @MainActor static func thumbnail(for asset: PHAsset, size: CGSize = CGSize(width: 240, height: 240)) async -> UIImage? {
        let key = "\(asset.localIdentifier):\(Int(size.width))x\(Int(size.height))" as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }
        let image: UIImage? = await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.resizeMode = .fast
            imageManager.requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { image, info in
                let degraded = info?[PHImageResultIsDegradedKey] as? Bool ?? false
                guard !degraded else { return }
                continuation.resume(returning: image)
            }
        }
        if let image {
            thumbnailCache.setObject(image, forKey: key, cost: Int(size.width * size.height * 4))
        }
        return image
    }

    /// Original filename as recorded by PhotoKit, falling back to a generated name
    /// only when the asset has no resource metadata at all.
    static func originalFilename(for asset: PHAsset) -> String? {
        PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    static func duration(for asset: PHAsset) -> TimeInterval? {
        asset.mediaType == .video ? asset.duration : nil
    }

    /// Copies the original image or video data for `asset` into a new sandboxed
    /// temporary file, preserving the original filename and extension. The source
    /// asset itself is never modified.
    static func exportOriginal(for asset: PHAsset) async throws -> (url: URL, isVideo: Bool) {
        let resources = PHAssetResource.assetResources(for: asset)
        let isVideo = asset.mediaType == .video
        let resource = isVideo
            ? resources.first(where: { $0.type == .video || $0.type == .fullSizeVideo })
            : resources.first(where: { $0.type == .photo || $0.type == .fullSizePhoto })
        guard let resource else { throw ServiceError.resourceUnavailable }

        return (try await exportResource(resource, fallbackExtension: isVideo ? "mov" : "jpg"), isVideo)
    }

    /// Live Photo의 동영상 원본을 읽는다. 편집 준비 전용이며 보관함·복사 경로는 바꾸지 않는다.
    static func exportPairedVideo(for asset: PHAsset) async throws -> URL {
        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = resources.first(where: { $0.type == .pairedVideo || $0.type == .fullSizePairedVideo }) else {
            throw ServiceError.resourceUnavailable
        }
        return try await exportResource(resource, fallbackExtension: "mov")
    }

    private static func exportResource(_ resource: PHAssetResource, fallbackExtension: String) async throws -> URL {
        let originalExtension = URL(fileURLWithPath: resource.originalFilename).pathExtension
        let fileExtension = originalExtension.isEmpty ? fallbackExtension : originalExtension
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nasfinder-calendar-\(UUID().uuidString)")
            .appendingPathExtension(fileExtension)

        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true

        let request = PhotoLibraryResourceExport(url: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                request.start(resource: resource, options: options, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
        }
        return url
    }
}

/// 썸네일은 보이는 셀에서만 비동기 요청한다. 사진·달력에서 같은 캐시와 선택 표시를 쓴다.
struct LocalPhotoLibraryAssetCell: View {
    let asset: PHAsset
    let isSelected: Bool
    let onToggle: () -> Void
    var size: CGFloat = ui(100)
    var showsSelectionIndicator = true
    @State private var thumbnail: UIImage?

    var body: some View {
        Button(action: onToggle) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
                    else { Rectangle().fill(.secondary.opacity(0.15)).overlay(ProgressView()) }
                }
                .frame(width: size, height: size).clipped()
                if asset.mediaType == .video {
                    Text(durationLabel).font(.system(size: min(ui(11), max(ui(6), size * 0.18)))).foregroundStyle(.white)
                        .padding(ui(3)).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: ui(4)))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(ui(3))
                }
                if showsSelectionIndicator {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(.white, isSelected ? Color.accentColor : Color.black.opacity(0.3))
                        .padding(ui(4))
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: ui(10)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(asset.mediaType == .video ? "영상 \(durationLabel)" : "사진")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .task(id: asset.localIdentifier) {
            thumbnail = nil
            let image = await LocalPhotoLibraryCalendarService.thumbnail(for: asset, size: CGSize(width: min(max(size * 2, 100), 720), height: min(max(size * 2, 100), 720)))
            if !Task.isCancelled { thumbnail = image }
        }
    }
    private var durationLabel: String {
        let seconds = asset.duration.isFinite ? max(0, Int(asset.duration)) : 0
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// PhotoKit 요청 취소와 임시 파일 정리를 한 곳에서 직렬화한다.
private final class PhotoLibraryResourceExport: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var requestID: PHAssetResourceDataRequestID?
    private var continuation: CheckedContinuation<Void, Error>?
    private var file: FileHandle?
    private var finished = false

    init(url: URL) { self.url = url }

    func start(resource: PHAssetResource, options: PHAssetResourceRequestOptions,
               continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        do {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
                throw LocalPhotoLibraryCalendarService.ServiceError.resourceUnavailable
            }
            file = try FileHandle(forWritingTo: url)
            lock.unlock()
        } catch {
            lock.unlock()
            finish(error: error)
            return
        }
        let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { [self] data in
            lock.lock()
            guard !finished else { lock.unlock(); return }
            do { try file?.write(contentsOf: data); lock.unlock() }
            catch { lock.unlock(); finish(error: error) }
        } completionHandler: { [self] error in
            finish(error: error)
        }
        lock.lock()
        let shouldCancel = finished
        if !finished { requestID = id }
        lock.unlock()
        if shouldCancel { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() { finish(error: CancellationError()) }

    private func finish(error: Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let completion = continuation
        continuation = nil
        let id = requestID
        requestID = nil
        try? file?.close()
        file = nil
        lock.unlock()
        if let error {
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
            try? FileManager.default.removeItem(at: url)
            completion?.resume(throwing: error)
        } else {
            completion?.resume()
        }
    }
}

enum NasFinderKoreanHolidayService {
    private static let cacheKey = "nasFinderKoreanHolidayJSON.v1"
    private static let endpoint =
        "https://holidays.hyunbin.page/basic.json"

    static func cachedHolidayNames(for year: Int, calendar: Calendar)
        -> [Date: String]
    {
        holidayNames(
            from: cachedHolidayMap(),
            year: year,
            calendar: calendar
        )
    }

    static func refreshedHolidayNames(for year: Int, calendar: Calendar)
        async -> [Date: String]
    {
        do {
            let holidayMap = try await fetchHolidayMap()
            cache(holidayMap)
            return holidayNames(
                from: holidayMap,
                year: year,
                calendar: calendar
            )
        } catch {
            return cachedHolidayNames(for: year, calendar: calendar)
        }
    }

    private static func fetchHolidayMap() async throws
        -> [String: [String]]
    {
        guard let url = URL(string: endpoint) else { return [:] }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else { return [:] }

        return try decodeHolidayMap(from: data)
    }

    private static func cachedHolidayMap() -> [String: [String]] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let dates = try? decodeHolidayMap(from: data)
        else { return [:] }
        return dates
    }

    private static func cache(_ holidayMap: [String: [String]]) {
        guard let data = try? JSONEncoder().encode(holidayMap) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private static func decodeHolidayMap(from data: Data) throws
        -> [String: [String]]
    {
        if let years = try? JSONDecoder()
            .decode([String: [String: [String]]].self, from: data) {
            return years.values.reduce(into: [String: [String]]()) {
                result,
                holidays in
                holidays.forEach { date, names in
                    result[date] = names
                }
            }
        }

        if let dates = try? JSONDecoder().decode([String: [String]].self, from: data) {
            return dates
        }

        return try JSONDecoder()
            .decode([String: String].self, from: data)
            .mapValues { [$0] }
    }

    private static func holidayNames(
        from holidayMap: [String: [String]],
        year: Int,
        calendar: Calendar
    ) -> [Date: String] {
        let prefix = "\(year)-"
        return holidayMap.reduce(into: [Date: String]()) { result, item in
            let key = item.key
            guard key.hasPrefix(prefix) else { return }
            let parts = key.split(separator: "-").compactMap {
                Int(String($0))
            }
            guard parts.count == 3 else { return }
            guard let date = calendar.date(
                from: DateComponents(
                    year: parts[0],
                    month: parts[1],
                    day: parts[2]
                )
            ) else { return }
            guard let name = item.value.first else { return }
            result[calendar.startOfDay(for: date)] = name
        }
    }
}
