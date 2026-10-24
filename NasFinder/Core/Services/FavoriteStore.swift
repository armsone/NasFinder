import Foundation

@MainActor
final class FavoriteStore: ObservableObject {
    /// 비공개를 포함한 전체 즐겨찾기. 저장·삭제·순서 변경은 항상 이 전체 목록을 대상으로 한다.
    @Published private(set) var storedItems: [FavoriteItem] = []

    /// 지금 모드에서 보이는 즐겨찾기: 일반 모드는 공개만, 프라이버시 모드는 공개 + 비공개.
    /// 비공개 연결·폰하드 경로를 가리키는 즐겨찾기도 일반 모드에서는 가려진다.
    var items: [FavoriteItem] { storedItems.filter(Self.isVisible) }

    private let defaults: UserDefaults
    private let storageKey = "favorites.v1"

    enum ToggleResult { case added, removed, blocked }

    init(defaults: UserDefaults? = UserDefaults(suiteName: "group.com.armsone.nasfinder")) {
        self.defaults = defaults ?? .standard
        load()
    }

    nonisolated static func isVisible(_ favorite: FavoriteItem) -> Bool {
        PrivacyMode.isVisible(favorite.isPrivate)
            && !PrivacyMode.hides(connectionID: favorite.connectionID, path: favorite.path)
    }

    func contains(_ item: RemoteFileItem) -> Bool {
        storedItems.contains { $0.id == item.id && Self.isVisible($0) }
    }

    /// 보이는 즐겨찾기면 해제, 아니면 추가한다. 같은 id의 숨겨진 레코드가 있으면 아무것도 바꾸지 않는다
    /// (조용히 공개로 바꾸거나 지우지 않는다). 새 레코드는 프라이버시 모드에서만 비공개로 시작한다.
    @discardableResult
    func toggle(_ item: RemoteFileItem) -> ToggleResult {
        if let existing = storedItems.first(where: { $0.id == item.id }) {
            guard Self.isVisible(existing) else { return .blocked }
            remove(id: item.id)
            return .removed
        }
        storedItems.append(FavoriteItem(item: item, isPrivate: PrivacyMode.shared.newRecordFlag))
        persist()
        return .added
    }

    func remove(id: FavoriteItem.ID) {
        // 보이는 레코드만 사용자가 지울 수 있다.
        guard storedItems.contains(where: { $0.id == id && Self.isVisible($0) }) else { return }
        storedItems.removeAll { $0.id == id }
        persist()
    }

    /// 명시적인 공개/비공개 전환. id·순서·추가 시각은 그대로 두고 플래그만 바꾼다.
    func setPrivate(id: FavoriteItem.ID, _ isPrivate: Bool) {
        guard let index = storedItems.firstIndex(where: { $0.id == id }) else { return }
        let flag: Bool? = isPrivate ? true : nil
        guard storedItems[index].isPrivate != flag else { return }
        storedItems[index].isPrivate = flag
        persist()
    }

    /// `destination`은 보이는 목록의 위치다. 숨겨진 즐겨찾기의 상대 순서는 바꾸지 않는다.
    func move(id: FavoriteItem.ID, to destination: Int) {
        let visible = items
        guard let visibleSource = visible.firstIndex(where: { $0.id == id }),
              visible.indices.contains(destination),
              visibleSource != destination,
              let item = storedItems.first(where: { $0.id == id }) else {
            return
        }
        let anchorID = visible[destination].id
        let movesDown = visibleSource < destination
        storedItems.removeAll { $0.id == id }
        guard let anchor = storedItems.firstIndex(where: { $0.id == anchorID }) else {
            storedItems.append(item)
            persist()
            return
        }
        storedItems.insert(item, at: movesDown ? anchor + 1 : anchor)
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let savedItems = try? JSONDecoder().decode([FavoriteItem].self, from: data) else {
            return
        }
        storedItems = savedItems
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(storedItems) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
