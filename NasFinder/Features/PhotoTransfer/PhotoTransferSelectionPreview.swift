import Photos
import PhotosUI
import SwiftUI
import UIKit

struct PhotoTransferSelectionPreview: @unchecked Sendable {
    let image: UIImage?
    let duration: TimeInterval?
    let isLivePhotoAsset: Bool?
}

/// 선택 검토 화면은 PhotoKit의 캐싱 썸네일만 요청하며 영상 원본을 미리 읽지 않는다.
@MainActor
final class PhotoTransferSelectionPreviewLoader {
    private let imageManager = PHCachingImageManager()

    func load(for item: PhotosPickerItem, targetSize: CGSize) async -> PhotoTransferSelectionPreview {
        let transferableLivePhoto = try? await item.loadTransferable(type: PHLivePhoto.self)
        guard let identifier = item.itemIdentifier,
              let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
        else {
            return PhotoTransferSelectionPreview(
                image: nil,
                duration: nil,
                isLivePhotoAsset: transferableLivePhoto != nil ? true : nil
            )
        }

        imageManager.startCachingImages(
            for: [asset],
            targetSize: targetSize,
            contentMode: .aspectFill,
            options: nil
        )
        let image = await requestImage(for: asset, targetSize: targetSize)
        let duration = asset.mediaType == .video || asset.mediaSubtypes.contains(.photoLive)
            ? asset.duration
            : nil
        return PhotoTransferSelectionPreview(
            image: image,
            duration: duration,
            isLivePhotoAsset: asset.mediaSubtypes.contains(.photoLive)
        )
    }

    private func requestImage(for asset: PHAsset, targetSize: CGSize) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .exact
            options.isNetworkAccessAllowed = true
            var resumed = false
            imageManager.requestImage(
                for: asset,
                targetSize: targetSize,
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                guard !resumed else { return }
                resumed = true
                continuation.resume(returning: image)
            }
        }
    }
}
