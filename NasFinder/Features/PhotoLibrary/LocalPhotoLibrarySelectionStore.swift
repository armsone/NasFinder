import Foundation
import Photos
import PhotosUI
import SwiftUI

enum LocalPhotoSelectionOrigin { case photoPicker, calendar, file, network, phoneHard, googlePhotos }

/// 선택만 해 두고 아직 가져오지 않은 항목의 가져오기 방법. 영상 제작·미리보기·폰하드 복사처럼 원본이 실제로 필요한
/// 동작을 **시작할 때에만** 쓰며, '작업대에 담기'는 이것을 쓰지 않고 참조(`reference`)만 쓴다.
enum LocalPhotoDeferredSource {
    case remote(item: RemoteFileItem, service: any RemoteFileService)
    case bookmark(Data)
}

/// 미디어 고르기 화면이 고른 항목 하나. 앱 소유 임시 사본(`ownsURL`)이면 명시적 제거·비우기에서만 지운다.
struct LocalPhotoSelectionEntry: Identifiable {
    let id: String
    let item: RemoteFileItem
    var url: URL?
    let isVideo: Bool
    var thumbnail: UIImage?
    let origin: LocalPhotoSelectionOrigin
    var duration: TimeInterval?
    var asset: PHAsset? = nil
    var pickerItem: PhotosPickerItem? = nil
    /// 폰하드에 이미 저장된 파일은 읽기만 하며 바스켓이 지우지 않는다.
    var ownsURL = true
    /// '작업대에 담기'가 쓰는 원본 위치 참조. 임시 사본이 아니라 원본을 다시 가리킬 수 있는 정보만 담는다.
    /// 만들 수 없는 항목은 nil이며, 몰래 복사하지 않고 담지 못했다고 알린다.
    var reference: WorkbenchEntry? = nil
    /// 값이 있으면 아직 원본을 가져오지 않은 선택이다(`url`이 nil). 필요한 순간 `prepare`가 가져온다.
    var deferred: LocalPhotoDeferredSource? = nil
}

/// 미디어 고르기 선택(대기 항목·출처 페이지·Google 세션)을 화면 수명과 분리해 들고 있는 세션.
/// 화면이 pop·재생성되어도 선택 순서와 임시 사본 소유권은 유지되고,
/// 사용자가 제거·비우기를 하거나 `releaseAll()`이 불릴 때만 임시 사본을 지운다.
@MainActor
final class LocalPhotoLibrarySelectionStore: ObservableObject {
    enum Scope: String { case library, trailer, mediaMusic, project }
    private static var stores: [Scope: LocalPhotoLibrarySelectionStore] = [:]

    /// 진입 맥락(일반 사진·영상 / 영상 만들기 / 뮤직비디오 / 현재 프로젝트에 추가)마다 따로 유지한다.
    static func store(for scope: Scope) -> LocalPhotoLibrarySelectionStore {
        if let existing = stores[scope] { return existing }
        let created = LocalPhotoLibrarySelectionStore()
        stores[scope] = created
        return created
    }

    @Published var entries: [LocalPhotoSelectionEntry] = []
    @Published var pickerSelection: [PhotosPickerItem] = []
    @Published var sourcePage: MediaSourcePage = .photos
    /// Google 포토 페이지가 가져온 뒤 아직 선택에 담지 못한 기록.
    var queuedGoogleRecords: [SharedInboxRecord] = []
    var rememberedIdentities: [PhotosPickerItem: String] = [:]
    let googleLifecycle = EmbeddedGooglePhotosLifecycle()

    private init() {}

    /// 앱 소유 임시 사본만 지운다. 폰하드 등 읽기 전용 원본은 건드리지 않는다.
    func discardOwnedFile(of entry: LocalPhotoSelectionEntry) {
        if entry.ownsURL, let url = entry.url { try? FileManager.default.removeItem(at: url) }
    }

    /// 사용자의 명시적 "모두 비우기" 또는 세션 최종 해제. Google 세션도 이때 닫는다.
    func releaseAll() {
        googleLifecycle.cancel()
        for entry in entries { discardOwnedFile(of: entry) }
        entries = []
        pickerSelection = []
        rememberedIdentities = [:]
        queuedGoogleRecords = []
    }
}
