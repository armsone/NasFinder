import Foundation
import os

/// 프라이버시 모드: 잠금이 아닌 **추가형 가시성**. 일반 모드는 공개 기록만, 프라이버시 모드는 공개 + 비공개를 함께 보여 준다.
/// 모드는 RAM에만 있다(저장 안 함 → 콜드 스타트는 항상 일반 모드). 자동 해제 타이머·PIN·생체·암호화 없음.
/// 숨김은 이 앱 화면의 표시 단계뿐이며 NAS·클라우드·기기 원본이나 OS 캐시를 보호하지 않는다.
/// 필터는 읽기 투영(`visible…`)에서만 쓰고, 저장·삭제·이동·정리는 항상 전체(raw) 목록을 대상으로 한다.
/// 백그라운드 작업도 읽을 수 있도록 상태는 잠금으로 보호한 스냅샷이고, `@Published` 값은 화면 갱신용 미러다.
struct PrivacySnapshot: Sendable {
    var isActive = false
    var privateConnectionIDs: Set<UUID> = []
    var phoneHard = PrivateScope(records: [])
}

@MainActor
final class PrivacyMode: ObservableObject {
    static let shared = PrivacyMode()

    @Published private(set) var isActive = false
    /// 모드가 바뀔 때마다 늘어난다. 앱 셸이 화면 트리를 새로 만들어 열린 시트·선택·탐색 스택을 비운다.
    @Published private(set) var epoch = 0

    nonisolated static let didChangeNotification = Notification.Name("NasFinder.privacyModeDidChange")
    private nonisolated static let state = OSAllocatedUnfairLock(initialState: PrivacySnapshot())

    private init() {}

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        Self.state.withLock { $0.isActive = active }
        isActive = active
        epoch += 1
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    func toggle() { setActive(!isActive) }

    func setPrivateConnectionIDs(_ ids: Set<UUID>) { Self.state.withLock { $0.privateConnectionIDs = ids } }
    func setPrivatePhoneHard(_ scope: PrivateScope) { Self.state.withLock { $0.phoneHard = scope } }

    /// 새 기록의 기본값: 프라이버시 모드에서 만들면 비공개, 일반 모드에서는 플래그 없음(nil).
    var newRecordFlag: Bool? { isActive ? true : nil }

    // MARK: 어느 스레드에서나 읽는 판정

    nonisolated static var currentlyActive: Bool { state.withLock { $0.isActive } }

    /// 비공개 플래그가 없으면(nil) 공개다.
    nonisolated static func isVisible(_ isPrivate: Bool?) -> Bool { currentlyActive || isPrivate != true }

    /// 이 연결·경로가 비공개 출처인지(모드와 무관). 산출물 origin 고정에 쓴다.
    nonisolated static func isPrivateOrigin(connectionID: UUID, path: String? = nil) -> Bool {
        state.withLock { snapshot in
            if snapshot.privateConnectionIDs.contains(connectionID) { return true }
            guard connectionID == LocalInboxFileService.connectionID, let path else { return false }
            let relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if let id = UUID(uuidString: relative), snapshot.phoneHard.ids.contains(id) { return true }
            return snapshot.phoneHard.contains(storedFilename: relative)
        }
    }

    /// 이 연결·경로를 지금 목록에서 숨겨야 하는지. 프라이버시 모드에서는 숨기지 않는다.
    nonisolated static func hides(connectionID: UUID, path: String? = nil) -> Bool {
        !currentlyActive && isPrivateOrigin(connectionID: connectionID, path: path)
    }

    /// 폰하드 저장 경로가 비공개(자기 플래그 또는 상위 폴더)인지. 앱 모드와 무관하다.
    /// 로컬 웹하드 같은 앱 밖 표면은 앱 모드를 모르므로 항상 일반 모드 기준으로 이 판정을 쓴다.
    nonisolated static func isPhoneHardStoredPathPrivate(_ storedFilename: String) -> Bool {
        state.withLock { $0.phoneHard.contains(storedFilename: storedFilename) }
    }

    /// 새 작업을 시작하는 순간 한 번 잡아 Job에 저장한다(이후 모드가 바뀌어도 쓰기 대상이 바뀌지 않는다).
    nonisolated static func capturedOrigin(inputPrivate: Bool = false) -> Bool { currentlyActive || inputPrivate }

    // MARK: 문구
    static let brandName = "Privacy"
    static let honestNote = "이 앱의 목록에서만 숨깁니다. 잠금이나 암호화가 아니며, NAS·클라우드·기기 원본과 다른 앱·OS 캐시는 바뀌지 않습니다."
}
