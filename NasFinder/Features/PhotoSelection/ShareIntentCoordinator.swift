import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 공유 시트에서 "영상 만들기"/"이미지 선별"을 고른 배치를 앱 안으로 이어 받는다.
/// - 영상 만들기: 받은 배치를 작업대로 안내한다. 공유 확장이 앱 그룹에 둔 파일은 그대로 두고,
///   사용자가 고른 포켓에 참조로만 담는다(자동 복사·자동 담기·자동 삭제 없음).
/// - 이미지 선별: 사진 선별 세션이 입력으로 올린다.
@MainActor
final class ShareIntentCoordinator: ObservableObject {
    static let shared = ShareIntentCoordinator()

    /// 아직 어느 포켓에도 담기지 않아 대기 중인 영상 만들기 배치(항목이 남은 것만).
    @Published private(set) var pendingMaterialBatches: [ShareIntentBatch] = []
    @Published var notice: String?

    var pendingMaterialItemCount: Int { pendingMaterialBatches.reduce(0) { $0 + $1.items.count } }

    /// `nasfinder://share-intent?batch=<uuid>&intent=<photoSelect|makeVideo>`
    static func parse(_ url: URL) -> (batchID: UUID, intent: ShareIntent)? {
        guard url.scheme?.caseInsensitiveCompare("nasfinder") == .orderedSame,
              url.host?.caseInsensitiveCompare("share-intent") == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let batchValue = components.queryItems?.first(where: { $0.name == "batch" })?.value,
              let batchID = UUID(uuidString: batchValue),
              let intentValue = components.queryItems?.first(where: { $0.name == "intent" })?.value,
              let intent = ShareIntent(rawValue: intentValue) else { return nil }
        return (batchID, intent)
    }

    /// 딥링크로 들어온 배치를 처리하고 알맞은 화면으로 안내한다.
    func handle(_ url: URL, router: AppShellRouter) {
        guard let parsed = Self.parse(url) else { return }
        switch parsed.intent {
        case .makeVideo:
            refresh()
            router.request = .workbench
        case .photoSelect:
            router.openPhotoSelection()
            PhotoSelectionSession.shared.loadSharedBatches()
        }
    }

    /// 앱이 정상적으로 foreground가 될 때 공유 확장이 남긴 배치를 이어 받는다(확장은 앱 자동 열기를 보장받지 못한다).
    /// - 영상 만들기: 대기 중인 항목이 있으면 작업대로 안내한다. 어디에 담을지는 사용자가 정한다.
    /// - 이미지 선별: 새 입력이 있으면 사진 선별 화면으로 안내한다.
    func consumeOnForeground(router: AppShellRouter) {
        let before = Set(pendingMaterialBatches.map(\.id))
        refresh()
        let referenced = Set(WorkbenchStore.shared.storedPockets.flatMap(\.entries).compactMap(\.stagedItemID))
        let hasNewUnreferenced = pendingMaterialBatches.contains { batch in
            !before.contains(batch.id) && batch.items.contains { !referenced.contains($0.id) }
        }
        if hasNewUnreferenced { router.request = .workbench }
        if PhotoSelectionSession.shared.loadSharedBatches() > 0 { router.openPhotoSelection() }
    }

    /// 앱이 켜지거나 활성화될 때 남은 배치를 다시 살핀다. 이미지 선별 배치는 사진 선별 화면이 올리고,
    /// 영상 만들기 배치는 작업대의 대기 목록으로 남겨 사용자가 포켓을 고르게 한다.
    func refresh() {
        pendingMaterialBatches = ShareIntentStaging.pendingBatches().filter { $0.intent == .makeVideo }
    }

    /// 사용자가 대기 배치를 명시적으로 버릴 때만 쓴다. 포켓이 참조하는 파일이 있는 배치는 버리지 않는다.
    func discardPending(batchID: UUID) {
        let referenced = WorkbenchStore.shared.storedPockets.flatMap(\.entries).contains { $0.stagedBatchID == batchID }
        if referenced {
            notice = "이 공유 항목은 작업대 포켓이 참조하고 있어 버리지 않았습니다. 포켓에서 먼저 빼 주세요."
            return
        }
        ShareIntentStaging.discardBatch(batchID: batchID)
        refresh()
    }
}
