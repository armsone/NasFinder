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
    /// 비공개 즐겨찾기(nil = 공개, 예전 데이터와 같다). 같은 id당 레코드는 하나이고 플래그만 바뀐다.
    var isPrivate: Bool?

    init(item: RemoteFileItem, addedAt: Date = .now, isPrivate: Bool? = nil) {
        self.isPrivate = isPrivate == true ? true : nil
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
