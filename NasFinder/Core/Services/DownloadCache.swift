import CryptoKit
import Foundation

actor DownloadCache {
    static let shared = DownloadCache()

    private let root: URL
    private let fileManager = FileManager.default
    private let maximumByteCount: Int64 = 512 * 1_024 * 1_024
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60

    init(root: URL? = nil) {
        if let root {
            self.root = root
        } else {
            let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = base.appending(path: "RemoteFiles", directoryHint: .isDirectory)
        }
    }

    func cachedURL(for item: RemoteFileItem) -> URL? {
        let url = destinationURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else { return nil }

        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        if let modifiedAt = values?.contentModificationDate,
           Date().timeIntervalSince(modifiedAt) > maximumAge {
            try? fileManager.removeItem(at: url)
            return nil
        }

        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func store(downloadedURL: URL, for item: RemoteFileItem) throws -> URL {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = destinationURL(for: item)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.moveItem(at: downloadedURL, to: destination)
        try? trimCacheIfNeeded(keeping: destination)
        return destination
    }

    private func trimCacheIfNeeded(keeping protectedURL: URL) throws {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]
        let urls = try fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles]
        )
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var totalBytes: Int64 = 0
        let expirationDate = Date().addingTimeInterval(-maximumAge)

        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast
            if date < expirationDate, url != protectedURL {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append((url, size, date))
            totalBytes += size
        }

        for entry in entries.sorted(by: { $0.date < $1.date })
        where totalBytes > maximumByteCount && entry.url != protectedURL {
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private func destinationURL(for item: RemoteFileItem) -> URL {
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        let rawKey = "\(item.connectionID.uuidString)|\(item.path)|\(version)|\(item.size ?? -1)"
        let digest = SHA256.hash(data: Data(rawKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (item.name as NSString).pathExtension
        let filename = ext.isEmpty ? digest : "\(digest).\(ext)"
        return root.appending(path: filename, directoryHint: .notDirectory)
    }
}
