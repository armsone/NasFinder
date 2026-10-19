import CryptoKit
import Foundation

actor SuperThumbnailCache {
    static let shared = SuperThumbnailCache()

    private static let networkUsageKey = "superThumbnailLifetimeNetworkBytes.v1"
    private let fileManager = FileManager.default
    private let directoryURL: URL
    private let userDefaults: UserDefaults
    private var generation: UInt64 = 0

    init(directoryURL: URL? = nil, userDefaults: UserDefaults = .standard) {
        if let directoryURL {
            self.directoryURL = directoryURL
        } else {
            let baseURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.directoryURL = baseURL.appendingPathComponent(
                "SuperThumbnails.v1",
                isDirectory: true
            )
        }
        self.userDefaults = userDefaults
    }

    func data(forKey key: String) -> Data? {
        try? Data(contentsOf: fileURL(forKey: key), options: .mappedIfSafe)
    }

    /// Version stamp of a stored entry: the NAS Super Thumbnail's modification
    /// date when the entry was restored from the Vault, otherwise the local
    /// write time. It is the file's own modification date, so no extra
    /// metadata file or schema exists, and older entries keep working.
    func storedVersion(forKey key: String) -> Date? {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL(forKey: key).path)
        return attributes?[.modificationDate] as? Date
    }

    /// Byte size of the stored raw JPEG payload (file attribute only, no read).
    /// Stored bytes are the exact Vault payload, so this is comparable with the
    /// NAS record size; decoded image sizes are never compared.
    func storedByteSize(forKey key: String) -> Int64? {
        let attributes = try? fileManager.attributesOfItem(atPath: fileURL(forKey: key).path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    /// A NAS record is newer when its mtime is strictly later than the local
    /// version, or when both byte sizes are known and positive and differ.
    /// Unknown values never invalidate; same size with same/unknown mtime is
    /// treated as unchanged (a known limitation).
    nonisolated static func nasRecordIsNewer(
        nasModifiedAt: Date?,
        nasSize: Int64?,
        localVersion: Date,
        localSize: Int64?
    ) -> Bool {
        if let nasModifiedAt, nasModifiedAt.timeIntervalSince(localVersion) > 1 {
            return true
        }
        if let nasSize, let localSize, nasSize > 0, localSize > 0, nasSize != localSize {
            return true
        }
        return false
    }

    func containsData(forKey key: String) -> Bool {
        fileManager.fileExists(atPath: fileURL(forKey: key).path)
    }

    func containsAnyData(forKeys keys: Set<String>) -> Bool {
        keys.contains { key in
            fileManager.fileExists(atPath: fileURL(forKey: key).path)
        }
    }

    func store(
        _ data: Data,
        forKey key: String,
        expectedGeneration: UInt64? = nil,
        nasModifiedAt: Date? = nil
    ) async {
        guard !data.isEmpty else { return }
        if let expectedGeneration, expectedGeneration != generation { return }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL(forKey: key), options: .atomic)
            if let nasModifiedAt {
                // Compare NAS time with NAS time later, never with the phone clock.
                try? fileManager.setAttributes(
                    [.modificationDate: nasModifiedAt],
                    ofItemAtPath: fileURL(forKey: key).path
                )
            }
            await FileProviderThumbnailCache.shared.store(data, forKey: key)
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .superThumbnailCacheDidChange,
                    object: key
                )
                NotificationCenter.default.post(
                    name: .remoteThumbnailDiskCacheDidStore,
                    object: key
                )
            }
        } catch {
            // The generated image still remains available to the current task.
        }
    }

    func currentGeneration() -> UInt64 {
        generation
    }

    func addNetworkUsage(_ byteCount: Int64) async {
        guard byteCount > 0 else { return }
        let current = Int64(userDefaults.double(forKey: Self.networkUsageKey))
        userDefaults.set(Double(current + byteCount), forKey: Self.networkUsageKey)
        await notifyChange()
    }

    func statistics() -> SuperThumbnailStatistics {
        let entries = cacheEntries()
        return SuperThumbnailStatistics(
            fileCount: entries.count,
            cacheBytes: entries.reduce(Int64(0)) { $0 + $1 },
            lifetimeNetworkBytes: Int64(
                userDefaults.double(forKey: Self.networkUsageKey)
            )
        )
    }

    func reset() async {
        generation &+= 1
        try? fileManager.removeItem(at: directoryURL)
        await FileProviderThumbnailCache.shared.removeAll()
        userDefaults.removeObject(forKey: Self.networkUsageKey)
        await RemoteVideoThumbnailTrafficBudget.completeFileShared.reset()
        await RemoteVideoThumbnailTrafficBudget.completeFileFastPass.reset()
        await RemoteVideoThumbnailTrafficBudget.completeFileRetryPass.reset()
        await RemoteVideoThumbnailTrafficBudget.completeFileRecoveryPass.reset()
        await SuperThumbnailQueueStore.shared.reset()
        await RemoteThumbnailLoader.clearInMemoryCaches()
        await notifyChange()
    }

    private func notifyChange() async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .superThumbnailCacheDidChange,
                object: nil
            )
        }
    }

    private func fileURL(forKey key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8))
        let filename = digest.map { String(format: "%02x", $0) }.joined()
        return directoryURL.appendingPathComponent(filename, isDirectory: false)
    }

    private func cacheEntries() -> [Int64] {
        let keys: Set<URLResourceKey> = [.fileSizeKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return urls.map {
            let values = try? $0.resourceValues(forKeys: keys)
            return Int64(values?.fileSize ?? 0)
        }
    }
}

struct SuperThumbnailStatistics: Equatable, Sendable {
    let fileCount: Int
    let cacheBytes: Int64
    let lifetimeNetworkBytes: Int64

    static let empty = SuperThumbnailStatistics(
        fileCount: 0,
        cacheBytes: 0,
        lifetimeNetworkBytes: 0
    )
}

extension Notification.Name {
    static let superThumbnailCacheDidChange = Notification.Name(
        "superThumbnailCacheDidChange"
    )
}
