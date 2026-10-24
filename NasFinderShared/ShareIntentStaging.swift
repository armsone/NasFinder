import Foundation

/// 공유 시트에서 사용자가 고른 목적. 폰하드 저장은 기존 `SharedInbox` 흐름이 그대로 맡는다.
public enum ShareIntent: String, Codable, Sendable {
    case photoSelect
    case makeVideo
}

public struct ShareIntentItem: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let originalFilename: String
    /// 배치 폴더 안의 파일 이름(하위 경로 없음).
    public let storedFilename: String
    public let contentTypeIdentifier: String?
    public let byteCount: Int64
    public let isVideo: Bool
    /// 앱이 마지막으로 처리하지 못한 사유. 성공한 항목은 목록에서 사라지므로 남아 있다면 재시도 대기 항목이다.
    public var lastError: String?

    public init(id: UUID, originalFilename: String, storedFilename: String, contentTypeIdentifier: String?,
                byteCount: Int64, isVideo: Bool, lastError: String? = nil) {
        self.id = id
        self.originalFilename = originalFilename
        self.storedFilename = storedFilename
        self.contentTypeIdentifier = contentTypeIdentifier
        self.byteCount = byteCount
        self.isVideo = isVideo
        self.lastError = lastError
    }
}

public struct ShareIntentBatch: Codable, Sendable, Identifiable, Hashable {
    public let id: UUID
    public let intent: ShareIntent
    public let createdAt: Date
    /// 받은 순서를 그대로 유지한다.
    public var items: [ShareIntentItem]
    /// 확장이 읽지 못해 건너뛴 항목의 사유(파일명 포함). 숨기지 않고 앱에서도 보여 준다.
    public var skippedReasons: [String]

    public init(id: UUID, intent: ShareIntent, createdAt: Date, items: [ShareIntentItem], skippedReasons: [String] = []) {
        self.id = id
        self.intent = intent
        self.createdAt = createdAt
        self.items = items
        self.skippedReasons = skippedReasons
    }
}

/// 공유 확장이 App Group 안에 임시로 복사해 둔 입력과 매니페스트.
/// - 배치는 `commit` 전까지 앱에 보이지 않는다(매니페스트가 원자적으로 생길 때만 유효).
/// - 확장은 자기 배치의 커밋 전 파일만 지운다. 앱이 처리에 성공한 항목만 `markConsumed`로 지우고,
///   실패한 항목은 사유와 함께 남겨 다시 시도할 수 있다.
public enum ShareIntentStaging {
    public static let directoryName = "ShareIntents"
    private static let manifestName = "batch.json"
    private static let filesDirectoryName = "files"
    /// 커밋 없이 남은 폴더(확장 비정상 종료)를 앱이 정리하기까지의 유예.
    private static let uncommittedGrace: TimeInterval = 24 * 60 * 60
    private static let lock = NSLock()

    public enum StagingError: LocalizedError, Sendable {
        case appGroupUnavailable
        case unsafeSource
        case unsupportedType
        case emptySource
        case invalidBatch

        public var errorDescription: String? {
            switch self {
            case .appGroupUnavailable: "NasFinder App Group 저장소를 열 수 없습니다."
            case .unsafeSource: "일반 파일이 아닌 공유 항목은 가져올 수 없습니다."
            case .unsupportedType: "사진이나 영상이 아닌 형식이라 가져오지 않았습니다."
            case .emptySource: "내용이 없는 파일입니다."
            case .invalidBatch: "공유 대기 정보가 올바르지 않습니다."
            }
        }
    }

    // MARK: 확장 쪽

    public static func createBatch(intent: ShareIntent) throws -> UUID {
        let id = UUID()
        try FileManager.default.createDirectory(at: filesURL(batchID: id), withIntermediateDirectories: true)
        return id
    }

    /// 보안 범위 접근은 호출자가 start/stop 한다. 일반 파일만 복사하고 심볼릭 링크·폴더는 거부한다.
    public static func stage(
        fileAt source: URL,
        originalFilename: String,
        contentTypeIdentifier: String?,
        isVideo: Bool,
        intoBatch batchID: UUID
    ) throws -> ShareIntentItem {
        let values = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else { throw StagingError.unsafeSource }
        guard (values.fileSize ?? 0) > 0 else { throw StagingError.emptySource }
        let directory = try filesURL(batchID: batchID)
        let itemID = UUID()
        let safeName = sanitizedFilename(originalFilename, fallback: source.lastPathComponent)
        let stored = "\(itemID.uuidString)-\(safeName)"
        let destination = directory.appendingPathComponent(stored, isDirectory: false)
        try FileManager.default.copyItem(at: source, to: destination)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map(Int64.init) ?? Int64(values.fileSize ?? 0)
        return ShareIntentItem(id: itemID, originalFilename: safeName, storedFilename: stored,
                               contentTypeIdentifier: contentTypeIdentifier, byteCount: size, isVideo: isVideo)
    }

    /// 배치를 앱이 볼 수 있게 확정한다. 매니페스트는 원자적으로 쓴다.
    public static func commit(_ batch: ShareIntentBatch) throws {
        try withLock { try writeManifest(batch) }
    }

    /// 확장 취소/실패 때 아직 커밋하지 않은 자기 배치를 지운다. 커밋된 배치는 건드리지 않는다.
    public static func discardUncommitted(batchID: UUID) {
        withLock {
            guard let root = try? batchURL(batchID: batchID),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(manifestName).path) else { return }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: 앱 쪽

    /// 아직 처리하지 못한 배치를 오래된 순으로. 커밋 없이 오래 남은 폴더는 여기서 정리한다.
    public static func pendingBatches() -> [ShareIntentBatch] {
        withLock {
            guard let root = try? rootURL(),
                  let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
            var result: [ShareIntentBatch] = []
            for name in names {
                guard let id = UUID(uuidString: name) else { continue }
                let directory = root.appendingPathComponent(name, isDirectory: true)
                let manifest = directory.appendingPathComponent(manifestName)
                if let data = try? Data(contentsOf: manifest),
                   let batch = try? decoder.decode(ShareIntentBatch.self, from: data), batch.id == id {
                    result.append(batch)
                } else if !FileManager.default.fileExists(atPath: manifest.path) {
                    let modified = (try? directory.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if let modified, Date().timeIntervalSince(modified) > uncommittedGrace {
                        try? FileManager.default.removeItem(at: directory)
                    }
                }
            }
            return result.sorted { $0.createdAt < $1.createdAt }
        }
    }

    public static func batch(id: UUID) -> ShareIntentBatch? {
        pendingBatches().first { $0.id == id }
    }

    public static func fileURL(batchID: UUID, item: ShareIntentItem) throws -> URL {
        let directory = try filesURL(batchID: batchID)
        guard item.storedFilename == (item.storedFilename as NSString).lastPathComponent,
              !item.storedFilename.isEmpty, item.storedFilename != ".", item.storedFilename != ".." else {
            throw StagingError.invalidBatch
        }
        return directory.appendingPathComponent(item.storedFilename, isDirectory: false)
    }

    /// 성공적으로 넘긴 항목만 지운다. 남은 항목이 없으면 배치 전체를 지운다. 실패한 항목은 그대로 남는다.
    public static func markConsumed(batchID: UUID, itemIDs: Set<UUID>) throws {
        try withLock {
            guard var batch = try readManifest(batchID: batchID) else { return }
            for item in batch.items where itemIDs.contains(item.id) {
                if let url = try? fileURL(batchID: batchID, item: item) { try? FileManager.default.removeItem(at: url) }
            }
            batch.items.removeAll { itemIDs.contains($0.id) }
            if batch.items.isEmpty {
                try? FileManager.default.removeItem(at: batchURL(batchID: batchID))
            } else {
                try writeManifest(batch)
            }
        }
    }

    /// 처리 실패 사유를 항목에 남긴다. 파일은 지우지 않는다.
    public static func recordFailures(batchID: UUID, reasons: [UUID: String]) throws {
        try withLock {
            guard var batch = try readManifest(batchID: batchID) else { return }
            for index in batch.items.indices {
                if let reason = reasons[batch.items[index].id] { batch.items[index].lastError = reason }
            }
            try writeManifest(batch)
        }
    }

    /// 사용자가 대기 배치를 명시적으로 버릴 때만 쓴다.
    public static func discardBatch(batchID: UUID) {
        withLock {
            if let url = try? batchURL(batchID: batchID) { try? FileManager.default.removeItem(at: url) }
        }
    }

    // MARK: 내부

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func rootURL() throws -> URL {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: SharedInbox.appGroupIdentifier) else {
            throw StagingError.appGroupUnavailable
        }
        let root = container.appendingPathComponent(directoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private static func batchURL(batchID: UUID) throws -> URL {
        try rootURL().appendingPathComponent(batchID.uuidString, isDirectory: true)
    }

    private static func filesURL(batchID: UUID) throws -> URL {
        try batchURL(batchID: batchID).appendingPathComponent(filesDirectoryName, isDirectory: true)
    }

    private static func readManifest(batchID: UUID) throws -> ShareIntentBatch? {
        let url = try batchURL(batchID: batchID).appendingPathComponent(manifestName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let batch = try decoder.decode(ShareIntentBatch.self, from: data)
        guard batch.id == batchID else { throw StagingError.invalidBatch }
        return batch
    }

    private static func writeManifest(_ batch: ShareIntentBatch) throws {
        let url = try batchURL(batchID: batch.id).appendingPathComponent(manifestName)
        try encoder.encode(batch).write(to: url, options: [.atomic])
    }

    private static func sanitizedFilename(_ proposed: String, fallback: String) -> String {
        var leaf = (proposed as NSString).lastPathComponent
        if leaf.isEmpty || leaf == "." || leaf == ".." { leaf = (fallback as NSString).lastPathComponent }
        if leaf.isEmpty || leaf == "." || leaf == ".." { leaf = "shared-file" }
        return String(leaf.replacingOccurrences(of: "/", with: "_").prefix(180))
    }

    @discardableResult
    private static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
