import XCTest

/// 실기기(iPhone)에서 작업대 포켓 만들기 → 파인더 출처 선택기 → 폰하드 담기 → 참조 확인을 한 번 눈으로 확인하기 위한 좁은 UI 점검.
/// 합성 파일(NF-check-20261022-ios-*)만 건드리며, 만든 포켓 이름은 `pocketName` 하나다. 개인 사진 보관함은 열지 않는다.
@MainActor
final class WorkbenchDeviceCheckUITests: XCTestCase {
    private let pocketName = "NF-check-20261022-iphone"

    override func setUp() {
        continueAfterFailure = false
    }

    private func el(_ app: XCUIApplication, _ text: String) -> XCUIElement {
        let predicate = NSPredicate(format: "label CONTAINS %@ OR identifier CONTAINS %@ OR value CONTAINS %@", text, text, text)
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func dump(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name + ".tree"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func tap(_ app: XCUIApplication, _ text: String, timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        let element = el(app, text)
        if !element.waitForExistence(timeout: timeout) {
            shot(app, "missing-" + text)
            dump(app, "missing-" + text)
            XCTFail("요소를 찾지 못했습니다: \(text)", file: file, line: line)
            return
        }
        element.tap()
    }

    /// 1단계: 작업대 → 포켓 만들기 → 포켓 열기 → + → 파인더에서 담기 → 선택기 화면 캡처.
    func testStep1PocketAndFinderChooser() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        shot(app, "01-launch")
        tap(app, "작업대")
        shot(app, "02-workbench")
        if !app.staticTexts[pocketName].waitForExistence(timeout: 3) {
            tap(app, "새 포켓")
            let field = app.textFields.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            field.tap()
            field.typeText(pocketName)
            shot(app, "03-typed")
            app.alerts.buttons["만들기"].tap()
        }
        XCTAssertTrue(app.staticTexts[pocketName].waitForExistence(timeout: 8))
        shot(app, "04-created")
        app.staticTexts[pocketName].tap()
        sleep(1)
        shot(app, "05-pocket")
        tap(app, "포켓에 담기")
        sleep(1)
        shot(app, "06-addmenu")
        tap(app, "파인더에서 담기")
        sleep(1)
        shot(app, "07-finderchooser")
        dump(app, "07-finderchooser")
        XCTAssertTrue(el(app, "폰하드").exists)
    }

    /// 호스트 마우스 없이 폰에서만 누르는 점검: 이미 설치된 앱을 bundle id로 띄워(재설치·launch 인자 없음) 만들기 → 제목이
    /// 정확히 "QA 폰편집 4AEB9DAD"인 편집본 하나만 열고 → 클립 탭 닫기/열기 → 재생/일시 정지 라벨이 바뀌는지만 본다.
    /// 후보가 정확히 하나가 아니면 아무 편집본도 누르지 않고 멈춘다. 저장·이름 바꾸기·다른 편집본 조작은 없다.
    func testOwnQAEditorPlayPauseMouseFree() {
        let app = XCUIApplication(bundleIdentifier: "com.armsone.nasfinder")
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        sleep(2)
        shot(app, "m01-launch")
        let makeTab = app.buttons["만들기"].firstMatch
        XCTAssertTrue(makeTab.waitForExistence(timeout: 10))
        makeTab.tap()
        sleep(2)
        // 카드 버튼 라벨은 "제목, 길이"다. 같은 제목의 "… 편집 메뉴" 단추는 쉼표가 없어 걸리지 않는다.
        let own = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "QA 폰편집 4AEB9DAD, "))
        var swipes = 0
        while own.count == 0, swipes < 4 { app.swipeUp(); sleep(1); swipes += 1 }
        shot(app, "m02-make")
        print("NF-MOUSEFREE own candidates=\(own.count) swipes=\(swipes)")
        guard own.count == 1 else {
            dump(app, "m02-make")
            XCTFail("자기 QA 편집본 후보가 정확히 하나가 아닙니다: \(own.count)")
            return
        }
        print("NF-MOUSEFREE own label=\(own.element.label)")
        own.element.tap()
        let play = app.buttons["재생"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        sleep(2)
        shot(app, "m03-editor")
        let clipTab = app.buttons.matching(NSPredicate(format: "label == %@", "클립"))
        print("NF-MOUSEFREE clipTab count=\(clipTab.count)")
        if clipTab.count == 1 {
            clipTab.element.tap()
            sleep(1)
            shot(app, "m04-clip-closed")
            clipTab.element.tap()
            sleep(1)
            shot(app, "m05-clip-open")
        }
        app.buttons["재생"].firstMatch.tap()
        let pause = app.buttons["일시 정지"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5), "재생을 눌렀는데 일시 정지 단추로 바뀌지 않았습니다")
        sleep(2)
        shot(app, "m06-playing")
        pause.tap()
        XCTAssertTrue(app.buttons["재생"].firstMatch.waitForExistence(timeout: 5), "일시 정지를 눌렀는데 재생 단추로 돌아오지 않았습니다")
        sleep(1)
        shot(app, "m07-paused")
        print("NF-MOUSEFREE play/pause toggled")
    }
}
