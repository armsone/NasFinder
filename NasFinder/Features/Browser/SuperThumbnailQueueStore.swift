import Foundation

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
    let failures: [SuperThumbnailFailureRecord]
    let pendingCount: Int
    let cachedCount: Int

    var successfulCount: Int { successCounts.reduce(0, +) }
    var hasWorkToResume: Bool { pendingCount > 0 || !failures.isEmpty }
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

actor SuperThumbnailQueueStore {
    struct CachedTransition: Sendable, Equatable {
        let previousSuccessAttempt: Int?
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
        var failure: SuperThumbnailFailureRecord?
    }

    private struct SessionState: Codable {
        var queue: [String: ItemState] = [:]
        var results: [String: ResultState] = [:]
        var cachedItems: [String: String]? = nil
    }

    private typealias Sessions = [String: SessionState]

    private static let storageKey = "superThumbnail.retryQueues.v2"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func attempts(
        for items: [RemoteFileItem],
        sessionKey: String
    ) -> [String: Int] {
        var sessions = load()
        var session = sessions[sessionKey] ?? SessionState()
        let currentItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
        for item in items
        where session.queue[item.id] == nil
            && session.results[item.id] == nil
            && session.cachedItems?[item.id] == nil {
            session.queue[item.id] = ItemState(
                signature: signature(for: item),
                nextAttempt: 0
            )
        }
        sessions[sessionKey] = session
        save(sessions)
        return session.queue.mapValues { min(max($0.nextAttempt, 0), 2) }
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
        var removedFailure = false
        updateSession(sessionKey) { session in
            previousSuccessAttempt = session.results[item.id]?.successAttempt
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
                failure: record
            )
        }
    }

    func report(sessionKey: String) -> SuperThumbnailSessionReport? {
        guard let session = load()[sessionKey] else { return nil }
        var counts = [0, 0, 0]
        var failures: [SuperThumbnailFailureRecord] = []
        for result in session.results.values {
            if let attempt = result.successAttempt,
               counts.indices.contains(attempt) {
                counts[attempt] += 1
            }
            if let failure = result.failure {
                failures.append(failure)
            }
        }
        return SuperThumbnailSessionReport(
            successCounts: counts,
            failures: failures.sorted {
                $0.name.localizedStandardCompare($1.name) == .orderedAscending
            },
            pendingCount: session.queue.count,
            cachedCount: session.cachedItems?.count ?? 0
        )
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
