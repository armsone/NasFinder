import Foundation
import Photos
import UniformTypeIdentifiers

// MARK: - 실행 결과 모델

/// 실행(영상 제작·미디어 전송)에서 사용자에게 그대로 보여 줄 실패. `.relink`는 '다시 연결' 상태로 남길 사유다.
enum WorkbenchFailure: LocalizedError {
    case relink(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .relink(let message), .failed(let message): message
        }
    }

    var needsRelink: Bool {
        if case .relink = self { return true }
        return false
    }

    /// 원본이 없어졌거나 권한·로그인이 필요한 오류는 '다시 연결', 일시적인 네트워크 오류는 그냥 실패로 나눈다.
    static func classify(_ error: Error) -> WorkbenchFailure {
        if let failure = error as? WorkbenchFailure { return failure }
        if let loading = error as? PhotoTransferSelectionLoader.LoadingError {
            switch loading {
            case .photoAccessDenied, .assetMissing, .livePhotoIdentifierUnavailable:
                return .relink(loading.localizedDescription)
            default:
                return .failed(loading.localizedDescription)
            }
        }
        if let known = error as? NasFinderError {
            switch known {
            case .credentialsMissing, .authenticationFailed:
                return .relink("연결의 로그인 정보를 다시 확인해 주세요. 항목은 그대로 보관됩니다.")
            default:
                return .failed(known.localizedDescription)
            }
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(ns.code) {
            return .relink("원본 파일을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 다시 연결이 필요합니다.")
        }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOENT) {
            return .relink("원본 파일을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 다시 연결이 필요합니다.")
        }
        let text = error.localizedDescription
        let lowered = text.lowercased()
        if lowered.contains("not found") || lowered.contains("no such file") || text.contains("찾을 수 없") {
            return .relink("원본을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 다시 연결이 필요합니다.")
        }
        return .failed(UserErrorText.koreanDetail(error) ?? "항목을 처리하지 못했습니다. 잠시 후 다시 시도해 주세요.")
    }
}

struct WorkbenchProblem: Identifiable, Equatable {
    let id = UUID()
    let entryID: UUID?
    let name: String
    let reason: String
    let needsRelink: Bool
}

/// 폴더를 실행 시점에 펼친 뒤 실제로 가져올 항목 하나.
struct WorkbenchPlanItem: Identifiable, Sendable {
    enum Source: Sendable {
        case remote(RemoteFileItem)
        case asset(String)
        case file(bookmark: Data, relativePath: String?)
        case google(itemID: String, sessionID: String)
        /// 이미 앱 안에 있는 파일. 그 자리에서 읽기만 하고 지우지 않는다.
        case existing(URL)
        /// 이미 앱 안에 있는 Live/Motion 복사본(이미지 + 짝 영상). 둘 다 그 자리에서 읽기만 한다.
        case existingLivePair(image: URL, video: URL)
    }

    let id = UUID()
    let entryID: UUID
    let name: String
    let mediaKind: WorkbenchMediaKind
    /// 출처 안에서의 안정 식별자(보내기 재시도가 같은 항목을 알아보는 데 쓴다). 이름·해시로 만들지 않는다.
    let identity: String
    let source: Source
    var byteCount: Int64?
    var modifiedAt: Date?
    var contentTypeIdentifier: String?
    var isLivePhoto = false
}

private enum WorkbenchLimits {
    /// 폴더 순환·과도한 깊이를 막는 한도(기존 폴더 내려받기와 같은 값).
    static let maximumFolderDepth = 48
}

/// 한 실행이 만든 임시 파일 묶음. `remove()`는 이 묶음의 파일과 작업 폴더만 지운다.
struct WorkbenchArtifacts {
    fileprivate let urls: [URL]
    fileprivate let directory: URL

    func remove() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - 연결 서비스·북마크·Google 도우미

@MainActor
enum WorkbenchServiceResolver {
    /// 폰하드는 로컬 서비스, 기기 폴더는 기억한 폴더 권한, 나머지는 저장된 연결과 로그인 정보로 서비스를 만든다.
    static func service(connectionID: UUID, connectionStore: ConnectionStore) -> (any RemoteFileService)? {
        if connectionID == LocalInboxFileService.connectionID { return LocalInboxFileService() }
        if case .granted(let access) = DeviceFolderBookmark.restore(), access.connectionID == connectionID {
            return DeviceFolderFileService(access: access)
        }
        // 이미 시작한 작업은 모드가 바뀌어도 자기 연결을 계속 읽어야 하므로 숨김 필터가 없는 전체 목록에서 찾는다.
        guard let connection = connectionStore.allConnections.first(where: { $0.id == connectionID }),
              let credential = try? connectionStore.credential(for: connection) else { return nil }
        return RemoteFileServiceFactory.make(connection: connection, credential: credential)
    }
}

enum WorkbenchBookmark {
    #if targetEnvironment(macCatalyst)
    private static var resolutionOptions: URL.BookmarkResolutionOptions { [.withSecurityScope] }
    #else
    private static var resolutionOptions: URL.BookmarkResolutionOptions { [] }
    #endif

    static func resolve(_ data: Data) throws -> URL {
        var stale = false
        do {
            return try URL(resolvingBookmarkData: data, options: resolutionOptions, relativeTo: nil, bookmarkDataIsStale: &stale)
        } catch {
            throw WorkbenchFailure.relink("파일 권한(북마크)을 열 수 없습니다. 옮겨졌거나 권한이 취소됐을 수 있어 같은 파일을 다시 담아 연결해 주세요.")
        }
    }
}

/// Google 포토 Picker 세션 항목을 실행 시점에만 다시 나열해 새 baseUrl로 내려받는다.
/// 토큰·baseUrl은 이 객체의 메모리에만 있고 어디에도 저장하지 않는다. 세션이 끝났으면 '다시 연결'로 알린다.
@MainActor
final class WorkbenchGoogleResolver {
    private var listings: [String: (items: [String: GooglePhotosPickedMediaItem], listedAt: Date)] = [:]
    private var token: String?
    private static let listingLifetime: TimeInterval = 40 * 60

    private func accessToken(forceRefresh: Bool = false) async throws -> String {
        if let token, !forceRefresh { return token }
        let store = GooglePhotosKeychainCredentialStore()
        guard let stored = (try? store.load()) ?? nil else {
            throw WorkbenchFailure.relink("Google 포토 로그인이 필요합니다. 설정에서 Google 포토를 연결한 뒤 다시 시도해 주세요.")
        }
        var credential = stored
        if forceRefresh || stored.isExpired() {
            do {
                let configuration = try GooglePhotosOAuthConfiguration.loadFromMainBundle()
                credential = try await GooglePhotosTokenClient(configuration: configuration).refresh(stored)
                try? store.save(credential)
            } catch GooglePhotosOAuthError.reauthorizationRequired {
                throw WorkbenchFailure.relink("Google 포토 로그인이 만료되었습니다. 다시 로그인한 뒤 같은 항목을 다시 선택해 주세요.")
            } catch {
                throw WorkbenchFailure.failed(GooglePhotosImportFlowController.safeMessage(for: error))
            }
        }
        token = credential.accessToken
        return credential.accessToken
    }

    private func list(session id: String) async throws -> [String: GooglePhotosPickedMediaItem] {
        for attempt in 0..<2 {
            let bearer = try await accessToken(forceRefresh: attempt == 1)
            do {
                let items = try await GooglePhotosPickerClient(accessTokenProvider: { bearer }).allMediaItems(sessionID: id)
                return Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            } catch GooglePhotosPickerError.http(statusCode: let status, category: _) {
                if status == 401, attempt == 0 { continue }
                if [400, 403, 404].contains(status) {
                    throw WorkbenchFailure.relink("Google 포토 선택 세션이 끝났거나 접근 권한이 취소되었습니다. Google 포토에서 같은 항목을 다시 선택하면 이 항목에 다시 연결됩니다.")
                }
                throw WorkbenchFailure.failed("Google 포토가 응답하지 않았습니다 (HTTP \(status)). 잠시 후 다시 시도해 주세요.")
            }
        }
        throw WorkbenchFailure.failed("Google 포토 인증을 확인하지 못했습니다.")
    }

    private func item(sessionID: String, itemID: String) async throws -> GooglePhotosPickedMediaItem {
        if let cached = listings[sessionID], Date().timeIntervalSince(cached.listedAt) < Self.listingLifetime {
            if let item = cached.items[itemID] { return item }
        } else {
            listings[sessionID] = (items: try await list(session: sessionID), listedAt: Date())
        }
        guard let item = listings[sessionID]?.items[itemID] else {
            throw WorkbenchFailure.relink("Google 포토 선택 목록에서 이 항목을 찾을 수 없습니다. 같은 항목을 다시 선택해 주세요.")
        }
        return item
    }

    /// 항목을 새 baseUrl로 내려받아 `destination`에 둔다.
    func download(sessionID: String, itemID: String, to destination: URL) async throws {
        let picked = try await item(sessionID: sessionID, itemID: itemID)
        if picked.type == .video, let status = picked.mediaFile?.metadata?.videoMetadata?.processingStatus,
           status == .processing {
            throw WorkbenchFailure.failed("Google에서 영상 처리가 아직 끝나지 않았습니다. 잠시 후 다시 시도해 주세요.")
        }
        let bearer = try await accessToken()
        let client = GooglePhotosPickerClient(accessTokenProvider: { bearer })
        let temporary: URL
        do {
            temporary = try await GooglePhotosContentDownloadService(pickerClient: client).download(for: picked)
        } catch GooglePhotosPickerError.http(statusCode: let status, category: _) where [401, 403, 404, 410].contains(status) {
            listings[sessionID] = nil
            throw WorkbenchFailure.relink("Google 포토가 이 항목의 다운로드를 거부했습니다(HTTP \(status)). 같은 항목을 다시 선택해 주세요.")
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}

// MARK: - 실행

/// 포켓의 항목으로 영상 제작·미디어 전송을 **명시적으로 시작**할 때만 만들어지는 실행 한 번.
/// 폴더는 이 시점의 현재 내용으로 펼치고, 원본은 이 실행 전용 임시 작업 폴더로만 가져온다.
/// 실패·취소·종료 때 지우는 것은 이 실행의 임시 파일뿐이고, 포켓의 참조와 원본은 그대로다.
@MainActor
final class WorkbenchRun: ObservableObject {
    enum Purpose { case production, transfer }
    enum Phase: Equatable {
        case idle
        case planning
        /// 사용할 수 없는 항목이 있어 사용자의 선택(가능한 것만 계속 / 취소)을 기다린다.
        case decision
        case materializing
        case ready
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published private(set) var currentName: String?
    @Published private(set) var itemProgress: Double?
    @Published private(set) var problems: [WorkbenchProblem] = []
    @Published private(set) var skippedNotices: [String] = []
    /// 결정 대기가 파일 준비를 마친 뒤의 것인지(true) 계획 단계의 것인지(false).
    @Published private(set) var decisionAfterFetch = false

    let purpose: Purpose
    /// 시작하는 순간 한 번 정해지는 비공개 출처 여부(프라이버시 모드에서 시작했거나 입력에 비공개 출처·포켓이 있음).
    /// 이후 모드가 바뀌어도 바뀌지 않으며 산출물(편집본·폰하드 파일)에 그대로 이어진다.
    private(set) var originPrivate = false
    /// 일반 모드 화면에는 비공개 출처 작업의 파일 이름을 보이지 않는다.
    var masksNames: Bool { originPrivate && !PrivacyMode.currentlyActive }
    private var jobDirectory: URL
    private var plan: [WorkbenchPlanItem] = []
    private var connectionStore: ConnectionStore?
    private var task: Task<Void, Never>?
    /// `cancel()`·`start()`마다 올라가는 세대. 이전 세대 작업이 늦게 끝나도 지금 상태를 바꾸지 못하게 한다.
    private var generation = 0
    private var ownedURLs: [URL] = []
    private var preparedClips: [(item: RemoteFileItem, url: URL)] = []
    private let google = WorkbenchGoogleResolver()

    init(purpose: Purpose) {
        self.purpose = purpose
        jobDirectory = Self.makeJobDirectory()
    }

    private static func makeJobDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("NasFinderWorkbench", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    var isBusy: Bool { phase == .planning || phase == .materializing }
    var planCount: Int { plan.count }

    /// 영상 제작에 넘길 준비된 클립(순서 유지)과 그 파일을 읽는 서비스.
    var productionClips: [(item: RemoteFileItem, url: URL)] { preparedClips.filter { $0.item.isTrailerEligible } }
    func productionService() -> LocalPhotoLibraryFileService {
        LocalPhotoLibraryFileService(entries: productionClips.map { ($0.item, $0.url) })
    }

    // MARK: 시작·결정·종료

    func start(entries: [WorkbenchEntry], connectionStore: ConnectionStore, inputPrivate: Bool = false) {
        cancel()
        originPrivate = PrivacyMode.capturedOrigin(inputPrivate: inputPrivate || entries.contains(where: \.isEffectivelyPrivate))
        self.connectionStore = connectionStore
        phase = .planning
        let token = generation
        task = Task { [weak self] in await self?.runPlanning(entries, token: token) }
    }

    private func isStale(_ token: Int) -> Bool { Task.isCancelled || token != generation }

    /// 사용할 수 없는 항목은 빼고(포켓에는 그대로 남음) 가능한 항목으로 계속한다. 사용자가 직접 고른 경우에만 부른다.
    func continueWithAvailable() {
        guard phase == .decision else { return }
        if decisionAfterFetch {
            phase = .ready
            return
        }
        let token = generation
        task = Task { [weak self] in await self?.proceedAfterPlanning(token: token) }
    }

    /// 진행 중인 작업을 멈추고 이 실행의 임시 파일을 지운다.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        cleanup()
        plan = []
        preparedClips = []
        problems = []
        skippedNotices = []
        completed = 0
        total = 0
        currentName = nil
        itemProgress = nil
        decisionAfterFetch = false
        phase = .idle
    }

    /// 결과 사용(편집기·보내기 화면)이 끝났을 때 임시 파일을 정리한다.
    func finish() { cancel() }

    /// 실행 결과를 다른 쪽(예: 열려 있는 편집 프로젝트가 나중에 읽는 파일)에 넘기고 이 실행은 초기화한다.
    /// 임시 파일은 지우지 않고 돌려주며, 사용이 끝난 쪽이 `remove()`로 지운다.
    func detachArtifacts() -> WorkbenchArtifacts {
        let detached = WorkbenchArtifacts(urls: ownedURLs, directory: jobDirectory)
        ownedURLs = []
        jobDirectory = Self.makeJobDirectory()
        cancel()
        return detached
    }

    private func cleanup() {
        for url in ownedURLs { try? FileManager.default.removeItem(at: url) }
        ownedURLs = []
        try? FileManager.default.removeItem(at: jobDirectory)
    }

    // MARK: 계획 (폴더 펼치기 + 가능 여부 확인)

    private func runPlanning(_ entries: [WorkbenchEntry], token: Int) async {
        var items: [WorkbenchPlanItem] = []
        var found: [Problem] = []
        var skipped: [String] = []
        var seen = Set<String>()
        var duplicates = 0
        var relinkReasons: [String: Set<UUID>] = [:]
        var recovered = Set<UUID>()
        total = entries.count
        completed = 0
        for entry in entries {
            if isStale(token) { return }
            currentName = entry.name
            do {
                let resolved = try await resolve(entry, skipped: &skipped, problems: &found)
                for item in resolved {
                    if seen.insert(item.identity).inserted { items.append(item) } else { duplicates += 1 }
                }
                if entry.relinkReason != nil { recovered.insert(entry.id) }
            } catch is CancellationError {
                return
            } catch {
                let failure = WorkbenchFailure.classify(error)
                found.append(Problem(entryID: entry.id, name: entry.name, reason: failure.localizedDescription,
                                     needsRelink: failure.needsRelink))
                if failure.needsRelink { relinkReasons[failure.localizedDescription, default: []].insert(entry.id) }
            }
            if isStale(token) { return }
            completed += 1
        }
        if isStale(token) { return }
        // 다시 연결이 필요한 항목은 상태만 남기고, 이번에 문제없던 항목은 상태를 풀어 준다. 항목은 지우지 않는다.
        for (reason, ids) in relinkReasons { WorkbenchStore.shared.setRelink(reason, forEntryIDs: ids) }
        if !recovered.isEmpty { WorkbenchStore.shared.setRelink(nil, forEntryIDs: recovered) }
        if duplicates > 0 { skipped.append("같은 원본을 가리키는 중복 \(duplicates)개는 한 번만 사용합니다.") }
        plan = items
        problems = found.map { WorkbenchProblem(entryID: $0.entryID, name: $0.name, reason: $0.reason, needsRelink: $0.needsRelink) }
        skippedNotices = skipped
        currentName = nil
        if items.isEmpty {
            let detail = problems.first.map { originPrivate ? " \($0.reason)" : " \($0.name): \($0.reason)" } ?? ""
            phase = .failed("사용할 수 있는 사진·영상이 없습니다.\(detail)")
            return
        }
        if !problems.isEmpty || skipped.contains(where: { !$0.hasPrefix("같은 원본") }) {
            decisionAfterFetch = false
            phase = .decision
            return
        }
        await proceedAfterPlanning(token: token)
    }

    private func proceedAfterPlanning(token: Int) async {
        switch purpose {
        case .transfer:
            // 미디어 전송은 보내는 순간에 항목마다 가져오므로 여기서는 계획만 확정한다.
            phase = .ready
        case .production:
            await materializeForProduction(token: token)
        }
    }

    private struct Problem {
        let entryID: UUID?
        let name: String
        let reason: String
        let needsRelink: Bool
    }

    private func resolve(_ entry: WorkbenchEntry, skipped: inout [String], problems: inout [Problem]) async throws -> [WorkbenchPlanItem] {
        guard entry.mediaKind != .other else {
            throw WorkbenchFailure.failed("사진·영상이 아니라 영상 제작·미디어 전송에 쓸 수 없습니다. 포켓에는 그대로 보관되며, 필요 없으면 포켓에서 빼 주세요.")
        }
        func item(_ source: WorkbenchPlanItem.Source, identity: String? = nil, name: String? = nil,
                  kind: WorkbenchMediaKind? = nil, live: Bool = false) -> WorkbenchPlanItem {
            var plan = WorkbenchPlanItem(entryID: entry.id, name: name ?? entry.name, mediaKind: kind ?? entry.mediaKind,
                                         identity: identity ?? entry.identity, source: source)
            plan.byteCount = entry.byteCount
            plan.modifiedAt = entry.modifiedAt
            plan.contentTypeIdentifier = entry.contentTypeIdentifier
            plan.isLivePhoto = live
            return plan
        }
        switch entry.kind {
        case .legacyCopy:
            guard let name = entry.legacyFilename, let url = WorkbenchLegacyFiles.url(forLegacyName: name) else {
                throw WorkbenchFailure.relink(entry.relinkReason ?? "예전 복사본을 찾을 수 없습니다. 원본에서 다시 담아 주세요.")
            }
            if let companionName = entry.legacyCompanionFilename {
                guard let video = WorkbenchLegacyFiles.url(forLegacyName: companionName) else {
                    throw WorkbenchFailure.relink("예전 Live/Motion 복사본의 짝 영상 파일을 찾을 수 없습니다. 원본에서 다시 담아 주세요.")
                }
                return [item(.existingLivePair(image: url, video: video), live: true)]
            }
            return [item(.existing(url))]
        case .remote:
            guard let connectionID = entry.connectionID, let path = entry.path else {
                throw WorkbenchFailure.relink("원본 연결 정보가 없습니다. 원본에서 다시 담아 주세요.")
            }
            if !entry.isFolder, let name = entry.legacyFilename, let url = WorkbenchLegacyFiles.url(forLegacyName: name) {
                return [item(.existing(url))]
            }
            guard let connectionStore,
                  let service = WorkbenchServiceResolver.service(connectionID: connectionID, connectionStore: connectionStore) else {
                throw WorkbenchFailure.relink("이 항목의 연결이 삭제되었거나 로그인 정보가 없습니다. 연결을 다시 추가하거나 로그인한 뒤 시도해 주세요.")
            }
            let root = RemoteFileItem(
                connectionID: connectionID, path: path, remoteIdentifier: entry.remoteIdentifier, name: entry.name,
                kind: entry.isFolder ? .folder : .file, size: entry.byteCount, modifiedAt: entry.modifiedAt,
                contentTypeIdentifier: entry.contentTypeIdentifier)
            guard entry.isFolder else { return [item(.remote(root))] }
            guard Self.safeComponents(root.path) != nil else {
                throw WorkbenchFailure.failed("폴더 경로에 '.' 또는 '..'가 있어 안전하지 않아 펼치지 않았습니다.")
            }
            let walk = RemoteWalk(root: root)
            try await walkRemote(root, relative: entry.name, depth: 0, entry: entry, service: service, walk: walk)
            skipped.append(contentsOf: walk.skipped)
            problems.append(contentsOf: walk.failures.map {
                Problem(entryID: entry.id, name: $0.path, reason: $0.reason, needsRelink: false)
            })
            return walk.items
        case .photoAsset:
            guard let identifier = entry.assetIdentifier else { throw WorkbenchFailure.relink("사진 보관함 식별자가 없습니다. 다시 담아 주세요.") }
            let status = await Self.photoAuthorization()
            guard status == .authorized || status == .limited else {
                throw WorkbenchFailure.relink("사진 접근이 허용되지 않았습니다. 설정에서 사진 접근을 허용한 뒤 다시 시도해 주세요.")
            }
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                throw WorkbenchFailure.relink("사진 보관함에서 이 항목을 찾을 수 없습니다. 삭제되었거나 허용한 범위 밖일 수 있어 다시 연결이 필요합니다.")
            }
            return [item(.asset(identifier), kind: asset.mediaType == .video ? .video : .photo,
                         live: asset.mediaSubtypes.contains(.photoLive))]
        case .fileBookmark:
            guard let data = entry.bookmarkData else { throw WorkbenchFailure.relink("파일 권한 정보가 없습니다. 다시 담아 주세요.") }
            let root = try WorkbenchBookmark.resolve(data)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw WorkbenchFailure.relink("파일을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 다시 연결이 필요합니다.")
            }
            guard entry.isFolder else { return [item(.file(bookmark: data, relativePath: nil))] }
            // 큰 폴더 탐색 중 취소가 분리된 작업까지 전달되게 한다.
            let worker = Task.detached(priority: .userInitiated) { Self.walkLocal(root: root) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            try Task.checkCancellation()
            skipped.append(contentsOf: result.skipped.map { "폴더 '\(entry.name)': \($0)" })
            return result.files.map { file in
                var plan = WorkbenchPlanItem(
                    entryID: entry.id, name: file.name, mediaKind: file.kind,
                    identity: "\(entry.identity)/\(file.relativePath)",
                    source: .file(bookmark: data, relativePath: file.relativePath))
                plan.byteCount = file.byteCount
                plan.modifiedAt = file.modifiedAt
                return plan
            }
        case .googlePhoto:
            guard entry.googleItemID != nil, entry.googleSessionID != nil else {
                throw WorkbenchFailure.relink("Google 포토 항목 정보가 없습니다. 다시 선택해 주세요.")
            }
            if let expires = entry.googleSessionExpiresAt, expires <= Date() {
                throw WorkbenchFailure.relink("Google 포토 선택 세션이 만료되었습니다. Google 포토에서 같은 항목을 다시 선택하면 이 항목에 다시 연결됩니다.")
            }
            guard ((try? GooglePhotosKeychainCredentialStore().load()) ?? nil) != nil else {
                throw WorkbenchFailure.relink("Google 포토 로그인이 필요합니다. 설정에서 Google 포토를 연결해 주세요.")
            }
            return [item(.google(itemID: entry.googleItemID ?? "", sessionID: entry.googleSessionID ?? ""))]
        case .sharedStaging:
            guard let batchID = entry.stagedBatchID, let itemID = entry.stagedItemID,
                  let batch = ShareIntentStaging.batch(id: batchID),
                  let staged = batch.items.first(where: { $0.id == itemID }),
                  let url = try? ShareIntentStaging.fileURL(batchID: batchID, item: staged),
                  FileManager.default.fileExists(atPath: url.path) else {
                throw WorkbenchFailure.relink("공유로 받은 파일이 앱에서 정리되었습니다. 같은 파일을 다시 공유해 주세요.")
            }
            return [item(.existing(url))]
        }
    }

    private static func photoAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
        }
    }

    // MARK: 폴더 펼치기

    private final class RemoteWalk {
        struct Failure { let path: String; let reason: String }
        /// 사용자가 담은 폴더. 펼친 모든 항목은 같은 연결의 이 폴더 안 경로여야 한다.
        let root: RemoteFileItem
        var items: [WorkbenchPlanItem] = []
        var skipped: [String] = []
        var failures: [Failure] = []
        var visitedPaths: Set<String>
        var visitedIDs: Set<RemoteFileItem.ID>
        init(root: RemoteFileItem) {
            self.root = root
            visitedPaths = [RemoteDownloadCoordinator.normalizedPath(root.path)]
            visitedIDs = [root.id]
        }
    }

    /// 슬래시로 나눈 경로 구성요소. `.`/`..`가 섞인 경로는 정규화로 범위를 속일 수 있어 안전하지 않다고 보고 nil을 돌려준다.
    nonisolated static func safeComponents(_ path: String) -> [String]? {
        var result: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." || part == ".." { return nil }
            result.append(String(part))
        }
        return result
    }

    /// `child`가 `root`의 진짜 하위 경로인지(구성요소 단위 비교, `.`/`..` 포함 경로는 거부).
    nonisolated static func isInside(_ child: String, of root: String) -> Bool {
        guard let childParts = safeComponents(child), let rootParts = safeComponents(root) else { return false }
        return childParts.count > rootParts.count && Array(childParts.prefix(rootParts.count)) == rootParts
    }

    /// 저장된 연결의 폴더를 현재 내용으로 깊이 우선 펼친다. 이름 순서를 지키고, 반복 경로·ID·과도한 깊이는
    /// 링크 순환으로 보고 건너뛴다. 읽지 못한 하위 폴더와 사진·영상이 아닌 파일은 숨기지 않고 보고한다.
    private func walkRemote(_ folder: RemoteFileItem, relative: String, depth: Int, entry: WorkbenchEntry,
                            service: any RemoteFileService, walk: RemoteWalk) async throws {
        try Task.checkCancellation()
        currentName = relative
        let children: [RemoteFileItem]
        do {
            children = try await service.list(directory: folder.path)
                .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch {
            if RemoteRequestCancellation.isCancellation(error) || Task.isCancelled { throw CancellationError() }
            // 최상위 폴더를 읽지 못하면 이 항목 전체 문제로, 하위 폴더면 그 폴더만 보고하고 나머지는 계속한다.
            if depth == 0 { throw error }
            walk.failures.append(.init(path: relative + "/", reason: UserErrorText.message("폴더를 읽지 못했습니다", error, recovery: "폴더 접근 권한을 확인해 주세요.")))
            return
        }
        var unsupported: [String] = []
        for child in children {
            try Task.checkCancellation()
            let childRelative = relative + "/" + child.name
            guard RemoteDownloadCoordinator.safeComponent(child.name) != nil else {
                walk.skipped.append("'\(childRelative)': 안전하지 않은 이름이라 건너뜁니다.")
                continue
            }
            // 서비스가 돌려준 경로·연결도 믿지 않는다: 같은 연결이고, 정규화 전 경로에 '.'/'..'가 없으며, 담은 폴더 안이어야 한다.
            guard child.connectionID == walk.root.connectionID else {
                walk.skipped.append("'\(childRelative)': 다른 연결의 항목이라 건너뜁니다.")
                continue
            }
            guard Self.isInside(child.path, of: walk.root.path) else {
                walk.skipped.append("'\(childRelative)': 담은 폴더 밖이거나 안전하지 않은 경로라 건너뜁니다.")
                continue
            }
            if child.isDirectory {
                guard depth + 1 <= WorkbenchLimits.maximumFolderDepth,
                      walk.visitedPaths.insert(RemoteDownloadCoordinator.normalizedPath(child.path)).inserted,
                      walk.visitedIDs.insert(child.id).inserted else {
                    walk.skipped.append("'\(childRelative)/': 반복되거나 너무 깊은 폴더(링크 순환 가능)라 건너뜁니다.")
                    continue
                }
                try await walkRemote(child, relative: childRelative, depth: depth + 1, entry: entry, service: service, walk: walk)
            } else if child.isImage || child.isVideo {
                var item = WorkbenchPlanItem(
                    entryID: entry.id, name: child.name, mediaKind: child.isVideo ? .video : .photo,
                    identity: "remote:\(child.connectionID.uuidString):\(child.remoteIdentifier ?? child.path)",
                    source: .remote(child))
                item.byteCount = child.size
                item.modifiedAt = child.modifiedAt
                item.contentTypeIdentifier = child.contentTypeIdentifier
                walk.items.append(item)
                total = max(total, completed + walk.items.count)
            } else {
                unsupported.append(child.name)
            }
        }
        if !unsupported.isEmpty {
            let sample = unsupported.prefix(3).joined(separator: ", ")
            walk.skipped.append("'\(relative)/': 사진·영상이 아닌 파일 \(unsupported.count)개는 건너뜁니다 (\(sample)\(unsupported.count > 3 ? " 외" : "")).")
        }
    }

    private struct LocalFile: Sendable {
        let relativePath: String
        let name: String
        let kind: WorkbenchMediaKind
        let byteCount: Int64?
        let modifiedAt: Date?
    }

    /// 보안 범위가 열린 로컬 폴더를 이름 순서로 펼친다. 바로가기(심볼릭 링크)는 따라가지 않아 범위 밖으로 나가지 않는다.
    private nonisolated static func walkLocal(root: URL) -> (files: [LocalFile], skipped: [String]) {
        var files: [LocalFile] = []
        var skipped: [String] = []
        // 선택한 폴더의 실제(심볼릭 링크를 푼) 경로. 각 항목도 실제 경로가 이 안에 있어야 한다.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isAliasFileKey, .fileSizeKey, .contentModificationDateKey]
        func walk(_ directory: URL, relative: String, depth: Int) {
            if Task.isCancelled { return }
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                skipped.append("'\(relative.isEmpty ? "/" : relative)': 폴더를 읽지 못했습니다.")
                return
            }
            var unsupported = 0
            for child in children.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
                if Task.isCancelled { return }
                let childRelative = relative.isEmpty ? child.lastPathComponent : relative + "/" + child.lastPathComponent
                let values = try? child.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true || values?.isAliasFile == true {
                    skipped.append("'\(childRelative)': 바로가기(링크·별칭)는 따라가지 않고 건너뜁니다.")
                    continue
                }
                guard child.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(rootPath + "/") else {
                    skipped.append("'\(childRelative)': 선택한 폴더 밖이라 건너뜁니다.")
                    continue
                }
                if values?.isDirectory == true {
                    guard depth + 1 <= WorkbenchLimits.maximumFolderDepth else {
                        skipped.append("'\(childRelative)/': 너무 깊은 폴더라 건너뜁니다.")
                        continue
                    }
                    walk(child, relative: childRelative, depth: depth + 1)
                    continue
                }
                let type = UTType(filenameExtension: child.pathExtension.lowercased())
                let kind: WorkbenchMediaKind
                if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
                else if type?.conforms(to: .image) == true { kind = .photo }
                else { unsupported += 1; continue }
                files.append(LocalFile(relativePath: childRelative, name: child.lastPathComponent, kind: kind,
                                       byteCount: values?.fileSize.map(Int64.init), modifiedAt: values?.contentModificationDate))
            }
            if unsupported > 0 { skipped.append("'\(relative.isEmpty ? "/" : relative)': 사진·영상이 아닌 파일 \(unsupported)개는 건너뜁니다.") }
        }
        walk(root, relative: "", depth: 0)
        return (files, skipped)
    }

    // MARK: 가져오기 (실행 전용 임시 작업 폴더)

    private struct Fetched {
        let url: URL
        /// 이 실행이 만든 임시 파일이면 true. false인 파일(폰하드 원본·예전 복사본 등)은 지우지 않는다.
        let ownsFile: Bool
    }

    private func jobURL(name: String) throws -> URL {
        try FileManager.default.createDirectory(at: jobDirectory, withIntermediateDirectories: true)
        let ext = (name as NSString).pathExtension
        return jobDirectory.appendingPathComponent(UUID().uuidString + (ext.isEmpty ? "" : "." + ext))
    }

    /// 이 실행이 만든 임시 파일로 등록한다. 이미 취소·종료됐거나(작업 취소 또는 세대 변경) 다른 실행으로 넘어갔다면
    /// 방금 만든 이 파일만 지우고 취소로 끝낸다. 전송은 보내기 세션의 작업에서 부르므로 작업 취소만으로는 알 수 없어 세대도 본다.
    private func adopt(_ url: URL, token: Int) throws {
        if isStale(token) {
            try? FileManager.default.removeItem(at: url)
            throw CancellationError()
        }
        ownedURLs.append(url)
    }

    /// 이미 끝난 실행이 작업 폴더를 다시 만들지 못하게 한다.
    private func ensureCurrent(_ token: Int) throws {
        if isStale(token) { throw CancellationError() }
    }

    private func fetch(_ item: WorkbenchPlanItem, token: Int) async throws -> Fetched {
        try ensureCurrent(token)
        itemProgress = 0
        defer { itemProgress = nil }
        switch item.source {
        case .existing(let url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw WorkbenchFailure.relink("앱 안의 파일이 사라졌습니다. 원본에서 다시 담아 주세요.")
            }
            return Fetched(url: url, ownsFile: false)
        case .existingLivePair(let image, _):
            // 영상 제작은 대표 이미지를 쓴다. 이미지+영상 묶음 전송은 prepareTransferItem이 따로 처리한다.
            guard FileManager.default.fileExists(atPath: image.path) else {
                throw WorkbenchFailure.relink("앱 안의 파일이 사라졌습니다. 원본에서 다시 담아 주세요.")
            }
            return Fetched(url: image, ownsFile: false)
        case .remote(let remote):
            guard let connectionStore,
                  let service = WorkbenchServiceResolver.service(connectionID: remote.connectionID, connectionStore: connectionStore) else {
                throw WorkbenchFailure.relink("이 항목의 연결이 삭제되었거나 로그인 정보가 없습니다.")
            }
            let report: @MainActor @Sendable (Double) -> Void = { [weak self] value in self?.itemProgress = value }
            let downloaded = try await service.download(remote) { value in
                await report(value.fractionCompleted ?? 0)
            }
            // 폰하드의 저장 파일은 그대로 읽는다. 그 밖의 서비스가 돌려준 파일은 공유 캐시일 수 있어 이 실행 전용 사본을 만든다.
            if service is LocalInboxFileService { return Fetched(url: downloaded, ownsFile: false) }
            try ensureCurrent(token)
            let destination = try jobURL(name: item.name)
            try await Task.detached(priority: .utility) { try Self.copyCoordinated(from: downloaded, to: destination) }.value
            try adopt(destination, token: token)
            return Fetched(url: destination, ownsFile: true)
        case .asset(let identifier):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                throw WorkbenchFailure.relink("사진 보관함에서 이 항목을 찾을 수 없습니다.")
            }
            let exported = try await LocalPhotoLibraryCalendarService.exportOriginal(for: asset)
            if isStale(token) {
                // 내보내기가 끝났을 때 이미 끝난 실행이면 방금 내보낸 이 임시 파일만 지운다.
                try? FileManager.default.removeItem(at: exported.url)
                throw CancellationError()
            }
            let destination = try jobURL(name: exported.url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: exported.url, to: destination)
                try adopt(destination, token: token)
                return Fetched(url: destination, ownsFile: true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                try adopt(exported.url, token: token)
                return Fetched(url: exported.url, ownsFile: true)
            }
        case .file(let bookmark, let relativePath):
            let root = try WorkbenchBookmark.resolve(bookmark)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            let source: URL
            if let relativePath {
                source = root.appendingPathComponent(relativePath)
                guard source.resolvingSymlinksInPath().standardizedFileURL.path
                    .hasPrefix(root.resolvingSymlinksInPath().standardizedFileURL.path + "/") else {
                    throw WorkbenchFailure.failed("선택한 폴더 밖의 경로라 가져오지 않았습니다.")
                }
            } else {
                source = root
            }
            guard FileManager.default.fileExists(atPath: source.path) else {
                throw WorkbenchFailure.relink("파일을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 다시 연결이 필요합니다.")
            }
            try ensureCurrent(token)
            let destination = try jobURL(name: item.name)
            try await Task.detached(priority: .utility) { try Self.copyCoordinated(from: source, to: destination) }.value
            try adopt(destination, token: token)
            return Fetched(url: destination, ownsFile: true)
        case .google(let itemID, let sessionID):
            try ensureCurrent(token)
            let destination = try jobURL(name: item.name)
            try await google.download(sessionID: sessionID, itemID: itemID, to: destination)
            try adopt(destination, token: token)
            return Fetched(url: destination, ownsFile: true)
        }
    }

    private nonisolated static func copyCoordinated(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: destination) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    // MARK: 영상 제작용 준비

    private func materializeForProduction(token: Int) async {
        phase = .materializing
        decisionAfterFetch = true
        total = plan.count
        completed = 0
        preparedClips = []
        var failures: [WorkbenchProblem] = []
        var relinkReasons: [String: Set<UUID>] = [:]
        for item in plan {
            if isStale(token) { return }
            currentName = item.name
            do {
                try await prepareClip(item, token: token)
            } catch is CancellationError {
                return
            } catch {
                if isStale(token) { return }
                let failure = WorkbenchFailure.classify(error)
                failures.append(WorkbenchProblem(entryID: item.entryID, name: item.name, reason: failure.localizedDescription,
                                                 needsRelink: failure.needsRelink))
                if failure.needsRelink { relinkReasons[failure.localizedDescription, default: []].insert(item.entryID) }
            }
            completed += 1
        }
        if isStale(token) { return }
        for (reason, ids) in relinkReasons { WorkbenchStore.shared.setRelink(reason, forEntryIDs: ids) }
        currentName = nil
        if preparedClips.isEmpty {
            problems += failures
            phase = .failed("영상 제작에 쓸 사진·영상을 가져오지 못했습니다.")
            return
        }
        if failures.isEmpty {
            phase = .ready
        } else {
            problems = failures
            skippedNotices = []
            phase = .decision
        }
    }

    private func prepareClip(_ item: WorkbenchPlanItem, token: Int) async throws {
        let fetched = try await fetch(item, token: token)
        var url = fetched.url
        var name = item.name
        if case .asset(let identifier) = item.source, item.isLivePhoto,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            // 편집에서는 Live Photo의 대표사진·영상·좋은 프레임 중 하나를 기존 규칙으로 고른다.
            let decision = try await LivePhotoEditingSelection.choose(asset: asset, originalPhotoURL: url)
            if isStale(token) {
                for owned in decision.ownedURLs { try? FileManager.default.removeItem(at: owned) }
                throw CancellationError()
            }
            ownedURLs.append(contentsOf: decision.ownedURLs)
            if decision.kind != .originalPhoto {
                url = decision.url
                let base = (name as NSString).deletingPathExtension
                let ext = decision.url.pathExtension.lowercased()
                name = base + "." + (ext.isEmpty ? (decision.kind == .video ? "mov" : "jpg") : ext)
            }
        }
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? item.byteCount
        let clip = RemoteFileItem(
            connectionID: LocalPhotoLibraryFileService.connectionID, path: item.id.uuidString, name: name, kind: .file,
            size: size, modifiedAt: item.modifiedAt, contentTypeIdentifier: type?.identifier)
        // 취소·재시작으로 세대가 바뀌었으면 늦게 끝난 결과를 지금 상태에 넣지 않는다.
        if isStale(token) { throw CancellationError() }
        preparedClips.append((clip, url))
    }

    // MARK: 미디어 전송용 소스

    /// 보내는 순간에 항목마다 가져오는 전송 소스(포켓 순서 그대로). 실패는 숨기지 않고 보내기 화면에 그대로 드러난다.
    func sendSources() -> [PhotoTransferSendSource] {
        let token = generation
        return plan.map { item in
            let kind: PhotoTransferMediaKind = item.isLivePhoto ? .livePhoto : item.mediaKind == .video ? .video : .photo
            return PhotoTransferSendSource(id: item.identity, kind: kind) { [weak self] index, itemId in
                guard let self else { throw WorkbenchFailure.failed("작업대 실행이 이미 끝났습니다. 다시 시작해 주세요.") }
                return try await self.prepareTransferItem(item, index: index, itemId: itemId, token: token)
            }
        }
    }

    private func prepareTransferItem(_ item: WorkbenchPlanItem, index: Int, itemId: String, token: Int) async throws -> PhotoTransferPreparedItem {
        do {
            try ensureCurrent(token)
            if case .asset(let identifier) = item.source {
                return try await PhotoTransferSelectionLoader.load(assetIdentifier: identifier, index: index, itemId: itemId)
            }
            if case .existingLivePair(let image, let video) = item.source {
                // 예전 Live/Motion 복사본은 이미지+영상 묶음 그대로 보내고, 보낸 뒤에도 지우지 않는다.
                return try await Task.detached(priority: .utility) {
                    try PhotoTransferSelectionLoader.prepareLivePair(
                        imageURL: image, videoURL: video, index: index, itemId: itemId)
                }.value
            }
            let fetched = try await fetch(item, token: token)
            let type = item.contentTypeIdentifier.flatMap { UTType($0) }
            let name = item.name
            let owns = fetched.ownsFile
            let url = fetched.url
            do {
                return try await Task.detached(priority: .utility) {
                    try PhotoTransferSelectionLoader.prepareFile(
                        at: url, name: name, contentType: type, index: index, itemId: itemId, ownsFile: owns)
                }.value
            } catch {
                if owns { try? FileManager.default.removeItem(at: url) }
                throw error
            }
        } catch {
            // 취소는 실패로 바꾸지 않는다(보내기 세션이 취소로 처리한다).
            if error is CancellationError { throw error }
            let failure = WorkbenchFailure.classify(error)
            if failure.needsRelink { WorkbenchStore.shared.setRelink(failure.localizedDescription, forEntryIDs: [item.entryID]) }
            throw failure
        }
    }
}
