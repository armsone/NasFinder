import AVFoundation
import Foundation
import UIKit

/// 컬렉션에 등록된 완성 영상 한 편. 편집 프로젝트(편집본)와는 별개이며 프로젝트를 지워도 남는다.
struct CollectedVideo: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var videoFilename: String
    var posterFilename: String
    let createdAt: Date
    var duration: Double
    var byteCount: Int64
    var isPinned: Bool
    /// 이 영상을 만든 편집본(TrailerDraftEntry.id). 편집본이 남아 있으면 다시 열 수 있다.
    var sourceProjectID: UUID?
    /// 외부에서 가져온 영상인지. 가져온 영상은 새 제작에서 클립 한 개로만 쓴다.
    var isImported: Bool
    /// 앱 안에 복사하지 않고 사용자가 고른 원본 파일을 가리키는 보안 범위 북마크. 있으면 이 항목은 "원본 참조"이며
    /// `videoFilename`은 비어 있다. 컬렉션은 이 원본을 읽기만 하고 바꾸거나 지우지 않는다.
    var referenceBookmark: Data? = nil
    var referenceName: String? = nil

    var isReference: Bool { referenceBookmark != nil }
}

/// 원본 참조 항목의 현재 상태. 복사본 항목은 항상 `.ready`다.
enum CollectionReferenceState: Equatable {
    case ready
    /// 북마크는 풀리지만 원본이 이동·삭제됐거나 저장 장치가 연결돼 있지 않다.
    case missing(String)
    /// 북마크 자체를 더는 풀 수 없다. 원본을 다시 골라야 한다.
    case needsReselect(String)

    var message: String? {
        switch self {
        case .ready: nil
        case .missing(let text), .needsReselect(let text): text
        }
    }
}

/// 추천 썸네일 후보 한 장. 점수는 선명도·노출·해상도로 계산한 값이다(학습 모델이 아니다).
struct PosterCandidate: Identifiable, Equatable {
    let id = UUID()
    let data: Data
    let time: Double
    let score: Double
}

enum CollectionCompressionOption: String, CaseIterable, Identifiable {
    case p1080, p720, p540
    var id: String { rawValue }
    var title: String {
        switch self {
        case .p1080: "1080p 고화질"
        case .p720: "720p 절약"
        case .p540: "540p 최소"
        }
    }
    fileprivate var preset: String {
        switch self {
        case .p1080: AVAssetExportPreset1920x1080
        case .p720: AVAssetExportPreset1280x720
        case .p540: AVAssetExportPreset960x540
        }
    }
}

/// 컬렉션 저장소. 개수 제한과 자동 삭제가 없다. 영상과 포스터는 앱이 소유한 복사본이며
/// 삭제·압축은 이 복사본에만 적용하고 원본은 읽기만 한다. 성공한 완성 파일만 등록한다.
@MainActor
final class MovieCollectionStore: ObservableObject {
    static let shared = MovieCollectionStore()

    @Published private(set) var videos: [CollectedVideo] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var referenceStates: [UUID: CollectionReferenceState] = [:]
    /// 참조 항목을 재생·공유하려고 열어 둔 보안 범위 접근. 제거하거나 다시 풀 때 닫는다.
    private var accessing: [UUID: URL] = [:]

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MovieCollection", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([CollectedVideo].self, from: data) {
            // 파일이 사라진 항목도 목록에서 지우지 않는다. 복사본이 없으면 화면에서 사유를 보여 준다.
            videos = decoded
        } else if FileManager.default.fileExists(atPath: indexURL.path) {
            // 읽지 못한 인덱스는 다음 저장이 덮어쓰기 전에 따로 보관한다.
            let backup = base.appendingPathComponent("index.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: indexURL, to: backup)
            errorMessage = "컬렉션 목록을 읽지 못해 원본을 따로 보관했습니다."
        }
    }

    func videoURL(_ video: CollectedVideo) -> URL {
        if video.isReference { return accessing[video.id] ?? directory.appendingPathComponent("missing-reference") }
        return directory.appendingPathComponent(video.videoFilename)
    }

    /// 지금 재생·공유할 수 있는 실제 파일 주소. 없으면 nil.
    func playbackURL(_ video: CollectedVideo) -> URL? {
        let url = videoURL(video)
        if video.isReference, referenceStates[video.id] != .ready { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func state(of video: CollectedVideo) -> CollectionReferenceState {
        if video.isReference { return referenceStates[video.id] ?? .missing("확인하는 중입니다.") }
        return playbackURL(video) == nil ? .missing("앱 안의 영상 파일을 찾을 수 없습니다.") : .ready
    }
    func posterURL(_ video: CollectedVideo) -> URL { directory.appendingPathComponent(video.posterFilename) }

    /// 고정된 영상이 앞에, 그다음은 사용자가 정한 순서.
    var ordered: [CollectedVideo] { videos.filter(\.isPinned) + videos.filter { !$0.isPinned } }

    func clearError() { errorMessage = nil }

    // MARK: 등록

    /// 완성된 영상 파일을 등록한다. 기본은 앱 소유 복사본이며, `asReference`일 때만 사용자가 고른 원본의 보안 범위
    /// 북마크를 저장한다. 읽을 수 없거나 길이가 0이면 등록하지 않는다. 파일·포스터는 새 이름으로 먼저 만들고,
    /// 인덱스 저장까지 성공한 뒤에야 목록에 넣는다. 저장에 실패하면 이번에 만든 파일만 지우고 이전 목록을 유지한다.
    @discardableResult
    func add(from source: URL, title: String, posterData: Data? = nil,
             sourceProjectID: UUID? = nil, isImported: Bool, asReference: Bool = false) async -> CollectedVideo? {
        let id = UUID()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        var videoName = ""
        var bookmark: Data?
        var playable = source
        var created: [URL] = []
        func rollback() { for url in created { try? FileManager.default.removeItem(at: url) } }

        if asReference {
            do { bookmark = try Self.makeBookmark(for: source) } catch {
                errorMessage = "원본 위치를 기억하지 못했습니다: \(error.localizedDescription)"
                return nil
            }
        } else {
            let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension
            videoName = "\(id.uuidString).\(ext)"
            let destination = directory.appendingPathComponent(videoName)
            do {
                try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: source, to: destination)
                }.value
            } catch {
                try? FileManager.default.removeItem(at: destination)
                errorMessage = "컬렉션에 복사하지 못했습니다: \(error.localizedDescription)"
                return nil
            }
            created.append(destination)
            playable = destination
        }
        let asset = AVURLAsset(url: playable)
        let seconds = (try? await asset.load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else {
            rollback()
            errorMessage = "재생할 수 없는 영상이라 컬렉션에 등록하지 않았습니다."
            return nil
        }
        let poster: Data
        if let posterData {
            poster = posterData
        } else if let frame = await Self.frames(of: asset, count: 1, duration: seconds).first {
            poster = frame
        } else {
            rollback()
            errorMessage = "영상에서 포스터를 만들지 못했습니다."
            return nil
        }
        let posterName = "\(id.uuidString).jpg"
        let posterURL = directory.appendingPathComponent(posterName)
        do {
            try poster.write(to: posterURL, options: .atomic)
            created.append(posterURL)
        } catch {
            rollback()
            errorMessage = "포스터를 저장하지 못했습니다: \(error.localizedDescription)"
            return nil
        }
        let size = (try? playable.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let video = CollectedVideo(
            id: id, title: title, videoFilename: videoName, posterFilename: posterName,
            createdAt: Date(), duration: seconds, byteCount: size, isPinned: false,
            sourceProjectID: sourceProjectID, isImported: isImported,
            referenceBookmark: bookmark, referenceName: asReference ? source.lastPathComponent : nil)
        let previous = videos
        videos.append(video)
        guard save() else {
            videos = previous
            rollback()
            return nil
        }
        errorMessage = nil
        if asReference { await refreshReferences(ids: [id]) }
        return video
    }

    // MARK: 원본 참조

    private static func makeBookmark(for url: URL) throws -> Data {
        #if targetEnvironment(macCatalyst)
        return try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private nonisolated static func resolveBookmark(_ data: Data) -> (url: URL?, stale: Bool, error: String?) {
        var stale = false
        do {
            #if targetEnvironment(macCatalyst)
            let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
            #else
            let options: URL.BookmarkResolutionOptions = []
            #endif
            let url = try URL(resolvingBookmarkData: data, options: options, relativeTo: nil, bookmarkDataIsStale: &stale)
            return (url, stale, nil)
        } catch {
            return (nil, false, error.localizedDescription)
        }
    }

    /// 참조 항목의 원본이 아직 열리는지 다시 확인한다. 실패해도 항목은 지우지 않고 상태만 바꾼다.
    func refreshReferences(ids: Set<UUID>? = nil) async {
        for video in videos where video.isReference && (ids?.contains(video.id) ?? true) {
            guard let data = video.referenceBookmark else { continue }
            let resolved = await Task.detached { Self.resolveBookmark(data) }.value
            if let old = accessing[video.id] { old.stopAccessingSecurityScopedResource(); accessing[video.id] = nil }
            guard let url = resolved.url else {
                referenceStates[video.id] = .needsReselect("저장된 원본 위치를 더 이상 열 수 없습니다. 원본을 다시 선택해 주세요.")
                continue
            }
            _ = url.startAccessingSecurityScopedResource()
            guard FileManager.default.fileExists(atPath: url.path) else {
                url.stopAccessingSecurityScopedResource()
                referenceStates[video.id] = .missing("원본 파일이 이동·삭제됐거나 저장 장치·네트워크가 연결돼 있지 않습니다. 연결한 뒤 다시 확인하거나 원본을 다시 선택해 주세요.")
                continue
            }
            accessing[video.id] = url
            referenceStates[video.id] = .ready
            if resolved.stale, let fresh = try? Self.makeBookmark(for: url) {
                update(video.id) { $0.referenceBookmark = fresh }
            }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
            if let size, size != video.byteCount { update(video.id) { $0.byteCount = size } }
        }
    }

    /// 사용자가 다시 고른 원본으로 참조를 바꾼다. 재생할 수 있는 영상일 때만 바꾸고, 실패하면 이전 참조를 유지한다.
    @discardableResult
    func reselectReference(_ id: UUID, to source: URL) async -> Bool {
        guard videos.contains(where: { $0.id == id }) else { return false }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let seconds = (try? await AVURLAsset(url: source).load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else {
            errorMessage = "다시 고른 파일을 재생할 수 없어 이전 연결을 그대로 두었습니다."
            return false
        }
        guard let bookmark = try? Self.makeBookmark(for: source) else {
            errorMessage = "원본 위치를 기억하지 못해 이전 연결을 그대로 두었습니다."
            return false
        }
        let name = source.lastPathComponent
        // 인덱스에 기록된 경우에만 새 참조로 전환한다. 실패하면 이전 참조·열린 접근을 그대로 둔다.
        guard commit(id, { $0.referenceBookmark = bookmark; $0.referenceName = name; $0.duration = seconds }) else {
            return false
        }
        await refreshReferences(ids: [id])
        return true
    }

    /// 참조 항목을 앱 안 복사본으로 바꾼다. 복사와 확인이 끝난 뒤에만 전환하며 원본은 건드리지 않는다.
    @discardableResult
    func convertToCopy(_ id: UUID) async -> Bool {
        guard let video = videos.first(where: { $0.id == id }), video.isReference,
              let source = playbackURL(video) else {
            errorMessage = "원본에 연결할 수 없어 복사본을 만들 수 없습니다. 먼저 원본을 다시 연결해 주세요."
            return false
        }
        let name = "\(id.uuidString)-\(UUID().uuidString.prefix(8)).\(source.pathExtension.isEmpty ? "mp4" : source.pathExtension)"
        let destination = directory.appendingPathComponent(name)
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: source, to: destination)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = "복사하지 못했습니다. 원본 연결은 그대로입니다: \(error.localizedDescription)"
            return false
        }
        let seconds = (try? await AVURLAsset(url: destination).load(.duration).seconds) ?? 0
        guard seconds.isFinite, seconds > 0 else {
            try? FileManager.default.removeItem(at: destination)
            errorMessage = "복사본을 재생할 수 없어 원본 연결을 그대로 두었습니다."
            return false
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard commit(id, { $0.videoFilename = name; $0.referenceBookmark = nil; $0.referenceName = nil; $0.byteCount = size }) else {
            try? FileManager.default.removeItem(at: destination)
            return false
        }
        if let old = accessing[id] { old.stopAccessingSecurityScopedResource(); accessing[id] = nil }
        referenceStates[id] = nil
        return true
    }

    // MARK: 관리

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func togglePin(_ id: UUID) { update(id) { $0.isPinned.toggle() } }

    /// 같은 고정 구역 안에서 한 칸 이동한다.
    func move(_ id: UUID, by offset: Int) {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return }
        let pinned = videos[index].isPinned
        let peers = videos.indices.filter { videos[$0].isPinned == pinned }
        guard let position = peers.firstIndex(of: index) else { return }
        let target = position + offset
        guard peers.indices.contains(target) else { return }
        let previous = videos
        videos.swapAt(index, peers[target])
        if !save() { videos = previous }
    }

    /// 고른 포스터를 저장한다. 같은 이름의 새 파일을 원자적으로 교체하므로 쓰기에 실패해도 이전 포스터가 남는다.
    func setPoster(_ id: UUID, data: Data) {
        guard let video = videos.first(where: { $0.id == id }) else { return }
        do {
            try data.write(to: posterURL(video), options: .atomic)
            objectWillChange.send()
        } catch {
            errorMessage = "포스터를 바꾸지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 추천 썸네일 후보. 영상 길이를 고르게 나눈 장면을 `generation`마다 다른 위치에서 뽑고, 선명도·노출·해상도
    /// 점수가 높은 순으로 돌려준다. 학습된 Vision 모델은 쓰지 않고 기기 안에서만 처리한다.
    func posterCandidates(for video: CollectedVideo, generation: Int = 0, count: Int = 6) async -> [PosterCandidate] {
        guard let url = playbackURL(video) else { return [] }
        return await PosterCandidateGenerator.candidates(url: url, duration: video.duration, generation: generation, count: count)
    }

    /// 앱이 소유한 복사본(또는 원본 참조에서 새로 만든 압축본)을 새 파일로 압축한 뒤 성공했을 때만 전환한다.
    /// 출력이 더 작고 재생 가능할 때만 인덱스를 바꾸고, 실패·취소·검증 실패면 이전 파일과 메타데이터를 그대로 둔다.
    /// 참조 항목이면 원본은 읽기만 하고, 성공하면 이 항목이 앱 안 압축본으로 전환된다.
    func compress(_ id: UUID, option: CollectionCompressionOption) async -> Bool {
        guard let video = videos.first(where: { $0.id == id }) else { return false }
        guard let source = playbackURL(video) else {
            errorMessage = "원본 영상을 열 수 없어 압축할 수 없습니다. 연결을 확인해 주세요."
            return false
        }
        let finalName = "\(video.id.uuidString)-\(UUID().uuidString.prefix(8)).mp4"
        let output = directory.appendingPathComponent(finalName)
        guard let session = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: option.preset) else {
            errorMessage = "이 영상은 압축할 수 없습니다."
            return false
        }
        session.shouldOptimizeForNetworkUse = true
        do {
            try await session.export(to: output, as: .mp4)
            try Task.checkCancellation()
        } catch {
            try? FileManager.default.removeItem(at: output)
            errorMessage = error is CancellationError
                ? "압축을 취소했습니다. 기존 영상은 그대로입니다."
                : "압축하지 못했습니다. 기존 영상은 그대로입니다: \(error.localizedDescription)"
            return false
        }
        let newSize = (try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        // 참조 항목은 원본 크기를 기준으로 비교하고, 더 작지 않으면 새 복사본을 만들 이유가 없다.
        let newSeconds = (try? await AVURLAsset(url: output).load(.duration).seconds) ?? 0
        guard newSize > 0, newSize < video.byteCount, newSeconds.isFinite,
              newSeconds > 0, abs(newSeconds - video.duration) < max(1.5, video.duration * 0.05) else {
            try? FileManager.default.removeItem(at: output)
            errorMessage = "압축 결과가 더 작지 않거나 재생 검증을 통과하지 못해 기존 영상을 그대로 두었습니다."
            return false
        }
        let oldURL = video.isReference ? nil : source
        guard commit(id, {
            $0.videoFilename = finalName; $0.byteCount = newSize; $0.duration = newSeconds
            $0.referenceBookmark = nil; $0.referenceName = nil
        }) else {
            try? FileManager.default.removeItem(at: output)
            return false
        }
        // 새 메타데이터가 자리 잡은 뒤에만 이전 앱 복사본을 지운다. 참조의 원본은 지우지 않는다.
        if let oldURL, oldURL != output { try? FileManager.default.removeItem(at: oldURL) }
        if let old = accessing[id] { old.stopAccessingSecurityScopedResource(); accessing[id] = nil }
        referenceStates[id] = nil
        errorMessage = nil
        return true
    }

    /// 컬렉션에서 뺀다. 앱이 만든 복사본과 포스터, 참조 기록만 지우며 편집본과 외부 원본은 지우지 않는다.
    /// 인덱스 저장이 성공한 뒤에만 파일을 지운다.
    func remove(_ id: UUID) {
        guard let video = videos.first(where: { $0.id == id }) else { return }
        let previous = videos
        videos.removeAll { $0.id == id }
        guard save() else { videos = previous; return }
        if !video.isReference { try? FileManager.default.removeItem(at: directory.appendingPathComponent(video.videoFilename)) }
        try? FileManager.default.removeItem(at: posterURL(video))
        if let old = accessing[id] { old.stopAccessingSecurityScopedResource(); accessing[id] = nil }
        referenceStates[id] = nil
    }

    // MARK: 내부

    /// 값을 바꾸고 저장한다. 저장에 실패하면 이전 값으로 되돌리고 false.
    private func commit(_ id: UUID, _ change: (inout CollectedVideo) -> Void) -> Bool {
        guard let index = videos.firstIndex(where: { $0.id == id }) else { return false }
        let previous = videos
        change(&videos[index])
        guard save() else { videos = previous; return false }
        return true
    }

    private func update(_ id: UUID, _ change: (inout CollectedVideo) -> Void) { _ = commit(id, change) }

    /// `.atomic` 쓰기라 실패해도 기존 인덱스 파일은 그대로 남는다.
    @discardableResult
    private func save() -> Bool {
        do {
            try JSONEncoder().encode(videos).write(to: indexURL, options: .atomic)
            return true
        } catch {
            errorMessage = "컬렉션을 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }

    fileprivate static func frames(of asset: AVURLAsset, count: Int, duration: Double) async -> [Data] {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        var result: [Data] = []
        for index in 0..<max(count, 1) {
            let fraction = count == 1 ? 0.3 : (Double(index) + 0.5) / Double(count)
            let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
            if let image = try? await generator.image(at: time).image,
               let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) {
                result.append(data)
            }
        }
        return result
    }
}

/// 추천 썸네일 후보를 만든다. 기존 `VideoTrailerPhotoQuality`의 선명도·노출·해상도 점수를 재사용하며
/// Vision 미학 모델은 쓰지 않는다. 다시 만들 때마다(`generation`) 뽑는 위치가 달라져 다른 장면이 나온다.
enum PosterCandidateGenerator {
    static func candidates(url: URL, duration: Double, generation: Int, count: Int) async -> [PosterCandidate] {
        guard duration > 0 else { return [] }
        let sampleCount = max(count * 2, 8)
        // 황금비 위상으로 세대마다 겹치지 않는 위치를 고른다.
        let phase = (Double(generation) * 0.618_033_988).truncatingRemainder(dividingBy: 1)
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 1280)
        var scored: [PosterCandidate] = []
        for index in 0..<sampleCount {
            let fraction = min(0.98, max(0.02, (Double(index) + 0.15 + phase * 0.7) / Double(sampleCount)))
            let seconds = duration * fraction
            guard let image = try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image,
                  let data = UIImage(cgImage: image).jpegData(compressionQuality: 0.8) else { continue }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("poster-score-\(UUID().uuidString).jpg")
            defer { try? FileManager.default.removeItem(at: temp) }
            var score = 0.0
            if (try? data.write(to: temp)) != nil,
               let measured = await VideoTrailerPhotoQuality.measure(fileAt: temp, includeAesthetics: false) {
                score = measured.qualityScore
            }
            scored.append(PosterCandidate(data: data, time: seconds, score: score))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(count))
    }
}
