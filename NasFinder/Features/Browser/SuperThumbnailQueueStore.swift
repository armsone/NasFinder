import Foundation

enum SuperThumbnailMediaScope: String, Codable, Sendable, CaseIterable {
    case videosOnly
    case videosAndPhotos
}

struct SuperThumbnailFailureRecord: Codable, Identifiable, Sendable, Equatable {
    let itemID: String
    let name: String
    let fileExtension: String
    let fileSize: Int64?
    let durationSeconds: TimeInterval?
    let reason: String

    var id: String { itemID }
}

struct SuperThumbnailSessionReport: Sendable, Equatable {
    let successCounts: [Int]
    var photoSuccessCount: Int = 0
    let failures: [SuperThumbnailFailureRecord]
    let pendingCount: Int
    let cachedCount: Int
    var vaultFolders: [SuperThumbnailVaultFolderReport] = []
    var vaultLastVerifiedAt: Date? = nil
    var mediaScope: SuperThumbnailMediaScope = .videosAndPhotos

    var successfulCount: Int { successCounts.reduce(0, +) + photoSuccessCount }
    var vaultUploadedCount: Int { vaultFolders.reduce(0) { $0 + $1.uploadedCount } }
    var vaultPendingCount: Int { vaultFolders.reduce(0) { $0 + $1.pendingCount } }
    var vaultFailedCount: Int { vaultFolders.reduce(0) { $0 + $1.failedCount } }
    var vaultWaitingThumbnailCount: Int {
        vaultFolders.reduce(0) { $0 + $1.waitingThumbnailCount }
    }
    var hasWorkToResume: Bool {
        pendingCount > 0
            || !failures.isEmpty
            || vaultPendingCount > 0
            || vaultFailedCount > 0
    }
    var unresolvedCount: Int { max(pendingCount, failures.count) }
    var totalCount: Int { cachedCount + successfulCount + unresolvedCount }
    var remainingCounts: [Int] {
        let counts = (0..<3).map {
            successCounts.indices.contains($0) ? successCounts[$0] : 0
        }
        return [
            counts[1] + counts[2] + unresolvedCount,
            counts[2] + unresolvedCount,
            unresolvedCount,
        ]
    }
}

struct SuperThumbnailVaultFolderReport: Identifiable, Sendable, Equatable {
    let path: String
    let totalCount: Int
    let uploadedCount: Int
    let waitingThumbnailCount: Int
    let pendingCount: Int
    let failedCount: Int
    let errorDescription: String?

    var id: String { path }
}

actor SuperThumbnailQueueStore {
    struct CachedTransition: Sendable, Equatable {
        let previousSuccessAttempt: Int?
        let removedPhotoSuccess: Bool
        let removedFailure: Bool
    }

    static let shared = SuperThumbnailQueueStore()

    private struct ItemState: Codable {
        let signature: String
        var nextAttempt: Int
    }

    private struct ResultState: Codable {
        let signature: String
        var successAttempt: Int?
        var photoSuccess: Bool? = nil
        var failure: SuperThumbnailFailureRecord?
    }

    private enum VaultStatus: String, Codable {
        case waitingForThumbnail
        case pendingUpload
        case uploaded
        case uploadFailed
    }

    private struct VaultItemState: Codable {
        let signature: String
        let folderPath: String
        var status: VaultStatus
        var errorDescription: String?
    }

    private struct SessionState: Codable {
        var queue: [String: ItemState] = [:]
        var results: [String: ResultState] = [:]
        var cachedItems: [String: String]? = nil
        var vaultItems: [String: VaultItemState]? = nil
        var vaultLastVerifiedAt: Date? = nil
        var mediaScope: SuperThumbnailMediaScope? = nil
    }

    private typealias Sessions = [String: SessionState]

    private static let storageKey = "superThumbnail.retryQueues.v2"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func attempts(
        for items: [RemoteFileItem],
        sessionKey: String,
        allObservedItems: [RemoteFileItem]? = nil,
        mediaScope: SuperThumbnailMediaScope = .videosAndPhotos,
        preservesUnobservedItems: Bool = false
    ) -> [String: Int] {
        var sessions = load()
        var session = sessions[sessionKey] ?? SessionState()
        let observedItems = allObservedItems ?? items
        let currentItems = Dictionary(uniqueKeysWithValues: observedItems.map { ($0.id, $0) })
        if !preservesUnobservedItems {
            session.queue = session.queue.filter { itemID, state in
                guard let item = currentItems[itemID] else { return false }
                return state.signature == signature(for: item)
            }
            session.results = session.results.filter { itemID, state in
                guard let item = currentItems[itemID] else { return false }
                return state.signature == signature(for: item)
            }
            session.cachedItems = session.cachedItems?.filter { itemID, signature in
                guard let item = currentItems[itemID] else { return false }
                return signature == self.signature(for: item)
            }
            session.vaultItems = session.vaultItems?.filter { itemID, state in
                guard let item = currentItems[itemID] else { return false }
                return state.signature == signature(for: item)
            }
        }
        for item in items
        where session.queue[item.id] == nil
            && session.results[item.id] == nil
            && session.cachedItems?[item.id] == nil {
            session.queue[item.id] = ItemState(
                signature: signature(for: item),
                nextAttempt: 0
            )
        }
        session.mediaScope = mediaScope
        sessions[sessionKey] = session
        save(sessions)
        return session.queue.mapValues { min(max($0.nextAttempt, 0), 2) }
    }

    func prepareVault(
        for items: [RemoteFileItem],
        sessionKey: String,
        allObservedItems: [RemoteFileItem]? = nil,
        preservesUnobservedItems: Bool = false
    ) {
        updateSession(sessionKey) { session in
            var vaultItems = session.vaultItems ?? [:]
            let observedItems = allObservedItems ?? items
            let currentItems = Dictionary(uniqueKeysWithValues: observedItems.map { ($0.id, $0) })
            if !preservesUnobservedItems {
                vaultItems = vaultItems.filter { itemID, state in
                    guard let item = currentItems[itemID] else { return false }
                    return state.signature == signature(for: item)
                }
            }
            for item in items where vaultItems[item.id] == nil {
                vaultItems[item.id] = VaultItemState(
                    signature: signature(for: item),
                    folderPath: parentDirectory(of: item.path),
                    status: .waitingForThumbnail,
                    errorDescription: nil
                )
            }
            session.vaultItems = vaultItems
        }
    }

    func markVaultPending(
        _ item: RemoteFileItem,
        sessionKey: String
    ) {
        updateSession(sessionKey) { session in
            var vaultItems = session.vaultItems ?? [:]
            let previous = vaultItems[item.id]
            vaultItems[item.id] = VaultItemState(
                signature: signature(for: item),
                folderPath: parentDirectory(of: item.path),
                status: previous?.status == .uploaded ? .uploaded : .pendingUpload,
                errorDescription: nil
            )
            session.vaultItems = vaultItems
        }
    }

    func recordVaultResult(
        storedItemIDs: Set<String>,
        attemptedItemIDs: Set<String>,
        errorDescription: String?,
        sessionKey: String
    ) {
        updateSession(sessionKey) { session in
            guard var vaultItems = session.vaultItems else { return }
            for itemID in attemptedItemIDs {
                guard var state = vaultItems[itemID] else { continue }
                if storedItemIDs.contains(itemID) {
                    state.status = .uploaded
                    state.errorDescription = nil
                } else if errorDescription != nil {
                    state.status = .uploadFailed
                    state.errorDescription = errorDescription
                } else {
                    state.status = .pendingUpload
                    state.errorDescription = nil
                }
                vaultItems[itemID] = state
            }
            session.vaultItems = vaultItems
        }
    }

    func recordVaultVerification(
        storedItemIDs: Set<String>,
        verifiedAt: Date,
        sessionKey: String
    ) {
        updateSession(sessionKey) { session in
            guard var vaultItems = session.vaultItems else { return }
            for (itemID, var state) in vaultItems {
                if storedItemIDs.contains(itemID) {
                    state.status = .uploaded
                    state.errorDescription = nil
                } else if state.status == .uploaded {
                    state.status = .pendingUpload
                    state.errorDescription = nil
                }
                vaultItems[itemID] = state
            }
            session.vaultItems = vaultItems
            session.vaultLastVerifiedAt = verifiedAt
        }
    }

    func deferItem(
        _ item: RemoteFileItem,
        sessionKey: String,
        nextAttempt: Int
    ) {
        updateSession(sessionKey) { session in
            session.queue[item.id] = ItemState(
                signature: signature(for: item),
                nextAttempt: min(max(nextAttempt, 0), 2)
            )
            session.results[item.id] = nil
        }
    }

    @discardableResult
    func markCached(
        _ item: RemoteFileItem,
        sessionKey: String
    ) -> CachedTransition {
        var previousSuccessAttempt: Int?
        var removedPhotoSuccess = false
        var removedFailure = false
        updateSession(sessionKey) { session in
            previousSuccessAttempt = session.results[item.id]?.successAttempt
            removedPhotoSuccess = session.results[item.id]?.photoSuccess == true
            removedFailure = session.results[item.id]?.failure != nil
            session.queue[item.id] = nil
            var cachedItems = session.cachedItems ?? [:]
            cachedItems[item.id] = signature(for: item)
            session.cachedItems = cachedItems
            // One file belongs to exactly one report category. Once its
            // thumbnail is observed in cache it is no longer a stage result.
            session.results[item.id] = nil
        }
        return CachedTransition(
            previousSuccessAttempt: previousSuccessAttempt,
            removedPhotoSuccess: removedPhotoSuccess,
            removedFailure: removedFailure
        )
    }

    func recordSuccess(
        _ item: RemoteFileItem,
        sessionKey: String,
        attempt: Int
    ) {
        updateSession(sessionKey) { session in
            session.queue[item.id] = nil
            session.cachedItems?[item.id] = nil
            session.results[item.id] = ResultState(
                signature: signature(for: item),
                successAttempt: min(max(attempt, 0), 2),
                photoSuccess: false,
                failure: nil
            )
        }
    }

    func recordPhotoSuccess(_ item: RemoteFileItem, sessionKey: String) {
        updateSession(sessionKey) { session in
            session.queue[item.id] = nil
            session.cachedItems?[item.id] = nil
            session.results[item.id] = ResultState(
                signature: signature(for: item),
                successAttempt: nil,
                photoSuccess: true,
                failure: nil
            )
        }
    }

    func recordFailure(
        _ item: RemoteFileItem,
        sessionKey: String,
        durationSeconds: TimeInterval?,
        reason: String
    ) {
        let record = SuperThumbnailFailureRecord(
            itemID: item.id,
            name: item.name,
            fileExtension: (item.name as NSString).pathExtension.uppercased(),
            fileSize: item.size,
            durationSeconds: durationSeconds,
            reason: reason
        )
        updateSession(sessionKey) { session in
            session.queue[item.id] = ItemState(
                signature: signature(for: item),
                nextAttempt: 2
            )
            session.cachedItems?[item.id] = nil
            session.results[item.id] = ResultState(
                signature: signature(for: item),
                successAttempt: nil,
                photoSuccess: false,
                failure: record
            )
        }
    }

    func report(sessionKey: String) -> SuperThumbnailSessionReport? {
        guard let session = load()[sessionKey] else { return nil }
        var counts = [0, 0, 0]
        var photoSuccessCount = 0
        var failures: [SuperThumbnailFailureRecord] = []
        for result in session.results.values {
            if let attempt = result.successAttempt,
               counts.indices.contains(attempt) {
                counts[attempt] += 1
            }
            if let failure = result.failure {
                failures.append(failure)
            }
            if result.photoSuccess == true { photoSuccessCount += 1 }
        }
        let vaultStates = session.vaultItems.map { Array($0.values) } ?? []
        let folderReports = Dictionary(grouping: vaultStates) {
            $0.folderPath
        }
        .map { path, states in
            SuperThumbnailVaultFolderReport(
                path: path,
                totalCount: states.count,
                uploadedCount: states.lazy.filter { $0.status == .uploaded }.count,
                waitingThumbnailCount: states.lazy.filter {
                    $0.status == .waitingForThumbnail
                }.count,
                pendingCount: states.lazy.filter { $0.status == .pendingUpload }.count,
                failedCount: states.lazy.filter { $0.status == .uploadFailed }.count,
                errorDescription: states.lazy.compactMap(\.errorDescription).first
            )
        }
        .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return SuperThumbnailSessionReport(
            successCounts: counts,
            photoSuccessCount: photoSuccessCount,
            failures: failures.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            pendingCount: session.queue.count,
            cachedCount: session.cachedItems?.count ?? 0,
            vaultFolders: folderReports,
            vaultLastVerifiedAt: session.vaultLastVerifiedAt,
            mediaScope: session.mediaScope ?? .videosAndPhotos
        )
    }

    func mediaScope(sessionKey: String) -> SuperThumbnailMediaScope? {
        load()[sessionKey]?.mediaScope
    }

    func resumeItems(
        sessionKey: String,
        connectionID: UUID
    ) -> [RemoteFileItem] {
        guard let session = load()[sessionKey] else { return [] }
        var itemIDs = Set(session.queue.keys)
        itemIDs.formUnion(session.results.compactMap { itemID, state in
            state.failure == nil ? nil : itemID
        })
        if let vaultItems = session.vaultItems {
            itemIDs.formUnion(vaultItems.compactMap { itemID, state in
                state.status == .uploaded ? nil : itemID
            })
        }
        return itemIDs.compactMap { itemID in
            let signature = session.queue[itemID]?.signature
                ?? session.results[itemID]?.signature
                ?? session.cachedItems?[itemID]
                ?? session.vaultItems?[itemID]?.signature
            guard let signature else { return nil }
            return remoteItem(
                itemID: itemID,
                signature: signature,
                connectionID: connectionID
            )
        }
        .sorted { lhs, rhs in
            lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
        }
    }

    func reset() {
        userDefaults.removeObject(forKey: Self.storageKey)
    }

    private func updateSession(
        _ sessionKey: String,
        change: (inout SessionState) -> Void
    ) {
        var sessions = load()
        var session = sessions[sessionKey] ?? SessionState()
        change(&session)
        sessions[sessionKey] = session
        save(sessions)
    }

    private func signature(for item: RemoteFileItem) -> String {
        let modified = item.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(item.id)|\(item.size ?? -1)|\(modified)"
    }

    private func remoteItem(
        itemID: String,
        signature: String,
        connectionID: UUID
    ) -> RemoteFileItem? {
        let itemPrefix = "\(connectionID.uuidString):"
        guard itemID.hasPrefix(itemPrefix),
              signature.hasPrefix("\(itemID)|") else { return nil }
        let path = String(itemID.dropFirst(itemPrefix.count))
        let metadata = signature.dropFirst(itemID.count + 1).split(separator: "|", maxSplits: 1)
        guard metadata.count == 2 else { return nil }
        let storedSize = Int64(String(metadata[0]))
        let modifiedInterval = TimeInterval(String(metadata[1]))
        return RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: (path as NSString).lastPathComponent,
            kind: .file,
            size: storedSize == -1 ? nil : storedSize,
            modifiedAt: modifiedInterval.flatMap {
                $0 == 0 ? nil : Date(timeIntervalSince1970: $0)
            },
            contentTypeIdentifier: nil
        )
    }

    private func parentDirectory(of path: String) -> String {
        let parent = (path as NSString).deletingLastPathComponent
        if parent.isEmpty { return path.hasPrefix("/") ? "/" : "." }
        return parent
    }

    private func load() -> Sessions {
        guard let data = userDefaults.data(forKey: Self.storageKey),
              let sessions = try? JSONDecoder().decode(Sessions.self, from: data)
        else { return [:] }
        return sessions
    }

    private func save(_ sessions: Sessions) {
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        userDefaults.set(data, forKey: Self.storageKey)
    }
}
