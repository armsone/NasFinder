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

    static func temporaryURL(fileExtension: String) -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("nasfinder-library-\(UUID().uuidString)\(suffix)", isDirectory: false)
    }
}
