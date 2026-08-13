import CryptoKit
import Foundation
import ImageIO

struct ProviderThumbnailCache {
    private let fileManager = FileManager.default
    private let directoryURL: URL?

    init(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: NasFinderFileProviderIdentifiers.appGroup
    )) {
        directoryURL = containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("FileProviderThumbnails.v1", isDirectory: true)
    }

    func data(forKey key: String) -> Data? {
        guard let directoryURL,
              let data = try? Data(
                contentsOf: fileURL(forKey: key, directoryURL: directoryURL),
                options: .mappedIfSafe
              ),
              isValidImage(data) else { return nil }
        return data
    }

    func store(_ data: Data, forKey key: String) {
        guard !data.isEmpty, isValidImage(data), let directoryURL else { return }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(forKey: key, directoryURL: directoryURL), options: .atomic)
        } catch {
            // Files can fall back to its normal icon if the cache is unavailable.
        }
    }

    static func key(
        for node: ProviderRemoteNode,
        connectionID: UUID,
        size: ProviderThumbnailSize
    ) -> String {
        let itemID = "\(connectionID.uuidString):\(node.path)"
        let version = node.modifiedAt?.timeIntervalSince1970 ?? 0
        return "\(itemID)|\(version)|\(node.size ?? -1)|\(size.rawValue)"
    }

    private func fileURL(forKey key: String, directoryURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func isValidImage(_ data: Data) -> Bool {
        CGImageSourceCreateWithData(data as CFData, nil) != nil
    }
}
