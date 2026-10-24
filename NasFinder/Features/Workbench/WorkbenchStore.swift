import Foundation

enum WorkbenchStoreError: LocalizedError, Equatable {
    case emptyName
    case duplicateName
    case missingPocket
    case readOnly
    case persistence(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: "포켓 이름을 입력해 주세요."
        case .duplicateName: "같은 이름의 포켓이 이미 있습니다."
        case .missingPocket: "선택한 포켓을 찾을 수 없습니다."
        case .readOnly: "작업대 기록을 읽지 못해 변경을 막았습니다. 기존 기록은 그대로 보관 중입니다."
        case .persistence(let message): message
        }
    }
}

/// 작업대(포켓 모음)의 유일한 저장소. 영상 재료함과 미디어 전송 임시 공간을 하나로 합친 곳이다.
///
/// - 항목은 **참조**(연결 ID·경로, PhotoKit ID, 북마크, Google 항목 ID 등)만 담고 원본 바이트는 담지 않는다.
/// - 포켓·항목을 빼거나 비워도 지워지는 것은 참조뿐이다. 원본과 예전 복사본 파일은 지우지 않는다.
/// - 기록은 한 파일에 원자적으로 쓴다. 쓰기에 실패하면 이전 기록과 화면 상태가 그대로이고,
///   읽지 못한 기록은 읽기 전용으로 잠가 어떤 변경도 덮어쓰지 못하게 한다(파일을 지우지도 않는다).
@MainActor
final class WorkbenchStore: ObservableObject {
    static let shared = WorkbenchStore()

    static let legacyPocketName = "기존 재료"

    /// 비공개를 포함한 전체 포켓. 스테이징 파일 정리·소유권 계산은 항상 이 전체 목록을 쓴다.
    @Published private(set) var storedPockets: [WorkbenchPocket] = []
    /// 지금 모드에서 보이는 포켓: 일반 모드는 공개 포켓만, 항목도 출처가 숨겨진 것은 뺀다.
    var pockets: [WorkbenchPocket] {
        let active = PrivacyMode.currentlyActive
        guard !active else { return storedPockets }
        return storedPockets.filter { $0.isPrivate != true }.map { pocket in
            var visible = pocket
            visible.entries = pocket.entries.filter(\.isVisibleNow)
            return visible
        }
    }
    @Published private(set) var persistenceError: String?
    /// 기록을 읽지 못한 상태. true인 동안은 모든 변경을 거부한다.
    @Published private(set) var isReadOnly = false

    private let directory: URL
    private let legacy: MaterialBasketStore
    private let legacyTransfer: LegacyTransferPendingStore
    private var document = WorkbenchDocument()
    /// 포켓을 비우거나 지울 때 올라가는 세대. 오래 걸리는 담기 작업이 끝난 뒤 지워진 포켓에 되살리지 못하게 한다.
    private var epochs: [UUID: Int] = [:]

    private var fileURL: URL { directory.appendingPathComponent("workbench.json") }

    init(directory: URL? = nil, legacy: MaterialBasketStore? = nil, legacyTransfer: LegacyTransferPendingStore? = nil) {
        self.directory = directory ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workbench", isDirectory: true)
        self.legacy = legacy ?? MaterialBasketStore.shared
        self.legacyTransfer = legacyTransfer ?? LegacyTransferPendingStore.shared
        load()
    }

    // MARK: 조회

    func pocket(_ id: UUID?) -> WorkbenchPocket? {
        guard let id else { return nil }
        return pockets.first { $0.id == id }
    }

    /// 포켓 안에 지금 모드에서 숨겨진 항목이 있는지(일반 모드에서 지우기·비우기를 막는 데 쓴다).
    private func hasHiddenEntries(_ pocket: WorkbenchPocket) -> Bool {
        !PrivacyMode.currentlyActive && pocket.entries.contains { !$0.isVisibleNow }
    }

    /// 담기 작업을 시작할 때 읽어 두는 세대. `add(…expectedEpoch:)`에 되돌려 주면 그 사이 포켓이 비워졌는지 확인한다.
    func epoch(of pocketID: UUID) -> Int { epochs[pocketID] ?? 0 }

    // MARK: 포켓

    @discardableResult
    func createPocket(named rawName: String) -> Result<UUID, WorkbenchStoreError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard !hasPocket(named: name, excluding: nil) else { return .failure(.duplicateName) }
        var candidate = document
        let pocket = WorkbenchPocket(name: name, isPrivate: PrivacyMode.shared.newRecordFlag)
        candidate.pockets.append(pocket)
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(pocket.id)
    }

    @discardableResult
    func renamePocket(_ id: UUID, to rawName: String) -> Result<Void, WorkbenchStoreError> {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return .failure(.emptyName) }
        guard let index = document.pockets.firstIndex(where: { $0.id == id }) else { return .failure(.missingPocket) }
        guard !hasPocket(named: name, excluding: id) else { return .failure(.duplicateName) }
        var candidate = document
        candidate.pockets[index].name = name
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(())
    }

    /// 포켓과 그 참조만 지운다. 원본·예전 복사본 파일은 건드리지 않는다.
    @discardableResult
    func removePocket(_ id: UUID) -> Result<Void, WorkbenchStoreError> {
        guard let existing = document.pockets.first(where: { $0.id == id }),
              PrivacyMode.currentlyActive || existing.isPrivate != true else { return .failure(.missingPocket) }
        // 일반 모드에서 보이지 않는 비공개 출처 항목을 조용히 함께 지우지 않는다.
        guard !hasHiddenEntries(existing) else {
            return .failure(.persistence("포켓 안에 이 모드에서 보이지 않는 항목이 있어 삭제하지 않았습니다."))
        }
        var candidate = document
        candidate.pockets.removeAll { $0.id == id }
        if let failure = commit(candidate) { return .failure(failure) }
        epochs[id, default: 0] += 1
        return .success(())
    }

    /// 포켓 안의 참조를 모두 뺀다(포켓은 남는다). 원본·예전 복사본은 그대로다.
    @discardableResult
    func clearPocket(_ id: UUID) -> Result<Void, WorkbenchStoreError> {
        guard let index = document.pockets.firstIndex(where: { $0.id == id }),
              PrivacyMode.currentlyActive || document.pockets[index].isPrivate != true else { return .failure(.missingPocket) }
        var candidate = document
        // 보이는 항목만 비운다. 이 모드에서 숨겨진 항목은 그대로 둔다.
        candidate.pockets[index].entries.removeAll(where: \.isVisibleNow)
        if let failure = commit(candidate) { return .failure(failure) }
        epochs[id, default: 0] += 1
        return .success(())
    }

    /// 명시적인 공개/비공개 전환. 포켓의 id·이름·항목·순서는 그대로 두고 플래그만 바꾼다.
    @discardableResult
    func setPocketPrivate(_ id: UUID, _ isPrivate: Bool) -> Result<Void, WorkbenchStoreError> {
        guard let index = document.pockets.firstIndex(where: { $0.id == id }) else { return .failure(.missingPocket) }
        let flag: Bool? = isPrivate ? true : nil
        guard document.pockets[index].isPrivate != flag else { return .success(()) }
        var candidate = document
        candidate.pockets[index].isPrivate = flag
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(())
    }

    /// 항목 하나의 명시적인 공개/비공개 전환(포켓 자체가 비공개이면 포켓이 가린다).
    @discardableResult
    func setEntryPrivate(_ entryID: UUID, in pocketID: UUID, _ isPrivate: Bool) -> Result<Void, WorkbenchStoreError> {
        guard let p = document.pockets.firstIndex(where: { $0.id == pocketID }),
              let e = document.pockets[p].entries.firstIndex(where: { $0.id == entryID }) else { return .failure(.missingPocket) }
        let flag: Bool? = isPrivate ? true : nil
        guard document.pockets[p].entries[e].isPrivate != flag else { return .success(()) }
        var candidate = document
        candidate.pockets[p].entries[e].isPrivate = flag
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(())
    }

    /// 이름 중복은 지금 모드에서 보이는 포켓끼리만 비교한다(일반 모드에서 비공개 포켓 이름이 드러나지 않게).
    private func hasPocket(named name: String, excluding id: UUID?) -> Bool {
        document.pockets.contains {
            $0.id != id && PrivacyMode.isVisible($0.isPrivate) && $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    // MARK: 항목

    /// 선택한 포켓 끝에 참조를 순서대로 담는다. 같은 포켓 안의 같은 출처는 건너뛰고,
    /// Google 포토는 같은 항목 ID가 어느 포켓에 있든 새 세션으로 다시 연결한다.
    /// `expectedEpoch`가 있으면 그 사이 포켓이 비워졌거나 지워진 경우 아무것도 담지 않는다.
    func add(_ newEntries: [WorkbenchEntry], to pocketID: UUID, expectedEpoch: Int? = nil) -> WorkbenchAddOutcome {
        guard let index = document.pockets.firstIndex(where: { $0.id == pocketID }) else {
            return WorkbenchAddOutcome(failureMessage: WorkbenchStoreError.missingPocket.localizedDescription)
        }
        if let expectedEpoch, expectedEpoch != epoch(of: pocketID) {
            return WorkbenchAddOutcome(failureMessage: "그 사이 포켓이 비워지거나 바뀌어 담지 않았습니다.")
        }
        var candidate = document
        var outcome = WorkbenchAddOutcome()
        var known = Set(candidate.pockets[index].entries.map(\.identity))
        var changed = false
        for entry in newEntries {
            if entry.kind == .googlePhoto, let itemID = entry.googleItemID {
                var matched = false
                for p in candidate.pockets.indices {
                    for e in candidate.pockets[p].entries.indices where candidate.pockets[p].entries[e].googleItemID == itemID {
                        candidate.pockets[p].entries[e].googleSessionID = entry.googleSessionID
                        candidate.pockets[p].entries[e].googleSessionExpiresAt = entry.googleSessionExpiresAt
                        candidate.pockets[p].entries[e].relinkReason = nil
                        matched = true
                        changed = true
                    }
                }
                if matched, known.contains(entry.identity) { outcome.relinked += 1; continue }
            }
            // 다시 연결이 필요한 같은 출처를 다시 담으면 새 항목을 만들지 않고 그 항목을 되살린다(북마크는 새 것으로).
            if known.contains(entry.identity),
               let existing = candidate.pockets[index].entries.firstIndex(where: { $0.identity == entry.identity && $0.relinkReason != nil }) {
                if entry.kind == .fileBookmark { candidate.pockets[index].entries[existing].bookmarkData = entry.bookmarkData }
                candidate.pockets[index].entries[existing].relinkReason = nil
                outcome.relinked += 1
                changed = true
                continue
            }
            guard known.insert(entry.identity).inserted else { outcome.duplicates += 1; continue }
            var fresh = entry
            fresh.id = UUID()
            // 프라이버시 모드에서 공개 포켓에 새로 담는 항목은 항목 자신이 비공개다(포켓을 숨기지도, 항목을 공개하지도 않는다).
            if PrivacyMode.currentlyActive, candidate.pockets[index].isPrivate != true { fresh.isPrivate = true }
            candidate.pockets[index].entries.append(fresh)
            outcome.added += 1
            changed = true
        }
        guard changed else { return outcome }
        if let failure = commit(candidate) {
            return WorkbenchAddOutcome(failureMessage: failure.localizedDescription)
        }
        return outcome
    }

    /// 포켓에서 참조만 뺀다. 인덱스 기록에 성공한 경우에만 화면에도 반영한다.
    @discardableResult
    func removeEntries(_ ids: Set<UUID>, from pocketID: UUID) -> Result<Void, WorkbenchStoreError> {
        guard let index = document.pockets.firstIndex(where: { $0.id == pocketID }) else { return .failure(.missingPocket) }
        var candidate = document
        candidate.pockets[index].entries.removeAll { ids.contains($0.id) }
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(())
    }

    /// 포켓 안 순서를 바꾼다(List의 끌어 옮기기).
    @discardableResult
    func moveEntries(in pocketID: UUID, from source: IndexSet, to destination: Int) -> Result<Void, WorkbenchStoreError> {
        guard let index = document.pockets.firstIndex(where: { $0.id == pocketID }) else { return .failure(.missingPocket) }
        var candidate = document
        // 인덱스는 보이는 항목 기준이다. 보이는 항목들이 차지하던 자리에 새 순서를 채우고 숨은 항목은 제자리에 둔다.
        let entries = candidate.pockets[index].entries
        let visiblePositions = entries.indices.filter { entries[$0].isVisibleNow }
        var reordered = visiblePositions.map { entries[$0] }
        reordered.move(fromOffsets: source, toOffset: destination)
        for (slot, position) in visiblePositions.enumerated() { candidate.pockets[index].entries[position] = reordered[slot] }
        if let failure = commit(candidate) { return .failure(failure) }
        return .success(())
    }

    /// 실행 중 확인한 '다시 연결' 상태를 항목에 남긴다(nil이면 해제). 항목은 지우지 않는다.
    func setRelink(_ reason: String?, forEntryIDs ids: Set<UUID>) {
        guard !ids.isEmpty, !isReadOnly else { return }
        var candidate = document
        var changed = false
        for p in candidate.pockets.indices {
            for e in candidate.pockets[p].entries.indices where ids.contains(candidate.pockets[p].entries[e].id) {
                if candidate.pockets[p].entries[e].relinkReason != reason {
                    candidate.pockets[p].entries[e].relinkReason = reason
                    changed = true
                }
            }
        }
        if changed { _ = commit(candidate) }
    }

    // MARK: 기록 읽기·쓰기

    /// 읽기 전용으로 잠긴 기록을 다시 읽어 본다(일시적인 읽기 실패 복구용).
    func reload() { load() }

    /// 해석할 수 없는 기록을 지우지 않고 옆으로 옮겨 두고 빈 작업대로 시작한다. 사용자가 직접 고른 경우에만 부른다.
    func startFreshKeepingUnreadable() -> Bool {
        guard isReadOnly else { return true }
        let name = "workbench.unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).json"
        do {
            try FileManager.default.moveItem(at: fileURL, to: directory.appendingPathComponent(name))
        } catch {
            persistenceError = UserErrorText.message("기록을 따로 보관하지 못해 새로 시작하지 않았습니다", error, recovery: "저장 공간을 확인한 뒤 앱을 다시 열어 주세요.")
            return false
        }
        isReadOnly = false
        persistenceError = nil
        document = WorkbenchDocument()
        bridgeLegacyIfNeeded()
        storedPockets = document.pockets
        return true
    }

    private func load() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: fileURL.path) else {
            document = WorkbenchDocument()
            isReadOnly = false
            persistenceError = nil
            bridgeLegacyIfNeeded()
            storedPockets = document.pockets
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            lock(UserErrorText.message("작업대 기록을 읽지 못했습니다", error, recovery: "기록은 그대로 두었고 변경을 막았습니다."))
            return
        }
        do {
            document = try JSONDecoder().decode(WorkbenchDocument.self, from: data)
        } catch {
            // 해석할 수 없는 기록은 같은 내용을 한 번 더 보관해 두고, 덮어쓰지 못하게 잠근다.
            let backup = directory.appendingPathComponent("workbench.unreadable-copy.json")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup, options: .atomic) }
            lock("작업대 기록을 해석하지 못해 변경을 막았습니다. 기록 파일은 지우지 않고 보관했습니다.")
            return
        }
        isReadOnly = false
        persistenceError = nil
        bridgeLegacyIfNeeded()
        storedPockets = document.pockets
    }

    private func lock(_ message: String) {
        isReadOnly = true
        persistenceError = message
        document = WorkbenchDocument()
        storedPockets = []
    }

    /// 쓰기에 성공했을 때만 메모리·화면 상태를 바꾼다. 실패 사유를 돌려주고 이전 기록은 그대로 둔다.
    private func commit(_ candidate: WorkbenchDocument) -> WorkbenchStoreError? {
        guard !isReadOnly else {
            persistenceError = WorkbenchStoreError.readOnly.localizedDescription
            return .readOnly
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(candidate)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            let message = UserErrorText.message("작업대를 저장하지 못했습니다", error, recovery: "저장 공간을 확인한 뒤 다시 시도해 주세요.")
            persistenceError = message
            return .persistence(message)
        }
        document = candidate
        storedPockets = candidate.pockets
        persistenceError = nil
        return nil
    }

    // MARK: 예전 저장소 → '기존 재료'·'기존 전송 대기' 포켓

    /// 예전 영상 재료 메타데이터와 2.24.4 전송 대기 목록을 순서 그대로 각각의 포켓으로 한 번만 옮긴다.
    /// 예전 인덱스·복사본 파일은 읽기만 하고 지우거나 다시 복사하지 않는다. 읽지 못한 예전 기록은 건드리지 않고
    /// 완료로 표시하지 않아 다음 실행에서 다시 시도한다. 한쪽 쓰기가 실패해도 다른 쪽과 기존 기록은 그대로다.
    private func bridgeLegacyIfNeeded() {
        guard !isReadOnly else { return }
        if !document.legacyBridgeDone { bridgeLegacyMaterials() }
        if !document.legacyTransferBridgeDone { bridgeLegacyTransferPending() }
    }

    private func bridgeLegacyMaterials() {
        switch legacy.loadState {
        case .unreadable:
            persistenceError = "예전 영상 재료 목록을 읽지 못해 옮기지 않았습니다. 파일은 그대로이며 다음 실행에서 다시 시도합니다."
        case .absent:
            document.legacyBridgeDone = true
        case .loaded:
            guard !legacy.items.isEmpty else {
                document.legacyBridgeDone = true
                return
            }
            var candidate = document
            candidate.legacyBridgeDone = true
            candidate.pockets.insert(
                WorkbenchPocket(name: Self.uniqueName(Self.legacyPocketName, in: candidate.pockets),
                                entries: legacy.items.map(Self.entry(fromLegacy:))),
                at: 0)
            if commit(candidate) != nil { document.legacyBridgeDone = false }
        }
    }

    static let legacyTransferPocketName = "기존 전송 대기"

    private func bridgeLegacyTransferPending() {
        switch legacyTransfer.loadState {
        case .unreadable:
            persistenceError = "예전 전송 대기 기록을 읽지 못해 옮기지 않았습니다. 파일은 그대로이며 다음 실행에서 다시 시도합니다."
        case .absent:
            document.legacyTransferBridgeDone = true
        case .loaded:
            guard !legacyTransfer.entries.isEmpty else {
                document.legacyTransferBridgeDone = true
                return
            }
            var candidate = document
            candidate.legacyTransferBridgeDone = true
            // 재료 포켓이 있으면 그 바로 뒤에 둔다(둘 다 예전 것이라 사용자 포켓보다 앞).
            let position = candidate.pockets.first?.name.hasPrefix(Self.legacyPocketName) == true ? 1 : 0
            candidate.pockets.insert(
                WorkbenchPocket(name: Self.uniqueName(Self.legacyTransferPocketName, in: candidate.pockets),
                                entries: legacyTransfer.entries.map(Self.entry(fromPending:))),
                at: position)
            if commit(candidate) != nil { document.legacyTransferBridgeDone = false }
        }
    }

    private static func uniqueName(_ base: String, in pockets: [WorkbenchPocket]) -> String {
        var name = base
        var number = 2
        while pockets.contains(where: { $0.name == name }) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// 2.24.4 전송 대기 항목 → 제자리에서 읽는 예전 복사본 참조. 구성요소가 둘이면 Live/Motion으로 묶음을 유지한다.
    nonisolated static func entry(fromPending item: LegacyTransferPendingStore.Entry) -> WorkbenchEntry {
        var entry = WorkbenchEntry(
            id: UUID(uuidString: item.id) ?? UUID(), kind: .legacyCopy, mediaKind: item.isVideo ? .video : .photo,
            name: item.displayName, sourceLabel: item.sourceLabel, addedAt: item.addedAt)
        entry.legacyFilename = item.fileNames.first.map { WorkbenchLegacyFiles.pendingName(id: item.id, fileName: $0) }
        if item.fileNames.count > 1 {
            entry.legacyCompanionFilename = WorkbenchLegacyFiles.pendingName(id: item.id, fileName: item.fileNames[1])
        }
        if entry.legacyFilename == nil { entry.relinkReason = "예전 전송 대기 항목의 파일 정보가 없습니다. 원본에서 다시 담아 주세요." }
        return entry
    }

    nonisolated static func entry(fromLegacy item: MaterialItem) -> WorkbenchEntry {
        let hasRemote = item.connectionID != nil && item.remotePath != nil
        var entry = WorkbenchEntry(
            id: item.id, kind: hasRemote ? .remote : .legacyCopy, mediaKind: item.isVideo ? .video : .photo,
            name: item.name, sourceLabel: item.sourceKind.title, byteCount: item.byteCount,
            modifiedAt: item.modifiedAt, addedAt: item.addedAt)
        entry.connectionID = item.connectionID
        entry.path = item.remotePath
        entry.remoteIdentifier = item.remoteIdentifier
        entry.contentTypeIdentifier = item.contentTypeIdentifier
        entry.legacyFilename = item.localFilename
        if !hasRemote, item.localFilename == nil {
            entry.relinkReason = item.failureMessage ?? "예전 재료의 원본 연결 정보가 없습니다. 다시 담아 주세요."
        }
        return entry
    }
}
