import XCTest

final class LaunchTests: XCTestCase {
    func testHomeStartsWithAProblemInsteadOfAnInstrument() {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting", "-demoMode"]
        app.launch()

        XCTAssertTrue(app.staticTexts["homeTitle"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["startHumInvestigation"].exists)
        XCTAssertFalse(app.staticTexts["FFT"].exists)
    }
}
