import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum NasFinderVaultCompatibility {
    static let directoryName = ".NasFinder-Vault"
    static let engineVersion = 1
    static let workersDirectoryName = ".workers-v1"

    static func thumbnailFilename(for url: URL) throws -> String {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return thumbnailFilename(
            name: url.lastPathComponent,
            size: values.fileSize.map(Int64.init),
            modifiedAt: values.contentModificationDate
        )
    }

    static func thumbnailFilename(
        name: String,
        size: Int64?,
        modifiedAt: Date?
    ) -> String {
        let identity = [
            "engine=\(engineVersion)",
            "name=\(name.precomposedStringWithCanonicalMapping)",
            "size=\(size ?? -1)",
            "modified=\(Int64((modifiedAt?.timeIntervalSince1970 ?? 0) * 1_000))",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return "v\(engineVersion)-"
            + digest.map { String(format: "%02x", $0) }.joined()
            + ".jpg"
    }

    /// Folder Super Thumbnail records use a name-only identity so any client
    /// can resolve them from a plain directory listing. Directory size and
    /// modification dates differ between protocols and must stay out of the
    /// digest. The `v1-folder-` prefix can never collide with file records.
    static func folderThumbnailFilename(folderName: String) -> String {
        "v\(engineVersion)-folder-" + folderIdentityDigest(folderName: folderName) + ".jpg"
    }

    /// Explicit indexed state for folders without any visible child. The
    /// marker keeps re-runs cheap while unreadable or cancelled folders leave
    /// no record and therefore remain retryable.
    static func folderEmptyMarkerFilename(folderName: String) -> String {
        "v\(engineVersion)-folder-" + folderIdentityDigest(folderName: folderName) + ".empty"
    }

    private static func folderIdentityDigest(folderName: String) -> String {
        let identity = [
            "engine=\(engineVersion)",
            "kind=folder",
            "name=\(folderName.precomposedStringWithCanonicalMapping)",
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

enum SupportedMedia {
    private static let imageExtensions: Set<String> = [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp",
    ]
    private static let videoExtensions: Set<String> = [
        "3gp", "avi", "m2ts", "m4v", "mkv", "mov", "mp4", "mpeg", "mpg", "mts", "ts", "webm",
    ]

    static func kind(for url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) { return .image }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }
}

enum MediaKind: Hashable {
    case image
    case video
}

struct MediaFile {
    let url: URL
    let kind: MediaKind
    let size: Int64
}

struct ProcessingResult {
    let generated: Bool
    let alreadyCached: Bool
    let thumbnailBytes: Int64
}

private struct VaultWorkerRecord: Codable {
    let workerID: String
    let expiresAt: Date
}

struct VaultLeaseRecord: Codable {
    let workerID: String
    let token: String
    let expiresAt: Date
}

enum VaultProcessorError: LocalizedError {
    case cannotDecode
    case cannotEncode
    case claimUnavailable
    case unsafeVaultRemoval

    var errorDescription: String? {
        switch self {
        case .cannotDecode:
            return "지원되지 않거나 손상된 미디어입니다."
        case .cannotEncode:
            return "썸네일 JPEG를 만들지 못했습니다."
        case .claimUnavailable:
            return "다른 기기가 처리 중입니다."
        case .unsafeVaultRemoval:
            return "선택한 폴더 안의 .NasFinder-Vault만 삭제할 수 있습니다."
        }
    }
}

enum VaultProcessor {
    static let fileManager = FileManager.default
    private static let workerLifetime: TimeInterval = 90
    static let leaseLifetime: TimeInterval = 180
    static let leaseRecordName = ".owner.json"
    static let maxPixelSize = 384

    static func discoverMedia(in root: URL) throws -> [MediaFile] {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .isDirectoryKey,
            .isHiddenKey,
            .fileSizeKey,
            .nameKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var files: [MediaFile] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true,
               url.lastPathComponent == NasFinderVaultCompatibility.directoryName {
                enumerator.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true,
                  values?.isHidden != true,
                  let kind = SupportedMedia.kind(for: url) else { continue }
            files.append(
                MediaFile(
                    url: url,
                    kind: kind,
                    size: Int64(values?.fileSize ?? 0)
                )
            )
        }
        return files.sorted {
            $0.url.path.localizedStandardCompare($1.url.path) == .orderedAscending
        }
    }

    @discardableResult
    static func registerWorker(_ workerID: String, root: URL) throws -> URL {
        let workers = root
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
            .appendingPathComponent(NasFinderVaultCompatibility.workersDirectoryName, isDirectory: true)
        try fileManager.createDirectory(at: workers, withIntermediateDirectories: true)
        let record = VaultWorkerRecord(
            workerID: workerID,
            expiresAt: Date().addingTimeInterval(workerLifetime)
        )
        let destination = workers.appendingPathComponent("worker-\(workerID).json")
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        return destination
    }

    static func process(_ file: MediaFile, workerID: String) async throws -> ProcessingResult {
        try Task.checkCancellation()
        let vault = file.url.deletingLastPathComponent()
            .appendingPathComponent(NasFinderVaultCompatibility.directoryName, isDirectory: true)
        try fileManager.createDirectory(at: vault, withIntermediateDirectories: true)

        let filename = try NasFinderVaultCompatibility.thumbnailFilename(for: file.url)
        let destination = vault.appendingPathComponent(filename)
        if fileManager.fileExists(atPath: destination.path) {
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return ProcessingResult(generated: false, alreadyCached: true, thumbnailBytes: size)
        }

        let claimName = ".claim-" + String(filename.dropLast(".jpg".count))
        let claim = vault.appendingPathComponent(claimName, isDirectory: true)
        try acquireClaim(at: claim, workerID: workerID)
        defer { try? fileManager.removeItem(at: claim) }

        if fileManager.fileExists(atPath: destination.path) {
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return ProcessingResult(generated: false, alreadyCached: true, thumbnailBytes: size)
        }

        let data: Data
        switch file.kind {
        case .image:
            data = try imageThumbnailData(for: file.url)
        case .video:
            data = try await videoThumbnailData(for: file.url)
        }
        try Task.checkCancellation()

        let temporary = vault.appendingPathComponent(".upload-\(UUID().uuidString).tmp")
        try data.write(to: temporary, options: .atomic)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
        } catch {
            try? fileManager.removeItem(at: temporary)
            if !fileManager.fileExists(atPath: destination.path) { throw error }
            let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return ProcessingResult(generated: false, alreadyCached: true, thumbnailBytes: size)
        }
        return ProcessingResult(
            generated: true,
            alreadyCached: false,
            thumbnailBytes: Int64(data.count)
        )
    }

    static func acquireClaim(at claim: URL, workerID: String) throws {
        if fileManager.fileExists(atPath: claim.path) {
            let owner = claim.appendingPathComponent(leaseRecordName)
            if let data = try? Data(contentsOf: owner),
               let record = try? JSONDecoder().decode(VaultLeaseRecord.self, from: data),
               record.expiresAt > Date(),
               record.workerID != workerID {
                throw VaultProcessorError.claimUnavailable
            }
            try? fileManager.removeItem(at: claim)
        }
        do {
            try fileManager.createDirectory(at: claim, withIntermediateDirectories: false)
        } catch {
            throw VaultProcessorError.claimUnavailable
        }
        let record = VaultLeaseRecord(
            workerID: workerID,
            token: UUID().uuidString,
            expiresAt: Date().addingTimeInterval(leaseLifetime)
        )
        try JSONEncoder().encode(record)
            .write(to: claim.appendingPathComponent(leaseRecordName), options: .atomic)
    }

    private static func imageThumbnailData(for url: URL) throws -> Data {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw VaultProcessorError.cannotDecode
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw VaultProcessorError.cannotDecode
        }
        return try jpegData(from: image, quality: 0.82)
    }

    private static func videoThumbnailData(for url: URL) async throws -> Data {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixelSize, height: maxPixelSize)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let duration = try await asset.load(.duration)
        let seconds = duration.seconds.isFinite ? duration.seconds : 0
        let captureTime = CMTime(seconds: min(max(seconds * 0.1, 0), 3), preferredTimescale: 600)
        let image = try await generator.image(at: captureTime).image
        return try jpegData(from: image, quality: 0.82)
    }

    static func jpegData(from image: CGImage, quality: Double) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { throw VaultProcessorError.cannotEncode }
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary
        )
        guard CGImageDestinationFinalize(destination) else {
            throw VaultProcessorError.cannotEncode
        }
        return output as Data
    }

    /// Canonical `.NasFinder-Vault` directories strictly contained within the
    /// selected root, without following symlinks. Two-phase cleanup uses this
    /// list as the determinate total; each entry is re-validated again at
    /// deletion time by `removeVaultDirectory(at:within:)`.
    static func discoverVaultDirectories(in root: URL) throws -> [URL] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        var vaults: [URL] = []
        var seenPaths = Set<String>()

        // 1. Root's direct vault directory if present
        let directVault = canonicalRoot.appendingPathComponent(
            NasFinderVaultCompatibility.directoryName,
            isDirectory: true
        )
        if fileManager.fileExists(atPath: directVault.path) {
            let values = try? directVault.resourceValues(forKeys: keys)
            let canonicalVault = directVault.resolvingSymlinksInPath().standardizedFileURL
            if values?.isDirectory == true,
               values?.isSymbolicLink != true,
               isContained(target: canonicalVault, within: canonicalRoot),
               canonicalVault.lastPathComponent == NasFinderVaultCompatibility.directoryName,
               seenPaths.insert(canonicalVault.path).inserted {
                vaults.append(canonicalVault)
            }
        }

        // 2. Subdirectory vault directories
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return vaults }

        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isDirectory == true else { continue }
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if url.lastPathComponent == NasFinderVaultCompatibility.directoryName {
                enumerator.skipDescendants()
                let canonicalVault = url.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(target: canonicalVault, within: canonicalRoot),
                      canonicalVault.lastPathComponent == NasFinderVaultCompatibility.directoryName,
                      canonicalVault != canonicalRoot,
                      seenPaths.insert(canonicalVault.path).inserted
                else { continue }
                vaults.append(canonicalVault)
            }
        }
        return vaults
    }

    /// Deletes one previously discovered vault directory. Containment and the
    /// `.NasFinder-Vault` name are re-checked on the symlink-resolved path so
    /// a target that moved or was swapped for a link can never delete outside
    /// the root. Returns `false` if the directory already disappeared.
    @discardableResult
    static func removeVaultDirectory(at vault: URL, within root: URL) throws -> Bool {
        guard fileManager.fileExists(atPath: vault.path) else { return false }
        let values = try vault.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw VaultProcessorError.unsafeVaultRemoval
        }
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let canonicalVault = vault.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalVault.lastPathComponent == NasFinderVaultCompatibility.directoryName,
              isContained(target: canonicalVault, within: canonicalRoot)
        else { throw VaultProcessorError.unsafeVaultRemoval }
        try fileManager.removeItem(at: vault.standardizedFileURL)
        return true
    }

    /// Removes only `.NasFinder-Vault` directories strictly contained within
    /// the selected root. Original media files, parent paths, and unrelated
    /// directories are never removed.
    @discardableResult
    static func removeVaultDirectories(in root: URL) throws -> Int {
        var removedCount = 0
        for vault in try discoverVaultDirectories(in: root) {
            try Task.checkCancellation()
            if try removeVaultDirectory(at: vault, within: root) {
                removedCount += 1
            }
        }
        return removedCount
    }

    static func isContained(target: URL, within root: URL) -> Bool {
        let rootPath = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let targetPath = target.path.hasSuffix("/") ? target.path : target.path + "/"
        return targetPath.hasPrefix(rootPath) && targetPath != rootPath
    }

    /// Discovers existing Super Thumbnail files and folder sheets in the vault
    /// without reading or duplicating original media files.
    static func discoverExistingPreviews(
        in root: URL,
        limit: Int = SuperThumbnailPreviewOrdering.defaultLimit
    ) -> [SuperThumbnailMacPreviewItem] {
        let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let keys: Set<URLResourceKey> = [
            .isDirectoryKey,
            .isHiddenKey,
            .isSymbolicLinkKey,
        ]
        guard let enumerator = fileManager.enumerator(
            at: canonicalRoot,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }

        var candidates: [SuperThumbnailPreviewOrdering.Candidate] = []
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: keys)
            if values?.isDirectory == true {
                if values?.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    continue
                }
                if url.lastPathComponent != NasFinderVaultCompatibility.directoryName {
                    if values?.isHidden == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                enumerator.skipDescendants()
                let vaultURL = url
                guard let vaultFiles = try? fileManager.contentsOfDirectory(
                    at: vaultURL,
                    includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                let parentFolder = vaultURL.deletingLastPathComponent()
                for file in vaultFiles where file.pathExtension.lowercased() == "jpg" {
                    let name = file.lastPathComponent
                    let isFolder = name.hasPrefix("v1-folder-")
                    let modDate = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date.distantPast
                    let displayName = isFolder ? parentFolder.lastPathComponent : name
                    candidates.append(SuperThumbnailPreviewOrdering.Candidate(
                        item: SuperThumbnailMacPreviewItem(
                            id: SuperThumbnailPreviewOrdering.canonicalID(for: file),
                            name: displayName,
                            isFolder: isFolder,
                            vaultFileURL: file
                        ),
                        date: modDate
                    ))
                }
            }
        }
        return SuperThumbnailPreviewOrdering.newestFirst(candidates, limit: limit)
    }
}

struct SuperThumbnailMacPreviewItem: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let isFolder: Bool
    let vaultFileURL: URL
}
