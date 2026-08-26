import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Concurrency preference selectable by the user.
/// - auto: Conservative limit based on storage type (network/removable: 2, local fixed: 4) and thermal state.
/// - explicit (1, 2, 4, 8): Fixed upper bound, dynamically clamped to 1 under serious/critical thermal pressure.
enum SuperThumbnailWorkerPreference: String, CaseIterable, Identifiable, Sendable, Codable {
    case auto = "auto"
    case one = "1"
    case two = "2"
    case four = "4"
    case eight = "8"

    var id: String { rawValue }

    var explicitCount: Int? {
        switch self {
        case .auto: return nil
        case .one: return 1
        case .two: return 2
        case .four: return 4
        case .eight: return 8
        }
    }

    var displayName: String {
        switch self {
        case .auto:
            return "자동"
        case .one:
            return "1개"
        case .two:
            return "2개"
        case .four:
            return "4개"
        case .eight:
            return "8개"
        }
    }

    var menuTitle: String {
        switch self {
        case .auto:
            return "자동 (저장소 및 발열에 맞춤)"
        case .one:
            return "1개 (순차 처리)"
        case .two:
            return "2개 작업자"
        case .four:
            return "4개 작업자"
        case .eight:
            return "8개 작업자"
        }
    }
}

/// Pure policy functions and helpers for concurrency limits and storage/thermal detection.
enum SuperThumbnailConcurrencyPolicy {
    static let autoLocalWorkerLimit = 4
    static let autoRemoteOrRemovableWorkerLimit = 2
    static let maxFolderWorkers = 2
    static let thermalThrottledWorkerLimit = 1

    /// Detects if a URL is on a network volume or removable storage.
    static func isNetworkOrRemovable(url: URL) -> Bool {
        let canonical = url.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.volumeIsLocalKey, .volumeIsRemovableKey, .volumeIsInternalKey]
        guard let values = try? canonical.resourceValues(forKeys: keys) else {
            return true // Conservative fallback
        }
        if values.volumeIsLocal == false || values.volumeIsRemovable == true {
            return true
        }
        return false
    }

    /// Base worker count before thermal pressure is applied.
    static func baseWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool
    ) -> Int {
        switch preference {
        case .auto:
            return isNetworkOrRemovable ? autoRemoteOrRemovableWorkerLimit : autoLocalWorkerLimit
        case .one:
            return 1
        case .two:
            return 2
        case .four:
            return 4
        case .eight:
            return 8
        }
    }

    /// Whether the system is under serious or critical thermal pressure.
    static func isThermalThrottled(thermalState: ProcessInfo.ThermalState) -> Bool {
        thermalState == .serious || thermalState == .critical
    }

    /// Effective worker limit for item-level processing.
    /// Clamps to 1 if thermal state is serious or critical.
    static func effectiveWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        if isThermalThrottled(thermalState: thermalState) {
            return thermalThrottledWorkerLimit
        }
        let base = baseWorkerLimit(preference: preference, isNetworkOrRemovable: isNetworkOrRemovable)
        return max(1, base)
    }

    /// Effective worker limit for folder processing within a single depth group.
    /// Deepest depth first; within one depth allows bounded concurrency capped at 2.
    /// Clamped to 1 under thermal pressure.
    static func effectiveFolderWorkerLimit(
        preference: SuperThumbnailWorkerPreference,
        isNetworkOrRemovable: Bool,
        thermalState: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    ) -> Int {
        let itemLimit = effectiveWorkerLimit(
            preference: preference,
            isNetworkOrRemovable: isNetworkOrRemovable,
            thermalState: thermalState
        )
        return min(itemLimit, maxFolderWorkers)
    }
}

/// Helper for partitioning folder entries by depth into deepest-first batches.
enum FolderDepthGrouping {
    /// Groups folders by depth descending (deepest depth first).
    /// Folders within the same depth are sorted by localized path for determinism.
    static func groupDeepestFirst(folders: [FolderEntry]) -> [[FolderEntry]] {
        let grouped = Dictionary(grouping: folders, by: \.depth)
        let sortedDepths = grouped.keys.sorted(by: >)
        return sortedDepths.map { depth in
            (grouped[depth] ?? []).sorted {
                $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
            }
        }
    }
}

/// Result of processing a single media file in bounded concurrency.
struct MediaFileProcessingOutcome: Sendable {
    let file: MediaFile
    let result: Result<ProcessingResult, Error>
    let previewItem: SuperThumbnailMacPreviewItem?
}

/// Result of processing a single folder in bounded concurrency.
struct FolderProcessingOutcome: Sendable {
    let folder: FolderEntry
    let result: Result<FolderProcessingResult, Error>
    let previewItem: SuperThumbnailMacPreviewItem?
}

extension VaultProcessor {
    /// Processes a single media file asynchronously and gathers result and preview item.
    static func processMediaItem(
        _ file: MediaFile,
        workerID: String
    ) async -> MediaFileProcessingOutcome {
        do {
            let result = try await process(file, workerID: workerID)
            var preview: SuperThumbnailMacPreviewItem? = nil
            let vault = file.url.deletingLastPathComponent()
                .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
            if let filename = try? NasFinderVaultCompatibility.thumbnailFilename(for: file.url) {
                let thumbnailURL = vault.appendingPathComponent(filename)
                if fileManager.fileExists(atPath: thumbnailURL.path) {
                    preview = SuperThumbnailMacPreviewItem(
                        id: SuperThumbnailPreviewOrdering.canonicalID(for: thumbnailURL),
                        name: file.url.lastPathComponent,
                        isFolder: false,
                        vaultFileURL: thumbnailURL
                    )
                }
            }
            return MediaFileProcessingOutcome(
                file: file,
                result: .success(result),
                previewItem: preview
            )
        } catch is CancellationError {
            return MediaFileProcessingOutcome(
                file: file,
                result: .failure(CancellationError()),
                previewItem: nil
            )
        } catch {
            return MediaFileProcessingOutcome(
                file: file,
                result: .failure(error),
                previewItem: nil
            )
        }
    }

    /// Processes a single folder asynchronously and gathers result and preview item.
    static func processFolderItem(
        _ folder: FolderEntry,
        workerID: String,
        tileCache: FolderSheetTileCache
    ) async -> FolderProcessingOutcome {
        do {
            let result = try await Task.detached(priority: .utility) {
                try VaultProcessor.processFolder(
                    folder,
                    workerID: workerID,
                    tileCache: tileCache
                )
            }.value

            var preview: SuperThumbnailMacPreviewItem? = nil
            if result.state == .generated {
                let parentVault = folder.url.deletingLastPathComponent()
                    .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
                let sheetURL = parentVault.appendingPathComponent(
                    NasFinderVaultCompatibility.folderThumbnailFilename(folderName: folder.url.lastPathComponent)
                )
                if fileManager.fileExists(atPath: sheetURL.path) {
                    preview = SuperThumbnailMacPreviewItem(
                        id: SuperThumbnailPreviewOrdering.canonicalID(for: sheetURL),
                        name: folder.url.lastPathComponent,
                        isFolder: true,
                        vaultFileURL: sheetURL
                    )
                }
            }
            return FolderProcessingOutcome(
                folder: folder,
                result: .success(result),
                previewItem: preview
            )
        } catch is CancellationError {
            return FolderProcessingOutcome(
                folder: folder,
                result: .failure(CancellationError()),
                previewItem: nil
            )
        } catch {
            return FolderProcessingOutcome(
                folder: folder,
                result: .failure(error),
                previewItem: nil
            )
        }
    }
}
