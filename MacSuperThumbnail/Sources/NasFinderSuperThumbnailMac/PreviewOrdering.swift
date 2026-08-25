import Foundation

/// Ordering rules for the generated-thumbnail preview strip. The strip is
/// always newest-left: discovered vault files are ordered by modification
/// date (newest first) and equal dates fall back to the stable `id` so two
/// scans of the same vault never disagree; live results are placed at the
/// front because "most recently processed" is the newest thing on screen.
enum SuperThumbnailPreviewOrdering {
    static let defaultLimit = 60

    /// Live results are built from the user-selected root while discovery
    /// walks the symlink-resolved root; one canonical id keeps the two from
    /// producing duplicates of the same vault file.
    static func canonicalID(for vaultFileURL: URL) -> String {
        vaultFileURL.resolvingSymlinksInPath().standardizedFileURL.path
    }

    struct Candidate: Equatable {
        let item: SuperThumbnailMacPreviewItem
        let date: Date
    }

    static func newestFirst(
        _ candidates: [Candidate],
        limit: Int = defaultLimit
    ) -> [SuperThumbnailMacPreviewItem] {
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.item.id < rhs.item.id
        }
        var seen = Set<String>()
        let unique = sorted.filter { seen.insert($0.item.id).inserted }
        return Array(unique.prefix(max(limit, 0)).map(\.item))
    }

    /// Places `item` at the far left. A newly generated thumbnail that is
    /// already listed moves to the front; a merely re-verified one leaves the
    /// discovered strip unchanged so a resume run doesn't reshuffle it.
    static func prepending(
        _ item: SuperThumbnailMacPreviewItem,
        to items: [SuperThumbnailMacPreviewItem],
        limit: Int = defaultLimit,
        promotesExisting: Bool
    ) -> [SuperThumbnailMacPreviewItem] {
        if !promotesExisting {
            return items
        }
        var result = items.filter { $0.id != item.id }
        result.insert(item, at: 0)
        if result.count > limit {
            result.removeLast(result.count - max(limit, 0))
        }
        return result
    }
}
