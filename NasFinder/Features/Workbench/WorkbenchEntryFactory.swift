import Foundation
import Photos
import UniformTypeIdentifiers

/// 각 담기 경로가 같은 방식으로 참조 항목을 만들게 하는 공통 도우미.
/// 여기서 만든 항목은 원본 바이트를 읽거나 복사하지 않는다(북마크·식별자·경로만 기록).
enum WorkbenchSourceLabel {
    static let nas = "NAS·클라우드"
    static let phoneHard = "폰하드"
    static let deviceFiles = "기기 파일"
    static let media = "내 미디어"
    static let googlePhotos = "Google 포토"
    static let shared = "공유로 받음"

    /// 연결 ID만으로 알 수 있는 출처 이름. 기기 폴더 여부는 호출한 화면이 알 때 직접 넘긴다.
    static func forConnection(_ id: UUID) -> String {
        id == LocalInboxFileService.connectionID ? phoneHard : nas
    }
}

enum WorkbenchEntryFactory {
    enum FactoryError: LocalizedError {
        case bookmarkUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .bookmarkUnavailable(let name):
                "\(name): 이 파일을 나중에 다시 열 수 있는 연결(북마크)을 만들 수 없어 담지 않았습니다. 파일을 폰하드나 NAS에 두고 거기서 담아 주세요."
            }
        }
    }

    // MARK: 연결(NAS·클라우드·폰하드·기기 폴더)

    static func entry(remote item: RemoteFileItem, sourceLabel: String? = nil) -> WorkbenchEntry {
        let media: WorkbenchMediaKind = item.isDirectory ? .folder : item.isVideo ? .video : item.isImage ? .photo : .other
        var entry = WorkbenchEntry(
            kind: .remote, mediaKind: media, name: item.name,
            sourceLabel: sourceLabel ?? WorkbenchSourceLabel.forConnection(item.connectionID),
            byteCount: item.size, modifiedAt: item.modifiedAt)
        entry.connectionID = item.connectionID
        entry.path = item.path
        entry.remoteIdentifier = item.remoteIdentifier
        entry.contentTypeIdentifier = item.contentTypeIdentifier
        return entry
    }

    // MARK: 사진 보관함

    static func entry(assetIdentifier: String, name: String, isVideo: Bool, modifiedAt: Date? = nil) -> WorkbenchEntry {
        var entry = WorkbenchEntry(
            kind: .photoAsset, mediaKind: isVideo ? .video : .photo, name: name,
            sourceLabel: WorkbenchSourceLabel.media, modifiedAt: modifiedAt)
        entry.assetIdentifier = assetIdentifier
        return entry
    }

    static func entry(asset: PHAsset, name: String? = nil) -> WorkbenchEntry {
        let isVideo = asset.mediaType == .video
        let fallback = isVideo ? "영상" : "사진"
        return entry(assetIdentifier: asset.localIdentifier,
                     name: name ?? LocalPhotoLibraryCalendarService.originalFilename(for: asset) ?? fallback,
                     isVideo: isVideo, modifiedAt: asset.creationDate)
    }

    // MARK: 파일·폴더 (보안 범위 북마크)

    #if targetEnvironment(macCatalyst)
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions { [.withSecurityScope] }
    #else
    private static var bookmarkCreationOptions: URL.BookmarkCreationOptions { [] }
    #endif

    /// 사용자가 고른 파일·폴더의 북마크 항목. 보안 범위 접근은 이 함수 안에서 열고 닫아 짝이 맞는다.
    /// 북마크를 만들 수 없으면 몰래 복사하지 않고 실패를 돌려준다.
    static func entry(fileURL url: URL, sourceLabel: String = WorkbenchSourceLabel.deviceFiles) -> Result<WorkbenchEntry, FactoryError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? url.bookmarkData(options: bookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return .failure(.bookmarkUnavailable(url.lastPathComponent))
        }
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        let media: WorkbenchMediaKind
        if values?.isDirectory == true { media = .folder }
        else if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { media = .video }
        else if type?.conforms(to: .image) == true { media = .photo }
        else { media = .other }
        var entry = WorkbenchEntry(
            kind: .fileBookmark, mediaKind: media, name: url.lastPathComponent, sourceLabel: sourceLabel,
            byteCount: values?.fileSize.map(Int64.init), modifiedAt: values?.contentModificationDate)
        entry.bookmarkData = data
        entry.fileKey = url.standardizedFileURL.path
        entry.contentTypeIdentifier = type?.identifier
        return .success(entry)
    }

    // MARK: Google 포토 (Picker 항목 ID + 세션 참조)

    /// 다운로드 없이 Picker가 돌려준 메타데이터만 기록한다. baseUrl·토큰은 기록하지 않는다(baseUrl은 약 60분 유효).
    static func entry(google item: GooglePhotosPickedMediaItem, sessionID: String, sessionExpiresAt: Date?) -> WorkbenchEntry {
        let media: WorkbenchMediaKind = switch item.type {
        case .photo: .photo
        case .video: .video
        case .unspecified: .other
        }
        var entry = WorkbenchEntry(
            kind: .googlePhoto, mediaKind: media, name: item.mediaFile?.filename ?? "Google 포토 항목",
            sourceLabel: WorkbenchSourceLabel.googlePhotos, modifiedAt: item.createTime)
        entry.googleItemID = item.id
        entry.googleSessionID = sessionID
        entry.googleSessionExpiresAt = sessionExpiresAt
        entry.contentTypeIdentifier = item.mediaFile?.mimeType.flatMap { UTType(mimeType: $0)?.identifier }
        return entry
    }

    // MARK: 공유로 받은 항목

    static func entry(stagedBatch batchID: UUID, item: ShareIntentItem) -> WorkbenchEntry {
        var entry = WorkbenchEntry(
            kind: .sharedStaging, mediaKind: item.isVideo ? .video : .photo, name: item.originalFilename,
            sourceLabel: WorkbenchSourceLabel.shared, byteCount: item.byteCount)
        entry.stagedBatchID = batchID
        entry.stagedItemID = item.id
        entry.contentTypeIdentifier = item.contentTypeIdentifier
        return entry
    }
}
