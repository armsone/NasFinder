import CryptoKit
import Foundation

/// On-NAS naming for folder Super Thumbnail records inside the parent
/// directory's `.NasFinder-Vault`. The identity is name-only (engine version,
/// literal `kind=folder`, NFC-precomposed folder name joined with `|`, SHA-256
/// lowercase hex) because directory sizes and modification dates differ
/// between protocols and devices. The `v1-folder-` prefix can never collide
/// with the existing `v1-<digest>.jpg` file records, so old clients simply
/// ignore folder records and new clients keep reading old file records.
enum FolderSuperThumbnailNaming {
    static let engineVersion = 1

    static func thumbnailFilename(folderName: String) -> String {
        "v\(engineVersion)-folder-" + identityDigest(folderName: folderName) + ".jpg"
    }

    /// Explicit indexed state written by the generator for folders without a
    /// visible child. Folders that were unreadable or cancelled leave no
    /// record and therefore remain retryable.
    static func emptyMarkerFilename(folderName: String) -> String {
        "v\(engineVersion)-folder-" + identityDigest(folderName: folderName) + ".empty"
    }

    private static func identityDigest(folderName: String) -> String {
        let identity = [
            "engine=\(engineVersion)",
            "kind=folder",
            "name=\(folderName.precomposedStringWithCanonicalMapping)",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum FolderSuperThumbnailLookup: Sendable {
    case data(Data)
    case emptyIndexed
    case missing
}

enum FolderSuperThumbnailDisplayPolicy {
    /// Folder sheets are display-only on Apple platforms: they are generated
    /// by the Mac helper and merely discovered here, so lookup applies to
    /// every directory the browser can show.
    static func shouldLookup(item: RemoteFileItem) -> Bool {
        item.isDirectory
    }

    /// How long a lookup result without a sheet stays negatively cached. An
    /// indexed empty folder is stable; a missing record stays retryable soon.
    static func negativeCacheDuration(
        for lookup: FolderSuperThumbnailLookup
    ) -> TimeInterval? {
        switch lookup {
        case .data:
            return nil
        case .emptyIndexed:
            return 10 * 60
        case .missing:
            return 60
        }
    }
}
