import SwiftUI

enum FolderItemCountState: Equatable {
    case loading
    case counted(folders: Int, files: Int)
    case unavailable

    var label: String {
        switch self {
        case .loading: "개수 확인 중…"
        case let .counted(folders, files): "폴더 \(folders), 파일 \(files)"
        case .unavailable: "개수 확인 불가"
        }
    }
}

/// Caches immediate (non-recursive) child counts per connection/folder/generation,
/// with bounded concurrency so grid/list scrolling never fires unbounded network requests.
actor FolderItemCountCache {
    static let shared = FolderItemCountCache()

    private struct Entry {
        let state: FolderItemCountState
        let generation: Int
        let cachedAt: ContinuousClock.Instant
    }

    private let ttl: Duration = .seconds(20)
    private let maximumConcurrentRequests = 2
    private var activeRequestCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<(state: FolderItemCountState, wasCancelled: Bool), Never>] = [:]

    func count(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        generation: Int
    ) async -> FolderItemCountState {
        let key = "\(item.connectionID.uuidString)|\(item.path)"
        let inFlightKey = "\(key)|\(generation)"
        pruneExpiredEntries()

        if let entry = entries[key],
           entry.generation == generation,
           entry.cachedAt.duration(to: ContinuousClock.now) < ttl {
            return entry.state
        }

        if let existingTask = inFlight[inFlightKey] {
            return await existingTask.value.state
        }

        let task = Task<(state: FolderItemCountState, wasCancelled: Bool), Never> { [weak self] in
            guard let self else { return (.unavailable, false) }
            await self.acquireSlot()
            defer { Task { await self.releaseSlot() } }
            return await self.fetchCount(for: item, service: service)
        }
        inFlight[inFlightKey] = task
        let (state, wasCancelled) = await task.value
        inFlight[inFlightKey] = nil
        if !wasCancelled {
            entries[key] = Entry(state: state, generation: generation, cachedAt: ContinuousClock.now)
        }
        return state
    }

    private func pruneExpiredEntries() {
        let now = ContinuousClock.now
        entries = entries.filter { $0.value.cachedAt.duration(to: now) < ttl }
    }

    private func fetchCount(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> (state: FolderItemCountState, wasCancelled: Bool) {
        do {
            let children = try await service.list(directory: item.path)
                .filter { RemoteFileVisibilityPolicy.shouldDisplay(filename: $0.name) }
            let folders = children.filter(\.isDirectory).count
            let files = children.count - folders
            return (.counted(folders: folders, files: files), false)
        } catch is CancellationError {
            return (.unavailable, true)
        } catch {
            return (.unavailable, false)
        }
    }

    private func acquireSlot() async {
        if activeRequestCount < maximumConcurrentRequests {
            activeRequestCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
        // The permit was transferred directly from releaseSlot(); do not increment again.
    }

    private func releaseSlot() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
            return
        }
        activeRequestCount -= 1
    }
}

struct FolderItemCountLabel: View {
    enum Style {
        case caption
        case caption2
    }

    let item: RemoteFileItem
    let service: any RemoteFileService
    let generation: Int
    var style: Style = .caption

    // Base sizes match the system .caption/.caption2 text styles at the default
    // Dynamic Type size; scaling them with @ScaledMetric keeps them tracking Dynamic
    // Type (including the Mac app's forced accessibility size) the same way those
    // styles do, while landing at exactly 0.8x their rendered size. The Mac's 1.5x applies
    // on top, which leaves the count at 1.2x its earlier Mac size.
    @ScaledMetric(relativeTo: .caption) private var captionSize: CGFloat = 12
    @ScaledMetric(relativeTo: .caption2) private var caption2Size: CGFloat = 11

    @State private var state: FolderItemCountState = .loading

    var body: some View {
        Text(state.label)
            .font(.system(size: ui((style == .caption ? captionSize : caption2Size) * 0.8)))
            .task(id: taskID) {
                state = .loading
                let result = await FolderItemCountCache.shared.count(
                    for: item,
                    service: service,
                    generation: generation
                )
                guard !Task.isCancelled else { return }
                state = result
            }
    }

    private var taskID: String {
        "\(item.connectionID.uuidString)|\(item.path)|\(generation)"
    }
}
