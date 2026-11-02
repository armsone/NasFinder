import CryptoKit
import Foundation

actor DownloadCache {
    static let shared = DownloadCache()
    // Version 2 is written only after backend integrity validation. Bumping
    // the key keeps incomplete files created by older builds from being
    // mistaken for trusted cache entries after size validation moves to the
    // download boundary.
    private static let formatVersion = 2

    private let root: URL
    private let fileManager = FileManager.default
    private let maximumByteCount: Int64 = 512 * 1_024 * 1_024
    private let maximumAge: TimeInterval = 7 * 24 * 60 * 60
    private var protectedFilenames: [String: Int] = [:]

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

        let values = try? url.resourceValues(forKeys: [
            .contentModificationDateKey,
            .fileSizeKey,
        ])
        if let modifiedAt = values?.contentModificationDate,
           Date().timeIntervalSince(modifiedAt) > maximumAge,
           protectedFilenames[url.lastPathComponent] == nil {
            try? fileManager.removeItem(at: url)
            return nil
        }

        try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return url
    }

    func protect(_ item: RemoteFileItem) {
        let filename = destinationURL(for: item).lastPathComponent
        protectedFilenames[filename, default: 0] += 1
    }

    func release(_ item: RemoteFileItem) {
        let filename = destinationURL(for: item).lastPathComponent
        guard let count = protectedFilenames[filename] else { return }
        if count > 1 {
            protectedFilenames[filename] = count - 1
        } else {
            protectedFilenames[filename] = nil
        }
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

    struct Snapshot: Sendable, Equatable {
        var fileCount = 0
        var byteCount: Int64 = 0
        var retainedCount = 0
        var retainedByteCount: Int64 = 0
        /// Number of files whose deletion actually failed (never inferred from unknown state).
        var failedCount = 0
        /// False when the root or an entry could not be inspected; counts are then not trustworthy.
        var isUsageKnown = true
        var firstErrorDescription: String?
    }

    private struct Scan {
        var files: [(url: URL, size: Int64)] = []
        var firstError: String?
    }

    /// Direct cache-named regular files in the cache root only. No recursion, no symlinks.
    /// A missing root is an empty cache; any real IO error makes the usage unknown.
    func usageSnapshot() -> Snapshot {
        makeSnapshot(from: scanOwnedFiles(), failedCount: 0, deletionError: nil)
    }

    /// Removes only unprotected cache-named regular files directly inside the cache root.
    /// If the root cannot be safely enumerated nothing is deleted. Uninspected files are preserved.
    /// The returned snapshot describes what remains; actual delete failures are counted with the first error.
    /// No awaits in the loop, so the protection check and the delete stay serialized on the actor.
    func clearUnprotected() -> Snapshot {
        let scan = scanOwnedFiles()
        // 처음 스캔이 불확실하면 아무것도 지우지 않고 원래 I/O 오류를 그대로 돌려준다.
        if scan.firstError != nil {
            return makeSnapshot(from: scan, failedCount: 0, deletionError: nil)
        }
        var failedCount = 0
        var firstDeletionError: String?
        for entry in scan.files where protectedFilenames[entry.url.lastPathComponent] == nil {
            do {
                try fileManager.removeItem(at: entry.url)
            } catch {
                failedCount += 1
                if firstDeletionError == nil { firstDeletionError = error.localizedDescription }
            }
        }
        return makeSnapshot(from: scanOwnedFiles(), failedCount: failedCount, deletionError: firstDeletionError)
    }

    private func makeSnapshot(from scan: Scan, failedCount: Int, deletionError: String?) -> Snapshot {
        var snapshot = Snapshot()
        snapshot.failedCount = failedCount
        snapshot.isUsageKnown = scan.firstError == nil
        snapshot.firstErrorDescription = deletionError ?? scan.firstError
        guard snapshot.isUsageKnown else { return snapshot }
        for entry in scan.files {
            snapshot.fileCount += 1
            snapshot.byteCount += entry.size
            if protectedFilenames[entry.url.lastPathComponent] != nil {
                snapshot.retainedCount += 1
                snapshot.retainedByteCount += entry.size
            }
        }
        return snapshot
    }

    private func scanOwnedFiles() -> Scan {
        var scan = Scan()
        // Only the root itself must be a real directory; system ancestor aliases (/var) are fine.
        do {
            let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isSymbolicLink != true, rootValues.isDirectory == true else {
                scan.firstError = "캐시 폴더가 올바른 폴더가 아닙니다."
                return scan
            }
        } catch {
            if !Self.isMissingFile(error) { scan.firstError = error.localizedDescription }
            return scan
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles]
            )
        } catch {
            if !Self.isMissingFile(error) { scan.firstError = error.localizedDescription }
            return scan
        }
        for url in urls where Self.isCacheFilename(url.lastPathComponent) {
            do {
                let values = try url.resourceValues(forKeys: keys)
                guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                scan.files.append((url, Int64(values.fileSize ?? 0)))
            } catch {
                if Self.isMissingFile(error) { continue }
                if scan.firstError == nil { scan.firstError = error.localizedDescription }
            }
        }
        return scan
    }

    private static func isMissingFile(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            return nsError.code == NSFileNoSuchFileError || nsError.code == NSFileReadNoSuchFileError
        }
        return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
    }

    /// Matches destinationURL(for:): lowercase 64-hex SHA256, optionally "." + a single extension.
    private static func isCacheFilename(_ name: String) -> Bool {
        let digest = name.prefix(64)
        guard digest.count == 64,
              digest.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x61 && $0 <= 0x66) }) else {
            return false
        }
        let rest = name.dropFirst(64)
        if rest.isEmpty { return true }
        guard rest.first == "." else { return false }
        let ext = rest.dropFirst()
        return !ext.isEmpty && !ext.contains(".") && !ext.contains("/")
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
        // Directory enumeration may return a different URL representation of the same file.
        let protectedFilename = protectedURL.lastPathComponent

        for url in urls {
            let values = try url.resourceValues(forKeys: resourceKeys)
            guard values.isRegularFile == true else { continue }
            let size = Int64(values.fileSize ?? 0)
            let date = values.contentModificationDate ?? .distantPast
            if date < expirationDate, url.lastPathComponent != protectedFilename,
               protectedFilenames[url.lastPathComponent] == nil {
                try? fileManager.removeItem(at: url)
                continue
            }
            entries.append((url, size, date))
            totalBytes += size
        }

        for entry in entries.sorted(by: { $0.date < $1.date })
        where totalBytes > maximumByteCount && entry.url.lastPathComponent != protectedFilename
            && protectedFilenames[entry.url.lastPathComponent] == nil {
            try? fileManager.removeItem(at: entry.url)
            totalBytes -= entry.size
        }
    }

    private func destinationURL(for item: RemoteFileItem) -> URL {
        let version = item.modifiedAt?.timeIntervalSince1970 ?? 0
        let rawKey = "v\(Self.formatVersion)|\(item.connectionID.uuidString)|\(item.path)|\(version)|\(item.size ?? -1)"
        let digest = SHA256.hash(data: Data(rawKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let ext = (item.name as NSString).pathExtension
        let filename = ext.isEmpty ? digest : "\(digest).\(ext)"
        return root.appending(path: filename, directoryHint: .notDirectory)
    }
}
