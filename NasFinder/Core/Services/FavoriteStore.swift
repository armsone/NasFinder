import Foundation

@MainActor
final class FavoriteStore: ObservableObject {
    @Published private(set) var items: [FavoriteItem] = []

    private let defaults: UserDefaults
    private let storageKey = "favorites.v1"

    init(defaults: UserDefaults? = UserDefaults(suiteName: "group.com.armsone.nasfinder")) {
        self.defaults = defaults ?? .standard
        load()
    }

    func contains(_ item: RemoteFileItem) -> Bool {
        items.contains { $0.id == item.id }
    }

    func toggle(_ item: RemoteFileItem) {
        if contains(item) {
            remove(id: item.id)
        } else {
            items.append(FavoriteItem(item: item))
            persist()
        }
    }

    func remove(id: FavoriteItem.ID) {
        guard items.contains(where: { $0.id == id }) else { return }
        items.removeAll { $0.id == id }
        persist()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let savedItems = try? JSONDecoder().decode([FavoriteItem].self, from: data) else {
            return
        }
        items = savedItems
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
