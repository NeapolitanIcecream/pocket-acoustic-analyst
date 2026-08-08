import Foundation

struct SpatialScanEvaluator: Sendable {
  var minimumMeasuredPointCount = 3
  var minimumRecommendationImprovementDB = 3.0
  var maximumOriginTargetDifferenceDB = 2.0
  var maximumOriginDistanceMeters = AcousticPositionTolerance.hardMaximumMeters
  var maximumHeightDifferenceMeters = AcousticPositionTolerance.hardMaximumMeters
  var maximumOrientationDifferenceDegrees = 10.0

  func evaluate(
    measurements: [SpatialMeasurement],
    originChecks: [SpatialMeasurement],
    closure: SpatialMeasurement
  ) -> SpatialScanEvaluation {
    let targetFrequency = measurements.first?.targetFrequencyHz ?? closure.targetFrequencyHz
    let allOriginChecks = originChecks + [closure]
    let allMeasurements = measurements + allOriginChecks
    var issues: Set<SpatialScanIssue> = []

    if measurements.count < minimumMeasuredPointCount {
      issues.insert(.insufficientMeasuredPoints)
    }
    if allOriginChecks.count != max(0, measurements.count - 1) {
      issues.insert(.missingAdjacentOriginChecks)
    }
    if allMeasurements.contains(where: {
      !$0.analysis.quality.isUsable
        || !$0.position.quality.isUsable
        || $0.analysis.lockedBand == nil
        || ($0.analysis.lockedBand?.levelSpreadDB ?? .infinity)
          > $0.analysis.configuration.stableLevelSpreadDB
    }) {
      issues.insert(.lowMeasurementQuality)
    }

    if allMeasurements.contains(where: {
      abs($0.targetFrequencyHz - targetFrequency) > frequencyTolerance(for: $0.analysis)
        || abs(($0.analysis.lockedBand?.centerFrequencyHz ?? .infinity) - targetFrequency) > 0.01
        || abs(
          ($0.analysis.lockedBand?.halfWidthHz ?? .infinity) - $0.targetBandHalfWidthHz
        ) > 0.01
    }) {
      issues.insert(.targetFrequencyChanged)
    }
    if allMeasurements.contains(where: { measurement in
      guard let tone = measurement.analysis.tone,
        tone.isStable,
        tone.confidence != .low
      else { return false }
      return measurement.analysis.lockedBand?.contains(
        frequencyHz: tone.frequencyHz,
        nominalFrequencyResolutionHz: measurement.analysis.nominalFrequencyResolutionHz
      ) != true
    }) {
      issues.insert(.targetFrequencyChanged)
    }

    if let reference = measurements.first,
      allMeasurements.contains(where: { !isComparable($0.analysis, to: reference.analysis) })
    {
      issues.insert(.routeOrConfigurationChanged)
    }

    if let origin = measurements.first {
      let continuityMeasurements = [origin] + allOriginChecks
      if continuityMeasurements.contains(where: { !targetIsDetected(in: $0) }) {
        issues.insert(.targetFrequencyChanged)
      }

      let originSequence = [origin] + allOriginChecks
      if zip(originSequence, originSequence.dropFirst()).contains(where: { before, after in
        abs(before.targetLevelDB - after.targetLevelDB) > maximumOriginTargetDifferenceDB
      }) {
        issues.insert(.originSoundDidNotClose)
      }

      if origin.position.source == .arkit {
        if allMeasurements.contains(where: {
          $0.position.source != .arkit
            || origin.position.trackingEpoch == nil
            || origin.position.trackingEpoch != $0.position.trackingEpoch
        }) {
          issues.insert(.trackingEpochChanged)
        }
        let positionTolerance = spatialPositionToleranceMeters(for: targetFrequency)
        if allOriginChecks.contains(where: {
          origin.position.coordinate.distance(to: $0.position.coordinate) > positionTolerance
        }) {
          issues.insert(.originPositionDidNotClose)
        }
        let heightTolerance = min(
          maximumHeightDifferenceMeters,
          spatialPositionToleranceMeters(for: targetFrequency)
        )
        if allMeasurements.contains(where: {
          abs($0.position.coordinate.y - origin.position.coordinate.y) > heightTolerance
        }) {
          issues.insert(.measurementHeightChanged)
        }
        if allMeasurements.contains(where: {
          origin.position.orientation.angularDistanceDegrees(to: $0.position.orientation)
            > maximumOrientationDifferenceDegrees
        }) {
          issues.insert(.measurementOrientationChanged)
        }
      } else if allMeasurements.contains(where: { $0.position.source != .guidedManual }) {
        issues.insert(.trackingEpochChanged)
      }
    }

    let pointComparisons = makePointComparisons(
      measurements: measurements,
      originChecks: allOriginChecks
    )
    var recommendation: QuietPointRecommendation?
    let blockingIssues: Set<SpatialScanIssue> = [
      .insufficientMeasuredPoints,
      .lowMeasurementQuality,
      .targetFrequencyChanged,
      .routeOrConfigurationChanged,
      .trackingEpochChanged,
      .measurementHeightChanged,
      .measurementOrientationChanged,
      .missingAdjacentOriginChecks,
      .lowestPointTargetNotDetected,
      .originPositionDidNotClose,
      .originSoundDidNotClose,
    ]
    if issues.isDisjoint(with: blockingIssues),
      let origin = measurements.first,
      let quietestComparison = pointComparisons.min(by: {
        $0.targetDeltaDB < $1.targetDeltaDB
      }),
      let quietest = measurements.first(where: {
        $0.id == quietestComparison.measurementID
      })
    {
      let improvement = -quietestComparison.targetDeltaDB
      if improvement < minimumRecommendationImprovementDB {
        issues.insert(.improvementTooSmall)
      } else if !targetIsDetected(in: quietest) {
        issues.insert(.lowestPointTargetNotDetected)
      } else {
        let hasDistance = origin.position.source == .arkit && quietest.position.source == .arkit
        recommendation = QuietPointRecommendation(
          currentMeasurementID: origin.id,
          recommendedMeasurementID: quietest.id,
          targetFrequencyHz: targetFrequency,
          improvementDB: improvement,
          distanceMeters: hasDistance
            ? origin.position.coordinate.distance(to: quietest.position.coordinate)
            : nil,
          confidence: .medium
        )
      }
    }

    return SpatialScanEvaluation(
      targetFrequencyHz: targetFrequency,
      measurements: measurements,
      originChecks: originChecks,
      closureMeasurement: closure,
      pointComparisons: pointComparisons,
      recommendation: recommendation,
      issues: issues
    )
  }
}

extension SpatialScanEvaluator {
  fileprivate func makePointComparisons(
    measurements: [SpatialMeasurement],
    originChecks: [SpatialMeasurement]
  ) -> [SpatialPointComparison] {
    guard let origin = measurements.first,
      originChecks.count == max(0, measurements.count - 1)
    else { return [] }

    return measurements.dropFirst().enumerated().map { index, candidate in
      let precedingOrigin = index == 0 ? origin : originChecks[index - 1]
      let followingOrigin = originChecks[index]
      let targetReference = aggregateLevel([
        precedingOrigin.targetLevelDB, followingOrigin.targetLevelDB,
      ])
      let lowFrequencyReference = aggregateLevel([
        precedingOrigin.analysis.lowFrequencyLevelDB,
        followingOrigin.analysis.lowFrequencyLevelDB,
      ])
      return SpatialPointComparison(
        measurementID: candidate.id,
        precedingOriginCheckID: precedingOrigin.id,
        followingOriginCheckID: followingOrigin.id,
        targetDeltaDB: candidate.targetLevelDB - targetReference,
        lowFrequencyDeltaDB: candidate.analysis.lowFrequencyLevelDB - lowFrequencyReference
      )
    }
  }

  fileprivate func aggregateLevel(_ levelsDB: [Double]) -> Double {
    let meanPower = levelsDB.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(levelsDB.count)
    return 10 * log10(max(meanPower, 1e-16))
  }

  fileprivate func spatialPositionToleranceMeters(for targetFrequencyHz: Double) -> Double {
    min(
      maximumOriginDistanceMeters,
      AcousticPositionTolerance.maximumMeters(for: targetFrequencyHz)
    )
  }

  fileprivate func frequencyTolerance(for analysis: AcousticAnalysis) -> Double {
    max(1, analysis.nominalFrequencyResolutionHz)
  }

  fileprivate func targetIsDetected(in measurement: SpatialMeasurement) -> Bool {
    measurement.analysis.tone?.isStable == true
      && measurement.analysis.tone?.confidence != .low
      && measurement.analysis.lockedBand?.contains(
        frequencyHz: measurement.analysis.tone?.frequencyHz ?? .infinity,
        nominalFrequencyResolutionHz: measurement.analysis.nominalFrequencyResolutionHz
      ) == true
  }

  fileprivate func isComparable(_ analysis: AcousticAnalysis, to reference: AcousticAnalysis)
    -> Bool
  {
    analysis.inputRouteID == reference.inputRouteID
      && analysis.inputChannelCount == reference.inputChannelCount
      && analysis.selectedInputChannelIndex == reference.selectedInputChannelIndex
      && abs(analysis.sampleRate - reference.sampleRate) < 0.5
      && analysis.analysisVersion == reference.analysisVersion
      && analysis.configuration == reference.configuration
      && analysis.windowSampleCount == reference.windowSampleCount
  }
}
