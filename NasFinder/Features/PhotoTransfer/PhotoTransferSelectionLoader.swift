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
    /// 발신 로컬에만 두는 원본 신원. 정확한 PHAsset 자원으로 내보낸 경우에만 있다(그렇지 않으면 삭제 대상이 아니다).
    var snapshot: PhotoTransferSourceSnapshot?
    var wireKind: PhotoTransferWireItemKind = .photo
    /// 앱 전용 보내기 보관함의 파일이면 true. 보낸 뒤에도 지우지 않는다(사용자가 목록에서 직접 지울 때만 삭제).
    var retainsFiles = false

    /// 구성요소별 검증 해시(= 수신에 보낸 입력 해시). 변환 후 저장물 해시가 아니다.
    var inputs: [PhotoTransferReceiptInput] {
        components.compactMap { component in
            guard let index = component.header.componentIndex, let sha = component.header.sha256 else { return nil }
            return PhotoTransferReceiptInput(index: index, sha256: sha)
        }
    }

    func removeTemporaryFiles() {
        guard !retainsFiles else { return }
        for component in components {
            try? FileManager.default.removeItem(at: component.fileURL)
        }
    }
}

/// 보내기 흐름이 한 항목을 읽어 오는 방법. 재시도 때도 같은 `id`로 이어 가므로 출처 안의 안정 식별자를 쓴다.
/// `load`는 보내는 순간에만 불리며, 작업대 참조는 이때 원본을 이 실행 전용 임시 파일로 가져온다.
struct PhotoTransferSendSource: Identifiable {
    let id: String
    let kind: PhotoTransferMediaKind
    let load: (_ index: Int, _ itemId: String) async throws -> PhotoTransferPreparedItem
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
        case photoAccessDenied
        case assetMissing
        case unsupportedType

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
            case .photoAccessDenied:
                "사진 접근이 허용되지 않았습니다. 설정에서 사진 접근을 허용한 뒤 다시 연결해 주세요."
            case .assetMissing:
                "사진 보관함에서 이 항목을 찾을 수 없습니다. 삭제되었거나 허용한 범위 밖일 수 있어 다시 연결이 필요합니다."
            case .unsupportedType:
                "사진 또는 영상 파일이 아니라 미디어 전송에 쓸 수 없습니다."
            }
        }
    }

    /// 원본 자원 선택 규칙. 보낼 때와 삭제 직전 재검증이 같은 자원을 고르도록 한 곳에 둔다.
    static func transferResources(
        in resources: [PHAssetResource],
        wireKind: PhotoTransferWireItemKind
    ) -> [PHAssetResource]? {
        switch wireKind {
        case .video:
            return preferredResource(in: resources, types: [.video, .fullSizeVideo]).map { [$0] }
        case .photo:
            return preferredResource(in: resources, types: [.photo, .fullSizePhoto]).map { [$0] }
        case .livePhoto, .motionPhoto:
            guard let image = preferredResource(in: resources, types: [.fullSizePhoto, .photo]),
                  let video = preferredResource(in: resources, types: [.fullSizePairedVideo, .pairedVideo]) else { return nil }
            return [image, video]
        }
    }

    private static func snapshot(for asset: PHAsset, resources: [PHAssetResource]) -> PhotoTransferSourceSnapshot {
        PhotoTransferSourceSnapshot(
            assetLocalIdentifier: asset.localIdentifier,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            resources: resources.map {
                .init(typeRawValue: $0.type.rawValue, originalFilename: $0.originalFilename,
                      uniformTypeIdentifier: $0.uniformTypeIdentifier)
            },
            allResourceTypeRawValues: PHAssetResource.assetResources(for: asset).map { $0.type.rawValue })
    }

    @MainActor
    static func load(
        item: PhotosPickerItem,
        index: Int,
        kind: PhotoTransferMediaKind,
        itemId: String = UUID().uuidString
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
                index: index,
                itemId: itemId
            )
        }
        return try await loadRegularFile(item: item, index: index, kind: kind, itemId: itemId)
    }

    @MainActor
    private static func loadRegularFile(
        item: PhotosPickerItem,
        index: Int,
        kind: PhotoTransferMediaKind,
        itemId: String
    ) async throws -> PhotoTransferPreparedItem {
        let fileURL: URL
        let contentType: UTType?
        let originalFilename: String?
        var sourceSnapshot: PhotoTransferSourceSnapshot?
        if let (asset, resource) = await originalResource(for: item, kind: kind) {
            sourceSnapshot = snapshot(for: asset, resources: [resource])
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
            let wireKind: PhotoTransferWireItemKind = kind == .video ? .video : .photo
            let ext = fileURL.pathExtension.isEmpty ? fallbackExtension(for: kind) : fileURL.pathExtension
            let header = PhotoTransferWireHeader(
                id: itemId,
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
            return PhotoTransferPreparedItem(
                components: [.init(header: header, fileURL: fileURL)], snapshot: sourceSnapshot, wireKind: wireKind)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    @MainActor
    private static func loadLivePhoto(
        item: PhotosPickerItem,
        fallbackLivePhoto: PHLivePhoto?,
        index: Int,
        itemId: String
    ) async throws -> PhotoTransferPreparedItem {
        let authorization = await requestPhotoLibraryReadAuthorization()
        let resources: [PHAssetResource]
        var sourceAsset: PHAsset?
        if (authorization == .authorized || authorization == .limited),
           let identifier = item.itemIdentifier,
           let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject {
            resources = PHAssetResource.assetResources(for: asset)
            sourceAsset = asset
        } else if let fallbackLivePhoto {
            resources = PHAssetResource.assetResources(for: fallbackLivePhoto)
        } else {
            throw LoadingError.livePhotoIdentifierUnavailable(index)
        }
        return try await exportLivePhoto(resources: resources, sourceAsset: sourceAsset, index: index, itemId: itemId)
    }

    /// Live Photo의 원본 이미지와 paired video를 각각 내보내 한 묶음으로 만든다. 사진 선택기·작업대 참조가 같은 경로를 쓴다.
    @MainActor
    private static func exportLivePhoto(
        resources: [PHAssetResource],
        sourceAsset: PHAsset?,
        index: Int,
        itemId: String
    ) async throws -> PhotoTransferPreparedItem {
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
            // 계약: groupId는 itemId와 같고, 재시도 동안 itemId는 바뀌지 않는다.
            let groupId = itemId
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
            return PhotoTransferPreparedItem(
                components: [imageComponent, videoComponent],
                snapshot: sourceAsset.map { snapshot(for: $0, resources: [image, video]) },
                wireKind: .livePhoto)
        } catch {
            try? FileManager.default.removeItem(at: imageURL)
            try? FileManager.default.removeItem(at: videoURL)
            throw error
        }
    }

    /// 작업대 참조(PhotoKit 식별자)로 보낼 항목을 만든다. 보내는 순간에만 원본을 내보내며 Live Photo는 이미지+paired video로 유지한다.
    @MainActor
    static func load(assetIdentifier: String, index: Int, itemId: String) async throws -> PhotoTransferPreparedItem {
        let authorization = await requestPhotoLibraryReadAuthorization()
        guard authorization == .authorized || authorization == .limited else { throw LoadingError.photoAccessDenied }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetIdentifier], options: nil).firstObject else {
            throw LoadingError.assetMissing
        }
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaSubtypes.contains(.photoLive) {
            return try await exportLivePhoto(resources: resources, sourceAsset: asset, index: index, itemId: itemId)
        }
        let kind: PhotoTransferMediaKind = asset.mediaType == .video ? .video : .photo
        let wireKind: PhotoTransferWireItemKind = kind == .video ? .video : .photo
        guard let resource = transferResources(in: resources, wireKind: wireKind)?.first else {
            throw LoadingError.dataUnavailable(index)
        }
        let fileURL = temporaryURL(fileExtension: fileExtension(for: resource, fallback: fallbackExtension(for: kind)))
        do {
            try await export(resource: resource, to: fileURL)
            let byteLength = try fileSize(at: fileURL, index: index)
            let ext = fileURL.pathExtension.isEmpty ? fallbackExtension(for: kind) : fileURL.pathExtension
            let header = PhotoTransferWireHeader(
                id: itemId,
                name: resource.originalFilename.isEmpty ? "\(baseName(for: kind))-\(index).\(ext)" : resource.originalFilename,
                mimeType: UTType(resource.uniformTypeIdentifier)?.preferredMIMEType ?? fallbackMIMEType(for: kind),
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
            return PhotoTransferPreparedItem(
                components: [.init(header: header, fileURL: fileURL)],
                snapshot: snapshot(for: asset, resources: [resource]), wireKind: wireKind)
        } catch {
            try? FileManager.default.removeItem(at: fileURL)
            throw error
        }
    }

    /// 이미 이 실행의 작업 폴더에 받아 둔 파일(`ownsFile`)이나 그 자리에서 읽을 기존 파일로 보낼 항목을 만든다.
    /// 소유하지 않은 파일은 보낸 뒤에도 지우지 않는다.
    nonisolated static func prepareFile(
        at fileURL: URL, name: String, contentType: UTType?, index: Int, itemId: String, ownsFile: Bool
    ) throws -> PhotoTransferPreparedItem {
        let type = contentType ?? UTType(filenameExtension: fileURL.pathExtension.lowercased())
        let kind: PhotoTransferMediaKind
        if type?.conforms(to: .movie) == true || type?.conforms(to: .video) == true { kind = .video }
        else if type?.conforms(to: .image) == true { kind = .photo }
        else { throw LoadingError.unsupportedType }
        let wireKind: PhotoTransferWireItemKind = kind == .video ? .video : .photo
        let length = try fileSize(at: fileURL, index: index)
        let header = PhotoTransferWireHeader(
            id: itemId, name: name, mimeType: type?.preferredMIMEType ?? fallbackMIMEType(for: kind),
            mediaKind: kind.rawValue, sourcePlatform: .ios, byteLength: length, itemId: itemId, groupId: itemId,
            itemKind: wireKind, componentRole: .regularFile, componentIndex: 0, componentCount: 1,
            sha256: try sha256(of: fileURL), stillImageTimeUs: -1)
        return PhotoTransferPreparedItem(
            components: [.init(header: header, fileURL: fileURL)], snapshot: nil, wireKind: wireKind, retainsFiles: !ownsFile)
    }

    /// 앱 안에 이미 있는 예전 Live/Motion 복사본(이미지 + 짝 영상)을 한 묶음으로 보낼 항목으로 만든다.
    /// 두 파일은 그 자리에서 읽기만 하고 보낸 뒤에도 지우지 않는다(`retainsFiles`). 원본 스냅샷이 없어 원본 삭제 대상은 아니다.
    nonisolated static func prepareLivePair(
        imageURL: URL, videoURL: URL, index: Int, itemId: String
    ) throws -> PhotoTransferPreparedItem {
        let imageLength = try fileSize(at: imageURL, index: index)
        let videoLength = try fileSize(at: videoURL, index: index)
        func component(_ url: URL, role: PhotoTransferWireComponentRole, position: Int, length: UInt64,
                       defaultMIME: String) throws -> PhotoTransferPreparedComponent {
            let type = UTType(filenameExtension: url.pathExtension.lowercased())
            let header = PhotoTransferWireHeader(
                id: "\(itemId)-\(position)", name: url.lastPathComponent,
                mimeType: type?.preferredMIMEType ?? defaultMIME,
                mediaKind: PhotoTransferMediaKind.livePhoto.rawValue, sourcePlatform: .ios, byteLength: length,
                itemId: itemId, groupId: itemId, itemKind: .livePhoto, componentRole: role,
                componentIndex: position, componentCount: 2, sha256: try sha256(of: url), stillImageTimeUs: -1)
            return PhotoTransferPreparedComponent(header: header, fileURL: url)
        }
        return PhotoTransferPreparedItem(
            components: [
                try component(imageURL, role: .primaryImage, position: 0, length: imageLength, defaultMIME: "image/heic"),
                try component(videoURL, role: .motionVideo, position: 1, length: videoLength, defaultMIME: "video/quicktime"),
            ],
            snapshot: nil, wireKind: .livePhoto, retainsFiles: true)
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
    ) async -> (PHAsset, PHAssetResource)? {
        let authorization = await requestPhotoLibraryReadAuthorization()
        guard authorization == .authorized || authorization == .limited,
              let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(
                  withLocalIdentifiers: [identifier],
                  options: nil
              ).firstObject
        else { return nil }

        let resources = PHAssetResource.assetResources(for: asset)
        guard let resource = transferResources(in: resources, wireKind: kind == .video ? .video : .photo)?.first else { return nil }
        return (asset, resource)
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
            id: "\(itemId)-\(componentIndex)",
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
