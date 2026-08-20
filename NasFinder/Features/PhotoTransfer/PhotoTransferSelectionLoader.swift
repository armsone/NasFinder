import CoreTransferable
import CryptoKit
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct PhotoTransferPreparedComponent: Sendable {
    let header: PhotoTransferWireHeader
    let fileURL: URL
}

struct PhotoTransferPreparedItem: Sendable {
    let components: [PhotoTransferPreparedComponent]

    func removeTemporaryFiles() {
        for component in components {
            try? FileManager.default.removeItem(at: component.fileURL)
        }
    }
}

private struct PhotoTransferImportedFile: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .data) { received in
            let temporaryURL = PhotoTransferSelectionLoader.temporaryURL(
                fileExtension: received.file.pathExtension
            )
            try FileManager.default.copyItem(at: received.file, to: temporaryURL)
            return PhotoTransferImportedFile(url: temporaryURL)
        }
    }
}

/// PhotosPicker 자산을 전송 가능한 파일 컴포넌트로 준비한다.
/// Live Photo는 공개 PHAssetResource API로 원본 이미지와 paired video를 각각 추출한다.
enum PhotoTransferSelectionLoader {
    enum LoadingError: LocalizedError {
        case dataUnavailable(Int)
        case livePhotoIdentifierUnavailable(Int)
        case livePhotoResourcesUnavailable(Int)
        case fileTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .dataUnavailable(let index):
                "항목 \(index)의 사진 또는 영상 데이터를 불러오지 못했습니다."
            case .livePhotoIdentifierUnavailable(let index):
                "항목 \(index)의 Live Photo 원본에 접근할 수 없습니다. 사진 접근을 허용한 뒤 다시 선택해 주세요."
            case .livePhotoResourcesUnavailable(let index):
                "항목 \(index)의 Live Photo 구성 파일을 모두 불러오지 못했습니다."
            case .fileTooLarge(let index):
                "항목 \(index)이 2GB 전송 한도를 넘었습니다."
            }
        }
    }

    @MainActor
    static func load(
        item: PhotosPickerItem,
        index: Int,
        kind: PhotoTransferMediaKind
    ) async throws -> PhotoTransferPreparedItem {
        let transferableLivePhoto: PHLivePhoto?
        if kind == .photo || kind == .livePhoto {
            transferableLivePhoto = try? await item.loadTransferable(type: PHLivePhoto.self)
        } else {
            transferableLivePhoto = nil
        }
        if kind == .livePhoto || transferableLivePhoto != nil {
            return try await loadLivePhoto(
                item: item,
                fallbackLivePhoto: transferableLivePhoto,
                index: index
            )
        }
        return try await loadRegularFile(item: item, index: index, kind: kind)
    }

    @MainActor
    private static func loadRegularFile(
        item: PhotosPickerItem,
        index: Int,
        kind: PhotoTransferMediaKind
    ) async throws -> PhotoTransferPreparedItem {
        let fileURL: URL
        let contentType: UTType?
        let originalFilename: String?
        if let resource = await originalResource(for: item, kind: kind) {
            contentType = UTType(resource.uniformTypeIdentifier)
            originalFilename = resource.originalFilename
            fileURL = temporaryURL(
                fileExtension: fileExtension(
                    for: resource,
                    fallback: fallbackExtension(for: kind)
                )
            )
            do {
                try await export(resource: resource, to: fileURL)
            } catch {
                try? FileManager.default.removeItem(at: fileURL)
                throw error
            }
        } else if let importedFile = try? await item.loadTransferable(type: PhotoTransferImportedFile.self) {
            fileURL = importedFile.url
            contentType = preferredContentType(from: item.supportedContentTypes, kind: kind)
            originalFilename = nil
        } else if let data = try await item.loadTransferable(type: Data.self) {
            let type = preferredContentType(from: item.supportedContentTypes, kind: kind)
            fileURL = temporaryURL(fileExtension: type?.preferredFilenameExtension ?? fallbackExtension(for: kind))
            try data.write(to: fileURL, options: [.atomic])
            contentType = type
            originalFilename = nil
        } else {
            throw LoadingError.dataUnavailable(index)
        }

        do {
            let byteLength = try fileSize(at: fileURL, index: index)
            let itemId = UUID().uuidString
            let wireKind: PhotoTransferWireItemKind = kind == .video ? .video : .photo
            let ext = fileURL.pathExtension.isEmpty ? fallbackExtension(for: kind) : fileURL.pathExtension
            let header = PhotoTransferWireHeader(
                id: UUID().uuidString,
                name: originalFilename.flatMap { $0.isEmpty ? nil : $0 }
                    ?? "\(baseName(for: kind))-\(index).\(ext)",
                mimeType: contentType?.preferredMIMEType ?? fallbackMIMEType(for: kind),
                mediaKind: kind.rawValue,
                sourcePlatform: .ios,
                byteLength: byteLength,
                itemId: itemId,
                groupId: itemId,
                itemKind: wireKind,
                componentRole: .regularFile,
                componentIndex: 0,
                componentCount: 1,
                sha256: try sha256(of: fileURL),
                stillImageTimeUs: -1
            )
            return PhotoTransferPreparedItem(components: [.init(header: header, fileURL: fileURL)])
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    @MainActor
    private static func loadLivePhoto(
        item: PhotosPickerItem,
        fallbackLivePhoto: PHLivePhoto?,
        index: Int
    ) async throws -> PhotoTransferPreparedItem {
        let authorization = await requestPhotoLibraryReadAuthorization()
        let resources: [PHAssetResource]
        if (authorization == .authorized || authorization == .limited),
           let identifier = item.itemIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            resources = PHAssetResource.assetResources(for: asset)
        } else if let fallbackLivePhoto {
            resources = PHAssetResource.assetResources(for: fallbackLivePhoto)
        } else {
            throw LoadingError.livePhotoIdentifierUnavailable(index)
        }
        guard let image = preferredResource(in: resources, types: [.fullSizePhoto, .photo]),
              let video = preferredResource(in: resources, types: [.fullSizePairedVideo, .pairedVideo])
        else {
            throw LoadingError.livePhotoResourcesUnavailable(index)
        }

        let imageURL = temporaryURL(fileExtension: fileExtension(for: image, fallback: "heic"))
        let videoURL = temporaryURL(fileExtension: fileExtension(for: video, fallback: "mov"))
        do {
            try await export(resource: image, to: imageURL)
            try await export(resource: video, to: videoURL)
            let imageLength = try fileSize(at: imageURL, index: index)
            let videoLength = try fileSize(at: videoURL, index: index)
            let itemId = UUID().uuidString
            let groupId = UUID().uuidString
            let imageComponent = try makeGroupedComponent(
                resource: image,
                fileURL: imageURL,
                itemId: itemId,
                groupId: groupId,
                role: .primaryImage,
                componentIndex: 0,
                byteLength: imageLength
            )
            let videoComponent = try makeGroupedComponent(
                resource: video,
                fileURL: videoURL,
                itemId: itemId,
                groupId: groupId,
                role: .motionVideo,
                componentIndex: 1,
                byteLength: videoLength
            )
            return PhotoTransferPreparedItem(components: [imageComponent, videoComponent])
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
            throw error
        }
    }

    private static func requestPhotoLibraryReadAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    @MainActor
    private static func originalResource(
        for item: PhotosPickerItem,
        kind: PhotoTransferMediaKind
    ) async -> PHAssetResource? {
        let authorization = await requestPhotoLibraryReadAuthorization()
        guard authorization == .authorized || authorization == .limited,
              let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [identifier],
                  options: nil
              ).firstObject
        else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        let preferredTypes: [PHAssetResourceType] = kind == .video
            ? [.video, .fullSizeVideo]
            : [.photo, .fullSizePhoto]
        return preferredResource(in: resources, types: preferredTypes)
    }

    private static func makeGroupedComponent(
        resource: PHAssetResource,
        fileURL: URL,
        itemId: String,
        groupId: String,
        role: PhotoTransferWireComponentRole,
        componentIndex: Int,
        byteLength: UInt64
    ) throws -> PhotoTransferPreparedComponent {
        let type = UTType(resource.uniformTypeIdentifier)
        let defaultMIME = role == .primaryImage ? "image/heic" : "video/quicktime"
        let defaultExtension = role == .primaryImage ? "heic" : "mov"
        let proposedName = resource.originalFilename.isEmpty
            ? "live-photo-\(componentIndex).\(defaultExtension)"
            : resource.originalFilename
        let header = PhotoTransferWireHeader(
            id: UUID().uuidString,
            name: proposedName,
            mimeType: type?.preferredMIMEType ?? defaultMIME,
            mediaKind: PhotoTransferMediaKind.livePhoto.rawValue,
            sourcePlatform: .ios,
            byteLength: byteLength,
            itemId: itemId,
            groupId: groupId,
            itemKind: .livePhoto,
            componentRole: role,
            componentIndex: componentIndex,
            componentCount: 2,
            sha256: try sha256(of: fileURL),
            stillImageTimeUs: -1
        )
        return PhotoTransferPreparedComponent(header: header, fileURL: fileURL)
    }

    private static func preferredResource(
        in resources: [PHAssetResource],
        types: [PHAssetResourceType]
    ) -> PHAssetResource? {
        for type in types {
            if let resource = resources.first(where: { $0.type == type }) { return resource }
        }
        return nil
    }

    @MainActor
    private static func export(resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    private static func fileSize(at url: URL, index: Int) throws -> UInt64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let length = UInt64(values.fileSize ?? 0)
        guard length <= PhotoTransferWireCodec.maximumPayloadLength else {
            throw LoadingError.fileTooLarge(index)
        }
        return length
    }

    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func temporaryURL(fileExtension: String) -> URL {
        let suffix = fileExtension.isEmpty ? "" : ".\(fileExtension)"
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("nasfinder-photo-\(UUID().uuidString)\(suffix)", isDirectory: false)
    }

    private static func fileExtension(for resource: PHAssetResource, fallback: String) -> String {
        let value = URL(fileURLWithPath: resource.originalFilename).pathExtension
        return value.isEmpty ? (UTType(resource.uniformTypeIdentifier)?.preferredFilenameExtension ?? fallback) : value
    }

    private static func preferredContentType(from contentTypes: [UTType], kind: PhotoTransferMediaKind) -> UTType? {
        switch kind {
        case .video: contentTypes.first(where: { $0.conforms(to: .movie) }) ?? contentTypes.first
        case .photo, .livePhoto: contentTypes.first(where: { $0.conforms(to: .image) }) ?? contentTypes.first
        case .unknown: contentTypes.first
        }
    }

    private static func baseName(for kind: PhotoTransferMediaKind) -> String {
        switch kind {
        case .livePhoto: "live-photo"
        case .photo: "photo"
        case .video: "video"
        case .unknown: "media"
        }
    }

    private static func fallbackExtension(for kind: PhotoTransferMediaKind) -> String {
        kind == .video ? "mov" : "jpg"
    }

    private static func fallbackMIMEType(for kind: PhotoTransferMediaKind) -> String {
        kind == .video ? "video/quicktime" : "image/jpeg"
    }
}
