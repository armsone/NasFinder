import AVFoundation
import Foundation
import ImageIO

/// 재료함에 담긴 항목의 출처 종류. 같은 출처 안에서만 안정적인 식별자로 중복을 가린다.
enum MaterialSourceKind: String, Codable, Sendable {
    case nas = "NAS·클라우드"
    case phoneHard = "폰하드"
    case photoLibrary = "내 사진·영상"
    case systemFile = "기기 파일"
    case browserDownload = "웹 브라우저"
    case googlePhotos = "Google 포토"
}

enum MaterialAvailability: String, Codable, Sendable {
    /// 앱이 소유한 로컬 복사본이 있어 네트워크 없이 바로 쓸 수 있다.
    case localReady
    /// 출처에서 받아야 한다. 아직 받지 않았거나 받다가 멈췄다.
    case needsDownload
    /// 받으려 했으나 실패했다. 다시 시도하거나 제외할 수 있다.
    case unavailable
}

struct MaterialItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// 출처 안에서의 안정 식별자. 해시로 서로 다른 출처의 같은 파일을 추정하지 않는다.
    let sourceKey: String
    let sourceKind: MaterialSourceKind
    var name: String
    var isVideo: Bool
    var byteCount: Int64?
    var localFilename: String?
    var availability: MaterialAvailability
    var failureMessage: String?
    let addedAt: Date
    /// 원격 출처에서 다시 받기 위한 정보. 로컬 출처는 nil.
    var connectionID: UUID?
    var remotePath: String?
    var remoteIdentifier: String?
    var contentTypeIdentifier: String?
    var modifiedAt: Date?
}

/// 폴더·출처·앱 재시작을 넘어 유지되는 재료함. 항목은 사용자가 직접 빼기 전에는 지워지지 않고,
/// 영상 제작을 시작하거나 내보내도 비우지 않는다. 원본 파일은 읽기만 한다.
@MainActor
final class MaterialBasketStore: ObservableObject {
    static let shared = MaterialBasketStore()

    @Published private(set) var items: [MaterialItem] = []
    /// 항목별 내려받기 진행률(0...1). 저장하지 않는 화면 상태.
    @Published private(set) var progress: [UUID: Double] = [:]
    @Published private(set) var persistenceError: String?

    private let directory: URL
    private var indexURL: URL { directory.appendingPathComponent("index.json") }
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(directory: URL? = nil) {
        let base = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MaterialBasket", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        Self.removeStalePartials(in: base)
        load()
    }

    /// 이전 실행이 복사 도중 끊겨 남긴 `.partial-` 파일만 지운다. 인덱스와 완성 파일은 건드리지 않는다.
    private static func removeStalePartials(in directory: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(".partial-") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    var readyItems: [MaterialItem] { items.filter { $0.availability == .localReady && fileURL(for: $0) != nil } }

    func fileURL(for item: MaterialItem) -> URL? {
        guard let name = item.localFilename else { return nil }
        let url = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func contains(sourceKey: String) -> Bool { items.contains { $0.sourceKey == sourceKey } }

    // MARK: 담기

    /// 원격 항목을 담고 바로 내려받기를 시작한다. 중복 식별자는 건너뛴다.
    /// 인덱스에 실제로 기록된 개수만 돌려주고, 기록하지 못하면 아무것도 담지 않고 받기도 시작하지 않는다.
    @discardableResult
    func addRemote(_ remoteItems: [RemoteFileItem], service: any RemoteFileService,
                   kind: MaterialSourceKind) -> Int {
        var candidate = items
        var added: [UUID] = []
        for remote in remoteItems where !remote.isDirectory && remote.isTrailerEligible {
            guard !candidate.contains(where: { $0.sourceKey == remote.id }) else { continue }
            let item = MaterialItem(
                id: UUID(), sourceKey: remote.id, sourceKind: kind, name: remote.name,
                isVideo: remote.isVideo, byteCount: remote.size, localFilename: nil,
                availability: .needsDownload, failureMessage: nil, addedAt: Date(),
                connectionID: remote.connectionID, remotePath: remote.path,
                remoteIdentifier: remote.remoteIdentifier,
                contentTypeIdentifier: remote.contentTypeIdentifier, modifiedAt: remote.modifiedAt)
            candidate.append(item)
            added.append(item.id)
        }
        guard !added.isEmpty else { return 0 }
        guard commit(candidate) else { return 0 }
        for id in added { acquire(id, service: service) }
        return added.count
    }

    /// 담기 결과. 실패 사유는 사용자에게 그대로 보여 준다.
    enum AddResult: Equatable {
        case added
        case duplicate
        case failed(String)
    }

    /// 앱 밖에서 받은 파일(웹 다운로드 등)을 실제로 읽을 수 있는지 확인한 뒤 앱 영역에 복사해 담는다.
    /// 복사는 메인 스레드 밖에서 `.partial-` 이름으로 하고, 검증을 통과한 뒤에만 이름을 바꿔 등록한다.
    /// 같은 출처 식별자의 사용 불가 항목이 있으면 그 항목을 새 파일로 되살린다. 원본은 읽기만 한다.
    func addValidated(url: URL, name: String, isVideo: Bool, sourceKey: String,
                      kind: MaterialSourceKind) async -> AddResult {
        if let existing = items.first(where: { $0.sourceKey == sourceKey }),
           existing.availability == .localReady || tasks[existing.id] != nil {
            return .duplicate
        }
        let id = UUID()
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let staged: (filename: String, size: Int64?)
        switch await stageCopy(of: url, ownerID: id, isVideo: isVideo) {
        case .success(let value): staged = value
        case .failure(let failure): return .failed(failure.message)
        }
        let destination = directory.appendingPathComponent(staged.filename)
        // 복사하는 동안 같은 출처가 다른 경로로 준비됐으면 이번 복사본만 버린다.
        if let existing = items.first(where: { $0.sourceKey == sourceKey }),
           existing.availability == .localReady || tasks[existing.id] != nil {
            try? FileManager.default.removeItem(at: destination)
            return .duplicate
        }
        var candidate = items
        if let index = candidate.firstIndex(where: { $0.sourceKey == sourceKey }) {
            candidate[index].localFilename = staged.filename
            candidate[index].availability = .localReady
            candidate[index].failureMessage = nil
            candidate[index].byteCount = staged.size
        } else {
            candidate.append(MaterialItem(
                id: id, sourceKey: sourceKey, sourceKind: kind, name: name, isVideo: isVideo,
                byteCount: staged.size, localFilename: staged.filename, availability: .localReady,
                failureMessage: nil, addedAt: Date()))
        }
        guard commit(candidate) else {
            // 인덱스를 못 쓰면 이번에 만든 복사본만 되돌리고 이전 목록을 유지한다.
            try? FileManager.default.removeItem(at: destination)
            return .failed(persistenceError ?? "재료함을 저장하지 못했습니다.")
        }
        return .added
    }

    /// 가져오지 못한 출처 항목을 숨기지 않고 "사용 불가"로 남긴다. 파일이 없고 사유만 보존한다.
    /// 사용자가 제외하기 전에는 지워지지 않으며, 같은 식별자가 이미 있으면 덮어쓰지 않는다.
    /// 재료함에 그 출처가 기록돼 있으면(이미 있었거나 이번에 저장했으면) true, 저장하지 못했으면 false.
    @discardableResult
    func addUnresolved(name: String, isVideo: Bool, sourceKey: String, kind: MaterialSourceKind,
                       reason: String) -> Bool {
        guard !contains(sourceKey: sourceKey) else { return true }
        var candidate = items
        candidate.append(MaterialItem(
            id: UUID(), sourceKey: sourceKey, sourceKind: kind, name: name, isVideo: isVideo,
            byteCount: nil, localFilename: nil, availability: .unavailable, failureMessage: reason,
            addedAt: Date()))
        return commit(candidate)
    }

    // MARK: 로컬 준비

    private struct StageFailure: Error {
        let message: String
    }

    /// 원본을 읽기만 해서 재료함 안의 이 작업 전용 `.partial-` 파일로 복사하고, 실제로 열리는지 확인한 뒤
    /// 새 고유 이름으로 확정한다. 원본(`source`)은 옮기거나 지우지 않는다. 실패·취소 때는 이번에 만든
    /// partial/확정 파일만 지운다.
    private func stageCopy(of source: URL, ownerID: UUID,
                           isVideo: Bool) async -> Result<(filename: String, size: Int64?), StageFailure> {
        let ext = source.pathExtension.isEmpty ? "dat" : source.pathExtension
        let token = UUID().uuidString
        let filename = "\(ownerID.uuidString)-\(token).\(ext)"
        let partial = directory.appendingPathComponent(".partial-\(filename)")
        let destination = directory.appendingPathComponent(filename)
        do {
            try await Task.detached(priority: .utility) {
                try FileManager.default.copyItem(at: source, to: partial)
            }.value
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .failure(StageFailure(message: "복사하지 못했습니다: \(error.localizedDescription)"))
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: partial)
            return .failure(StageFailure(message: "취소했습니다."))
        }
        if let problem = await MaterialFileValidator.problem(for: partial, isVideo: isVideo) {
            try? FileManager.default.removeItem(at: partial)
            return .failure(StageFailure(message: problem))
        }
        do {
            // 옮기는 대상은 방금 만든 이 작업 소유의 partial 뿐이다. 같은 이름이 있으면 덮어쓰지 않고 실패한다.
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            return .failure(StageFailure(message: "저장하지 못했습니다: \(error.localizedDescription)"))
        }
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init)
        return .success((filename, size))
    }

    /// 항목을 출처에서 받아 앱 영역에 둔다. 실패하면 항목은 남기고 사유와 함께 다시 시도할 수 있다.
    /// 출처가 돌려준 파일은 원본이나 공유 캐시일 수 있으므로 읽기만 하고, 재료함 소유 복사본을 따로 만든다.
    func acquire(_ id: UUID, service: any RemoteFileService) {
        guard tasks[id] == nil, let item = items.first(where: { $0.id == id }),
              item.availability != .localReady,
              let connectionID = item.connectionID, let path = item.remotePath else { return }
        let remote = RemoteFileItem(
            connectionID: connectionID, path: path, remoteIdentifier: item.remoteIdentifier,
            name: item.name, kind: .file, size: item.byteCount, modifiedAt: item.modifiedAt,
            contentTypeIdentifier: item.contentTypeIdentifier)
        let isVideo = item.isVideo
        progress[id] = 0
        let report: @MainActor @Sendable (Double) -> Void = { [weak self] value in self?.progress[id] = value }
        tasks[id] = Task { [weak self] in
            defer {
                self?.progress[id] = nil
                self?.tasks[id] = nil
            }
            let downloaded: URL
            do {
                downloaded = try await service.download(remote) { value in
                    await report(value.fractionCompleted ?? 0)
                }
            } catch {
                guard let self else { return }
                if Task.isCancelled || RemoteRequestCancellation.isCancellation(error) {
                    self.update(id) { $0.availability = .needsDownload }
                } else {
                    self.update(id) {
                        $0.availability = .unavailable
                        $0.failureMessage = error.localizedDescription
                    }
                }
                return
            }
            guard let self else { return }
            let staged: (filename: String, size: Int64?)
            switch await self.stageCopy(of: downloaded, ownerID: id, isVideo: isVideo) {
            case .success(let value):
                staged = value
            case .failure(let failure):
                if Task.isCancelled {
                    self.update(id) { $0.availability = .needsDownload }
                } else {
                    self.update(id) {
                        $0.availability = .unavailable
                        $0.failureMessage = failure.message
                    }
                }
                return
            }
            let destination = self.directory.appendingPathComponent(staged.filename)
            // 받는 사이 제외됐거나 취소됐으면 이번 복사본만 버리고 기록하지 않는다.
            guard !Task.isCancelled, self.items.contains(where: { $0.id == id }) else {
                try? FileManager.default.removeItem(at: destination)
                if self.items.contains(where: { $0.id == id }) {
                    self.update(id) { $0.availability = .needsDownload }
                }
                return
            }
            let ready = self.update(id) {
                $0.localFilename = staged.filename
                $0.availability = .localReady
                $0.failureMessage = nil
                $0.byteCount = staged.size
            }
            if !ready {
                // 기록하지 못한 복사본은 지우고, 항목은 이전 상태(다시 받기 가능)로 남는다.
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    func cancelAcquire(_ id: UUID) { tasks[id]?.cancel() }

    // MARK: 제외

    /// 재료함에서 뺀다. 인덱스를 먼저 기록하고, 기록에 성공한 뒤에만 남은 항목이 참조하지 않는
    /// 앱 소유 복사본을 지운다. 기록하지 못하면 목록·파일을 그대로 두고 false를 돌려준다.
    /// 원본·진행 중인 편집본은 건드리지 않는다.
    @discardableResult
    func remove(_ ids: Set<UUID>) -> Bool {
        let removed = items.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return true }
        let remaining = items.filter { !ids.contains($0.id) }
        guard commit(remaining) else { return false }
        for id in ids { tasks[id]?.cancel() }
        let stillReferenced = Set(remaining.compactMap(\.localFilename))
        for item in removed {
            guard let name = item.localFilename, !stillReferenced.contains(name),
                  let url = ownedFileURL(named: name), !MaterialFileReferences.isInUse(url) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
        return true
    }

    /// 재료함 폴더 바로 아래의 앱 소유 파일만 돌려준다. 경로 구분자나 상위 이동이 섞인 이름은 거부한다.
    private func ownedFileURL(named name: String) -> URL? {
        guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", name != "index.json" else { return nil }
        let url = directory.appendingPathComponent(name)
        guard url.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    /// 한 항목을 바꿔 기록한다. 기록하지 못하면 화면 목록도 바꾸지 않고 false.
    @discardableResult
    private func update(_ id: UUID, _ change: (inout MaterialItem) -> Void) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = items
        change(&candidate[index])
        return commit(candidate)
    }

    // MARK: 저장

    private func load() {
        guard let data = try? Data(contentsOf: indexURL) else { return }
        guard var decoded = try? JSONDecoder().decode([MaterialItem].self, from: data) else {
            // 읽을 수 없는 인덱스는 다음 저장이 덮어쓰기 전에 보존한다.
            let backup = directory.appendingPathComponent("index.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: indexURL, to: backup)
            persistenceError = "재료함 목록을 읽지 못해 원본을 따로 보관했습니다."
            return
        }
        // 앱이 내려받는 도중 종료됐다면 다시 받을 수 있는 상태로 되돌리고, 사라진 복사본도 표시한다.
        for index in decoded.indices {
            if decoded[index].availability == .localReady, fileURL(for: decoded[index]) == nil {
                decoded[index].availability = decoded[index].connectionID == nil ? .unavailable : .needsDownload
                decoded[index].localFilename = nil
            }
        }
        items = decoded
    }

    /// 새 목록을 인덱스에 `.atomic`으로 쓰고, 성공했을 때만 화면 목록에 반영한다.
    /// 쓰기가 실패하면 기존 인덱스 파일과 화면 목록이 그대로 남는다.
    private func commit(_ candidate: [MaterialItem]) -> Bool {
        do {
            let data = try JSONEncoder().encode(candidate)
            try data.write(to: indexURL, options: .atomic)
            items = candidate
            persistenceError = nil
            return true
        } catch {
            persistenceError = "재료함을 저장하지 못했습니다: \(error.localizedDescription)"
            return false
        }
    }
}

/// 재료함 파일을 어떤 편집 프로젝트가 쓰고 있는지의 참조 개수. 편집본 쪽이 등록하면 재료함 정리 때
/// 쓰는 파일은 지우지 않는다.
@MainActor
enum MaterialFileReferences {
    private static var counts: [String: Int] = [:]
    static func retain(_ url: URL) { counts[url.path, default: 0] += 1 }
    static func release(_ url: URL) {
        guard let value = counts[url.path] else { return }
        if value <= 1 { counts[url.path] = nil } else { counts[url.path] = value - 1 }
    }
    static func isInUse(_ url: URL) -> Bool { (counts[url.path] ?? 0) > 0 }
}

/// 재료로 쓸 파일이 실제로 열리는지 확인한다. 원격 주소나 기록이 아니라 로컬 파일만 대상으로 한다.
enum MaterialFileValidator {
    /// 문제가 없으면 nil, 있으면 사용자에게 보여 줄 사유.
    static func problem(for url: URL, isVideo: Bool) async -> String? {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0 else { return "파일이 비어 있거나 읽을 수 없습니다." }
        if isVideo {
            let asset = AVURLAsset(url: url)
            let seconds = (try? await asset.load(.duration).seconds) ?? 0
            let playable = (try? await asset.load(.isPlayable)) ?? false
            guard playable, seconds.isFinite, seconds > 0 else { return "재생할 수 없는 영상입니다." }
        } else {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  CGImageSourceGetCount(source) > 0 else { return "열 수 없는 사진입니다." }
        }
        return nil
    }
}
