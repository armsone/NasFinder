import FileProvider
import Foundation
import UniformTypeIdentifiers

final class NasFinderFileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let storage: NasFinderFileProviderStorage
    private let manager: NSFileProviderManager

    required init(domain: NSFileProviderDomain) {
        guard let manager = NSFileProviderManager(for: domain) else {
            fatalError("Unable to create an NSFileProviderManager for \(domain.identifier.rawValue)")
        }
        self.manager = manager
        self.storage = NasFinderFileProviderStorage(domainIdentifier: domain.identifier)
        super.init()
    }

    func invalidate() {}

    func item(
        for identifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionHandler = ProviderSendableBox(completionHandler)
        let task = Task { [storage] in
            do {
                let item = try await storage.item(for: identifier)
                try Task.checkCancellation()
                completionHandler.value(item, nil)
            } catch {
                completionHandler.value(nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func fetchContents(
        for itemIdentifier: NSFileProviderItemIdentifier,
        version requestedVersion: NSFileProviderItemVersion?,
        request: NSFileProviderRequest,
        completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionHandler = ProviderSendableBox(completionHandler)
        let temporaryDirectory: URL
        do {
            temporaryDirectory = try manager.temporaryDirectoryURL()
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        } catch {
            completionHandler.value(nil, nil, error)
            progress.completedUnitCount = 1
            return progress
        }

        let task = Task { [storage] in
            do {
                let (url, item) = try await storage.materialize(
                    identifier: itemIdentifier,
                    in: temporaryDirectory
                )
                try Task.checkCancellation()
                completionHandler.value(url, item, nil)
            } catch {
                completionHandler.value(nil, nil, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func createItem(
        basedOn itemTemplate: NSFileProviderItem,
        fields: NSFileProviderItemFields,
        contents url: URL?,
        options: NSFileProviderCreateItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionHandler = ProviderSendableBox(completionHandler)
        let createRequest = ProviderCreateRequest(
            parentIdentifier: itemTemplate.parentItemIdentifier.rawValue,
            filename: itemTemplate.filename,
            contentTypeIdentifier: itemTemplate.contentType?.identifier
                ?? UTType(filenameExtension: (itemTemplate.filename as NSString).pathExtension)?.identifier
                ?? UTType.data.identifier
        )
        let task = Task { [storage] in
            do {
                let item = try await storage.create(
                    request: createRequest,
                    contents: url
                )
                completionHandler.value(item, [], false, nil)
            } catch {
                completionHandler.value(nil, fields, false, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func modifyItem(
        _ item: NSFileProviderItem,
        baseVersion version: NSFileProviderItemVersion,
        changedFields: NSFileProviderItemFields,
        contents newContents: URL?,
        options: NSFileProviderModifyItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionHandler = ProviderSendableBox(completionHandler)
        let modifyRequest = ProviderModifyRequest(
            identifier: item.itemIdentifier.rawValue,
            parentIdentifier: item.parentItemIdentifier.rawValue,
            filename: item.filename,
            changesFilename: changedFields.contains(.filename),
            changesParent: changedFields.contains(.parentItemIdentifier),
            changesContents: changedFields.contains(.contents)
        )
        let task = Task { [storage] in
            do {
                let updated = try await storage.modify(
                    request: modifyRequest,
                    contents: newContents
                )
                completionHandler.value(updated, [], false, nil)
            } catch {
                completionHandler.value(nil, changedFields, false, error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func deleteItem(
        identifier: NSFileProviderItemIdentifier,
        baseVersion version: NSFileProviderItemVersion,
        options: NSFileProviderDeleteItemOptions = [],
        request: NSFileProviderRequest,
        completionHandler: @escaping (Error?) -> Void
    ) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let completionHandler = ProviderSendableBox(completionHandler)
        let task = Task { [storage] in
            do {
                try await storage.delete(identifier: identifier)
                completionHandler.value(nil)
            } catch {
                completionHandler.value(error)
            }
            progress.completedUnitCount = 1
        }
        progress.cancellationHandler = { task.cancel() }
        return progress
    }

    func enumerator(
        for containerItemIdentifier: NSFileProviderItemIdentifier,
        request: NSFileProviderRequest
    ) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .trashContainer {
            throw NasFinderFileProviderErrors.readOnly
        }
        guard containerItemIdentifier == .rootContainer
                || containerItemIdentifier == .workingSet
                || NasFinderFileProviderIdentifiers.remotePath(
                    for: containerItemIdentifier
                ) != nil else {
            throw NasFinderFileProviderErrors.noSuchItem
        }
        return NasFinderFileProviderEnumerator(
            containerIdentifier: containerItemIdentifier,
            storage: storage
        )
    }
}
