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
    let storedItemIDs: Set<String>
    let attemptedItemIDs: Set<String>
    let errorDescription: String?
    let didAttempt: Bool

    var storedCount: Int { storedItemIDs.count }

    static let empty = Self(
        storedItemIDs: [],
        attemptedItemIDs: [],
        errorDescription: nil,
        didAttempt: false
    )
}

/// NAS 보관본 삭제의 실제 결과. 삭제를 시작한 뒤 멈췄어도 그때까지 지운 수를 그대로 알린다.
struct SuperThumbnailVaultRemovalResult: Equatable, Sendable {
    let removedFileCount: Int
    /// 안전하게 지울 수 없어 일부러 남긴 폴더 수(WebDAV의 Vault·임대·작업자 폴더).
    let retainedDirectoryCount: Int
    let errorDescription: String?
}

enum SuperThumbnailCooperativeClaim: Sendable {
    /// 임대를 얻지 못했고 다른 기기와 조율하지 않은 채 진행한다. 소유권을 뜻하지 않는다.
    case uncoordinated
    case acquired(SuperThumbnailCooperativeLease)
    case deferred
}

struct SuperThumbnailCooperativeLease: Sendable {
    let itemID: String
    let vaultPath: String
    let directoryName: String
    let token: String
}

private struct SuperThumbnailWorkerRecord: Codable, Sendable {
    let workerID: String
    let expiresAt: Date
}

private struct SuperThumbnailLeaseRecord: Codable, Sendable {
    let workerID: String
    let token: String
    let expiresAt: Date
}

actor SuperThumbnailVault {
    static let shared = SuperThumbnailVault()

    static let directoryName = ".NasFinder-Vault"
    private static let engineVersion = 1
    private static let workersDirectoryName = ".workers-v1"
    private static let workerLifetime: TimeInterval = 90
    private static let leaseLifetime: TimeInterval = 180
    private static let leaseRecordName = ".owner.json"
    private static let folderListingLifetime: TimeInterval = 60
    private var directoryEntries: [String: [RemoteFileItem]] = [:]
    private var missingLeaseFirstSeen: [String: Date] = [:]
    private var folderListingFetchedAt: [String: Date] = [:]
    private var pendingListings: [String: Task<[RemoteFileItem], Error>] = [:]

    func data(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        refreshListing: Bool = false
    ) async -> Data? {
        await versionedData(
            for: item,
            service: service,
            refreshListing: refreshListing
        )?.data
    }

    /// Metadata-only freshness probe: the modification date of the NAS Super
    /// Thumbnail record for this file or folder, from the shared (60 second)
    /// directory listing. Downloads nothing; nil when the listing is
    /// unavailable or no record exists, which callers treat as "unknown".
    func recordModificationDate(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> Date? {
        await recordVersion(for: item, service: service)?.modifiedAt
    }

    /// Like `recordModificationDate` but also returns the record's byte size
    /// (the JPEG payload size, matching the local raw cache file size). Either
    /// value is nil when the listing does not report it; the whole result is
    /// nil when the listing is unavailable or no record exists.
    func recordVersion(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> (modifiedAt: Date?, size: Int64?)? {
        let directory = parentDirectory(of: item.path)
        let vaultPath = appending(Self.directoryName, to: directory)
        guard let siblings = try? await folderEntries(in: directory, service: service),
              siblings.contains(where: { $0.name == Self.directoryName && $0.isDirectory }),
              let entries = try? await folderEntries(in: vaultPath, service: service)
        else { return nil }
        let name = filename(for: item)
        guard let record = entries.first(where: { $0.name == name && !$0.isDirectory }) else {
            return nil
        }
        return (record.modifiedAt, record.size)
    }

    /// Like `data(for:)` but also returns the record's NAS modification date
    /// so the local cache can remember which NAS version it holds.
    func versionedData(
        for item: RemoteFileItem,
        service: any RemoteFileService,
        refreshListing: Bool = false
    ) async -> (data: Data, modifiedAt: Date?)? {
        let directory = parentDirectory(of: item.path)
        let vaultPath = appending(Self.directoryName, to: directory)
        do {
            if refreshListing {
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                directoryEntries[listingKey(directory, service: service)] = nil
                folderListingFetchedAt[listingKey(vaultPath, service: service)] = nil
                folderListingFetchedAt[listingKey(directory, service: service)] = nil
            }
            let siblings = try await folderEntries(in: directory, service: service)
            guard siblings.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { return nil }
            let entries = try await folderEntries(in: vaultPath, service: service)
            guard let stored = entries.first(where: { $0.name == filename(for: item) && !$0.isDirectory }) else {
                return nil
            }
            let localURL = try await service.download(stored)
            defer { try? FileManager.default.removeItem(at: localURL) }
            let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
            return data.isEmpty ? nil : (data, stored.modifiedAt)
        } catch {
            return nil
        }
    }

    /// Read-only discovery of a folder Super Thumbnail generated by the Mac
    /// helper. Unlike the file path, this does not require write capabilities
    /// so read-only connections still display folder sheets.
    func folderSheet(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> FolderSuperThumbnailLookup {
        await versionedFolderSheet(for: item, service: service).lookup
    }

    /// `folderSheet` plus the sheet record's NAS modification date.
    func versionedFolderSheet(
        for item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> (lookup: FolderSuperThumbnailLookup, modifiedAt: Date?) {
        guard item.isDirectory else { return (.missing, nil) }
        let directory = parentDirectory(of: item.path)
        let vaultPath = appending(Self.directoryName, to: directory)
        do {
            let siblings = try await folderEntries(in: directory, service: service)
            guard siblings.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { return (.missing, nil) }
            let vaultEntries = try await folderEntries(in: vaultPath, service: service)
            let sheetName = FolderSuperThumbnailNaming.thumbnailFilename(
                folderName: item.name
            )
            if let stored = vaultEntries.first(where: {
                $0.name == sheetName && !$0.isDirectory
            }) {
                let localURL = try await service.download(stored)
                defer { try? FileManager.default.removeItem(at: localURL) }
                let data = try Data(contentsOf: localURL, options: .mappedIfSafe)
                if !data.isEmpty { return (.data(data), stored.modifiedAt) }
            }
            let markerName = FolderSuperThumbnailNaming.emptyMarkerFilename(
                folderName: item.name
            )
            if vaultEntries.contains(where: { $0.name == markerName }) {
                return (.emptyIndexed, nil)
            }
            return (.missing, nil)
        } catch {
            return (.missing, nil)
        }
    }

    func registerWorker(
        _ workerID: String,
        rootPath: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async throws {
        guard supportsVault(service) else { return }
        let workersPath = try await ensureWorkersDirectory(
            rootPath: rootPath,
            service: service
        )
        let record = SuperThumbnailWorkerRecord(
            workerID: workerID,
            expiresAt: now.addingTimeInterval(Self.workerLifetime)
        )
        try await uploadJSON(
            record,
            named: workerFilename(workerID),
            to: workersPath,
            conflictPolicy: .replace,
            service: service
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
    }

    func activeWorkerIDs(
        rootPath: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async throws -> Set<String> {
        guard supportsVault(service) else { return [] }
        let workersPath = try await ensureWorkersDirectory(
            rootPath: rootPath,
            service: service
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
        let workerItems = try await entries(in: workersPath, service: service)
            .filter { !$0.isDirectory && $0.name.hasPrefix("worker-") }
        var active: Set<String> = []
        for workerItem in workerItems {
            guard let record: SuperThumbnailWorkerRecord = await decodedJSON(
                from: workerItem,
                service: service
            ) else { continue }
            if record.expiresAt > now {
                active.insert(record.workerID)
            } else {
                _ = try? await service.delete(
                    workerItem,
                    recursive: false,
                    context: RemoteOperationContext()
                )
            }
        }
        directoryEntries[listingKey(workersPath, service: service)] = nil
        return active
    }

    func unregisterWorker(
        _ workerID: String,
        rootPath: String,
        service: any RemoteFileService
    ) async {
        guard supportsVault(service),
              let workersPath = try? await ensureWorkersDirectory(
                  rootPath: rootPath,
                  service: service
              ) else { return }
        directoryEntries[listingKey(workersPath, service: service)] = nil
        guard let workerItem = try? await entries(in: workersPath, service: service)
            .first(where: { $0.name == workerFilename(workerID) && !$0.isDirectory }) else { return }
        _ = try? await service.delete(
            workerItem,
            recursive: false,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(workersPath, service: service)] = nil
    }

    func claim(
        _ item: RemoteFileItem,
        workerID: String,
        service: any RemoteFileService,
        now: Date = Date()
    ) async -> SuperThumbnailCooperativeClaim {
        guard supportsVault(service) else { return .uncoordinated }
        let mediaDirectory = parentDirectory(of: item.path)
        do {
            let vaultPath = try await ensureVaultDirectory(
                in: mediaDirectory,
                service: service
            )
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            var vaultEntries = try await entries(in: vaultPath, service: service)
            if vaultEntries.contains(where: { $0.name == filename(for: item) }) {
                return .deferred
            }

            let directoryName = leaseDirectoryName(for: item)
            if let existingLease = vaultEntries.first(where: {
                $0.name == directoryName && $0.isDirectory
            }) {
                if await leaseIsActive(
                    existingLease,
                    service: service,
                    now: now
                ) {
                    return .deferred
                }
                // 폴더를 지울 수 없으면 MKCOL로 배타적 소유권을 다시 얻을 수 없다. 만료된 임대를 회수했다고 하지 않고 조율 없이 진행한다.
                guard canSafelyDeleteDirectories(service) else { return .uncoordinated }
                do {
                    try await removeOwnedSubdirectory(existingLease, service: service)
                } catch SuperThumbnailVaultError.unknownContent(_) {
                    // 앱이 만들지 않은 항목이 있어 지우지 않았다. 이 임대는 영영 풀리지 않으므로 조율 없이 진행한다.
                    return .uncoordinated
                } catch {
                    // 일시적인 실패다. 아래에서 폴더를 새로 만들지 못하면 나중에 다시 시도한다.
                }
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                vaultEntries = try await entries(in: vaultPath, service: service)
                if vaultEntries.contains(where: { $0.name == filename(for: item) }) {
                    return .deferred
                }
            }

            let leaseDirectory: RemoteFileItem
            do {
                leaseDirectory = try await service.createFolder(
                    named: directoryName,
                    in: vaultPath,
                    context: RemoteOperationContext()
                )
            } catch {
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                return .deferred
            }

            let token = UUID().uuidString
            let record = SuperThumbnailLeaseRecord(
                workerID: workerID,
                token: token,
                expiresAt: now.addingTimeInterval(Self.leaseLifetime)
            )
            do {
                try await uploadJSON(
                    record,
                    named: Self.leaseRecordName,
                    to: leaseDirectory.path,
                    conflictPolicy: .replace,
                    service: service
                )
            } catch {
                try? await removeOwnedSubdirectory(leaseDirectory, service: service)
                return .deferred
            }
            return .acquired(
                SuperThumbnailCooperativeLease(
                    itemID: item.id,
                    vaultPath: vaultPath,
                    directoryName: directoryName,
                    token: token
                )
            )
        } catch {
            return .uncoordinated
        }
    }

    /// 내 토큰이 확인된 임대만 푼다. WebDAV에서는 임대 파일만 지우고 빈 폴더는 남으므로 다른 기기는 만료 뒤 조율 없이 진행한다.
    func release(
        _ lease: SuperThumbnailCooperativeLease,
        service: any RemoteFileService
    ) async {
        directoryEntries[listingKey(lease.vaultPath, service: service)] = nil
        guard let leaseDirectory = try? await entries(
            in: lease.vaultPath,
            service: service
        ).first(where: {
            $0.name == lease.directoryName && $0.isDirectory
        }) else { return }
        directoryEntries[listingKey(leaseDirectory.path, service: service)] = nil
        guard let recordItem = try? await entries(
            in: leaseDirectory.path,
            service: service
        ).first(where: { $0.name == Self.leaseRecordName }),
              let record: SuperThumbnailLeaseRecord = await decodedJSON(
                  from: recordItem,
                  service: service
              ),
              record.token == lease.token else { return }
        try? await removeOwnedSubdirectory(leaseDirectory, service: service)
        directoryEntries[listingKey(lease.vaultPath, service: service)] = nil
    }

    func storeFolder(
        _ items: [RemoteFileItem],
        service: any RemoteFileService,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard supportsVault(service), !items.isEmpty else { return .empty }
        let mediaDirectory = parentDirectory(of: items[0].path)
        let attemptedItemIDs = Set(items.map(\.id))
        var storedItemIDs: Set<String> = []
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
                    storedItemIDs.insert(item.id)
                    continue
                }
                try await atomicallyUpload(
                    data,
                    named: name,
                    to: vaultPath,
                    service: service
                )
                directoryEntries[listingKey(vaultPath, service: service)] = nil
                storedItemIDs.insert(item.id)
            }
            return .init(
                storedItemIDs: storedItemIDs,
                attemptedItemIDs: attemptedItemIDs,
                errorDescription: nil,
                didAttempt: true
            )
        } catch {
            return .init(
                storedItemIDs: storedItemIDs,
                attemptedItemIDs: attemptedItemIDs,
                errorDescription: vaultErrorDescription(error),
                didAttempt: true
            )
        }
    }

    func storedItemIDs(
        for items: [RemoteFileItem],
        service: any RemoteFileService
    ) async throws -> Set<String> {
        guard supportsVault(service), !items.isEmpty else { return [] }
        directoryEntries.removeAll()
        var stored: Set<String> = []
        for (directory, folderItems) in Dictionary(grouping: items, by: {
            parentDirectory(of: $0.path)
        }) {
            try Task.checkCancellation()
            let vaultPath = appending(Self.directoryName, to: directory)
            let siblings = try await entries(in: directory, service: service)
            guard siblings.contains(where: {
                $0.name == Self.directoryName && $0.isDirectory
            }) else { continue }
            let names = Set(try await entries(in: vaultPath, service: service).map(\.name))
            for item in folderItems where names.contains(filename(for: item)) {
                stored.insert(item.id)
            }
        }
        return stored
    }

    func invalidateListings() {
        directoryEntries.removeAll()
        folderListingFetchedAt.removeAll()
    }

    /// 삭제를 시작하기 전의 확인 실패만 던진다(아무것도 지우지 않은 상태). 그 뒤의 실패는 지운 수와 함께 결과로 돌려준다.
    func removeVaults(
        startingAt rootPath: String,
        service: any RemoteFileService
    ) async throws -> SuperThumbnailVaultRemovalResult {
        guard service.capabilities.contains(.delete) else {
            throw RemoteFileOperationError.unsupported(operation: .delete)
        }
        defer { directoryEntries.removeAll() }
        // 먼저 전체를 확인한다. 앱이 만들지 않은 항목이 하나라도 있으면 아무것도 지우지 않고 실패한다.
        var plans: [SuperThumbnailVaultRemovalPlan] = []
        var pendingDirectories = [rootPath]
        while !pendingDirectories.isEmpty {
            try Task.checkCancellation()
            let directory = pendingDirectories.removeFirst()
            let children = try await service.list(directory: directory)
            for child in children where child.isDirectory {
                if child.name == Self.directoryName {
                    plans.append(try await removalPlan(for: child, service: service))
                } else if RemoteFileVisibilityPolicy.shouldDisplay(filename: child.name) {
                    pendingDirectories.append(child.path)
                }
            }
        }
        var removedFiles = 0
        var retainedDirectories = 0
        do {
            for plan in plans {
                try Task.checkCancellation()
                for record in plan.records {
                    _ = try await service.delete(
                        record,
                        recursive: false,
                        context: RemoteOperationContext()
                    )
                    removedFiles += 1
                }
                for subdirectory in plan.subdirectories {
                    let removed = try await removeOwnedSubdirectory(subdirectory, service: service)
                    if !removed { retainedDirectories += 1 }
                }
                let vaultRemoved = try await removeEmptyDirectory(plan.vault, service: service)
                if !vaultRemoved { retainedDirectories += 1 }
            }
        } catch {
            return .init(
                removedFileCount: removedFiles,
                retainedDirectoryCount: retainedDirectories,
                errorDescription: error.localizedDescription
            )
        }
        return .init(
            removedFileCount: removedFiles,
            retainedDirectoryCount: retainedDirectories,
            errorDescription: nil
        )
    }

    private func removalPlan(
        for vault: RemoteFileItem,
        service: any RemoteFileService
    ) async throws -> SuperThumbnailVaultRemovalPlan {
        var records: [RemoteFileItem] = []
        var subdirectories: [RemoteFileItem] = []
        for entry in try await service.list(directory: vault.path) {
            if entry.isDirectory {
                guard Self.isOwnedSubdirectory(entry.name) else {
                    throw SuperThumbnailVaultError.unknownContent(path: entry.path)
                }
                for child in try await service.list(directory: entry.path)
                where child.isDirectory
                    || !Self.isOwnedFile(child.name, inSubdirectory: entry.name) {
                    throw SuperThumbnailVaultError.unknownContent(path: child.path)
                }
                subdirectories.append(entry)
            } else {
                guard Self.isOwnedRecord(entry.name) else {
                    throw SuperThumbnailVaultError.unknownContent(path: entry.path)
                }
                records.append(entry)
            }
        }
        return SuperThumbnailVaultRemovalPlan(
            vault: vault,
            records: records,
            subdirectories: subdirectories
        )
    }

    /// 임대·작업자 폴더에서 앱이 만든 파일만 지우고 비어 있는 폴더를 지운다.
    /// 다른 항목이 있으면 아무것도 지우지 않는다.
    /// - Returns: 폴더까지 지웠으면 true, 파일만 지우고 폴더를 남겼으면(WebDAV) false.
    @discardableResult
    private func removeOwnedSubdirectory(
        _ directory: RemoteFileItem,
        service: any RemoteFileService
    ) async throws -> Bool {
        directoryEntries[listingKey(directory.path, service: service)] = nil
        let children = try await service.list(directory: directory.path)
        for child in children
        where child.isDirectory || !Self.isOwnedFile(child.name, inSubdirectory: directory.name) {
            throw SuperThumbnailVaultError.unknownContent(path: child.path)
        }
        for child in children {
            _ = try await service.delete(
                child,
                recursive: false,
                context: RemoteOperationContext()
            )
        }
        return try await removeEmptyDirectory(directory, service: service)
    }

    /// WebDAV DELETE는 recursive 값과 상관없이 폴더를 통째로 지운다. 비어 있음을 확인해도 그 사이 들어온 항목까지
    /// 지워질 수 있으므로 WebDAV에서는 Vault·임대·작업자 폴더에 DELETE를 보내지 않는다.
    private func canSafelyDeleteDirectories(_ service: any RemoteFileService) -> Bool {
        service.connection.kind != .webDAV
    }

    /// - Returns: 폴더를 지웠으면 true, 안전하게 지울 수 없어 남겼으면 false.
    private func removeEmptyDirectory(
        _ directory: RemoteFileItem,
        service: any RemoteFileService
    ) async throws -> Bool {
        guard canSafelyDeleteDirectories(service) else {
            directoryEntries[listingKey(directory.path, service: service)] = nil
            return false
        }
        if let remaining = try await service.list(directory: directory.path).first {
            throw SuperThumbnailVaultError.unknownContent(path: remaining.path)
        }
        _ = try await service.delete(
            directory,
            recursive: false,
            context: RemoteOperationContext()
        )
        directoryEntries[listingKey(directory.path, service: service)] = nil
        return true
    }

    /// Vault 폴더 바로 아래의 레코드: 썸네일과 빈 폴더 표시.
    private static func isOwnedRecord(_ name: String) -> Bool {
        name.range(of: #"^v[0-9]+-.+\.(jpg|empty)$"#, options: .regularExpression) != nil
            || isOwnedTemporaryFile(name)
    }

    /// 전송이 끊기면 남을 수 있는 임시 파일. `.nasfinder-`는 SFTP 스테이징, `.backup-`은 Android 교체 백업이다.
    private static func isOwnedTemporaryFile(_ name: String) -> Bool {
        name.hasSuffix(".tmp")
            && [".upload-", ".backup-", ".nasfinder-"].contains { name.hasPrefix($0) }
    }

    private static func isOwnedSubdirectory(_ name: String) -> Bool {
        name == workersDirectoryName || name.hasPrefix(".claim-")
    }

    private static func isOwnedFile(_ name: String, inSubdirectory directoryName: String) -> Bool {
        if isOwnedTemporaryFile(name) { return true }
        return directoryName == workersDirectoryName
            ? name.hasPrefix("worker-") && name.hasSuffix(".json")
            : name == leaseRecordName
    }

    /// 정리는 파일과 빈 폴더 삭제만 쓰므로 recursiveDelete가 없는 SMB·FTP도 Vault를 쓸 수 있다.
    /// WebDAV도 생성·읽기·파일 정리는 지원하며, 폴더 삭제와 만료 임대 회수만 지원하지 않는다.
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

    private func ensureWorkersDirectory(
        rootPath: String,
        service: any RemoteFileService
    ) async throws -> String {
        let vaultPath = try await ensureVaultDirectory(
            in: rootPath,
            service: service
        )
        let workersPath = appending(Self.workersDirectoryName, to: vaultPath)
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        let vaultEntries = try await entries(in: vaultPath, service: service)
        if vaultEntries.contains(where: {
            $0.name == Self.workersDirectoryName && $0.isDirectory
        }) {
            return workersPath
        }
        do {
            _ = try await service.createFolder(
                named: Self.workersDirectoryName,
                in: vaultPath,
                context: RemoteOperationContext()
            )
        } catch {
            directoryEntries[listingKey(vaultPath, service: service)] = nil
            let refreshed = try await entries(in: vaultPath, service: service)
            guard refreshed.contains(where: {
                $0.name == Self.workersDirectoryName && $0.isDirectory
            }) else { throw error }
        }
        directoryEntries[listingKey(vaultPath, service: service)] = nil
        directoryEntries[listingKey(workersPath, service: service)] = []
        return workersPath
    }

    private func workerFilename(_ workerID: String) -> String {
        "worker-\(workerID).json"
    }

    private func leaseDirectoryName(for item: RemoteFileItem) -> String {
        let name = filename(for: item)
        return ".claim-" + String(name.dropLast(".jpg".count))
    }

    private func leaseIsActive(
        _ leaseDirectory: RemoteFileItem,
        service: any RemoteFileService,
        now: Date
    ) async -> Bool {
        let key = listingKey(leaseDirectory.path, service: service)
        directoryEntries[listingKey(leaseDirectory.path, service: service)] = nil
        guard let items = try? await entries(
            in: leaseDirectory.path,
            service: service
        ),
              let recordItem = items.first(where: {
                  $0.name == Self.leaseRecordName && !$0.isDirectory
              }),
              let record: SuperThumbnailLeaseRecord = await decodedJSON(
                  from: recordItem,
                  service: service
              ) else {
            if let modifiedAt = leaseDirectory.modifiedAt {
                return modifiedAt.addingTimeInterval(Self.leaseLifetime) > now
            }
            let firstSeen = missingLeaseFirstSeen[key] ?? now
            missingLeaseFirstSeen[key] = firstSeen
            return firstSeen.addingTimeInterval(Self.leaseLifetime) > now
        }
        missingLeaseFirstSeen[key] = nil
        return record.expiresAt > now
    }

    private func uploadJSON<Value: Encodable>(
        _ value: Value,
        named name: String,
        to directoryPath: String,
        conflictPolicy: RemoteConflictPolicy,
        service: any RemoteFileService
    ) async throws {
        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        try JSONEncoder().encode(value).write(to: localURL, options: .atomic)
        defer { try? FileManager.default.removeItem(at: localURL) }
        _ = try await service.upload(
            localURL: localURL,
            to: directoryPath,
            preferredName: name,
            conflictPolicy: conflictPolicy,
            context: RemoteOperationContext()
        )
    }

    private func decodedJSON<Value: Decodable>(
        from item: RemoteFileItem,
        service: any RemoteFileService
    ) async -> Value? {
        guard let localURL = try? await service.download(item) else { return nil }
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard let data = try? Data(contentsOf: localURL, options: .mappedIfSafe) else {
            return nil
        }
        return try? JSONDecoder().decode(Value.self, from: data)
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
        guard let temporaryItem = currentEntries.first(where: { $0.name == temporaryName && !$0.isDirectory }) else {
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

    /// Folder-sheet lookups share the cached listing with sibling cells but
    /// refresh it after a bounded lifetime, so sheets generated by the Mac
    /// helper appear without restarting the app while the listing traffic per
    /// directory stays bounded.
    private func folderEntries(
        in path: String,
        service: any RemoteFileService
    ) async throws -> [RemoteFileItem] {
        let key = listingKey(path, service: service)
        if let fetchedAt = folderListingFetchedAt[key],
           Date().timeIntervalSince(fetchedAt) > Self.folderListingLifetime {
            directoryEntries[key] = nil
        }
        if directoryEntries[key] == nil {
            folderListingFetchedAt[key] = Date()
        }
        return try await entries(
            in: path,
            service: service,
            sharesPendingListing: true
        )
    }

    private func entries(
        in path: String,
        service: any RemoteFileService,
        sharesPendingListing: Bool = false
    ) async throws -> [RemoteFileItem] {
        let key = listingKey(path, service: service)
        if let cached = directoryEntries[key] { return cached }
        guard sharesPendingListing else {
            let listed = try await service.list(directory: path)
            directoryEntries[key] = listed
            return listed
        }
        // Read-only lookups of one folder's cards ask for the same two
        // listings at once (the freshness probe now runs for cache hits too);
        // share one request. Mutating paths above never join a pending listing.
        if let pending = pendingListings[key] { return try await pending.value }
        let listing = Task { try await service.list(directory: path) }
        pendingListings[key] = listing
        defer { pendingListings[key] = nil }
        let listed = try await listing.value
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
        if item.isDirectory {
            return FolderSuperThumbnailNaming.thumbnailFilename(folderName: item.name)
        }
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

private actor SuperThumbnailCooperationSession {
    private static let heartbeatInterval: Duration = .seconds(30)
    private static let peerRefreshInterval: TimeInterval = 5

    private let workerID: String
    private let rootPath: String
    private let service: any RemoteFileService
    private var heartbeatTask: Task<Void, Never>?
    private var lastPeerRefresh = Date.distantPast
    private var cachedHasPeers = false

    init(
        workerID: String,
        rootPath: String,
        service: any RemoteFileService
    ) {
        self.workerID = workerID
        self.rootPath = rootPath
        self.service = service
    }

    func start() async {
        guard heartbeatTask == nil else { return }
        do {
            try await SuperThumbnailVault.shared.registerWorker(
                workerID,
                rootPath: rootPath,
                service: service
            )
        } catch {
            return
        }
        let currentWorkerID = workerID
        let currentRootPath = rootPath
        let currentService = service
        heartbeatTask = Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.heartbeatInterval)
                } catch {
                    return
                }
                try? await SuperThumbnailVault.shared.registerWorker(
                    currentWorkerID,
                    rootPath: currentRootPath,
                    service: currentService
                )
            }
        }
        try? await Task.sleep(for: .milliseconds(750))
        _ = await hasPeers(forceRefresh: true)
    }

    func hasPeers(forceRefresh: Bool = false) async -> Bool {
        guard heartbeatTask != nil else { return false }
        let now = Date()
        if !forceRefresh,
           now.timeIntervalSince(lastPeerRefresh) < Self.peerRefreshInterval {
            return cachedHasPeers
        }
        do {
            let active = try await SuperThumbnailVault.shared.activeWorkerIDs(
                rootPath: rootPath,
                service: service,
                now: now
            )
            cachedHasPeers = active.contains { $0 != workerID }
        } catch {
            cachedHasPeers = false
        }
        lastPeerRefresh = now
        return cachedHasPeers
    }

    func claim(_ item: RemoteFileItem) async -> SuperThumbnailCooperativeClaim {
        guard await hasPeers() else { return .uncoordinated }
        return await SuperThumbnailVault.shared.claim(
            item,
            workerID: workerID,
            service: service
        )
    }

    func release(_ lease: SuperThumbnailCooperativeLease) async {
        await SuperThumbnailVault.shared.release(lease, service: service)
    }

    func stop() async {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        await SuperThumbnailVault.shared.unregisterWorker(
            workerID,
            rootPath: rootPath,
            service: service
        )
    }
}

private struct SuperThumbnailVaultRemovalPlan: Sendable {
    let vault: RemoteFileItem
    let records: [RemoteFileItem]
    let subdirectories: [RemoteFileItem]
}

private enum SuperThumbnailVaultError: LocalizedError {
    case uploadVerificationFailed
    case unknownContent(path: String)

    var errorDescription: String? {
        switch self {
        case .uploadVerificationFailed:
            "NAS Vault 업로드 결과를 확인하지 못했습니다."
        case .unknownContent(let path):
            "NasFinder가 만들지 않은 항목이 있어 삭제하지 않았습니다. 해당 항목을 확인해 주세요. (\(path))"
        }
    }
}

actor SuperThumbnailVaultRun {
    private static let maximumUploadAttempts = 3
    private static let retryDelay: Duration = .milliseconds(250)
    private let options: SuperThumbnailVaultOptions
    private let service: any RemoteFileService
    private let folderItems: [String: [RemoteFileItem]]
    private let cooperationSession: SuperThumbnailCooperationSession?
    private var completedItemIDs: Set<String> = []
    private var uploadedFolders: Set<String> = []

    init(
        options: SuperThumbnailVaultOptions,
        items: [RemoteFileItem],
        service: any RemoteFileService,
        cooperationRootPath: String? = nil,
        workerID: String? = nil
    ) {
        self.options = options
        self.service = service
        folderItems = Dictionary(grouping: items) {
            ($0.path as NSString).deletingLastPathComponent
        }
        if options.isEnabled,
           options.timing == .now,
           let cooperationRootPath,
           let workerID {
            cooperationSession = SuperThumbnailCooperationSession(
                workerID: workerID,
                rootPath: cooperationRootPath,
                service: service
            )
        } else {
            cooperationSession = nil
        }
    }

    func startCooperation() async {
        await cooperationSession?.start()
    }

    func stopCooperation() async {
        await cooperationSession?.stop()
    }

    func restoredData(for item: RemoteFileItem) async -> Data? {
        guard options.isEnabled else { return nil }
        return await SuperThumbnailVault.shared.data(for: item, service: service)
    }

    func cooperativeRestoredData(
        for item: RemoteFileItem,
        forceRefresh: Bool
    ) async -> Data? {
        guard cooperationSession != nil, forceRefresh else { return nil }
        return await SuperThumbnailVault.shared.data(
            for: item,
            service: service,
            refreshListing: true
        )
    }

    func cooperativeClaim(
        _ item: RemoteFileItem
    ) async -> SuperThumbnailCooperativeClaim {
        guard let cooperationSession else { return .uncoordinated }
        return await cooperationSession.claim(item)
    }

    func releaseCooperativeLease(
        _ lease: SuperThumbnailCooperativeLease
    ) async {
        await cooperationSession?.release(lease)
    }

    func registerCompleted(_ item: RemoteFileItem) {
        guard options.isEnabled else { return }
        completedItemIDs.insert(item.id)
    }

    func markCompleted(
        _ item: RemoteFileItem,
        cooperative: Bool = false,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        registerCompleted(item)
        guard options.timing == .now else { return .empty }
        if cooperative {
            return await storeFolderWithRetry([item], localData: localData)
        }
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

    func uploadAvailable(
        _ item: RemoteFileItem,
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled, options.timing == .now else { return .empty }
        registerCompleted(item)
        return await storeFolderWithRetry([item], localData: localData)
    }

    func finish(
        localData: @Sendable (RemoteFileItem) async -> Data?
    ) async -> SuperThumbnailVaultStoreResult {
        guard options.isEnabled else { return .empty }
        var storedItemIDs: Set<String> = []
        var attemptedItemIDs: Set<String> = []
        var firstError: String?
        for (folder, items) in folderItems where !uploadedFolders.contains(folder) {
            let result = await storeFolderWithRetry(
                items.filter { completedItemIDs.contains($0.id) },
                localData: localData
            )
            storedItemIDs.formUnion(result.storedItemIDs)
            attemptedItemIDs.formUnion(result.attemptedItemIDs)
            firstError = firstError ?? result.errorDescription
            if result.errorDescription == nil,
               result.didAttempt,
               items.allSatisfy({ completedItemIDs.contains($0.id) }) {
                uploadedFolders.insert(folder)
            }
        }
        return .init(
            storedItemIDs: storedItemIDs,
            attemptedItemIDs: attemptedItemIDs,
            errorDescription: firstError,
            didAttempt: !attemptedItemIDs.isEmpty || firstError != nil
        )
    }

    func verifyStoredItemIDs() async throws -> Set<String> {
        guard options.isEnabled else { return [] }
        return try await SuperThumbnailVault.shared.storedItemIDs(
            for: folderItems.values.flatMap { $0 },
            service: service
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
