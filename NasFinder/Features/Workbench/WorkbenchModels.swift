import Foundation

/// 작업대 항목이 가리키는 출처 종류. rawValue는 저장 키라 이름만 바꾸려고 바꾸지 않는다.
enum WorkbenchSourceKind: String, Codable, Sendable {
    /// 저장된 연결(NAS·클라우드·폰하드·기기 폴더)의 파일 또는 폴더. 연결 ID + 경로로만 가리킨다.
    case remote
    /// 사진 보관함 항목. PhotoKit 안정 식별자만 담는다.
    case photoAsset
    /// 파일 앱 등에서 고른 파일·폴더. 보안 범위 북마크만 담고 파일 내용은 담지 않는다.
    case fileBookmark
    /// Google 포토 Picker 항목. 영속 항목 ID와 세션 참조·만료 시각만 담는다.
    case googlePhoto
    /// 공유 확장이 앱 그룹에 이미 둔 항목(batch/item ID).
    case sharedStaging
    /// 예전 영상 재료함이 앱 안에 이미 가진 복사본. 새로 복사하지 않고 그 자리에서 읽기만 한다.
    case legacyCopy
}

enum WorkbenchMediaKind: String, Codable, Sendable {
    case photo
    case video
    case folder
    /// 사진·영상이 아닌 파일. 담을 수는 있지만 영상 제작·미디어 전송에는 쓸 수 없다.
    case other

    var title: String {
        switch self {
        case .photo: "사진"
        case .video: "영상"
        case .folder: "폴더"
        case .other: "기타 파일"
        }
    }

    var systemImage: String {
        switch self {
        case .photo: "photo"
        case .video: "play.rectangle"
        case .folder: "folder"
        case .other: "doc"
        }
    }

    var isMedia: Bool { self == .photo || self == .video }
}

/// 포켓 안의 참조 하나. 원본 바이트·다운로드 파일·세션 토큰·비밀번호는 담지 않는다.
/// 같은 원본을 여러 포켓이 각자의 항목(`id`)으로 참조할 수 있다.
struct WorkbenchEntry: Codable, Identifiable, Equatable, Sendable {
    /// 포켓 안에서 이 참조를 가리키는 고유 ID. 같은 원본을 다른 포켓에 담으면 포켓마다 새 ID가 생긴다.
    var id: UUID
    var kind: WorkbenchSourceKind
    var mediaKind: WorkbenchMediaKind
    var name: String
    /// 화면에 보이는 출처 이름(NAS·클라우드, 폰하드, 내 미디어 …).
    var sourceLabel: String
    var byteCount: Int64?
    var modifiedAt: Date?
    let addedAt: Date

    // remote
    var connectionID: UUID?
    var path: String?
    var remoteIdentifier: String?
    var contentTypeIdentifier: String?

    // photoAsset
    var assetIdentifier: String?

    // fileBookmark (fileKey는 고른 순간의 경로로, 같은 포켓 안 중복을 가리는 용도로만 쓴다)
    var bookmarkData: Data?
    var fileKey: String?

    // googlePhoto
    var googleItemID: String?
    var googleSessionID: String?
    var googleSessionExpiresAt: Date?

    // sharedStaging
    var stagedBatchID: UUID?
    var stagedItemID: UUID?

    // legacyCopy (원격 출처가 있는 옛 항목은 remote 필드와 함께 복사본 파일명을 둔다)
    var legacyFilename: String?
    /// Live/Motion 전송 대기 복사본의 짝 영상 파일. 있으면 이미지+영상을 한 묶음으로 보낸다.
    var legacyCompanionFilename: String?

    /// nil이 아니면 '다시 연결'이 필요한 상태. 항목은 자동으로 지워지지 않는다.
    var relinkReason: String?

    /// 항목 자신의 비공개 플래그(nil = 공개, 예전 데이터와 같다). 공개 포켓에 프라이버시 모드에서 새로 담은 항목이
    /// 조용히 공개되지 않게 하고, 포켓 전체를 숨기지도 않는다. 실제 비공개 여부는 자기 플래그 OR 포켓 OR 출처다.
    var isPrivate: Bool?

    init(id: UUID = UUID(), kind: WorkbenchSourceKind, mediaKind: WorkbenchMediaKind, name: String,
         sourceLabel: String, byteCount: Int64? = nil, modifiedAt: Date? = nil, addedAt: Date = Date()) {
        self.id = id
        self.kind = kind
        self.mediaKind = mediaKind
        self.name = name
        self.sourceLabel = sourceLabel
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
        self.addedAt = addedAt
    }

    /// 출처 안에서의 안정 식별자. 파일 이름·해시로 다른 출처의 같은 파일을 추정하지 않는다.
    var identity: String {
        switch kind {
        case .remote:
            "remote:\(connectionID?.uuidString ?? "-"):\(remoteIdentifier ?? path ?? "-")"
        case .photoAsset:
            "asset:\(assetIdentifier ?? "-")"
        case .fileBookmark:
            "file:\(fileKey ?? id.uuidString)"
        case .googlePhoto:
            "google:\(googleItemID ?? "-")"
        case .sharedStaging:
            "staged:\(stagedBatchID?.uuidString ?? "-"):\(stagedItemID?.uuidString ?? "-")"
        case .legacyCopy:
            "legacy:\(id.uuidString)"
        }
    }

    var isFolder: Bool { mediaKind == .folder }

    /// 이 항목의 출처(비공개 연결, 비공개 폰하드 경로)가 일반 모드에서 숨겨져야 하는지.
    var hasPrivateOrigin: Bool {
        guard let connectionID else { return false }
        return PrivacyMode.isPrivateOrigin(connectionID: connectionID, path: path)
    }

    /// 자기 플래그 또는 출처가 비공개인 항목(포켓 플래그는 포켓이 따로 가린다).
    var isEffectivelyPrivate: Bool { isPrivate == true || hasPrivateOrigin }

    /// 지금 모드에서 보이는 항목인지(프라이버시 모드에서는 항상 보인다).
    var isVisibleNow: Bool { PrivacyMode.currentlyActive || !isEffectivelyPrivate }
}

struct WorkbenchPocket: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
    var entries: [WorkbenchEntry]
    /// 비공개 포켓(nil = 공개, 예전 데이터와 같다). 포켓의 공개 범위가 안의 모든 항목에 적용된다.
    var isPrivate: Bool?

    init(id: UUID = UUID(), name: String, createdAt: Date = Date(), entries: [WorkbenchEntry] = [], isPrivate: Bool? = nil) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.entries = entries
        self.isPrivate = isPrivate == true ? true : nil
    }
}

/// 디스크에 한 파일로 원자적으로 기록되는 작업대 전체 상태.
/// 나중에 필드가 늘어도 이전 기록을 읽을 수 있도록 없는 필드는 기본값으로 읽는다(있는데 깨진 필드는 오류로 남긴다).
struct WorkbenchDocument: Codable, Equatable, Sendable {
    var version = 1
    var pockets: [WorkbenchPocket] = []
    /// 예전 영상 재료 메타데이터를 '기존 재료' 포켓으로 옮겼는지.
    var legacyBridgeDone = false
    /// 2.24.4 복사 기반 전송 대기 목록(PhotoTransferPending)을 '기존 전송 대기' 포켓으로 옮겼는지.
    var legacyTransferBridgeDone = false

    init() {}

    private enum CodingKeys: String, CodingKey {
        case version, pockets, legacyBridgeDone, legacyTransferBridgeDone
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        pockets = try container.decodeIfPresent([WorkbenchPocket].self, forKey: .pockets) ?? []
        legacyBridgeDone = try container.decodeIfPresent(Bool.self, forKey: .legacyBridgeDone) ?? false
        legacyTransferBridgeDone = try container.decodeIfPresent(Bool.self, forKey: .legacyTransferBridgeDone) ?? false
    }
}

/// 담기 결과 요약. 호출한 화면이 그대로 사용자에게 보여 준다.
struct WorkbenchAddOutcome: Equatable {
    var added = 0
    var duplicates = 0
    var relinked = 0
    var failureMessage: String?

    var summary: String {
        if let failureMessage { return failureMessage }
        var parts: [String] = []
        if added > 0 { parts.append("\(added)개를 담았습니다.") }
        if relinked > 0 { parts.append("이미 있던 \(relinked)개는 다시 연결했습니다.") }
        if duplicates > 0 { parts.append("이미 담긴 \(duplicates)개는 건너뛰었습니다.") }
        return parts.isEmpty ? "담을 항목이 없습니다." : parts.joined(separator: " ")
    }
}
