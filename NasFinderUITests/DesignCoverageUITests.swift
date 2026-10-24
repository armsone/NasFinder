import XCTest

/// iOS Simulator 전용 화면 커버리지 캡처. 합성/빈 상태만 열고 개인 사진 보관함·계정·네트워크 로그인은 건드리지 않는다.
/// 스크린샷은 호스트 경로 `NF_SHOT_DIR`(기본 /tmp/nasfinder-design-consistency-20261022/shots/ios)에 PNG로 쓴다.
/// 어떤 단계가 실패해도 다음 단계로 계속하고, 찾지 못한 요소는 `missing-*.png`와 로그로 남긴다.
@MainActor
final class DesignCoverageUITests: XCTestCase {
    private var tag = ""
    private var directory = URL(fileURLWithPath: "/tmp/nasfinder-design-consistency-20261022/shots/ios")
    private var counter = 0
    private var log: [String] = []

    override func setUp() {
        continueAfterFailure = true
    }

    private var isPad: Bool { UIDevice.current.userInterfaceIdiom == .pad }

    private func makeApp(theme: String? = nil, size: String? = nil, tag: String) -> XCUIApplication {
        self.tag = tag
        counter = 0
        let base = ProcessInfo.processInfo.environment["NF_SHOT_DIR"] ?? "/tmp/nasfinder-design-consistency-20261022/shots/ios"
        directory = URL(fileURLWithPath: base).appendingPathComponent(tag)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        if let theme { app.launchArguments += ["-app.theme.preference.v1", theme] }
        if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 25)
        sleep(2)
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        counter += 1
        let file = directory.appendingPathComponent(String(format: "%02d-%@.png", counter, name))
        let png = XCUIScreen.main.screenshot().pngRepresentation
        try? png.write(to: file)
        log.append("shot \(file.lastPathComponent)")
    }

    private func finish() {
        let file = directory.appendingPathComponent("_log.txt")
        try? log.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// 비싼 `.any` 질의를 피하고 흔한 요소 종류만 순서대로 본다(전체 접근성 트리 조회는 한 번에 30초 넘게 걸린다).
    private func find(_ app: XCUIApplication, _ text: String) -> XCUIElement? {
        for query in [app.buttons, app.cells, app.staticTexts, app.otherElements] {
            let element = query[text].firstMatch // 같은 이름이 여러 개(탭·행)여도 첫 일치만 쓴다.
            if element.exists { return element }
        }
        let loose = NSPredicate(format: "label CONTAINS %@", text)
        for query in [app.buttons, app.cells, app.staticTexts] {
            let element = query.matching(loose).firstMatch
            if element.exists { return element }
        }
        return nil
    }

    @discardableResult
    private func tap(_ app: XCUIApplication, _ text: String, wait: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(wait)
        var found: XCUIElement?
        repeat {
            found = find(app, text)
            if found != nil { break }
            usleep(500_000)
        } while Date() < deadline
        guard let element = found else {
            shot(app, "missing-" + text)
            log.append("MISSING \(text)")
            return false
        }
        element.tap()
        sleep(1)
        return true
    }

    private func back(_ app: XCUIApplication) {
        let bar = app.navigationBars.buttons.firstMatch
        if bar.exists, bar.isHittable { bar.tap(); sleep(1); return }
        let chevron = app.buttons["뒤로"]
        if chevron.exists { chevron.tap(); sleep(1) }
    }

    /// 화면이 무거워지면 접근성 질의가 매우 느려진다. 경로마다 앱을 새로 띄우고, 무거운 화면에 들어간 뒤에는 질의 없이 촬영만 한다.
    private func visit(_ app: inout XCUIApplication!, _ name: String, root: String?, steps: [String], theme: String? = nil, size: String? = nil) {
        app?.terminate()
        app = XCUIApplication()
        if let theme { app.launchArguments += ["-app.theme.preference.v1", theme] }
        if let size { app.launchArguments += ["-UIPreferredContentSizeCategoryName", size] }
        app.launch()
        _ = app.wait(for: .runningForeground, timeout: 25)
        sleep(2)
        if let root { openRoot(app, root) }
        for step in steps { _ = tap(app, step) }
        sleep(1)
        shot(app, name)
    }

    private func configure(_ tag: String) {
        self.tag = tag
        counter = 0
        let base = ProcessInfo.processInfo.environment["NF_SHOT_DIR"] ?? "/tmp/nasfinder-design-consistency-20261022/shots/ios"
        directory = URL(fileURLWithPath: base).appendingPathComponent(tag)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var variant: String { ProcessInfo.processInfo.environment["NF_VARIANT"] ?? "base" }
    private var theme: String? { ProcessInfo.processInfo.environment["NF_THEME"] }
    private var size: String? { ProcessInfo.processInfo.environment["NF_SIZE"] }

    /// 아이폰은 아래 막대, 넓은 창은 사이드바에서 루트를 연다.
    private func openRoot(_ app: XCUIApplication, _ name: String) {
        if isPad {
            let map = ["홈": "홈", "작업대": "작업대", "파인더": "즐겨찾기", "영상": "영상 제작", "도구": "미디어 전송"]
            _ = tap(app, map[name] ?? name)
        } else {
            _ = tap(app, name)
        }
    }

    func testRoots() {
        configure("roots-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "home", root: nil, steps: [], theme: theme, size: size)
        for root in ["작업대", "파인더", "영상", "도구"] {
            visit(&app, "root-" + root, root: root, steps: [], theme: theme, size: size)
        }
        visit(&app, "video-drafts", root: "영상", steps: ["편집본"], theme: theme, size: size)
        visit(&app, "video-collections", root: "영상", steps: ["컬렉션"], theme: theme, size: size)
        finish()
    }

    func testTools() {
        configure("tools-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "transfer", root: "도구", steps: ["미디어 전송"], theme: theme, size: size)
        visit(&app, "transfer-send", root: "도구", steps: ["미디어 전송", "보내기"], theme: theme, size: size)
        visit(&app, "selection", root: "도구", steps: ["사진 선별"], theme: theme, size: size)
        visit(&app, "settings", root: "도구", steps: ["설정"], theme: theme, size: size)
        app.swipeUp(); shot(app, "settings-2")
        app.swipeUp(); shot(app, "settings-3")
        app.swipeUp(); shot(app, "settings-4")
        if isPad { visit(&app, "storage", root: "도구", steps: ["저장공간"], theme: theme, size: size) }
        finish()
    }

    func testFinderSources() {
        configure("finder-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        for (name, step) in [("phonehard", "폰하드"), ("favorites", "즐겨찾기"), ("browser", "브라우저"), ("device-files", "기기 파일"), ("google-photos", "Google 포토")] {
            visit(&app, name, root: "파인더", steps: [step], theme: theme, size: size)
        }
        visit(&app, "add-network-dialog", root: "파인더", steps: ["네트워크 추가"], theme: theme, size: size)
        finish()
    }

    /// 팝오버 항목은 접근성 질의가 느려 화면 비율 좌표(아이폰 기준 NAS·서버 항목)로 연다.
    func testAddConnection() {
        configure("addconn-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "popover", root: "파인더", steps: ["네트워크 추가"], theme: theme, size: size)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: isPad ? 0.5 : 0.904)).tap()
        sleep(2)
        shot(app, "add-connection")
        app.swipeUp(); shot(app, "add-connection-2")
        finish()
    }

    func testMyMedia() {
        configure("mymedia-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "my-media", root: "파인더", steps: ["내 미디어"], theme: theme, size: size)
        finish()
    }

    func testVideoPicker() {
        configure("videopick-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "picker-media", root: "영상", steps: ["미디어 고르기"], theme: theme, size: size)
        if !isPad {
            // 탭 막대 좌표(질의 없이): 헤더 아래 첫 줄
            let tabs: [(String, CGFloat)] = [("calendar", 0.25), ("phonehard", 0.40), ("favorites", 0.58), ("nas", 0.82)]
            for (name, x) in tabs {
                app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.146)).tap()
                sleep(2)
                shot(app, "picker-" + name)
            }
            app.swipeLeft(); sleep(1)
            for (name, x) in [("files", 0.45), ("google", 0.75)] {
                app.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.146)).tap()
                sleep(2)
                shot(app, "picker-" + name)
            }
        }
        finish()
    }

    func testWorkbenchEmpty() {
        configure("workbench-\(isPad ? "ipad" : "iphone")-\(variant)")
        var app: XCUIApplication!
        visit(&app, "workbench-root", root: "작업대", steps: [], theme: theme, size: size)
        finish()
    }

    /// 질의 없이 환경변수 NF_STEPS(`;` 구분)를 순서대로 실행한다: `tap:x,y`(화면 비율) · `type`(NF_PAYLOAD 입력) · `wait:초` · `swipe`(위로) · `shot:이름`.
    /// 접근성 질의가 한 번에 30초 넘게 걸리는 Simulator 화면에서 정상 UI 경로를 좌표로만 밟기 위한 것이다. 코드 값은 기록하지 않는다.
    func testSteps() {
        configure("steps-\(isPad ? "ipad" : "iphone")-\(variant)")
        let app = XCUIApplication()
        log.append("attach=\(ProcessInfo.processInfo.environment["NF_ATTACH"] ?? "unset") stateBefore=\(app.state.rawValue)")
        // NF_ATTACH=1: 이미 실행 중인 앱(예: 받기 대기 화면)을 끄지 않고 앞으로만 가져온다.
        if ProcessInfo.processInfo.environment["NF_ATTACH"] == "1" { app.activate() } else { app.launch() }
        _ = app.wait(for: .runningForeground, timeout: 25)
        sleep(2)
        let steps = (ProcessInfo.processInfo.environment["NF_STEPS"] ?? "shot:start").split(separator: ";").map(String.init)
        for step in steps {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            let arg = parts.count > 1 ? parts[1] : ""
            switch parts[0] {
            case "tap":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                if xy.count == 2 { app.coordinate(withNormalizedOffset: CGVector(dx: xy[0], dy: xy[1])).tap() }
                sleep(2)
            case "tapName":
                // 메뉴·확인창의 정확한 버튼 이름으로 누른다. 없으면 후속 조작을 멈춘다.
                let button = app.buttons[arg].firstMatch
                guard button.waitForExistence(timeout: 4) else {
                    log.append("MISSING BUTTON \(arg)")
                    shot(app, "missing-button")
                    finish()
                    XCTFail("Expected button missing: \(arg)")
                    return
                }
                button.tap()
                sleep(1)
            case "press":
                // `press:x,y,초` — 화면 비율 좌표를 길게 눌러 시스템 편집 메뉴(붙여넣기)를 연다.
                let v = arg.split(separator: ",").compactMap { Double($0) }
                if v.count == 3 { app.coordinate(withNormalizedOffset: CGVector(dx: v[0], dy: v[1])).press(forDuration: v[2]) }
                sleep(1)
            case "drag":
                // `drag:x1,y1,x2,y2,누름초,끝에서머문초` — 화면 비율 좌표에서 누른 채 끌어 옮긴다(메뉴 행 순서 바꾸기 확인용).
                let v = arg.split(separator: ",").compactMap { Double($0) }
                if v.count == 6 {
                    let from = app.coordinate(withNormalizedOffset: CGVector(dx: v[0], dy: v[1]))
                    let to = app.coordinate(withNormalizedOffset: CGVector(dx: v[2], dy: v[3]))
                    from.press(forDuration: v[4], thenDragTo: to, withVelocity: .slow, thenHoldForDuration: v[5])
                }
                sleep(1)
            case "type":
                app.typeText(ProcessInfo.processInfo.environment["NF_PAYLOAD"] ?? "")
                sleep(1)
            case "wait": sleep(UInt32(Int(arg) ?? 1))
            case "swipe": app.swipeUp(); sleep(1)
            case "rotate":
                // `rotate:landscape` / `rotate:portrait` — 시뮬레이터 기기 방향만 바꾼다(끝날 때 portrait로 복원 권장).
                XCUIDevice.shared.orientation = arg == "landscape" ? .landscapeLeft : .portrait
                sleep(2)
            case "shot": shot(app, arg)
            default: log.append("UNKNOWN \(step)")
            }
        }
        finish()
    }
}
