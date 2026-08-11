import Foundation

struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    let connectionID: UUID
    let path: String
    let name: String
    let kind: RemoteFileItem.ItemKind
    let size: Int64?
    let modifiedAt: Date?
    let contentTypeIdentifier: String?
    let addedAt: Date

    init(item: RemoteFileItem, addedAt: Date = .now) {
        connectionID = item.connectionID
        path = item.path
        name = item.name
        kind = item.kind
        size = item.size
        modifiedAt = item.modifiedAt
        contentTypeIdentifier = item.contentTypeIdentifier
        self.addedAt = addedAt
    }

    var id: String { "\(connectionID.uuidString):\(path)" }

    var remoteItem: RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            name: name,
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }
}
