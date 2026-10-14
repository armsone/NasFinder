import Foundation

/// One editor ("예고편 조절" or "음악 입히기") the user left without discarding it. It keeps
/// that editor's own session alive in this process: the staged copies, the picked music,
/// the last finished video and every setting that was on screen. Nothing is written to
/// disk for it and nothing here survives the app being quit.
struct TrailerDraftEntry: Identifiable {
    let id: UUID
    let mode: VideoTrailerMode
    let items: [RemoteFileItem]
    let service: any RemoteFileService
    /// The editor's session, opaque here; only `VideoTrailerView` reads it back.
    let session: AnyObject
    /// Ends the session and removes its own temporary files. Originals are never touched.
    let discard: @MainActor () -> Void

    var title: String {
        let kind = mode == .mediaMusic ? "음악 입히기" : "예고편"
        guard let first = items.first else { return kind }
        return items.count == 1 ? "\(kind) · \(first.name)" : "\(kind) · \(first.name) 외 \(items.count - 1)개"
    }
}

/// The editors waiting to be reopened from the PhoneHard entry. Leaving an editor adds
/// it here; only an explicit choice by the user ever discards one.
@MainActor
final class TrailerDraftStore: ObservableObject {
    static let shared = TrailerDraftStore()

    @Published private(set) var entries: [TrailerDraftEntry] = []

    /// Keeps `entry`, in place of an earlier suspension of the same session only.
    func suspend(_ entry: TrailerDraftEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
        } else {
            entries.append(entry)
        }
    }

    /// The session is on screen again and owned by its editor; nothing is discarded.
    func reopen(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func discard(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries.remove(at: index).discard()
    }

    /// Suspended editors of the same kind other than the session `id`.
    func others(mode: VideoTrailerMode, than id: UUID) -> [TrailerDraftEntry] {
        entries.filter { $0.mode == mode && $0.id != id }
    }
}
