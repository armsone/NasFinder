import Foundation
import Photos
import SwiftUI
import UIKit

/// 사진 선별 결과를 내보내는 세 동작(작업대에 담기 / Photos 앨범에 저장 / 공유).
/// 어느 동작도 원본을 옮기거나 지우지 않는다. 사진 보관함 원본은 읽기만 하고, 공유 대기 복사본도 그대로 둔다.
@MainActor
enum PhotoSelectionActions {
    enum ActionError: LocalizedError {
        case photoAccessDenied
        case nothingSelected
        case sourceUnavailable(String)

        var errorDescription: String? {
            switch self {
            case .photoAccessDenied: "사진 보관함 접근이 필요합니다. 설정에서 사진 접근을 허용한 뒤 다시 시도해 주세요."
            case .nothingSelected: "선택된 사진이 없습니다."
            case let .sourceUnavailable(name): "\(name)의 원본을 읽지 못했습니다."
            }
        }
    }

    struct Materialized {
        let url: URL
        /// true면 이 동작이 만든 임시 파일이라 끝난 뒤 지운다.
        let isTemporary: Bool
    }

    static func materialize(_ item: PhotoSelectionItem) async throws -> Materialized {
        switch item.source {
        case let .asset(identifier):
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                throw ActionError.sourceUnavailable(item.name)
            }
            let exported = try await LocalPhotoLibraryCalendarService.exportOriginal(for: asset)
            return Materialized(url: exported.url, isTemporary: true)
        case let .file(url):
            return Materialized(url: url, isTemporary: false)
        case let .staged(_, _, url):
            return Materialized(url: url, isTemporary: false)
        }
    }

    /// 선별 결과의 원본 위치(참조)만 입력 순서 그대로 만든다. 사진을 복사하거나 내려받지 않는다.
    /// 참조를 만들 수 없는 항목은 숨기지 않고 안내 문구로 돌려준다.
    static func workbenchReferences(_ items: [PhotoSelectionItem]) -> (entries: [WorkbenchEntry], notices: [String]) {
        var entries: [WorkbenchEntry] = []
        var notices: [String] = []
        var hasStaged = false
        for item in items {
            switch item.source {
            case let .asset(identifier):
                entries.append(WorkbenchEntryFactory.entry(assetIdentifier: identifier, name: item.name, isVideo: false))
            case let .file(url):
                switch WorkbenchEntryFactory.entry(fileURL: url) {
                case .success(let entry): entries.append(entry)
                case .failure(let error): notices.append(error.localizedDescription)
                }
            case let .staged(batchID, itemID, _):
                var entry = WorkbenchEntry(kind: .sharedStaging, mediaKind: .photo, name: item.name,
                                           sourceLabel: WorkbenchSourceLabel.shared)
                entry.stagedBatchID = batchID
                entry.stagedItemID = itemID
                entries.append(entry)
                hasStaged = true
            }
        }
        if hasStaged {
            notices.append("공유로 받은 사진은 앱 그룹에 임시로 보관된 파일을 가리킵니다. 사진 선별을 마치거나 비우면 정리되어 다시 연결이 필요할 수 있습니다.")
        }
        return (entries, notices)
    }

    /// 새 Photos 앨범을 만들어 담는다. 사진 보관함 입력은 기존 자산을 앨범에 추가만 하고(복제 없음),
    /// 파일·공유 입력은 새 자산으로 만들어 같은 앨범에 넣는다.
    static func saveToPhotos(_ items: [PhotoSelectionItem], albumTitle: String) async throws -> String {
        guard !items.isEmpty else { throw ActionError.nothingSelected }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else { throw ActionError.photoAccessDenied }

        var existing: [PHAsset] = []
        var fileURLs: [URL] = []
        for item in items {
            switch item.source {
            case let .asset(identifier):
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
                    throw ActionError.sourceUnavailable(item.name)
                }
                existing.append(asset)
            case let .file(url), let .staged(_, _, url):
                fileURLs.append(url)
            }
        }
        let existingAssets = existing
        let newFiles = fileURLs
        guard !existingAssets.isEmpty || !newFiles.isEmpty else { throw ActionError.nothingSelected }
        let created = CreatedCountBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                var members: [PHObject] = existingAssets
                for url in newFiles {
                    if let request = PHAssetCreationRequest.creationRequestForAssetFromImage(atFileURL: url),
                       let placeholder = request.placeholderForCreatedAsset {
                        members.append(placeholder)
                        created.value += 1
                    }
                }
                guard !members.isEmpty else { return }
                let album = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: albumTitle)
                album.addAssets(members as NSArray)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: ActionError.photoAccessDenied) }
            }
        }
        return saveSummary(albumTitle: albumTitle, existingCount: existingAssets.count,
                           requestedNewCount: newFiles.count, createdNewCount: created.value)
    }

    private final class CreatedCountBox: @unchecked Sendable { var value = 0 }

    /// 실제로 앨범에 담긴 수(기존 자산 + 생성 요청이 성공한 새 자산)만 말한다. 생성 요청이 nil이었던 파일은 저장한 것으로 세지 않는다.
    nonisolated static func saveSummary(albumTitle: String, existingCount: Int, requestedNewCount: Int, createdNewCount: Int) -> String {
        let saved = existingCount + createdNewCount
        let skipped = max(0, requestedNewCount - createdNewCount)
        if saved == 0 { return "사진으로 만들 수 있는 항목이 없어 아무것도 저장하지 못했습니다. 앨범도 만들지 않았고 원본은 그대로입니다." }
        var text = "Photos 앨범 \"\(albumTitle)\"에 \(saved)장을 저장했습니다."
        if skipped > 0 { text += " 사진으로 만들지 못해 저장하지 못한 \(skipped)장은 앨범에 넣지 않았습니다." }
        return text + " 원본은 옮기거나 지우지 않았습니다."
    }

    /// 공유용 파일 복사본. 원래 이름을 유지하려고 전용 임시 폴더를 만들며, 공유가 끝나면 `directory`째 지운다.
    struct ShareFiles {
        let directory: URL
        let urls: [URL]
    }

    static func prepareShareFiles(_ items: [PhotoSelectionItem]) async throws -> ShareFiles {
        guard !items.isEmpty else { throw ActionError.nothingSelected }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("nasfinder-selection-share-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var urls: [URL] = []
        do {
            for item in items {
                let source = try await materialize(item)
                let safe = (item.name as NSString).lastPathComponent
                var destination = directory.appendingPathComponent(safe.isEmpty ? "photo" : safe)
                if FileManager.default.fileExists(atPath: destination.path) {
                    destination = directory.appendingPathComponent("\(UUID().uuidString.prefix(6))-\(destination.lastPathComponent)")
                }
                if source.isTemporary {
                    try FileManager.default.moveItem(at: source.url, to: destination)
                } else {
                    try FileManager.default.copyItem(at: source.url, to: destination)
                }
                urls.append(destination)
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        return ShareFiles(directory: directory, urls: urls)
    }
}

/// 공유 시트. 닫히면 호출자가 임시 복사본을 지운다.
struct PhotoSelectionShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onFinish() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
