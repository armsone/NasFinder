import CryptoKit
import Foundation

/// A small App Group cache shared with the File Provider extension. The cache
/// only contains generated previews; original remote files are never copied.
actor FileProviderThumbnailCache {
    static let shared = FileProviderThumbnailCache()

    private let fileManager = FileManager.default
    private let directoryURL: URL?

    init(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.armsone.nasfinder"
    )) {
        directoryURL = containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("FileProviderThumbnails.v1", isDirectory: true)
    }

    func store(_ data: Data, forKey key: String) {
        guard !data.isEmpty, let directoryURL else { return }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(forKey: key, directoryURL: directoryURL), options: .atomic)
        } catch {
            // Sharing with Files is an optimization. The app cache remains valid.
        }
    }

    func removeAll() {
        guard let directoryURL else { return }
        try? fileManager.removeItem(at: directoryURL)
    }

    private func fileURL(forKey key: String, directoryURL: URL) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }
}
