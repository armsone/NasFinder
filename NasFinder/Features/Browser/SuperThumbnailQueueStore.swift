import Foundation

actor SuperThumbnailQueueStore {
    static let shared = SuperThumbnailQueueStore()

    private struct ItemState: Codable {
        let signature: String
        var nextAttempt: Int
    }

    private typealias Sessions = [String: [String: ItemState]]

    private static let storageKey = "superThumbnail.retryQueues.v1"
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func attempts(
        for items: [RemoteFileItem],
        sessionKey: String
    ) -> [String: Int] {
        var sessions = load()
        let existing = sessions[sessionKey] ?? [:]
        let currentItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var cleaned: [String: ItemState] = [:]
        var result: [String: Int] = [:]

        for (itemID, state) in existing {
            guard let item = currentItems[itemID],
                  state.signature == signature(for: item) else { continue }
            let attempt = min(max(state.nextAttempt, 0), 3)
            cleaned[itemID] = ItemState(
                signature: state.signature,
                nextAttempt: attempt
            )
            result[itemID] = attempt
        }
        sessions[sessionKey] = cleaned
        save(sessions)
        return result
    }

    func deferItem(
        _ item: RemoteFileItem,
        sessionKey: String,
        nextAttempt: Int
    ) {
        var sessions = load()
        var session = sessions[sessionKey] ?? [:]
        session[item.id] = ItemState(
            signature: signature(for: item),
            nextAttempt: min(max(nextAttempt, 0), 3)
        )
        sessions[sessionKey] = session
        save(sessions)
    }

    func markSucceeded(_ item: RemoteFileItem, sessionKey: String) {
        var sessions = load()
        guard var session = sessions[sessionKey] else { return }
        session.removeValue(forKey: item.id)
        sessions[sessionKey] = session
        save(sessions)
    }

    func keepForRecovery(_ item: RemoteFileItem, sessionKey: String) {
        deferItem(item, sessionKey: sessionKey, nextAttempt: 3)
    }

    func reset() {
        userDefaults.removeObject(forKey: Self.storageKey)
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
