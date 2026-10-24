import AVFoundation
import Foundation

/// One editor ("예고편 조절" or "뮤직비디오") the user left without discarding it. A live entry
/// keeps that editor's own session alive in this process (staged copies, picked music, the
/// last finished video and every setting on screen). Every entry that has been saved is also
/// a project on disk (`TrailerProjectStore`), so after a restart the entry is rebuilt from it.
struct TrailerDraftEntry: Identifiable {
    let id: UUID
    let mode: VideoTrailerMode
    let items: [RemoteFileItem]
    let service: any RemoteFileService
    /// The editor's session, opaque here; only `VideoTrailerView` reads it back.
    let session: AnyObject
    /// Ends the session and removes its own temporary files. Originals are never touched.
    let discard: @MainActor () -> Void
    /// This session's own staged copy to draw a thumbnail from, and whether it is a
    /// still image; both captured when the editor suspended, never the original remote
    /// file (which the management screen must never touch).
    var thumbnailURL: URL?
    var thumbnailIsImage = false
    /// The actually generated video's own length once one exists, for display only;
    /// before anything has been generated this is the sum of every staged source's
    /// nominal duration instead, as a planned-length estimate.
    var totalDuration: Double = 0
    /// When this editor was left, for the management screen's "마지막 편집" display.
    var suspendedAt = Date()
    /// The name the user gave this project, if any.
    var customTitle: String?
    /// 비공개 편집본(nil = 공개). 목록·열기에서 일반 모드는 공개만 본다.
    var isPrivate: Bool?

    var title: String {
        if let customTitle, !customTitle.isEmpty { return customTitle }
        let kind = mode == .mediaMusic ? "뮤직비디오" : "예고편"
        let shown = items.filter { $0.isTrailerEligible }
        guard let first = shown.first else { return kind }
        return shown.count == 1 ? "\(kind) · \(first.name)" : "\(kind) · \(first.name) 외 \(shown.count - 1)개"
    }
}

/// The editors waiting to be reopened. Leaving an editor adds it here; only an explicit
/// choice by the user ever discards one. Projects saved on disk are loaded at launch.
@MainActor
final class TrailerDraftStore: ObservableObject {
    static let shared = TrailerDraftStore()

    /// 비공개를 포함한 전체 목록. 만들기·보관·되살리기·삭제는 항상 전체를 대상으로 한다.
    @Published private(set) var storedEntries: [TrailerDraftEntry] = []
    /// 공개 범위 전환처럼 디스크에 쓰는 동작이 실패했을 때 화면에 알린다.
    @Published var errorMessage: String?
    /// 지금 모드에서 보이는 편집본.
    var entries: [TrailerDraftEntry] { storedEntries.filter { PrivacyMode.isVisible($0.isPrivate) } }

    init() {
        let records = TrailerProjectStore.shared.records.values.sorted { $0.updatedAt > $1.updatedAt }
        storedEntries = records.map(Self.entry(from:))
        records.forEach(refreshOutputDuration(for:))
    }

    /// 저장된 완성 영상의 실제 길이를 백그라운드에서 읽어 목록 표시를 맞춘다. 영상 파일을 읽지 못하면 값을 만들지 않는다.
    private func refreshOutputDuration(for record: TrailerProjectRecord) {
        guard let file = record.outputFile,
              let url = TrailerProjectStore.shared.fileURL(file, id: record.id) else { return }
        let id = record.id
        Task { @MainActor [weak self] in
            guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
                  seconds.isFinite, seconds > 0,
                  let self, let index = self.storedEntries.firstIndex(where: { $0.id == id }) else { return }
            self.storedEntries[index].totalDuration = seconds
        }
    }

    /// An entry for a project that exists only on disk (after a restart, or a duplicate).
    static func entry(from record: TrailerProjectRecord) -> TrailerDraftEntry {
        let store = TrailerProjectStore.shared
        let rows = Dictionary(record.sources.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let items: [RemoteFileItem] = (0..<max(record.nextSourceID, 0)).map { index in
            guard let row = rows[index] else {
                // A source the user took out: it keeps its index so the others keep theirs.
                return RemoteFileItem(connectionID: TrailerProjectMediaService.connectionID, path: "removed-\(index)",
                                      name: "제거된 항목", kind: .file, size: nil, modifiedAt: nil, contentTypeIdentifier: nil)
            }
            return RemoteFileItem(
                connectionID: TrailerProjectMediaService.connectionID,
                path: store.fileURL(row.file, id: record.id)?.path ?? "missing-\(index)", name: row.name,
                kind: .file, size: nil, modifiedAt: row.captureDate, contentTypeIdentifier: row.contentTypeIdentifier)
        }
        let id = record.id
        var entry = TrailerDraftEntry(
            id: id, mode: record.mode == "mediaMusic" ? .mediaMusic : .trailer, items: items,
            service: TrailerProjectMediaService(), session: TrailerPersistedSession(record: record),
            discard: { })
        if let first = record.sources.first, let url = store.fileURL(first.file, id: id) {
            entry.thumbnailURL = url
            entry.thumbnailIsImage = first.isImage
        }
        // 만들어 둔 영상이 있으면 그 영상의 실제 길이가 기준이다(아래 `refreshOutputDuration`이 읽어 오기 전에는 0).
        // 원본 길이 합계는 영상이 없을 때의 추정값으로만 쓴다.
        if record.outputFile != nil {
            entry.totalDuration = 0
        } else {
            entry.totalDuration = record.scenes.map { $0.filter { !$0.excluded }.reduce(0) { $0 + $1.length } }
                ?? record.sources.reduce(0) { $0 + $1.duration }
        }
        entry.suspendedAt = record.updatedAt
        entry.customTitle = record.customTitle
        entry.isPrivate = record.isPrivate
        return entry
    }

    /// Keeps `entry`, in place of an earlier suspension of the same session only.
    func suspend(_ entry: TrailerDraftEntry) {
        if let index = storedEntries.firstIndex(where: { $0.id == entry.id }) {
            storedEntries[index] = entry
        } else {
            storedEntries.append(entry)
        }
    }

    /// The session is on screen again and owned by its editor; nothing is discarded.
    func reopen(_ id: UUID) {
        storedEntries.removeAll { $0.id == id }
    }

    /// The user chose to delete this edit: its session ends and its saved project folder goes.
    /// Material basket items, collection videos and originals are other files and stay.
    func discard(_ id: UUID) {
        if let index = storedEntries.firstIndex(where: { $0.id == id }) {
            storedEntries.remove(at: index).discard()
        }
        TrailerProjectStore.shared.delete(id)
    }

    func rename(_ id: UUID, to title: String) {
        Task {
            // 프로젝트 저장 줄에 서서 기록된 경우에만 목록 이름을 바꾼다.
            guard await TrailerProjectStore.shared.rename(id, to: title),
                  let index = storedEntries.firstIndex(where: { $0.id == id }) else { return }
            storedEntries[index].customTitle = TrailerProjectStore.shared.records[id]?.customTitle
        }
    }

    func duplicate(_ id: UUID) async {
        guard let copyID = await TrailerProjectStore.shared.duplicate(id),
              let record = TrailerProjectStore.shared.records[copyID] else { return }
        storedEntries.append(Self.entry(from: record))
        refreshOutputDuration(for: record)
    }

    /// Suspended editors of the same kind other than the session `id`.
    func others(mode: VideoTrailerMode, than id: UUID) -> [TrailerDraftEntry] {
        entries.filter { $0.mode == mode && $0.id != id }
    }

    /// 명시적인 공개/비공개 전환(디스크 프로젝트와 목록 항목을 함께 바꾼다).
    func setPrivate(_ id: UUID, _ isPrivate: Bool) {
        Task {
            // 디스크에 저장된 프로젝트가 있으면 쓰기에 성공했을 때만 목록의 표시를 바꾼다(실패하면 이전 상태 유지 + 알림).
            // 아직 프로젝트로 저장되지 않은 보관 편집은 디스크에 쓸 것이 없어 목록 항목만 바꾼다.
            if TrailerProjectStore.shared.records[id] != nil {
                guard await TrailerProjectStore.shared.setPrivate(id, isPrivate) else {
                    errorMessage = "공개 범위를 저장하지 못해 바꾸지 않았습니다. 잠시 후 다시 시도해 주세요."
                    return
                }
            }
            if let index = storedEntries.firstIndex(where: { $0.id == id }) {
                storedEntries[index].isPrivate = isPrivate ? true : nil
            }
        }
    }
}
