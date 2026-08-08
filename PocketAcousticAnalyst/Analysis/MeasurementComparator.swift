import Foundation

struct MeasurementComparator: Sendable {
  var bootstrapIterationCount = 10_000
  var minimumIndependentBlockCount = 6
  var maximumPositionDifferenceMeters = AcousticPositionTolerance.hardMaximumMeters
  var maximumOrientationDifferenceDegrees = 10.0

  func compare(before: ComparisonMeasurement, after: ComparisonMeasurement) -> MeasurementComparison
  {
    let beforeAnalysis = before.analysis
    let afterAnalysis = after.analysis
    var issues: Set<ComparisonIssue> = []

    if !beforeAnalysis.quality.isUsable || !afterAnalysis.quality.isUsable {
      issues.insert(.lowMeasurementQuality)
    }
    if beforeAnalysis.quality.issues.contains(.unstableEnvironment)
      || afterAnalysis.quality.issues.contains(.unstableEnvironment)
    {
      issues.insert(.unstableEnvironment)
    }
    let durationRatio =
      max(beforeAnalysis.durationSeconds, afterAnalysis.durationSeconds)
      / max(0.001, min(beforeAnalysis.durationSeconds, afterAnalysis.durationSeconds))
    if durationRatio > 1.2 {
      issues.insert(.durationMismatch)
    }
    if !isComparable(beforeAnalysis, afterAnalysis) {
      issues.insert(.routeOrConfigurationChanged)
    }

    let targetFrequency = beforeAnalysis.lockedBand?.centerFrequencyHz
    let beforeTargetIsStable =
      beforeAnalysis.tone?.isStable == true
      && beforeAnalysis.tone?.confidence != .low
      && targetFrequency != nil
      && beforeAnalysis.lockedBand?.contains(
        frequencyHz: beforeAnalysis.tone?.frequencyHz ?? .infinity,
        nominalFrequencyResolutionHz: beforeAnalysis.nominalFrequencyResolutionHz
      ) == true
    let afterTargetIsDetected =
      afterAnalysis.tone?.isStable == true
      && afterAnalysis.tone?.confidence != .low
      && afterAnalysis.lockedBand?.contains(
        frequencyHz: afterAnalysis.tone?.frequencyHz ?? .infinity,
        nominalFrequencyResolutionHz: afterAnalysis.nominalFrequencyResolutionHz
      ) == true
    let afterHasShiftedStableTone =
      afterAnalysis.tone?.isStable == true
      && afterAnalysis.tone?.confidence != .low
      && afterAnalysis.lockedBand?.contains(
        frequencyHz: afterAnalysis.tone?.frequencyHz ?? .infinity,
        nominalFrequencyResolutionHz: afterAnalysis.nominalFrequencyResolutionHz
      ) != true
    if !beforeTargetIsStable || afterHasShiftedStableTone {
      issues.insert(.targetFrequencyChanged)
    }
    if !afterTargetIsDetected {
      issues.insert(.targetNotDetectedAfter)
    }

    let beforeBlocks = beforeAnalysis.lockedBand?.independentBlockLevelsDB ?? []
    let afterBlocks = afterAnalysis.lockedBand?.independentBlockLevelsDB ?? []
    if beforeBlocks.count < minimumIndependentBlockCount
      || afterBlocks.count < minimumIndependentBlockCount
    {
      issues.insert(.insufficientIndependentBlocks)
    }
    evaluatePlacement(
      before: before,
      after: after,
      targetFrequencyHz: targetFrequency,
      issues: &issues
    )
    if !issues.contains(.positionMismatch), !issues.contains(.orientationMismatch) {
      // Even a small accepted repositioning error can create a large relative
      // change near a room-mode null. A single phone cannot verify that this
      // spatial sensitivity did not contribute to the before/after delta.
      issues.insert(.positionSensitiveMeasurement)
    }

    let blockingIssues: Set<ComparisonIssue> = [
      .targetFrequencyChanged,
      .lowMeasurementQuality,
      .unstableEnvironment,
      .durationMismatch,
      .positionMismatch,
      .orientationMismatch,
      .routeOrConfigurationChanged,
      .insufficientIndependentBlocks,
    ]

    var targetDelta: Double?
    var interval: ConfidenceInterval?
    var verdict: ComparisonVerdict = .inconclusive
    if issues.isDisjoint(with: blockingIssues) {
      let estimate = aggregateLevel(afterBlocks) - aggregateLevel(beforeBlocks)
      let bootstrapped = bootstrapDifference(before: beforeBlocks, after: afterBlocks)
      targetDelta = estimate
      interval = bootstrapped
      if estimate <= -3, bootstrapped.upperDB <= -1 {
        verdict = .improved
      } else if estimate >= 3, bootstrapped.lowerDB >= 1 {
        verdict = .worsened
      } else if abs(estimate) < 3,
        bootstrapped.lowerDB >= -3,
        bootstrapped.upperDB <= 3
      {
        verdict = .littleChange
      }
    }

    let confidence: AnalysisConfidence
    if verdict == .inconclusive {
      confidence = .low
    } else if !issues.contains(.positionUserConfirmedOnly),
      !issues.contains(.positionSensitiveMeasurement),
      !issues.contains(.targetNotDetectedAfter),
      let interval,
      interval.upperDB - interval.lowerDB <= 2
    {
      confidence = .high
    } else {
      confidence = .medium
    }

    return MeasurementComparison(
      beforeID: beforeAnalysis.id,
      afterID: afterAnalysis.id,
      verdict: verdict,
      targetFrequencyHz: targetFrequency,
      targetDeltaDB: targetDelta,
      targetDeltaInterval: interval,
      lowFrequencyDeltaDB: afterAnalysis.lowFrequencyLevelDB - beforeAnalysis.lowFrequencyLevelDB,
      confidence: confidence,
      issues: issues
    )
  }
}

extension MeasurementComparator {
  fileprivate func isComparable(_ lhs: AcousticAnalysis, _ rhs: AcousticAnalysis) -> Bool {
    guard
      let lhsCenter = lhs.lockedBand?.centerFrequencyHz,
      let rhsCenter = rhs.lockedBand?.centerFrequencyHz,
      let lhsHalfWidth = lhs.lockedBand?.halfWidthHz,
      let rhsHalfWidth = rhs.lockedBand?.halfWidthHz
    else {
      return false
    }
    return lhs.inputRouteID == rhs.inputRouteID
      && lhs.inputChannelCount == rhs.inputChannelCount
      && lhs.selectedInputChannelIndex == rhs.selectedInputChannelIndex
      && abs(lhs.sampleRate - rhs.sampleRate) < 0.5
      && lhs.analysisVersion == rhs.analysisVersion
      && lhs.configuration == rhs.configuration
      && lhs.windowSampleCount == rhs.windowSampleCount
      && abs(lhsCenter - rhsCenter) < 0.01
      && abs(lhsHalfWidth - rhsHalfWidth) < 0.01
  }

  fileprivate func evaluatePlacement(
    before: ComparisonMeasurement,
    after: ComparisonMeasurement,
    targetFrequencyHz: Double?,
    issues: inout Set<ComparisonIssue>
  ) {
    if let beforePosition = before.position,
      let afterPosition = after.position,
      beforePosition.source == .arkit,
      afterPosition.source == .arkit,
      beforePosition.trackingEpoch != nil,
      beforePosition.trackingEpoch == afterPosition.trackingEpoch
    {
      if beforePosition.coordinate.distance(to: afterPosition.coordinate)
        > min(
          maximumPositionDifferenceMeters,
          AcousticPositionTolerance.maximumMeters(for: targetFrequencyHz)
        )
      {
        issues.insert(.positionMismatch)
      }
      if beforePosition.orientation.angularDistanceDegrees(to: afterPosition.orientation)
        > maximumOrientationDifferenceDegrees
      {
        issues.insert(.orientationMismatch)
      }
    } else if before.positionConfirmedByUser, after.positionConfirmedByUser {
      issues.insert(.positionUserConfirmedOnly)
    } else {
      issues.insert(.positionMismatch)
    }
  }

  fileprivate func aggregateLevel(_ levelsDB: [Double]) -> Double {
    let meanPower = levelsDB.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(levelsDB.count)
    return 10 * log10(max(meanPower, 1e-16))
  }

  fileprivate func bootstrapDifference(before: [Double], after: [Double]) -> ConfidenceInterval {
    var random = ComparisonRandomNumberGenerator(seed: 0xAC0A_571C)
    var differences = [Double]()
    differences.reserveCapacity(bootstrapIterationCount)
    for _ in 0..<bootstrapIterationCount {
      let beforeSample = (0..<before.count).map { _ in
        before[Int(random.next() % UInt64(before.count))]
      }
      let afterSample = (0..<after.count).map { _ in
        after[Int(random.next() % UInt64(after.count))]
      }
      differences.append(aggregateLevel(afterSample) - aggregateLevel(beforeSample))
    }
    differences.sort()
    let lowerIndex = min(differences.count - 1, Int(Double(differences.count - 1) * 0.05))
    let upperIndex = min(differences.count - 1, Int(Double(differences.count - 1) * 0.95))
    return ConfidenceInterval(
      lowerDB: differences[lowerIndex],
      upperDB: differences[upperIndex],
      probability: 0.9
    )
  }
}

private struct ComparisonRandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}
