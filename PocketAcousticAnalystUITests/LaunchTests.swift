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

  func testIntermittentDemoExplainsTheEvidenceAndOpensHistoryDetails() {
    let app = XCUIApplication()
    app.launchArguments = ["-uiTesting", "-demoMode", "-intermittentDemo"]
    app.launch()

    tap(app.buttons["startHumInvestigation"], in: app)
    tap(app.buttons["requestMicrophonePermission"], in: app)
    tap(app.buttons["startMeasurement"], in: app)

    XCTAssertTrue(app.staticTexts["检测到间歇出现的低频音调"].waitForExistence(timeout: 20))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "时段出现")
      ).firstMatch.exists)
    XCTAssertFalse(app.buttons["startSpatialScan"].exists)
    XCTAssertTrue(app.staticTexts["为什么暂时不能比较位置"].exists)
    XCTAssertTrue(app.staticTexts["只在部分时段检测到候选音调"].exists)

    let back = app.navigationBars.buttons.firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    tap(app.buttons["historyButton"], in: app)
    let record = app.staticTexts["检测到间歇出现的低频音调"]
    XCTAssertTrue(record.waitForExistence(timeout: 5))
    record.tap()
    XCTAssertTrue(app.staticTexts["候选声音依据"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.staticTexts.matching(
        NSPredicate(format: "label BEGINSWITH %@", "出现时段：")
      ).firstMatch.exists)
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
          [
            "检测到持续低频声音",
            "检测到短暂出现的低频音调",
            "检测到间歇出现的低频音调",
            "检测到频率变化的低频音调",
            "检测到强弱变化明显的低频音调",
            "检测到多个低频音调",
            "低频能量没有集中在单一频率",
            "这次测量不能使用",
          ]
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
      if finalResult.label != "检测到持续低频声音" {
        XCTAssertFalse(app.buttons["startSpatialScan"].exists)
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

      let evidencePrefixes = [
        "声音类型：",
        "候选频率：",
        "出现时段：",
        "频率变化：",
        "强弱离散：",
        "结果可信度：",
      ]
      let evidenceLabels = evidencePrefixes.compactMap { prefix -> String? in
        let element = app.staticTexts.matching(
          NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
        return element.exists ? element.label : nil
      }
      let resultDetailPrefixes = [
        "主要集中在约",
        "主要包括约",
        "候选频率约",
        "主要在约",
        "主要频率约",
        "这次没有可锁定",
      ]
      let resultDetails = resultDetailPrefixes.compactMap { prefix -> String? in
        let element = app.staticTexts.matching(
          NSPredicate(format: "label BEGINSWITH %@", prefix)
        ).firstMatch
        return element.exists ? element.label : nil
      }
      let harmonicEvidence = app.staticTexts.matching(
        NSPredicate(format: "label CONTAINS %@", "倍数频率")
      ).firstMatch
      let additionalEvidence = harmonicEvidence.exists ? [harmonicEvidence.label] : []
      let summary =
        ([finalResult.label, sampleRate.label, microphone.label, channels.label] + evidenceLabels
        + resultDetails + additionalEvidence)
        .joined(separator: "\n")
      let metadataAttachment = XCTAttachment(
        string: summary
      )
      metadataAttachment.name = "Real device ambient analysis summary"
      metadataAttachment.lifetime = .keepAlways
      add(metadataAttachment)
      print("REAL_AMBIENT_ANALYSIS_BEGIN\n\(summary)\nREAL_AMBIENT_ANALYSIS_END")
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
