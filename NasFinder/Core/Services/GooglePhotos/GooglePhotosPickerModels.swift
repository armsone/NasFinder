import Foundation

/// Google Photos Picker API의 proto JSON 표기(RFC3339 타임스탬프, "3.5s" 형식 duration,
/// int64의 문자열 직렬화)를 처리하는 파서 모음.
enum GooglePhotosWireFormat {
    static func parseTimestamp(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func parseDuration(_ string: String) -> TimeInterval? {
        guard string.hasSuffix("s") else { return nil }
        return TimeInterval(string.dropLast())
    }

    static func decodeTimestampIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> Date? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parseTimestamp(raw)
    }

    static func decodeDurationIfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> TimeInterval? {
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return parseDuration(raw)
    }

    /// int64 필드는 JSON에서 숫자 또는 문자열로 올 수 있다.
    static func decodeInt64IfPresent<K: CodingKey>(
        from container: KeyedDecodingContainer<K>, forKey key: K
    ) throws -> Int? {
        if let number = try? container.decodeIfPresent(Int.self, forKey: key) {
            return number
        }
        guard let raw = try container.decodeIfPresent(String.self, forKey: key) else { return nil }
        return Int(raw)
    }
}

struct GooglePhotosPollingConfig: Equatable, Sendable, Decodable {
    let pollInterval: TimeInterval?
    let timeoutIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case pollInterval
        case timeoutIn
    }

    init(pollInterval: TimeInterval?, timeoutIn: TimeInterval?) {
        self.pollInterval = pollInterval
        self.timeoutIn = timeoutIn
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pollInterval = try GooglePhotosWireFormat.decodeDurationIfPresent(from: container, forKey: .pollInterval)
        timeoutIn = try GooglePhotosWireFormat.decodeDurationIfPresent(from: container, forKey: .timeoutIn)
    }
}

struct GooglePhotosPickingConfig: Equatable, Sendable, Decodable {
    let maxItemCount: Int?

    enum CodingKeys: String, CodingKey {
        case maxItemCount
    }

    init(maxItemCount: Int?) {
        self.maxItemCount = maxItemCount
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        maxItemCount = try GooglePhotosWireFormat.decodeInt64IfPresent(from: container, forKey: .maxItemCount)
    }
}

struct GooglePhotosPickingSession: Equatable, Sendable, Decodable {
    let id: String
    let pickerURI: String?
    let pollingConfig: GooglePhotosPollingConfig?
    let expireTime: Date?
    let pickingConfig: GooglePhotosPickingConfig?
    let mediaItemsSet: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case pickerURI = "pickerUri"
        case pollingConfig
        case expireTime
        case pickingConfig
        case mediaItemsSet
    }

    init(
        id: String,
        pickerURI: String?,
        pollingConfig: GooglePhotosPollingConfig?,
        expireTime: Date?,
        pickingConfig: GooglePhotosPickingConfig?,
        mediaItemsSet: Bool
    ) {
        self.id = id
        self.pickerURI = pickerURI
        self.pollingConfig = pollingConfig
        self.expireTime = expireTime
        self.pickingConfig = pickingConfig
        self.mediaItemsSet = mediaItemsSet
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        pickerURI = try container.decodeIfPresent(String.self, forKey: .pickerURI)
        pollingConfig = try container.decodeIfPresent(GooglePhotosPollingConfig.self, forKey: .pollingConfig)
        expireTime = try GooglePhotosWireFormat.decodeTimestampIfPresent(from: container, forKey: .expireTime)
        pickingConfig = try container.decodeIfPresent(GooglePhotosPickingConfig.self, forKey: .pickingConfig)
        mediaItemsSet = try container.decodeIfPresent(Bool.self, forKey: .mediaItemsSet) ?? false
    }
}

enum GooglePhotosMediaType: Equatable, Sendable {
    case photo
    case video
    case unspecified

    init(rawValue: String?) {
        switch rawValue {
        case "PHOTO": self = .photo
        case "VIDEO": self = .video
        default: self = .unspecified
        }
    }
}

enum GooglePhotosVideoProcessingStatus: Equatable, Sendable {
    case processing
    case ready
    case failed
    case unspecified

    init(rawValue: String?) {
        switch rawValue {
        case "PROCESSING": self = .processing
        case "READY": self = .ready
        case "FAILED": self = .failed
        default: self = .unspecified
        }
    }
}

struct GooglePhotosVideoMetadata: Equatable, Sendable, Decodable {
    let fps: Double?
    let processingStatus: GooglePhotosVideoProcessingStatus

    enum CodingKeys: String, CodingKey {
        case fps
        case processingStatus
    }

    init(fps: Double?, processingStatus: GooglePhotosVideoProcessingStatus) {
        self.fps = fps
        self.processingStatus = processingStatus
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        fps = try container.decodeIfPresent(Double.self, forKey: .fps)
        processingStatus = GooglePhotosVideoProcessingStatus(
            rawValue: try container.decodeIfPresent(String.self, forKey: .processingStatus)
        )
    }
}

struct GooglePhotosMediaFileMetadata: Equatable, Sendable, Decodable {
    let width: Int?
    let height: Int?
    let videoMetadata: GooglePhotosVideoMetadata?

    enum CodingKeys: String, CodingKey {
        case width
        case height
        case videoMetadata
    }

    init(width: Int?, height: Int?, videoMetadata: GooglePhotosVideoMetadata?) {
        self.width = width
        self.height = height
        self.videoMetadata = videoMetadata
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        width = try GooglePhotosWireFormat.decodeInt64IfPresent(from: container, forKey: .width)
        height = try GooglePhotosWireFormat.decodeInt64IfPresent(from: container, forKey: .height)
        videoMetadata = try container.decodeIfPresent(GooglePhotosVideoMetadata.self, forKey: .videoMetadata)
    }
}

struct GooglePhotosMediaFile: Equatable, Sendable, Decodable {
    let baseURL: String
    let mimeType: String?
    let filename: String?
    let metadata: GooglePhotosMediaFileMetadata?

    enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case mimeType
        case filename
        case metadata = "mediaFileMetadata"
    }

    init(baseURL: String, mimeType: String?, filename: String?, metadata: GooglePhotosMediaFileMetadata?) {
        self.baseURL = baseURL
        self.mimeType = mimeType
        self.filename = filename
        self.metadata = metadata
    }
}

struct GooglePhotosPickedMediaItem: Equatable, Sendable, Decodable {
    let id: String
    let createTime: Date?
    let type: GooglePhotosMediaType
    let mediaFile: GooglePhotosMediaFile?

    enum CodingKeys: String, CodingKey {
        case id
        case createTime
        case type
        case mediaFile
    }

    init(id: String, createTime: Date?, type: GooglePhotosMediaType, mediaFile: GooglePhotosMediaFile?) {
        self.id = id
        self.createTime = createTime
        self.type = type
        self.mediaFile = mediaFile
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        createTime = try GooglePhotosWireFormat.decodeTimestampIfPresent(from: container, forKey: .createTime)
        type = GooglePhotosMediaType(rawValue: try container.decodeIfPresent(String.self, forKey: .type))
        mediaFile = try container.decodeIfPresent(GooglePhotosMediaFile.self, forKey: .mediaFile)
    }
}

struct GooglePhotosMediaItemsPage: Equatable, Sendable, Decodable {
    let mediaItems: [GooglePhotosPickedMediaItem]
    let nextPageToken: String?

    enum CodingKeys: String, CodingKey {
        case mediaItems
        case nextPageToken
    }

    init(mediaItems: [GooglePhotosPickedMediaItem], nextPageToken: String?) {
        self.mediaItems = mediaItems
        self.nextPageToken = nextPageToken
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mediaItems = try container.decodeIfPresent([GooglePhotosPickedMediaItem].self, forKey: .mediaItems) ?? []
        nextPageToken = try container.decodeIfPresent(String.self, forKey: .nextPageToken)
    }
}

/// Picker baseUrl에 다운로드 파라미터(사진 `=d`, 동영상 `=dv`)를 안전하게 붙인다.
/// 실제 요청 시에는 Bearer 토큰이 함께 필요하다.
enum GooglePhotosContentURLBuilder {
    static func downloadURL(baseURL rawBaseURL: String, type: GooglePhotosMediaType) throws -> URL {
        var base = rawBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { throw GooglePhotosPickerError.invalidContentURL }
        // 이미 붙어 있는 다운로드 파라미터는 제거한 뒤 올바른 접미사를 붙인다.
        if base.hasSuffix("=dv") {
            base = String(base.dropLast(3))
        } else if base.hasSuffix("=d") {
            base = String(base.dropLast(2))
        }
        let suffix = type == .video ? "=dv" : "=d"
        guard let url = URL(string: base + suffix), url.scheme == "https" else {
            throw GooglePhotosPickerError.invalidContentURL
        }
        return url
    }

    static func downloadURL(for item: GooglePhotosPickedMediaItem) throws -> URL {
        guard let mediaFile = item.mediaFile else {
            throw GooglePhotosPickerError.invalidContentURL
        }
        return try downloadURL(baseURL: mediaFile.baseURL, type: item.type)
    }
}
