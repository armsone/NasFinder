import FileProvider
import Foundation

final class NasFinderFileProviderEnumerator: NSObject, NSFileProviderEnumerator {
    private let containerIdentifier: NSFileProviderItemIdentifier
    private let storage: NasFinderFileProviderStorage
    private let tasks = ProviderTaskRegistry()

    init(
        containerIdentifier: NSFileProviderItemIdentifier,
        storage: NasFinderFileProviderStorage
    ) {
        self.containerIdentifier = containerIdentifier
        self.storage = storage
        super.init()
    }

    func invalidate() {
        tasks.cancelAll()
    }

    func enumerateItems(
        for observer: NSFileProviderEnumerationObserver,
        startingAt page: NSFileProviderPage
    ) {
        let observer = ProviderSendableBox(observer)
        let task = Task { [containerIdentifier, storage] in
            do {
                let snapshot = try await storage.snapshot(for: containerIdentifier)
                try Task.checkCancellation()
                observer.value.didEnumerate(snapshot.items)
                observer.value.finishEnumerating(upTo: nil)
            } catch is CancellationError {
                observer.value.finishEnumeratingWithError(NSFileProviderError(.pageExpired))
            } catch {
                observer.value.finishEnumeratingWithError(error)
            }
        }
        tasks.insert(task)
    }

    func enumerateChanges(
        for observer: NSFileProviderChangeObserver,
        from syncAnchor: NSFileProviderSyncAnchor
    ) {
        let observer = ProviderSendableBox(observer)
        let task = Task { [containerIdentifier, storage] in
            do {
                let changes = try await storage.changes(
                    for: containerIdentifier,
                    from: syncAnchor
                )
                try Task.checkCancellation()
                if !changes.updatedItems.isEmpty {
                    observer.value.didUpdate(changes.updatedItems)
                }
                if !changes.deletedIdentifiers.isEmpty {
                    observer.value.didDeleteItems(
                        withIdentifiers: changes.deletedIdentifiers
                    )
                }
                observer.value.finishEnumeratingChanges(
                    upTo: changes.anchor,
                    moreComing: false
                )
            } catch is CancellationError {
                observer.value.finishEnumeratingWithError(NSFileProviderError(.syncAnchorExpired))
            } catch {
                observer.value.finishEnumeratingWithError(error)
            }
        }
        tasks.insert(task)
    }

    func currentSyncAnchor(
        completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void
    ) {
        let completionHandler = ProviderSendableBox(completionHandler)
        let task = Task { [containerIdentifier, storage] in
            let snapshot = try? await storage.snapshot(for: containerIdentifier)
            completionHandler.value(snapshot?.anchor)
        }
        tasks.insert(task)
    }
}

private final class ProviderTaskRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [Task<Void, Never>] = []

    func insert(_ task: Task<Void, Never>) {
        lock.lock()
        tasks.removeAll(where: { $0.isCancelled })
        tasks.append(task)
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let activeTasks = tasks
        tasks.removeAll()
        lock.unlock()
        activeTasks.forEach { $0.cancel() }
    }
}
