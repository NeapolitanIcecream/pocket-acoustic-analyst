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
    for pointNumber in 1...3 {
      let capture = app.buttons["captureSpatialPoint"]
      XCTAssertTrue(capture.waitForExistence(timeout: 8))
      capture.tap()
      if pointNumber > 1 {
        tap(app.buttons["captureOriginClosure"], in: app)
      }
    }

    tap(app.buttons["finishSpatialPoints"], in: app)

    XCTAssertTrue(app.staticTexts["发现目标声音较低的实测位置"].waitForExistence(timeout: 15))
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

  #if !targetEnvironment(simulator)
    func testRealDeviceCompletesAmbientAudioCapture() {
      let app = XCUIApplication()
      app.launchArguments = ["-uiTesting"]
      addUIInterruptionMonitor(withDescription: "System permissions") { alert in
        for label in ["允许", "Allow", "允许在使用 App 时", "Allow While Using App"] {
          let button = alert.buttons[label]
          if button.exists {
            button.tap()
            return true
          }
        }
        return false
      }
      app.launch()

      tap(app.buttons["startHumInvestigation"], in: app)
      tap(app.buttons["requestMicrophonePermission"], in: app)
      tap(app.buttons["startMeasurement"], in: app)

      let finalResult = app.staticTexts.matching(
        NSPredicate(
          format: "label IN %@",
          ["检测到持续低频声音", "这次没有找到持续音调", "这次测量不能使用"]
        )
      ).firstMatch
      XCTAssertTrue(finalResult.waitForExistence(timeout: 45))

      let resultAttachment = XCTAttachment(screenshot: app.screenshot())
      resultAttachment.name = "Real device ambient capture result"
      resultAttachment.lifetime = .keepAlways
      add(resultAttachment)

      if app.staticTexts["这次测量不能使用"].exists {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTFail("Real-device capture was invalid: \(labels)")
        return
      }

      let details = app.buttons["查看测量依据"]
      XCTAssertTrue(details.waitForExistence(timeout: 5))
      details.tap()
      let sampleRate = app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "实际采样率：")
      ).firstMatch
      let microphone = app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "麦克风：")
      ).firstMatch
      let channels = app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "输入通道：")
      ).firstMatch
      XCTAssertTrue(sampleRate.waitForExistence(timeout: 5))
      XCTAssertTrue(microphone.exists)
      XCTAssertTrue(channels.exists)

      let metadataAttachment = XCTAttachment(
        string: [sampleRate.label, microphone.label, channels.label].joined(separator: "\n")
      )
      metadataAttachment.name = "Real device capture metadata"
      metadataAttachment.lifetime = .keepAlways
      add(metadataAttachment)
    }

    func testRealDeviceCapturesARTrackedOrigin() {
      let app = XCUIApplication()
      app.launchArguments = ["-uiTesting", "-realPoseTest"]
      addUIInterruptionMonitor(withDescription: "System permissions") { alert in
        for label in ["允许", "Allow", "允许在使用 App 时", "Allow While Using App"] {
          let button = alert.buttons[label]
          if button.exists {
            button.tap()
            return true
          }
        }
        return false
      }
      app.launch()

      tap(app.buttons["startHumInvestigation"], in: app)
      tap(app.buttons["requestMicrophonePermission"], in: app)
      tap(app.buttons["startMeasurement"], in: app)
      let detected = app.staticTexts["检测到持续低频声音"]
      if !detected.waitForExistence(timeout: 45) {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        XCTFail("Deterministic AR reference capture did not produce a stable tone: \(labels)")
        return
      }

      tap(app.buttons["startSpatialScan"], in: app)
      tap(app.buttons["startPositionTracking"], in: app)
      let captureOrigin = app.buttons["captureSpatialPoint"]
      if !captureOrigin.waitForExistence(timeout: 3) {
        app.tap()
      }
      XCTAssertTrue(captureOrigin.waitForExistence(timeout: 15))
      captureOrigin.tap()
      XCTAssertTrue(app.staticTexts["正在测量，请保持手机不动"].waitForExistence(timeout: 5))

      let accepted = app.staticTexts["移动到下一个位置"]
      let rejected = app.staticTexts["这个点没有加入比较"]
      let originOutcome = app.staticTexts.matching(
        NSPredicate(format: "label IN %@", ["移动到下一个位置", "这个点没有加入比较"])
      ).firstMatch
      XCTAssertTrue(originOutcome.waitForExistence(timeout: 45))

      let attachment = XCTAttachment(screenshot: app.screenshot())
      attachment.name = "Real device AR-tracked origin"
      attachment.lifetime = .keepAlways
      add(attachment)

      if rejected.exists {
        let labels = app.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " | ")
        let diagnostic = XCTAttachment(string: labels)
        diagnostic.name = "Rejected AR origin diagnostic"
        diagnostic.lifetime = .keepAlways
        add(diagnostic)
        XCTFail(
          "AR initialized and recorded the origin, but the measurement was rejected: \(labels)")
        return
      }

      XCTAssertTrue(accepted.exists)
    }
  #endif

  private func tap(_ element: XCUIElement, in app: XCUIApplication) {
    XCTAssertTrue(element.waitForExistence(timeout: 8))
    for _ in 0..<4 where !element.isHittable {
      app.swipeUp()
    }
    XCTAssertTrue(element.isHittable)
    element.tap()
  }
}
