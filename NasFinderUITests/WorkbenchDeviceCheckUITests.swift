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
}
