import CryptoKit
import Foundation

enum PhotoTransferWireItemKind: String, Codable, CaseIterable, Sendable {
    case photo
    case video
    case livePhoto
    case motionPhoto
}

enum PhotoTransferWireComponentRole: String, Codable, CaseIterable, Sendable {
    case regularFile
    case primaryImage
    case motionVideo
    case motionContainer
}

/// QR 페어링 이후 같은 TCP 연결에서 주고받는 컴포넌트 헤더.
/// 기존 flat 파일과 Live/Motion Photo의 이미지+영상 그룹을 함께 표현한다.
struct PhotoTransferWireHeader: Codable, Equatable, Sendable {
    let id: String?
    let name: String?
    let mimeType: String?
    let mediaKind: String?
    let sourcePlatform: PhotoTransferPeerPlatform?
    let byteLength: UInt64?
    /// v2 grouped-media metadata. All fields are present together or all absent for legacy flat frames.
    let itemId: String?
    let groupId: String?
    let itemKind: PhotoTransferWireItemKind?
    let componentRole: PhotoTransferWireComponentRole?
    let componentIndex: Int?
    let componentCount: Int?
    let sha256: String?
    /// Motion/Live 대표 프레임 시점(마이크로초). 원본에서 확인할 수 없으면 -1.
    let stillImageTimeUs: Int64?
    let done: Bool?

    init(
        id: String,
        name: String,
        mimeType: String,
        mediaKind: String,
        sourcePlatform: PhotoTransferPeerPlatform,
        byteLength: UInt64,
        itemId: String? = nil,
        groupId: String? = nil,
        itemKind: PhotoTransferWireItemKind? = nil,
        componentRole: PhotoTransferWireComponentRole? = nil,
        componentIndex: Int? = nil,
        componentCount: Int? = nil,
        sha256: String? = nil,
        stillImageTimeUs: Int64? = nil
    ) {
        self.id = id
        self.name = name
        self.mimeType = mimeType
        self.mediaKind = mediaKind
        self.sourcePlatform = sourcePlatform
        self.byteLength = byteLength
        self.itemId = itemId
        self.groupId = groupId
        self.itemKind = itemKind
        self.componentRole = componentRole
        self.componentIndex = componentIndex
        self.componentCount = componentCount
        self.sha256 = sha256
        self.stillImageTimeUs = stillImageTimeUs
        self.done = nil
    }

    private init(done: Bool) {
        id = nil
        name = nil
        mimeType = nil
        mediaKind = nil
        sourcePlatform = nil
        byteLength = nil
        itemId = nil
        groupId = nil
        itemKind = nil
        componentRole = nil
        componentIndex = nil
        componentCount = nil
        sha256 = nil
        stillImageTimeUs = nil
        self.done = done
    }

    static let completion = PhotoTransferWireHeader(done: true)

    var isCompletion: Bool {
        done == true
            && id == nil
            && name == nil
            && mimeType == nil
            && mediaKind == nil
            && sourcePlatform == nil
            && byteLength == nil
            && itemId == nil
            && groupId == nil
            && itemKind == nil
            && componentRole == nil
            && componentIndex == nil
            && componentCount == nil
            && sha256 == nil
            && stillImageTimeUs == nil
    }

    var isFile: Bool {
        !isCompletion
            && !(id ?? "").isEmpty
            && !(name ?? "").isEmpty
            && !(mimeType ?? "").isEmpty
            && !(mediaKind ?? "").isEmpty
            && sourcePlatform != nil
            && sourcePlatform != .unknown
            && byteLength != nil
            && hasValidGroupingMetadata
    }

    var isLegacyFlatFile: Bool {
        itemId == nil && groupId == nil && itemKind == nil && componentRole == nil
            && componentIndex == nil && componentCount == nil && sha256 == nil
            && stillImageTimeUs == nil
    }

    var hasValidGroupingMetadata: Bool {
        if isLegacyFlatFile { return true }
        guard let itemId, !itemId.isEmpty,
              let groupId, !groupId.isEmpty,
              let itemKind,
              let componentRole,
              let componentIndex,
              let componentCount,
              componentCount > 0,
              componentIndex >= 0,
              componentIndex < componentCount,
              let sha256,
              Self.isValidSHA256(sha256),
              let stillImageTimeUs,
              stillImageTimeUs >= -1
        else { return false }

        switch itemKind {
        case .photo, .video:
            return componentCount == 1 && componentIndex == 0 && componentRole == .regularFile
        case .livePhoto, .motionPhoto:
            if itemKind == .motionPhoto, componentCount == 1 {
                return componentIndex == 0 && componentRole == .motionContainer
            }
            return componentCount == 2
                && ((componentIndex == 0 && componentRole == .primaryImage)
                    || (componentIndex == 1 && componentRole == .motionVideo))
        }
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    var legacyFlatCopy: PhotoTransferWireHeader? {
        guard let id, let name, let mimeType, let mediaKind,
              let sourcePlatform, let byteLength else { return nil }
        return PhotoTransferWireHeader(
            id: id,
            name: name,
            mimeType: mimeType,
            mediaKind: mediaKind,
            sourcePlatform: sourcePlatform,
            byteLength: byteLength
        )
    }
}

enum PhotoTransferWireCodec {
    static let maximumHeaderLength = 64 * 1024
    static let maximumPayloadLength: UInt64 = 2 * 1024 * 1024 * 1024

    enum CodecError: LocalizedError, Equatable {
        case invalidHeaderLength
        case invalidHeader
        case payloadTooLarge
        case payloadLengthMismatch
        case checksumMismatch
        case incompleteGroup
        case platformMismatch

        var errorDescription: String? {
            switch self {
            case .invalidHeaderLength: "파일 헤더 길이가 올바르지 않습니다."
            case .invalidHeader: "파일 헤더 형식이 올바르지 않습니다."
            case .payloadTooLarge: "파일이 전송 허용 크기를 넘었습니다."
            case .payloadLengthMismatch: "파일 크기와 전송된 데이터 크기가 다릅니다."
            case .checksumMismatch: "받은 파일의 무결성 검증에 실패했습니다."
            case .incompleteGroup: "움직이는 사진의 구성 파일이 완전하지 않습니다."
            case .platformMismatch: "연결된 기기와 파일의 출처 플랫폼이 다릅니다."
            }
        }
    }

    static func headerFrame(_ header: PhotoTransferWireHeader) throws -> Data {
        let json = try JSONEncoder().encode(header)
        guard !json.isEmpty, json.count <= maximumHeaderLength else {
            throw CodecError.invalidHeaderLength
        }
        var length = UInt32(json.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(json)
        return result
    }

    static func fileFrame(header: PhotoTransferWireHeader, payload: Data) throws -> Data {
        guard header.isFile, header.byteLength == UInt64(payload.count) else {
            throw CodecError.payloadLengthMismatch
        }
        guard UInt64(payload.count) <= maximumPayloadLength else {
            throw CodecError.payloadTooLarge
        }
        var result = try headerFrame(header)
        result.append(payload)
        return result
    }

    static func completionFrame() throws -> Data {
        try headerFrame(.completion)
    }
}

/// TCP 청크 경계와 무관하게 프레임을 복원하는 순수 증분 디코더.
struct PhotoTransferWireDecoder {
    enum Event: Equatable {
        case file(PhotoTransferWireHeader, Data)
        case completed
    }

    private var buffer = Data()
    private var pendingHeader: PhotoTransferWireHeader?

    var pendingPayloadByteCount: UInt64 {
        pendingHeader == nil ? 0 : UInt64(buffer.count)
    }

    var pendingPayloadLength: UInt64? {
        pendingHeader?.byteLength
    }

    var pendingFileName: String? {
        pendingHeader?.name
    }

    mutating func append(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []

        while true {
            if pendingHeader == nil {
                guard buffer.count >= MemoryLayout<UInt32>.size else { break }
                let headerLength = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard headerLength > 0,
                      Int(headerLength) <= PhotoTransferWireCodec.maximumHeaderLength
                else {
                    throw PhotoTransferWireCodec.CodecError.invalidHeaderLength
                }
                let frameLength = 4 + Int(headerLength)
                guard buffer.count >= frameLength else { break }
                let headerData = buffer.subdata(in: 4..<frameLength)
                buffer.removeSubrange(0..<frameLength)
                let header: PhotoTransferWireHeader
                do {
                    header = try JSONDecoder().decode(PhotoTransferWireHeader.self, from: headerData)
                } catch {
                    throw PhotoTransferWireCodec.CodecError.invalidHeader
                }
                if header.isCompletion {
                    events.append(.completed)
                    continue
                }
                guard header.done == nil else {
                    throw PhotoTransferWireCodec.CodecError.invalidHeader
                }
                guard header.isFile, let byteLength = header.byteLength else {
                    throw PhotoTransferWireCodec.CodecError.invalidHeader
                }
                guard byteLength <= PhotoTransferWireCodec.maximumPayloadLength,
                      byteLength <= UInt64(Int.max)
                else {
                    throw PhotoTransferWireCodec.CodecError.payloadTooLarge
                }
                pendingHeader = header
            }

            guard let header = pendingHeader, let byteLength = header.byteLength else { continue }
            guard buffer.count >= Int(byteLength) else { break }
            let payload = buffer.prefix(Int(byteLength))
            buffer.removeSubrange(0..<Int(byteLength))
            pendingHeader = nil
            events.append(.file(header, Data(payload)))
        }
        return events
    }
}

/// 실제 수신용 증분 디코더. payload를 임시 파일과 SHA-256에 즉시 흘려 보내므로
/// 큰 영상을 메모리 Data 하나로 보관하지 않는다.
struct PhotoTransferStreamingWireDecoder {
    enum Event {
        case file(PhotoTransferWireHeader, URL)
        case completed
    }

    private var buffer = Data()
    private var pendingHeader: PhotoTransferWireHeader?
    private var pendingURL: URL?
    private var pendingHandle: FileHandle?
    private var pendingHasher: SHA256?
    private var receivedByteCount: UInt64 = 0

    var pendingPayloadByteCount: UInt64 { receivedByteCount }
    var pendingPayloadLength: UInt64? { pendingHeader?.byteLength }
    var pendingFileName: String? { pendingHeader?.name }
    var hasUnconsumedData: Bool { !buffer.isEmpty || pendingHeader != nil }

    mutating func append(_ data: Data) throws -> [Event] {
        buffer.append(data)
        var events: [Event] = []
        while true {
            if pendingHeader == nil {
                guard buffer.count >= 4 else { break }
                let headerLength = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard headerLength > 0, Int(headerLength) <= PhotoTransferWireCodec.maximumHeaderLength else {
                    throw PhotoTransferWireCodec.CodecError.invalidHeaderLength
                }
                let frameLength = 4 + Int(headerLength)
                guard buffer.count >= frameLength else { break }
                let headerData = buffer.subdata(in: 4..<frameLength)
                buffer.removeSubrange(0..<frameLength)
                let header: PhotoTransferWireHeader
                do { header = try JSONDecoder().decode(PhotoTransferWireHeader.self, from: headerData) }
                catch { throw PhotoTransferWireCodec.CodecError.invalidHeader }
                if header.isCompletion {
                    events.append(.completed)
                    continue
                }
                guard header.done == nil, header.isFile, let byteLength = header.byteLength else {
                    throw PhotoTransferWireCodec.CodecError.invalidHeader
                }
                guard byteLength <= PhotoTransferWireCodec.maximumPayloadLength else {
                    throw PhotoTransferWireCodec.CodecError.payloadTooLarge
                }
                let fileExtension = Self.safeExtension(from: header.name)
                let url = PhotoTransferSelectionLoader.temporaryURL(fileExtension: fileExtension)
                FileManager.default.createFile(atPath: url.path, contents: nil)
                pendingHeader = header
                pendingURL = url
                pendingHandle = try FileHandle(forWritingTo: url)
                pendingHasher = SHA256()
                receivedByteCount = 0
            }

            guard let header = pendingHeader, let expected = header.byteLength else { continue }
            if receivedByteCount < expected {
                guard !buffer.isEmpty else { break }
                let count = min(buffer.count, Int(expected - receivedByteCount))
                let chunk = Data(buffer.prefix(count))
                buffer.removeSubrange(0..<count)
                try pendingHandle?.write(contentsOf: chunk)
                pendingHasher?.update(data: chunk)
                receivedByteCount += UInt64(count)
            }
            guard receivedByteCount == expected else { break }
            try pendingHandle?.close()
            guard let url = pendingURL, let hasher = pendingHasher else {
                throw PhotoTransferWireCodec.CodecError.invalidHeader
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            if let expectedHash = header.sha256, digest != expectedHash {
                try? FileManager.default.removeItem(at: url)
                clearPending()
                throw PhotoTransferWireCodec.CodecError.checksumMismatch
            }
            clearPending()
            events.append(.file(header, url))
        }
        return events
    }

    mutating func reset() {
        try? pendingHandle?.close()
        if let pendingURL { try? FileManager.default.removeItem(at: pendingURL) }
        clearPending()
        buffer.removeAll()
    }

    private mutating func clearPending() {
        pendingHeader = nil
        pendingURL = nil
        pendingHandle = nil
        pendingHasher = nil
        receivedByteCount = 0
    }

    private static func safeExtension(from name: String?) -> String {
        let value = URL(fileURLWithPath: name ?? "").pathExtension.lowercased()
        guard (1...10).contains(value.count), value.allSatisfy({ $0.isLetter || $0.isNumber }) else {
            return "bin"
        }
        return value
    }
}
