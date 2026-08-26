import Foundation

struct FavoriteItem: Codable, Hashable, Identifiable, Sendable {
    let connectionID: UUID
    let path: String
    let remoteIdentifier: String?
    let parentRemoteIdentifier: String?
    let revisionIdentifier: String?
    let name: String
    let kind: RemoteFileItem.ItemKind
    let size: Int64?
    let modifiedAt: Date?
    let contentTypeIdentifier: String?
    let addedAt: Date

    init(item: RemoteFileItem, addedAt: Date = .now) {
        connectionID = item.connectionID
        path = item.path
        remoteIdentifier = item.remoteIdentifier
        parentRemoteIdentifier = item.parentRemoteIdentifier
        revisionIdentifier = item.revisionIdentifier
        name = item.name
        kind = item.kind
        size = item.size
        modifiedAt = item.modifiedAt
        contentTypeIdentifier = item.contentTypeIdentifier
        self.addedAt = addedAt
    }

    var id: String {
        guard let remoteIdentifier else {
            return "\(connectionID.uuidString):\(path)"
        }
        return "\(connectionID.uuidString):remote:\(remoteIdentifier)"
    }

    var remoteItem: RemoteFileItem {
        RemoteFileItem(
            connectionID: connectionID,
            path: path,
            remoteIdentifier: remoteIdentifier,
            parentRemoteIdentifier: parentRemoteIdentifier,
            revisionIdentifier: revisionIdentifier,
            name: name,
            kind: kind,
            size: size,
            modifiedAt: modifiedAt,
            contentTypeIdentifier: contentTypeIdentifier
        )
    }
}
