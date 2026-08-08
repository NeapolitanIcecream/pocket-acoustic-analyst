import XCTest

@MainActor
final class LaunchTests: XCTestCase {
    func testHomeStartsWithAProblemInsteadOfAnInstrument() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoMode"]
        app.launch()

        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startHumInvestigation"].exists)
        XCTAssertFalse(app.staticTexts["FFT"].exists)
    }

    func testDemoCompletesGuidedHumMeasurement() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoMode"]
        app.launch()

        let start = app.buttons["startHumInvestigation"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        start.tap()

        let permission = app.buttons["requestMicrophonePermission"]
        XCTAssertTrue(permission.waitForExistence(timeout: 5))
        permission.tap()

        let measure = app.buttons["startMeasurement"]
        XCTAssertTrue(measure.waitForExistence(timeout: 5))
        measure.tap()

        XCTAssertTrue(app.staticTexts["检测到持续低频声音"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["startSpatialScan"].exists)
        XCTAssertFalse(app.staticTexts["这次测量不能使用"].exists)
    }

    func testDemoCompletesMeasuredPointScanWithOriginClosure() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoMode"]
        app.launch()

        tap(app.buttons["startHumInvestigation"], in: app)
        tap(app.buttons["requestMicrophonePermission"], in: app)
        tap(app.buttons["startMeasurement"], in: app)
        XCTAssertTrue(app.staticTexts["检测到持续低频声音"].waitForExistence(timeout: 20))
        tap(app.buttons["startSpatialScan"], in: app)

        tap(app.buttons["startPositionTracking"], in: app)
        for pointNumber in 1 ... 3 {
            let capture = app.buttons["captureSpatialPoint"]
            XCTAssertTrue(capture.waitForExistence(timeout: 8))
            capture.tap()
            let savedLabel = pointNumber == 1 ? "当前位置" : "实测点 \(pointNumber)"
            XCTAssertTrue(app.staticTexts[savedLabel].waitForExistence(timeout: 10))
        }

        tap(app.buttons["finishSpatialPoints"], in: app)
        tap(app.buttons["captureOriginClosure"], in: app)

        XCTAssertTrue(app.staticTexts["发现影响较小的实测位置"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["这次扫描不能比较位置"].exists)
    }

    func testDemoCompletesBeforeAfterValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoMode"]
        app.launch()

        tap(app.buttons["startBeforeAfter"], in: app)
        tap(app.buttons["prepareBeforeAfter"], in: app)
        tap(app.buttons["captureBefore"], in: app)
        XCTAssertTrue(app.staticTexts["调整前已记录"].waitForExistence(timeout: 15))

        tap(app.buttons["changeCompleted"], in: app)
        tap(app.buttons["captureAfter"], in: app)

        XCTAssertTrue(app.staticTexts["变化小于当前判断门槛"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["两次测量不能可靠比较"].exists)
    }

    private func tap(_ element: XCUIElement, in app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        for _ in 0 ..< 4 where !element.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
        element.tap()
    }
}
