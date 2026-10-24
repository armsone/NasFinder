import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

private struct LocalPhotoLibraryImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let destination = LocalPhotoLibrarySelectionLoader.temporaryURL(
                fileExtension: received.file.pathExtension
            )
            try FileManager.default.copyItem(at: received.file, to: destination)
            return Self(url: destination)
        }
    }
}

/// Loads PhotosPicker selections through the picker's own sandboxed item provider only.
/// This deliberately avoids every PhotoKit asset API (PHAsset, PHAssetResource) so the
/// app never requests, and never needs, photo-library access beyond the user's picker choice.
enum LocalPhotoLibrarySelectionLoader {
    enum LoadingError: LocalizedError {
        case dataUnavailable

        var errorDescription: String? {
            "사진 또는 영상을 불러오지 못했습니다. iCloud에서 내려받지 못했을 수 있습니다."
        }
    }

    struct LoadedMedia {
        let url: URL
        let contentType: UTType?
        let isVideo: Bool
    }

    @MainActor
    static func load(item: PhotosPickerItem) async throws -> LoadedMedia {
        let types = item.supportedContentTypes
        let isVideo = types.contains { $0.conforms(to: .movie) || $0.conforms(to: .video) }
        let contentType = isVideo
            ? types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .video) })
            : types.first(where: { $0.conforms(to: .image) }) ?? types.first

        if let imported = try? await item.loadTransferable(type: LocalPhotoLibraryImportedFile.self) {
            return LoadedMedia(url: imported.url, contentType: contentType, isVideo: isVideo)
        }
        guard let data = try await item.loadTransferable(type: Data.self) else {
            throw LoadingError.dataUnavailable
        }
        let fileExtension = contentType?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
        let url = temporaryURL(fileExtension: fileExtension)
        try data.write(to: url, options: [.atomic])
        return LoadedMedia(url: url, contentType: contentType, isVideo: isVideo)
    }

    /// 선택만 해 둔 항목을 이제서야 앱 소유 임시 사본으로 가져온다(영상 제작·미리보기·폰하드 복사를 시작할 때만).
    /// 원본(연결·북마크한 파일)은 읽기만 하며, 만든 임시 사본은 호출한 선택 세션이 지운다.
    static func materialize(_ source: LocalPhotoDeferredSource, name: String) async throws -> URL {
        let destination = temporaryURL(fileExtension: URL(fileURLWithPath: name).pathExtension)
        switch source {
        case .remote(let item, let service):
            let downloaded = try await service.download(item)
            try await Task.detached(priority: .utility) { try copyCoordinated(from: downloaded, to: destination) }.value
        case .bookmark(let data):
            let root = try WorkbenchBookmark.resolve(data)
            let scoped = root.startAccessingSecurityScopedResource()
            defer { if scoped { root.stopAccessingSecurityScopedResource() } }
            guard FileManager.default.fileExists(atPath: root.path) else {
                throw WorkbenchFailure.relink("파일을 찾을 수 없습니다. 옮겨지거나 지워졌을 수 있어 같은 파일을 다시 담아 주세요.")
            }
            try await Task.detached(priority: .utility) { try copyCoordinated(from: root, to: destination) }.value
        }
        return destination
    }

    private static func copyCoordinated(from source: URL, to destination: URL) throws {
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { readURL in
            do { try FileManager.default.copyItem(at: readURL, to: destination) } catch { copyError = error }
        }
        if let coordinationError { throw coordinationError }
        if let copyError { throw copyError }
    }

    static func temporaryURL(fileExtension: String) -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("nasfinder-library-\(UUID().uuidString)\(suffix)", isDirectory: false)
    }
}
