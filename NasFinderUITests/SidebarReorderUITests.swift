import XCTest

/// iPad 사이드바 "도구" 묶음 안에서 길게 눌러 끌기(held drag)로 순서를 바꾸는 최소 UI 테스트.
///
/// 검증 경계: XCTest는 끌기 도중(hover)의 목록 상태를 읽을 수 없다. 여기서는 제스처가 끝난 뒤의 순서,
/// 선택 경로 유지, 다시 실행한 뒤의 저장 여부만 확인한다. 끌기 중 실시간 이동은 검증하지 않는다.
/// 건드리는 것은 고정 메뉴 ID(사진 전송·저장공간·설정)와 기기 로컬 순서 설정뿐이며, 시작 순서로 되돌린다.
@MainActor
final class SidebarReorderUITests: XCTestCase {
    private let toolIDs = ["사진 전송", "저장공간", "설정"]

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

        // 선택 경로: 설정을 고른 뒤 끌기가 선택을 바꾸지 않아야 한다.
        row(app, "설정").tap()
        XCTAssertTrue(row(app, "설정").isSelected)

        // 첫 행을 마지막 행 위로 끌어 놓는다.
        hold(app, drag: initial[0], onto: initial[2])
        let reordered = order(app)
        XCTAssertNotEqual(reordered, initial, "끌어 놓은 뒤 순서가 바뀌어야 합니다")
        XCTAssertEqual(reordered.last, initial[0])
        XCTAssertTrue(row(app, "설정").isSelected, "순서가 바뀌어도 선택된 경로는 그대로여야 합니다")

        // 저장: 앱을 종료했다가 다시 실행해도 같은 순서.
        app.terminate()
        app = launch(restoringCollapse: true)
        XCTAssertEqual(order(app), reordered, "다시 실행한 뒤에도 순서가 유지되어야 합니다")

        restore(app, to: initial)
        XCTAssertEqual(order(app), initial, "시작 순서로 복원되어야 합니다")
    }

    /// 설정 화면의 세 분류(화면·테마/저장공간·연동/앱 정보)를 차례로 열어 각 분류의 안전한 표시 글자만 확인하고 홈으로 돌아온다.
    /// iPad 넓은 창에서는 분류 내용이 스크롤 없이 들어가므로 스크롤을 요구하지 않는다. 링크·캐시 정리·파일 접근·아이콘 변경 단추는 누르지 않는다.
    func testSettingsPanesNavigateAndShowOwnLabelsThenReturnHome() {
        let app = launch()
        addTeardownBlock { [self] in restoreCollapse(XCUIApplication()) }
        row(app, "설정").tap()

        let panes = ["화면·테마", "저장공간·연동", "앱 정보"]
        for pane in panes {
            XCTAssertTrue(app.buttons[pane].waitForExistence(timeout: 10), "설정 분류가 있어야 합니다: \(pane)")
        }

        app.buttons["화면·테마"].tap()
        XCTAssertTrue(app.staticTexts["테마"].firstMatch.waitForExistence(timeout: 5), "화면·테마 분류 글자가 보여야 합니다")

        app.buttons["저장공간·연동"].tap()
        XCTAssertTrue(app.staticTexts["썸네일 저장공간"].waitForExistence(timeout: 5), "저장공간·연동 분류 글자가 보여야 합니다")

        app.buttons["앱 정보"].tap()
        XCTAssertTrue(app.staticTexts["오픈 소스"].waitForExistence(timeout: 5))
        let creator = app.staticTexts["만든 사람"]
        XCTAssertTrue(creator.exists && creator.isHittable, "앱 정보의 마지막 구역이 스크롤 없이 보여야 합니다")

        app.buttons["화면·테마"].tap()
        let home = app.buttons["홈"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        home.tap()
        XCTAssertFalse(row(app, "설정").isSelected, "홈으로 돌아와야 합니다")
        restoreCollapse(app)
    }
}
