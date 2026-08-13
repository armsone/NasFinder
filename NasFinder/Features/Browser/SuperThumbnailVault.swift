import CryptoKit
import Foundation

enum SuperThumbnailVaultTiming: String, Codable, CaseIterable, Sendable {
    case now
    case later
}

struct SuperThumbnailVaultOptions: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var timing: SuperThumbnailVaultTiming

    static let recommended = Self(isEnabled: true, timing: .now)
}

struct SuperThumbnailVaultStoreResult: Equatable, Sendable {
    let storedCount: Int
    let errorDescription: String?
    let didAttempt: Bool

    static let empty = Self(storedCount: 0, errorDescription: nil, didAttempt: false)
}

actor SuperThumbnailVault {
    static let shared = SuperThumbnailVault()

    static let directoryName = ".NasFinder-Vault"
    private static let engineVersion = 1
    private var directoryEntries: [String: [RemoteFileItem]] = [:]

    func data(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> Data? {
        guard supportsVault(service) else { return nil }
        let directory = parentDirectory(of: item.path)
        let vaultPath = appending(Self.directoryName, to: directory)
        do {
            let entries = try await entries(in: vaultPath, service: service)
            guard let stored = entries.first(where: { $0.name == filename(for: item) }) else {
                return nil
            }
            let localURL = try await service.download(stored)
            defer { try? FileManager.default.removeItem(at: localURL) }
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    func storeFolder(
        _ items: [RemoteFileItem],
        service: any RemoteFileService,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard supportsVault(service), !items.isEmpty else { return .empty }
        let mediaDirectory = parentDirectory(of: items[0].path)
        var storedCount = 0
        do {
            let vaultPath = try await ensureVaultDirectory(
                in: mediaDirectory,
                service: service
            )
            for item in items {
                try Task.checkCancellation()
                guard parentDirectory(of: item.path) == mediaDirectory,
                      let data = await localData(item),
                      !data.isEmpty else { continue }
                let name = filename(for: item)
                let currentEntries = try await entries(in: vaultPath, service: service)
                if currentEntries.contains(where: { $0.name == name }) {
                    storedCount += 1
                    continue
                }
                try await atomicallyUpload(
                    data,
                    named: name,
                    to: vaultPath,
                    service: service
                )
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                storedCount += 1
            }
            return .init(
                storedCount: storedCount,
                errorDescription: nil,
                didAttempt: true
            )
        } catch {
            return .init(
                storedCount: storedCount,
                errorDescription: vaultErrorDescription(error),
                didAttempt: true
            )
        }
    }

    func invalidateListings() {
        directoryEntries.removeAll()
    }

    func removeVaults(
        startingAt rootPath: String,
        service: any RemoteFileService
    ) async throws -> Int {
        guard service.capabilities.contains(.delete) else { return 0 }
        var pendingDirectories = [rootPath]
        var removedFiles = 0
        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            let directory = pendingDirectories.removeFirst()
            let children = try await service.list(directory: directory)
            for child in children where child.isDirectory {
                if child.name == Self.directoryName {
                    let vaultItems = try await service.list(directory: child.path)
                    for vaultItem in vaultItems where !vaultItem.isDirectory {
                        _ = try await service.delete(
                            vaultItem,
                            recursive: false,
                            context: RemoteOperationContext()
                        )
                        removedFiles += 1
                    }
                    _ = try await service.delete(
                        child,
                        recursive: true,
                        context: RemoteOperationContext()
                    )
                } else if RemoteFileVisibilityPolicy.shouldDisplay(filename: child.name) {
                    pendingDirectories.append(child.path)
                }
            }
        }
        directoryEntries.removeAll()
        return removedFiles
    }

    private func supportsVault(_ service: any RemoteFileService) -> Bool {
        service.capabilities.contains(.createFolder)
            && service.capabilities.contains(.upload)
            && service.capabilities.contains(.rename)
            && service.capabilities.contains(.delete)
    }

    private func ensureVaultDirectory(
        in mediaDirectory: String,
        service: any RemoteFileService
    ) async throws -> String {
        let vaultPath = appending(Self.directoryName, to: mediaDirectory)
        let siblings = try await entries(in: mediaDirectory, service: service)
        if siblings.contains(where: { $0.name == Self.directoryName && $0.isDirectory }) {
            return vaultPath
        }
        do {
            _ = try await service.createFolder(
                named: Self.directoryName,
                in: mediaDirectory,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(mediaDirectory, service: service)] = nil
            let refreshed = try await entries(in: mediaDirectory, service: service)
            guard refreshed.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { throw error }
        }
        directoryEntries[listingKey(mediaDirectory, service: service)] = nil
        directoryEntries[listingKey(vaultPath, service: service)] = []
        return vaultPath
    }

    private func atomicallyUpload(
        _ data: Data,
        named finalName: String,
        to vaultPath: String,
        service: any RemoteFileService
    ) async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try data.write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }

        let temporaryName = ".upload-\(UUID().uuidString).tmp"
        _ = try await service.upload(
            localURL: localURL,
            to: vaultPath,
            preferredName: temporaryName,
            conflictPolicy: .fail,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        let currentEntries = try await entries(in: vaultPath, service: service)
        guard let temporaryItem = currentEntries.first(where: { $0.name == temporaryName }) else {
            throw SuperThumbnailVaultError.uploadVerificationFailed
        }
        if currentEntries.contains(where: { $0.name == finalName }) {
            _ = try? await service.delete(
                temporaryItem,
                recursive: false,
                context: RemoteOperationContext()
            )
            return
        }
        do {
            _ = try await service.rename(
                temporaryItem,
                to: finalName,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            let refreshed = try await entries(in: vaultPath, service: service)
            guard refreshed.contains(where: { $0.name == finalName }) else {
                throw error
            }
            _ = try? await service.delete(
                temporaryItem,
                recursive: false,
                context: RemoteOperationContext()
            )
        }
    }

    private func entries(
        in path: String,
        service: any RemoteFileService
    ) async throws -> [RemoteFileItem] {
        let key = listingKey(path, service: service)
        if let cached = directoryEntries[key] { return cached }
        let listed = try await service.list(directory: path)
        directoryEntries[key] = listed
        return listed
    }

    private func listingKey(
        _ path: String,
        service: any RemoteFileService
    ) -> String {
        "\(service.connection.id.uuidString)|\(path)"
    }

    private func filename(for item: RemoteFileItem) -> String {
        let identity = [
            "engine=\(Self.engineVersion)",
            "name=\(item.name.precomposedStringWithCanonicalMapping)",
            "size=\(item.size ?? -1)",
            "modified=\(Int64((item.modifiedAt?.timeIntervalSince1970 ?? 0) * 1_000))",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "v\(Self.engineVersion)-"
            + digest.map { String(format: "%02x", $0) }.joined()
            + ".jpg"
    }

    private func vaultErrorDescription(_ error: Error) -> String {
        if RemoteRequestCancellation.isCancellation(error) {
            return "업로드가 중단되어 자동 재시도 목록에 보관했습니다."
        }
        return error.localizedDescription
    }

    private func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { return path.hasPrefix("/") ? "/" : "." }
        return parent
    }

    private func appending(_ name: String, to path: String) -> String {
        if path == "/" { return "/\(name)" }
        if path == "." { return "./\(name)" }
        return path.hasSuffix("/") ? "\(path)\(name)" : "\(path)/\(name)"
    }
}

private enum SuperThumbnailVaultError: LocalizedError {
    case uploadVerificationFailed

    var errorDescription: String? {
        "NAS Vault 업로드 결과를 확인하지 못했습니다."
    }
}

actor SuperThumbnailVaultRun {
    private static let maximumUploadAttempts = 3
    private static let retryDelay: Duration = .milliseconds(250)
    private let options: SuperThumbnailVaultOptions
    private let service: any RemoteFileService
    private let folderItems: [String: [RemoteFileItem]]
    private var completedItemIDs: Set<String> = []
    private var uploadedFolders: Set<String> = []

    init(
        options: SuperThumbnailVaultOptions,
        items: [RemoteFileItem],
        service: any RemoteFileService
    ) {
        self.options = options
        self.service = service
        folderItems = Dictionary(grouping: items) {
            ($0.path as NSString).deletingLastPathComponent
        }
    }

    func restoredData(for item: RemoteFileItem) async -> Data? {
        guard options.isEnabled else { return nil }
        return await SuperThumbnailVault.shared.data(for: item, service: service)
    }

    func markCompleted(
        _ item: RemoteFileItem,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        completedItemIDs.insert(item.id)
        guard options.timing == .now else { return .empty }
        let folder = (item.path as NSString).deletingLastPathComponent
        guard !uploadedFolders.contains(folder),
              let items = folderItems[folder],
              items.allSatisfy({ completedItemIDs.contains($0.id) }) else {
            return .empty
        }
        let result = await storeFolderWithRetry(
            items,
            localData: localData
        )
        if result.errorDescription == nil, result.didAttempt {
            uploadedFolders.insert(folder)
        }
        return result
    }

    func finish(
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        var count = 0
        var firstError: String?
        for (folder, items) in folderItems where !uploadedFolders.contains(folder) {
            if options.timing == .now,
               !items.allSatisfy({ completedItemIDs.contains($0.id) }) {
                continue
            }
            let result = await storeFolderWithRetry(
                items.filter { completedItemIDs.contains($0.id) },
                localData: localData
            )
            count += result.storedCount
            firstError = firstError ?? result.errorDescription
            if result.errorDescription == nil, result.didAttempt {
                uploadedFolders.insert(folder)
            }
        }
        return .init(
            storedCount: count,
            errorDescription: firstError,
            didAttempt: true
        )
    }

    private func storeFolderWithRetry(
        _ items: [RemoteFileItem],
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        var latestResult = SuperThumbnailVaultStoreResult.empty
        for attempt in 1...Self.maximumUploadAttempts {
            guard !Task.isCancelled else { return latestResult }
            latestResult = await SuperThumbnailVault.shared.storeFolder(
                items,
                service: service,
                localData: localData
            )
            guard latestResult.errorDescription != nil else { return latestResult }
            guard attempt < Self.maximumUploadAttempts, !Task.isCancelled else {
                return latestResult
            }
            do {
                try await Task.sleep(for: Self.retryDelay)
            } catch {
                return latestResult
            }
        }
        return latestResult
    }
}
