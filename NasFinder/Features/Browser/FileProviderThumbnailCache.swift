import CryptoKit
import Foundation

/// A small App Group cache shared with the File Provider extension. The cache
/// only contains generated previews; original remote files are never copied.
actor FileProviderThumbnailCache {
    static let shared = FileProviderThumbnailCache()

    private static let migrationDefaultsKey = "fileProviderThumbnailCacheMigration.v1"

    private let fileManager = FileManager.default
    private let directoryURL: URL?
    private let legacyCacheURLs: [URL]
    private let migrationDefaults: UserDefaults

    init(containerURL: URL? = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: "group.com.armsone.nasfinder"
    ), legacyCacheURLs: [URL]? = nil, migrationDefaultsSuiteName: String? = nil) {
        directoryURL = containerURL?
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Caches", isDirectory: true)
            .appendingPathComponent("FileProviderThumbnails.v1", isDirectory: true)
        let appCachesURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first
        self.legacyCacheURLs = legacyCacheURLs ?? [
            appCachesURL?.appendingPathComponent("SuperThumbnails.v1", isDirectory: true),
            appCachesURL?.appendingPathComponent("RemoteThumbnails.v2", isDirectory: true)
        ].compactMap { $0 }
        self.migrationDefaults = UserDefaults(
            suiteName: migrationDefaultsSuiteName ?? "group.com.armsone.nasfinder"
        )
            ?? .standard
    }

    @discardableResult
    func migrateExistingCachesIfNeeded() -> Int {
        guard !migrationDefaults.bool(forKey: Self.migrationDefaultsKey),
              let directoryURL else { return 0 }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            var copiedCount = 0
            var hadCopyFailure = false
            for sourceDirectory in legacyCacheURLs {
                guard let sourceFiles = try? fileManager.contentsOfDirectory(
                    at: sourceDirectory,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for sourceURL in sourceFiles {
                    guard let values = try? sourceURL.resourceValues(
                        forKeys: [.isRegularFileKey]
                    ) else {
                        hadCopyFailure = true
                        continue
                    }
                    guard values.isRegularFile == true else { continue }
                    let destinationURL = directoryURL.appendingPathComponent(
                        sourceURL.lastPathComponent,
                        isDirectory: false
                    )
                    guard !fileManager.fileExists(atPath: destinationURL.path) else { continue }
                    do {
                        try fileManager.copyItem(at: sourceURL, to: destinationURL)
                        copiedCount += 1
                    } catch {
                        hadCopyFailure = true
                    }
                }
            }
            if !hadCopyFailure {
                migrationDefaults.set(true, forKey: Self.migrationDefaultsKey)
            }
            return copiedCount
        } catch {
            return 0
        }
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
