import CryptoKit
import Foundation
import Photos

/// 송신 완료 뒤 "보낸 원본 삭제"를 안전하게 하기 위한 판정과 실행.
/// - 판정은 와이어로 받은 영수증이 아니라 이 기기의 정확한 PHAsset과 전송 때 남긴 해시로 한다.
///   영수증은 "삭제해도 되는 후보" 힌트일 뿐 권한이 아니다(인증되지 않은 상대의 주장).
/// - 삭제 직전 `revalidate`가 원본을 다시 읽어 전송 때의 해시와 바이트 단위로 같은지 확인한다.
///   같은 이름·같은 해시만으로 원본을 추정하지 않고, 공유 staging 복사본·선택기 임시 파일은 원본으로 보지 않는다.
/// - 실제 삭제는 `PHPhotoLibrary.performChanges`의 시스템 삭제 확인 UI를 거친다. 그 동의는 우회하지 않는다.
@MainActor
enum PhotoTransferSourceVerifier {
    /// 삭제 후보 판정 결과. `reason`은 사용자에게 그대로 보이는 한국어 사유다.
    enum Eligibility: Equatable {
        case candidate
        case excluded(String)

        var isCandidate: Bool { self == .candidate }
    }

    static let tokenExposedReason = "이 QR 코드는 예전 방식으로 연결된 적이 있어 원본 삭제를 사용할 수 없습니다. 새 QR 코드로 다시 연결해 보내면 삭제를 선택할 수 있습니다."

    /// 입출력 없이 계획 항목만으로 하는 1차 판정. 영수증이 협상되지 않았거나 검증되지 않은 항목은 여기서 제외한다.
    static func preliminaryEligibility(
        of item: PhotoTransferSenderPlan.Item,
        receiptsNegotiated: Bool,
        tokenExposed: Bool = false
    ) -> Eligibility {
        if tokenExposed { return .excluded(tokenExposedReason) }
        guard receiptsNegotiated || item.status == .legacyAcknowledged else {
            return .excluded("상대 앱이 항목별 저장 확인을 지원하지 않아 원본 삭제를 사용할 수 없습니다.")
        }
        switch item.status {
        case .verified:
            break
        case .legacyAcknowledged:
            return .excluded("상대 앱이 항목별 저장 확인을 지원하지 않아 원본 삭제를 사용할 수 없습니다.")
        case .failed:
            return .excluded("받는 기기에 저장하지 못한 항목입니다. 원본은 그대로 둡니다.")
        case .unknown:
            return .excluded("받는 기기의 저장 여부를 확인하지 못했습니다. 원본은 그대로 둡니다.")
        case .pending:
            return .excluded("아직 전송이 끝나지 않은 항목입니다.")
        }
        guard let snapshot = item.snapshot else {
            return .excluded("보낸 원본을 사진 보관함의 정확한 항목과 연결하지 못했습니다(출처 확인 불가).")
        }
        guard !item.expectedInputs.isEmpty, item.expectedInputs.count == snapshot.resources.count else {
            return .excluded("보낸 구성 파일 정보가 완전하지 않아 원본을 확인할 수 없습니다.")
        }
        if let reason = layoutExclusionReason(
            snapshotWhole: snapshot.allResourceTypeRawValues,
            currentWhole: snapshot.allResourceTypeRawValues ?? [],
            transferred: snapshot.resources.map(\.typeRawValue)) {
            return .excluded(reason)
        }
        return .candidate
    }

    /// 삭제는 PHAsset 전체를 지운다. 그래서 전송한 자원이 자산의 모든 자원과 정확히 같은 단순 원본 구성일 때만 허용한다.
    /// - 사진: `photo` 1개 / 영상: `video` 1개 / Live Photo: `photo` + `pairedVideo` 정확히 2개.
    /// - 편집 렌더링, `adjustmentData`, 대체 사진, 전송하지 않은 자원이 하나라도 있으면 제외한다(전송 구성요소가 일부뿐인 Live Photo 포함).
    static func isSupportedOriginalShape(whole: [Int], transferred: [Int]) -> Bool {
        let wholeTypes = whole.sorted()
        guard wholeTypes == transferred.sorted() else { return false }
        let photo = PHAssetResourceType.photo.rawValue
        let video = PHAssetResourceType.video.rawValue
        let pairedVideo = PHAssetResourceType.pairedVideo.rawValue
        return wholeTypes == [photo] || wholeTypes == [video] || wholeTypes == [photo, pairedVideo].sorted()
    }

    /// 전체 자원 구성에 따른 제외 사유. nil이면 이 구성은 통과다. 스냅샷에 전체 구성이 없으면(이전 버전) 안전하게 제외한다.
    static func layoutExclusionReason(snapshotWhole: [Int]?, currentWhole: [Int], transferred: [Int]) -> String? {
        guard let snapshotWhole else {
            return "이전 버전에서 보낸 항목이라 원본의 전체 구성을 확인할 수 없어 삭제 대상에서 제외했습니다."
        }
        guard snapshotWhole.sorted() == currentWhole.sorted() else {
            return "전송한 뒤 원본의 구성이 바뀌어 삭제 대상에서 제외했습니다."
        }
        guard isSupportedOriginalShape(whole: currentWhole, transferred: transferred) else {
            return "편집본이나 보내지 않은 구성 파일이 있어 원본 삭제 대상에서 제외했습니다(보낸 파일만으로는 원본 전체를 대신할 수 없습니다)."
        }
        return nil
    }

    /// 삭제 직전(OS 동의 요청 직전) 마지막으로 하는 동기 점검: 같은 자산, 삭제 가능, 날짜 동일, 전체 자원 구성 동일.
    static func recheckBeforeDelete(_ item: PhotoTransferSenderPlan.Item, asset: PHAsset) -> Eligibility {
        guard let snapshot = item.snapshot, asset.localIdentifier == snapshot.assetLocalIdentifier else {
            return .excluded("원본 정보가 일치하지 않습니다.")
        }
        guard asset.canPerform(.delete) else { return .excluded("삭제할 수 없는 항목입니다(공유 앨범 등 읽기 전용).") }
        guard sameSecond(asset.creationDate, snapshot.creationDate),
              sameSecond(asset.modificationDate, snapshot.modificationDate) else {
            return .excluded("전송한 뒤 원본이 수정되어 삭제 대상에서 제외했습니다.")
        }
        if let reason = layoutExclusionReason(
            snapshotWhole: snapshot.allResourceTypeRawValues,
            currentWhole: PHAssetResource.assetResources(for: asset).map { $0.type.rawValue },
            transferred: snapshot.resources.map(\.typeRawValue)) {
            return .excluded(reason)
        }
        return .candidate
    }

    /// 삭제 직전 재검증. 이 기기에 있는 원본만 읽는다(네트워크 사용 안 함).
    static func revalidate(_ item: PhotoTransferSenderPlan.Item) async -> (eligibility: Eligibility, asset: PHAsset?) {
        guard let snapshot = item.snapshot else { return (.excluded("원본 정보가 없습니다."), nil) }
        var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined { status = await PHPhotoLibrary.requestAuthorization(for: .readWrite) }
        guard status == .authorized || status == .limited else {
            return (.excluded("사진 보관함 접근 권한이 필요합니다."), nil)
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [snapshot.assetLocalIdentifier], options: nil).firstObject else {
            return (.excluded("원본을 찾을 수 없습니다(이미 삭제되었거나 접근할 수 없습니다)."), nil)
        }
        guard asset.canPerform(.delete) else {
            return (.excluded("삭제할 수 없는 항목입니다(공유 앨범 등 읽기 전용)."), nil)
        }
        guard sameSecond(asset.creationDate, snapshot.creationDate),
              sameSecond(asset.modificationDate, snapshot.modificationDate) else {
            return (.excluded("전송한 뒤 원본이 수정되어 삭제 대상에서 제외했습니다."), nil)
        }
        if let reason = layoutExclusionReason(
            snapshotWhole: snapshot.allResourceTypeRawValues,
            currentWhole: PHAssetResource.assetResources(for: asset).map { $0.type.rawValue },
            transferred: snapshot.resources.map(\.typeRawValue)) {
            return (.excluded(reason), nil)
        }
        let wireKind = PhotoTransferWireItemKind(rawValue: item.kindRawValue) ?? .photo
        let kindForSelection: PhotoTransferWireItemKind = item.expectedInputs.count == 2 ? .livePhoto : wireKind
        guard let resources = PhotoTransferSelectionLoader.transferResources(
            in: PHAssetResource.assetResources(for: asset), wireKind: kindForSelection),
              resources.count == snapshot.resources.count,
              zip(resources, snapshot.resources).allSatisfy({
                  $0.type.rawValue == $1.typeRawValue && $0.originalFilename == $1.originalFilename
                      && $0.uniformTypeIdentifier == $1.uniformTypeIdentifier
              }) else {
            return (.excluded("전송한 뒤 원본의 구성이 바뀌어 삭제 대상에서 제외했습니다."), nil)
        }
        for (index, resource) in resources.enumerated() {
            guard let expected = item.expectedInputs.first(where: { $0.index == index }) else {
                return (.excluded("보낸 구성 파일 정보가 완전하지 않습니다."), nil)
            }
            do {
                let digest = try await localSHA256(of: resource)
                guard digest == expected.sha256 else {
                    return (.excluded("전송한 뒤 원본 내용이 바뀌어 삭제 대상에서 제외했습니다."), nil)
                }
            } catch let error as NSError where error.domain == PHPhotosErrorDomain {
                return (.excluded("원본이 이 기기에 없고 iCloud에만 있어 내용을 확인할 수 없습니다."), nil)
            } catch {
                return (.excluded("원본을 읽지 못해 확인할 수 없습니다: \(error.localizedDescription)"), nil)
            }
        }
        return (.candidate, asset)
    }

    /// 시스템 삭제 확인(OS 동의)을 거쳐 삭제한다. 사용자가 거부하면 던지는 오류를 그대로 전달한다.
    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { success, error in
                if let error { continuation.resume(throwing: error) }
                else if success { continuation.resume() }
                else { continuation.resume(throwing: CocoaError(.userCancelled)) }
            }
        }
    }

    static func isUserDeclined(_ error: Error) -> Bool {
        let nsError = error as NSError
        return (nsError.domain == PHPhotosErrorDomain && nsError.code == PHPhotosError.userCancelled.rawValue)
            || (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.userCancelled.rawValue)
    }

    // MARK: 내부

    /// 계획에 JSON(ISO-8601)으로 저장되면 초 미만이 사라지므로 초 단위로 비교한다.
    private static func sameSecond(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): true
        case let (l?, r?): Int(l.timeIntervalSince1970.rounded(.down)) == Int(r.timeIntervalSince1970.rounded(.down))
        default: false
        }
    }

    private final class HashBox: @unchecked Sendable {
        private let lock = NSLock()
        private var hasher = SHA256()
        func update(_ data: Data) { lock.lock(); hasher.update(data: data); lock.unlock() }
        func hex() -> String {
            lock.lock()
            defer { lock.unlock() }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// 파일로 내보내지 않고 자원 바이트를 흘려 SHA-256을 계산한다. 네트워크는 쓰지 않는다.
    private static func localSHA256(of resource: PHAssetResource) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        let box = HashBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                box.update(data)
            } completionHandler: { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: box.hex()) }
            }
        }
    }
}
