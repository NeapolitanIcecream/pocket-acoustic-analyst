import Foundation

struct SourceInvestigationEvaluator: Sendable {
  var requiredRoundCount = 3
  var maximumOrientationDifferenceDegrees = 10.0
  var maximumTrackedBandSpreadDB = 3.0
  var comparator = BracketedLevelComparator()

  func evaluate(
    subjectName: String,
    baselineStateName: String,
    changedStateName: String,
    plan: SourceFrequencyPlan,
    measurements: [SourceInvestigationMeasurement]
  ) -> SourceInvestigationEvaluation {
    var globalIssues: Set<SourceInvestigationIssue> = []
    let expectedMeasurementCount = requiredRoundCount * 2 + 1
    let expectedStates = (0..<expectedMeasurementCount).map {
      $0.isMultiple(of: 2) ? SourceExperimentState.baseline : .changed
    }
    if measurements.count != expectedMeasurementCount
      || measurements.map(\.state) != expectedStates
      || measurements.map(\.sequenceIndex) != Array(0..<expectedMeasurementCount)
    {
      globalIssues.insert(.incompleteSequence)
    }
    if measurements.contains(where: { !$0.analysis.quality.isUsable }) {
      globalIssues.insert(.lowMeasurementQuality)
    }
    if measurements.contains(where: {
      $0.analysis.quality.issues.contains(.unstableEnvironment)
    }) {
      globalIssues.insert(.unstableEnvironment)
    }
    if let reference = measurements.first?.analysis,
      measurements.contains(where: { !isComparable($0.analysis, to: reference) })
    {
      globalIssues.insert(.routeOrConfigurationChanged)
    }
    evaluatePlacement(
      measurements: measurements,
      targetFrequencyHz: plan.targetBands.map(\.centerFrequencyHz).max(),
      issues: &globalIssues
    )

    let rounds = makeRounds(
      plan: plan,
      measurements: measurements,
      inheritedIssues: globalIssues
    )
    let summaries = makeSummaries(targetBands: plan.targetBands, rounds: rounds)
    if summaries.contains(where: { $0.relationship == .inconclusive && $0.validRoundCount > 0 }) {
      globalIssues.insert(.inconsistentRoundDirection)
    }

    let blockingIssues: Set<SourceInvestigationIssue> = [
      .incompleteSequence,
      .lowMeasurementQuality,
      .unstableEnvironment,
      .routeOrConfigurationChanged,
      .positionMismatch,
      .orientationMismatch,
    ]
    let frequencySpecific = summaries.contains {
      $0.synchronizedRoundCount == requiredRoundCount
        && ($0.relationship == .lowerInChangedState
          || $0.relationship == .higherInChangedState)
    }
    let overallRelationships = rounds.compactMap(overallRelationship)
    let overallSynchronized =
      overallRelationships.count == requiredRoundCount
      && Set(overallRelationships).count == 1
      && overallRelationships.first != .littleChange
      && overallRelationships.first != .inconclusive

    let verdict: SourceInvestigationVerdict
    if !globalIssues.isDisjoint(with: blockingIssues) || rounds.count != requiredRoundCount {
      verdict = .inconclusive
    } else if frequencySpecific {
      verdict = .frequencySpecificSynchronization
    } else if overallSynchronized {
      verdict = .overallLowFrequencySynchronization
    } else if rounds.isEmpty || summaries.allSatisfy({ $0.validRoundCount == 0 }) {
      verdict = .inconclusive
    } else {
      verdict = .noConsistentSynchronization
    }

    return SourceInvestigationEvaluation(
      measuredAt: measurements.last?.analysis.measuredAt ?? .now,
      subjectName: subjectName,
      baselineStateName: baselineStateName,
      changedStateName: changedStateName,
      targetBands: plan.targetBands,
      measurements: measurements,
      rounds: rounds,
      bandSummaries: summaries,
      verdict: verdict,
      confidence: verdict == .inconclusive ? .low : .medium,
      issues: globalIssues.union(rounds.flatMap(\.issues))
    )
  }
}

extension SourceInvestigationEvaluator {
  fileprivate func makeRounds(
    plan: SourceFrequencyPlan,
    measurements: [SourceInvestigationMeasurement],
    inheritedIssues: Set<SourceInvestigationIssue>
  ) -> [SourceInvestigationRound] {
    guard measurements.count >= requiredRoundCount * 2 + 1 else { return [] }
    return (0..<requiredRoundCount).map { roundIndex in
      let before = measurements[roundIndex * 2]
      let changed = measurements[roundIndex * 2 + 1]
      let after = measurements[roundIndex * 2 + 2]
      var roundIssues = inheritedIssues

      let guardSeries = plan.guardBands.compactMap {
        guardBand -> (samples: BracketedLevelSamples, rawDeltaDB: Double)? in
        guard let beforeBand = trackedBand(in: before.analysis, matching: guardBand),
          let changedBand = trackedBand(in: changed.analysis, matching: guardBand),
          let afterBand = trackedBand(in: after.analysis, matching: guardBand),
          guardBandIsStable(beforeBand),
          guardBandIsStable(changedBand),
          guardBandIsStable(afterBand)
        else { return nil }
        let beforeLevel = comparator.aggregateLevel(beforeBand.independentBlockLevelsDB)
        let afterLevel = comparator.aggregateLevel(afterBand.independentBlockLevelsDB)
        guard abs(afterLevel - beforeLevel) <= comparator.maximumBaselineReturnDifferenceDB else {
          return nil
        }
        let samples = BracketedLevelSamples(
          precedingBaseline: beforeBand.independentBlockLevelsDB,
          changed: changedBand.independentBlockLevelsDB,
          followingBaseline: afterBand.independentBlockLevelsDB
        )
        let baselineLevel = comparator.aggregateLevel(
          samples.precedingBaseline + samples.followingBaseline)
        return (
          samples,
          comparator.aggregateLevel(samples.changed) - baselineLevel
        )
      }
      let guardSamples = guardSeries.map(\.samples)
      let guardMedian =
        guardSeries.count >= 3 ? median(guardSeries.map(\.rawDeltaDB)) : nil
      if guardMedian == nil {
        roundIssues.insert(.missingTrackedBand)
      }

      let bandEvidence = plan.targetBands.map { targetBand in
        evaluateTargetBand(
          targetBand,
          before: before.analysis,
          changed: changed.analysis,
          after: after.analysis,
          guardSamples: guardSamples
        )
      }
      roundIssues.formUnion(bandEvidence.flatMap(\.issues))

      let overallComparison = compareOverall(
        before: before.analysis,
        changed: changed.analysis,
        after: after.analysis
      )
      return SourceInvestigationRound(
        roundNumber: roundIndex + 1,
        precedingBaselineMeasurementID: before.id,
        changedMeasurementID: changed.id,
        followingBaselineMeasurementID: after.id,
        bandEvidence: bandEvidence,
        lowFrequencyDeltaDB: overallComparison?.adjustedDeltaDB,
        lowFrequencyRelationship: overallComparison?.relationship,
        guardBandMedianDeltaDB: guardMedian,
        issues: roundIssues
      )
    }
  }

  fileprivate func evaluateTargetBand(
    _ target: SourceFrequencyBand,
    before: AcousticAnalysis,
    changed: AcousticAnalysis,
    after: AcousticAnalysis,
    guardSamples: [BracketedLevelSamples]
  ) -> SourceBandRoundEvidence {
    var issues: Set<SourceInvestigationIssue> = []
    let definition = FrequencyBandDefinition(
      centerFrequencyHz: target.centerFrequencyHz,
      halfWidthHz: target.halfWidthHz
    )
    guard let beforeBand = trackedBand(in: before, matching: definition),
      let changedBand = trackedBand(in: changed, matching: definition),
      let afterBand = trackedBand(in: after, matching: definition)
    else {
      issues.insert(.missingTrackedBand)
      return emptyBandEvidence(target.centerFrequencyHz, issues: issues)
    }
    if !targetIsDetected(in: before, band: beforeBand)
      || !targetIsDetected(in: after, band: afterBand)
    {
      issues.insert(.baselineTargetNotDetected)
    }
    if !guardBandIsStable(beforeBand) || !guardBandIsStable(changedBand)
      || !guardBandIsStable(afterBand)
    {
      issues.insert(.unstableEnvironment)
    }
    if beforeBand.independentBlockLevelsDB.count < comparator.minimumIndependentBlockCount
      || changedBand.independentBlockLevelsDB.count < comparator.minimumIndependentBlockCount
      || afterBand.independentBlockLevelsDB.count < comparator.minimumIndependentBlockCount
    {
      issues.insert(.insufficientIndependentBlocks)
    }
    let beforeLevel = comparator.aggregateLevel(beforeBand.independentBlockLevelsDB)
    let afterLevel = comparator.aggregateLevel(afterBand.independentBlockLevelsDB)
    if abs(afterLevel - beforeLevel) > comparator.maximumBaselineReturnDifferenceDB {
      issues.insert(.baselineDidNotReturn)
    }
    guard
      issues.isDisjoint(with: [
        .baselineTargetNotDetected,
        .unstableEnvironment,
        .insufficientIndependentBlocks,
        .baselineDidNotReturn,
      ]), guardSamples.count >= 3,
      let comparison = comparator.compareFrequencySpecific(
        target: BracketedLevelSamples(
          precedingBaseline: beforeBand.independentBlockLevelsDB,
          changed: changedBand.independentBlockLevelsDB,
          followingBaseline: afterBand.independentBlockLevelsDB
        ),
        guards: guardSamples
      )
    else {
      if guardSamples.count < 3 { issues.insert(.missingTrackedBand) }
      return SourceBandRoundEvidence(
        frequencyHz: target.centerFrequencyHz,
        baselineLevelDB: beforeLevel.isFinite && afterLevel.isFinite
          ? comparator.aggregateLevel([beforeLevel, afterLevel]) : nil,
        changedLevelDB: changedBand.levelDB,
        changedDeltaDB: nil,
        frequencySpecificDeltaDB: nil,
        changedDeltaInterval: nil,
        baselineReturnDifferenceDB: afterLevel.isFinite && beforeLevel.isFinite
          ? afterLevel - beforeLevel : nil,
        relationship: .inconclusive,
        issues: issues
      )
    }

    return SourceBandRoundEvidence(
      frequencyHz: target.centerFrequencyHz,
      baselineLevelDB: comparison.baselineLevelDB,
      changedLevelDB: comparison.changedLevelDB,
      changedDeltaDB: comparison.rawDeltaDB,
      frequencySpecificDeltaDB: comparison.adjustedDeltaDB,
      changedDeltaInterval: comparison.adjustedInterval,
      baselineReturnDifferenceDB: comparison.baselineReturnDifferenceDB,
      relationship: comparison.relationship,
      issues: issues
    )
  }

  fileprivate func makeSummaries(
    targetBands: [SourceFrequencyBand],
    rounds: [SourceInvestigationRound]
  ) -> [SourceBandSummary] {
    targetBands.map { target in
      let evidence = rounds.compactMap { round in
        round.bandEvidence.first { abs($0.frequencyHz - target.centerFrequencyHz) < 0.01 }
      }
      let valid = evidence.filter { $0.relationship != .inconclusive }
      let significant = valid.filter {
        $0.relationship == .lowerInChangedState || $0.relationship == .higherInChangedState
      }
      let relationship: SourceBandRelationship
      if significant.count == requiredRoundCount,
        Set(significant.map(\.relationship)).count == 1
      {
        relationship = significant[0].relationship
      } else if valid.count == requiredRoundCount,
        valid.allSatisfy({ $0.relationship == .littleChange })
      {
        relationship = .littleChange
      } else {
        relationship = .inconclusive
      }
      let deltas = valid.compactMap(\.frequencySpecificDeltaDB)
      return SourceBandSummary(
        frequencyHz: target.centerFrequencyHz,
        relationship: relationship,
        meanChangedDeltaDB: deltas.isEmpty
          ? nil : deltas.reduce(0, +) / Double(deltas.count),
        synchronizedRoundCount: significant.count,
        validRoundCount: valid.count,
        roundDeltasDB: deltas
      )
    }
  }

  fileprivate func compareOverall(
    before: AcousticAnalysis,
    changed: AcousticAnalysis,
    after: AcousticAnalysis
  ) -> BracketedLevelComparison? {
    guard let beforeBlocks = before.lowFrequencyIndependentBlockLevelsDB,
      let changedBlocks = changed.lowFrequencyIndependentBlockLevelsDB,
      let afterBlocks = after.lowFrequencyIndependentBlockLevelsDB
    else { return nil }
    return comparator.compare(
      precedingBaseline: beforeBlocks,
      changed: changedBlocks,
      followingBaseline: afterBlocks
    )
  }

  fileprivate func overallRelationship(_ round: SourceInvestigationRound)
    -> SourceBandRelationship?
  {
    round.lowFrequencyRelationship
  }

  fileprivate func trackedBand(
    in analysis: AcousticAnalysis,
    matching definition: FrequencyBandDefinition
  ) -> LockedBandAnalysis? {
    analysis.trackedBands?.first {
      abs($0.centerFrequencyHz - definition.centerFrequencyHz) < 0.01
        && abs($0.halfWidthHz - definition.halfWidthHz) < 0.01
    }
  }

  fileprivate func targetIsDetected(
    in analysis: AcousticAnalysis,
    band: LockedBandAnalysis
  ) -> Bool {
    let components = analysis.spectralComponents ?? []
    return components.contains { component in
      component.persistence >= analysis.configuration.minimumTonePersistence
        && component.frequencySpreadHz <= analysis.configuration.stableFrequencySpreadHz
        && component.prominenceDB >= analysis.configuration.minimumToneProminenceDB
        && band.contains(
          frequencyHz: component.frequencyHz,
          nominalFrequencyResolutionHz: analysis.nominalFrequencyResolutionHz
        )
    }
  }

  fileprivate func guardBandIsStable(_ band: LockedBandAnalysis) -> Bool {
    band.levelSpreadDB <= maximumTrackedBandSpreadDB
      && band.independentBlockLevelsDB.count >= comparator.minimumIndependentBlockCount
  }

  fileprivate func evaluatePlacement(
    measurements: [SourceInvestigationMeasurement],
    targetFrequencyHz: Double?,
    issues: inout Set<SourceInvestigationIssue>
  ) {
    guard let first = measurements.first else {
      issues.insert(.positionMismatch)
      return
    }
    if let origin = first.position, origin.source == .arkit {
      let positions = measurements.compactMap(\.position)
      guard positions.count == measurements.count,
        positions.allSatisfy({
          $0.source == .arkit
            && $0.trackingEpoch != nil
            && $0.trackingEpoch == origin.trackingEpoch
        })
      else {
        issues.insert(.positionMismatch)
        return
      }
      let tolerance = AcousticPositionTolerance.maximumMeters(for: targetFrequencyHz)
      if positions.contains(where: {
        origin.coordinate.distance(to: $0.coordinate) > tolerance
      }) {
        issues.insert(.positionMismatch)
      }
      if positions.contains(where: {
        origin.orientation.angularDistanceDegrees(to: $0.orientation)
          > maximumOrientationDifferenceDegrees
      }) {
        issues.insert(.orientationMismatch)
      }
    } else if measurements.allSatisfy({
      $0.position == nil && $0.positionConfirmedByUser
    }) {
      issues.insert(.positionUserConfirmedOnly)
    } else {
      issues.insert(.positionMismatch)
    }
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

  fileprivate func emptyBandEvidence(
    _ frequencyHz: Double,
    issues: Set<SourceInvestigationIssue>
  ) -> SourceBandRoundEvidence {
    SourceBandRoundEvidence(
      frequencyHz: frequencyHz,
      baselineLevelDB: nil,
      changedLevelDB: nil,
      changedDeltaDB: nil,
      frequencySpecificDeltaDB: nil,
      changedDeltaInterval: nil,
      baselineReturnDifferenceDB: nil,
      relationship: .inconclusive,
      issues: issues
    )
  }

  fileprivate func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    return sorted.count.isMultiple(of: 2)
      ? (sorted[middle - 1] + sorted[middle]) / 2
      : sorted[middle]
  }
}
