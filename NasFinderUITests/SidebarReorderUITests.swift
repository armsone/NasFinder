import XCTest

/// iPad 사이드바 "도구" 묶음 안에서 길게 눌러 끌기(held drag)로 순서를 바꾸는 최소 UI 테스트.
///
/// 검증 경계: XCTest는 끌기 도중(hover)의 목록 상태를 읽을 수 없다. 여기서는 제스처가 끝난 뒤의 순서,
/// 선택 경로 유지, 다시 실행한 뒤의 저장 여부만 확인한다. 끌기 중 실시간 이동은 검증하지 않는다.
/// 건드리는 것은 고정 메뉴 ID(사진 선별·사진 전송(화면 표시 미디어 전송)·수퍼 썸네일·썸네일 캐시)와 기기 로컬 순서 설정뿐이며, 시작 순서로 되돌린다.
@MainActor
final class SidebarReorderUITests: XCTestCase {
    private let toolIDs = ["사진 선별", "사진 전송", "수퍼 썸네일", "썸네일 캐시"]

    override func setUp() {
        continueAfterFailure = false
    }

    /// 고정 ID로 좁게 찾는다. 단추로 노출되면 단추 질의만, 아니면 기타 요소 질의로 내려가 전체 트리 스냅숏을 피한다.
    private func row(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        let button = app.buttons["sidebar.tools.\(id)"]
        return button.exists ? button : app.otherElements["sidebar.tools.\(id)"].firstMatch
    }

    private func order(_ app: XCUIApplication) -> [String] {
        toolIDs.sorted { row(app, $0).frame.minY < row(app, $1).frame.minY }
    }

    private func hold(_ app: XCUIApplication, drag source: String, onto target: String) {
        let from = row(app, source).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = row(app, target).coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        from.press(forDuration: 1.0, thenDragTo: to, withVelocity: .slow, thenHoldForDuration: 0.5)
    }

    /// 시작 때 사이드바가 접혀 있었는지. 접혀 있으면 행이 접근성 트리에 없으므로 먼저 펼치고, 끝에서 원래대로 접는다.
    private var startedCollapsed = false

    private func launch(restoringCollapse: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launch()
        let expand = app.buttons["사이드바 펼치기"]
        if expand.waitForExistence(timeout: 5) {
            if !restoringCollapse { startedCollapsed = true }
            expand.tap()
        }
        // 활성 루트만 펼쳐지므로 도구 루트를 먼저 눌러 행을 보이게 한다.
        if !app.buttons["sidebar.tools.\(toolIDs[0])"].waitForExistence(timeout: 3) {
            let toolsRoot = app.buttons["도구"].firstMatch
            if toolsRoot.waitForExistence(timeout: 10) { toolsRoot.tap() }
        }
        for id in toolIDs {
            XCTAssertTrue(app.buttons["sidebar.tools.\(id)"].waitForExistence(timeout: 15)
                          || app.otherElements["sidebar.tools.\(id)"].waitForExistence(timeout: 2),
                          "iPad 가로/넓은 창 사이드바에 도구 묶음 행이 있어야 합니다: \(id)")
        }
        return app
    }

    /// 테스트 전에 접혀 있던 사이드바를 다시 접는다.
    private func restoreCollapse(_ app: XCUIApplication) {
        guard startedCollapsed else { return }
        let collapse = app.buttons["사이드바 접기"]
        if collapse.exists { collapse.tap() }
        startedCollapsed = false
    }

    /// 시작 순서와 같아질 때까지 첫 불일치 자리에 해당 행을 끌어다 놓는다.
    private func restore(_ app: XCUIApplication, to initial: [String]) {
        for _ in 0..<3 {
            let current = order(app)
            guard let index = zip(initial, current).enumerated().first(where: { $1.0 != $1.1 })?.offset else { return }
            hold(app, drag: initial[index], onto: current[index])
        }
    }

    func testToolsGroupHeldDragReordersKeepsSelectionAndPersists() {
        var app = launch()
        let initial = order(app)
        addTeardownBlock { [self] in
            let current = XCUIApplication()
            guard current.state == .runningForeground else { return }
            restore(current, to: initial)
            restoreCollapse(current)
        }

        // 선택 경로: 썸네일 캐시를 고른 뒤 끌기가 선택을 바꾸지 않아야 한다.
        row(app, "썸네일 캐시").tap()
        XCTAssertTrue(row(app, "썸네일 캐시").isSelected)

        // 첫 행을 마지막 행 위로 끌어 놓는다.
        hold(app, drag: initial[0], onto: initial[3])
        let reordered = order(app)
        XCTAssertNotEqual(reordered, initial, "끌어 놓은 뒤 순서가 바뀌어야 합니다")
        XCTAssertEqual(reordered.last, initial[0])
        XCTAssertTrue(row(app, "썸네일 캐시").isSelected, "순서가 바뀌어도 선택된 경로는 그대로여야 합니다")

        // 저장: 앱을 종료했다가 다시 실행해도 같은 순서.
        app.terminate()
        app = launch(restoringCollapse: true)
        XCTAssertEqual(order(app), reordered, "다시 실행한 뒤에도 순서가 유지되어야 합니다")

        restore(app, to: initial)
        XCTAssertEqual(order(app), initial, "시작 순서로 복원되어야 합니다")
    }

    /// 독립 설정 루트의 여섯 구역을 제한된 스크롤로 훑으며 보이는 순서를 확인하고 홈으로 돌아온다.
    /// 구역 제목(표시 글자)만 읽고, 캐시 정리·개인정보·테마·아이콘 변경 단추는 누르지 않는다.
    func testSettingsSectionsAppearInOrderThenReturnHome() {
        let app = launch()
        addTeardownBlock { [self] in restoreCollapse(XCUIApplication()) }
        let settingsRoot = app.buttons["설정"].firstMatch
        XCTAssertTrue(settingsRoot.waitForExistence(timeout: 10), "설정 루트가 있어야 합니다")
        settingsRoot.tap()

        let sections = ["저장공간·캐시", "화면 켜짐", "앱 아이콘", "프라이버시", "화면·테마", "앱 정보·업데이트"]
        XCTAssertTrue(app.staticTexts[sections[0]].firstMatch.waitForExistence(timeout: 10), "첫 설정 구역이 보여야 합니다: \(sections[0])")

        var seen: [String] = []
        for _ in 0..<8 {
            let visible = sections
                .filter { !seen.contains($0) }
                .map { ($0, app.staticTexts[$0].firstMatch) }
                .filter { $0.1.exists && $0.1.isHittable }
                .sorted { $0.1.frame.minY < $1.1.frame.minY }
            seen += visible.map(\.0)
            if seen.count == sections.count { break }
            app.swipeUp()
        }
        XCTAssertEqual(seen, sections, "설정 여섯 구역이 정해진 순서로 보여야 합니다")

        let home = app.buttons["홈"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertFalse(app.staticTexts[sections[0]].firstMatch.isHittable, "홈으로 돌아와야 합니다")
        restoreCollapse(app)
    }
}
