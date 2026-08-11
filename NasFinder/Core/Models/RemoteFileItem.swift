import Foundation
import UniformTypeIdentifiers

struct RemoteFileItem: Identifiable, Hashable, Sendable {
    private static let imageFilenameExtensions: Set<String> = [
        "avif", "arw", "bmp", "cr2", "cr3", "dng", "gif", "heic", "heif",
        "ico", "jpe", "jpeg", "jpg", "nef", "orf", "png", "raf", "raw",
        "rw2", "tif", "tiff", "webp"
    ]
    private static let videoFilenameExtensions: Set<String> = [
        "3g2", "3gp", "asf", "avi", "flv", "m2ts", "m4v", "mkv", "mov", "mpe",
        "mpeg", "mpg", "mp4", "mts", "ogv", "qt", "ts", "vob", "webm", "wmv"
    ]
    private static let quickLookThumbnailFilenameExtensions: Set<String> = [
        "csv", "doc", "docx", "epub", "htm", "html", "key", "markdown", "md",
        "numbers", "pages", "pdf", "ppt", "pptx", "rtf", "rtfd", "txt", "usdz",
        "xls", "xlsx"
    ]

    enum ItemKind: String, Sendable {
        case folder
        case file
    }

    let connectionID: UUID
    let path: String
    let name: String
    let kind: ItemKind
    let size: Int64?
    let modifiedAt: Date?
    let contentTypeIdentifier: String?

    var id: String { "\(connectionID.uuidString):\(path)" }
    var isDirectory: Bool { kind == .folder }

    var contentType: UTType {
        if let contentTypeIdentifier,
           let type = UTType(contentTypeIdentifier) {
            return type
        }
        if let type = UTType(filenameExtension: (name as NSString).pathExtension) {
            return type
        }
        return isDirectory ? .folder : .data
    }

    var isImage: Bool {
        !isDirectory && (
            contentType.conforms(to: .image)
                || Self.imageFilenameExtensions.contains(normalizedFilenameExtension)
        )
    }

    var isVideo: Bool {
        !isDirectory && (
            contentType.conforms(to: .movie)
                || contentType.conforms(to: .video)
                || Self.videoFilenameExtensions.contains(normalizedFilenameExtension)
        )
    }

    /// File types for which iOS Quick Look can commonly create a meaningful
    /// preview after the remote file has been cached locally.
    var supportsQuickLookThumbnail: Bool {
        guard !isDirectory else { return false }
        return isImage
            || isVideo
            || contentType.conforms(to: .pdf)
            || contentType.conforms(to: .text)
            || contentType.conforms(to: .audio)
            || Self.quickLookThumbnailFilenameExtensions.contains(normalizedFilenameExtension)
    }

    var systemImage: String {
        if isDirectory { return "folder.fill" }
        if isImage { return "photo.fill" }
        if isVideo { return "play.rectangle.fill" }
        if contentType.conforms(to: .audio) { return "waveform" }
        if contentType.conforms(to: .pdf) { return "doc.richtext.fill" }
        if contentType.conforms(to: .archive) { return "archivebox.fill" }
        return "doc.fill"
    }

    private var normalizedFilenameExtension: String {
        (name as NSString).pathExtension.lowercased()
    }
}
