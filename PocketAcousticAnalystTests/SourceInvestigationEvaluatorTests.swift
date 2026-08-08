import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct SourceInvestigationEvaluatorTests {
  @Test func threeBracketedRoundsFindOnlyThe216HzSpecificReduction() throws {
    let analyses = Self.sequence { index in
      Self.analysis(
        level54DB: -20,
        level216DB: index.isMultiple(of: 2) ? -20 : -26
      )
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.twoTargetPlan)
    let summary54 = try #require(result.bandSummaries.first { $0.frequencyHz == 54 })
    let summary216 = try #require(result.bandSummaries.first { $0.frequencyHz == 216 })

    #expect(result.verdict == .frequencySpecificSynchronization)
    #expect(summary54.relationship == .littleChange)
    #expect(summary54.synchronizedRoundCount == 0)
    #expect(summary216.relationship == .lowerInChangedState)
    #expect(summary216.synchronizedRoundCount == 3)
    #expect(try #require(summary216.meanChangedDeltaDB) < -5.5)
    #expect(result.strongestSynchronizedBand?.frequencyHz == 216)
  }

  @Test func inconsistentRoundDirectionsDoNotProduceSynchronization() throws {
    let changedLevels = [-26.0, -14.0, -26.0]
    let analyses = Self.sequence { index in
      let level = index.isMultiple(of: 2) ? -20 : changedLevels[index / 2]
      return Self.analysis(level216DB: level)
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)
    let summary = try #require(result.bandSummaries.only)

    #expect(result.verdict == .noConsistentSynchronization)
    #expect(summary.relationship == .inconclusive)
    #expect(summary.synchronizedRoundCount == 3)
    #expect(result.issues.contains(.inconsistentRoundDirection))
  }

  @Test func baselineClosureOverTwoDecibelsInvalidatesAffectedRounds() throws {
    let baselineLevels = [-20.0, -16.0, -16.0, -16.0]
    let analyses = Self.sequence { index in
      if index.isMultiple(of: 2) {
        return Self.analysis(level216DB: baselineLevels[index / 2])
      }
      let precedingBaseline = baselineLevels[index / 2]
      return Self.analysis(level216DB: precedingBaseline - 6)
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)
    let firstRound = try #require(result.rounds.first)
    let firstEvidence = try #require(firstRound.bandEvidence.only)

    #expect(firstEvidence.relationship == .inconclusive)
    #expect(firstEvidence.changedDeltaDB == nil)
    #expect(abs(try #require(firstEvidence.baselineReturnDifferenceDB) - 4) < 0.001)
    #expect(firstEvidence.issues.contains(.baselineDidNotReturn))
    #expect(result.verdict != .frequencySpecificSynchronization)
  }

  @Test func globalGainChangeProducesOnlyOverallSynchronization() throws {
    let analyses = Self.sequence { index in
      let delta = index.isMultiple(of: 2) ? 0.0 : -6.0
      return Self.analysis(
        level54DB: -20 + delta,
        level216DB: -20 + delta,
        guardLevelDB: -40 + delta,
        lowFrequencyLevelDB: -10 + delta
      )
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.twoTargetPlan)

    #expect(result.verdict == .overallLowFrequencySynchronization)
    #expect(result.bandSummaries.allSatisfy { $0.relationship == .littleChange })
    #expect(
      result.rounds.allSatisfy {
        abs(($0.guardBandMedianDeltaDB ?? .infinity) + 6) < 0.01
      })
    #expect(
      result.rounds.allSatisfy {
        $0.bandEvidence.allSatisfy { abs($0.frequencySpecificDeltaDB ?? .infinity) < 0.01 }
      })
  }

  @Test func guardBandChangeCannotInventAnUnchangedTargetEffect() throws {
    let analyses = Self.sequence { index in
      Self.analysis(
        level216DB: -20,
        guardLevelDB: index.isMultiple(of: 2) ? -40 : -36
      )
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)
    let summary = try #require(result.bandSummaries.only)

    #expect(result.verdict == .noConsistentSynchronization)
    #expect(summary.relationship == .littleChange)
    #expect(summary.synchronizedRoundCount == 0)
    #expect(
      result.rounds.allSatisfy {
        $0.bandEvidence.allSatisfy {
          abs($0.changedDeltaDB ?? .infinity) < 0.01
            && $0.relationship == .littleChange
        }
      })
  }

  @Test func uncertainGuardAdjustmentCannotCreateFrequencySpecificConfidence() throws {
    let uncertainGuardBlocks = [-40.0, -40, -40, -40, -40, -32]
    let analyses = Self.sequence { index in
      Self.analysis(
        level216DB: index.isMultiple(of: 2) ? -20 : -23.1,
        guardBlockLevelsDB: uncertainGuardBlocks,
        guardLevelSpreadDB: 2.99
      )
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)
    let summary = try #require(result.bandSummaries.only)

    #expect(result.verdict != .frequencySpecificSynchronization)
    #expect(summary.relationship == .inconclusive)
    #expect(
      result.rounds.allSatisfy {
        $0.bandEvidence.allSatisfy {
          $0.relationship == .inconclusive
            && ($0.changedDeltaInterval?.upperDB ?? -.infinity) > -1
        }
      })
  }

  @Test func overallPointEstimateWithoutIntervalSupportDoesNotSynchronize() {
    var analyses = Self.sequence { _ in Self.analysis() }
    for index in analyses.indices where !index.isMultiple(of: 2) {
      analyses[index].lowFrequencyIndependentBlockLevelsDB = [-10, -10, -10, -10, -10, 0]
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)

    #expect(result.rounds.allSatisfy { abs($0.lowFrequencyDeltaDB ?? 0) >= 3 })
    #expect(result.rounds.allSatisfy { $0.lowFrequencyRelationship == .inconclusive })
    #expect(result.rounds.allSatisfy { !$0.overallEvidenceText.contains("dB") })
    #expect(result.verdict == .noConsistentSynchronization)
  }

  @Test func sequenceIndicesMustMatchTheAlternatingCaptureOrder() {
    let analyses = Self.sequence { index in
      Self.analysis(level216DB: index.isMultiple(of: 2) ? -20 : -26)
    }
    var measurements = Self.measurements(from: analyses)
    measurements[3].sequenceIndex = 5

    let result = SourceInvestigationEvaluator().evaluate(
      subjectName: "游戏暂停",
      baselineStateName: "游戏运行",
      changedStateName: "游戏暂停",
      plan: Self.singleTargetPlan,
      measurements: measurements
    )

    #expect(result.verdict == .inconclusive)
    #expect(result.issues.contains(.incompleteSequence))
  }

  @Test func routeChangeMakesTheWholeInvestigationIncomparable() {
    var analyses = Self.sequence { index in
      Self.analysis(level216DB: index.isMultiple(of: 2) ? -20 : -26)
    }
    analyses[3].inputRouteID = "usb-mic"

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)

    #expect(result.verdict == .inconclusive)
    #expect(result.issues.contains(.routeOrConfigurationChanged))
    #expect(result.strongestSynchronizedBand == nil)
  }

  @Test func missingPeakInChangedStateStillUsesTheLockedBand() throws {
    let analyses = Self.sequence { index in
      Self.analysis(
        level216DB: index.isMultiple(of: 2) ? -20 : -26,
        detectedFrequencies: index.isMultiple(of: 2) ? [216] : []
      )
    }

    let result = Self.evaluate(analyses: analyses, plan: Self.singleTargetPlan)
    let summary = try #require(result.bandSummaries.only)

    #expect(result.verdict == .frequencySpecificSynchronization)
    #expect(summary.relationship == .lowerInChangedState)
    #expect(summary.synchronizedRoundCount == 3)
    #expect(
      result.rounds.allSatisfy {
        $0.bandEvidence.allSatisfy {
          $0.relationship == .lowerInChangedState
            && !$0.issues.contains(.baselineTargetNotDetected)
        }
      })
  }
}

extension SourceInvestigationEvaluatorTests {
  fileprivate static let target54 = SourceFrequencyBand(
    centerFrequencyHz: 54,
    halfWidthHz: 1,
    memberFrequenciesHz: [54],
    containsUnresolvedComponents: false
  )
  fileprivate static let target216 = SourceFrequencyBand(
    centerFrequencyHz: 216,
    halfWidthHz: 1,
    memberFrequenciesHz: [216],
    containsUnresolvedComponents: false
  )
  fileprivate static let guards = [20.0, 300.0, 460.0].map {
    FrequencyBandDefinition(centerFrequencyHz: $0, halfWidthHz: 10)
  }
  fileprivate static let singleTargetPlan = SourceFrequencyPlan(
    targetBands: [target216],
    guardBands: guards
  )
  fileprivate static let twoTargetPlan = SourceFrequencyPlan(
    targetBands: [target54, target216],
    guardBands: guards
  )

  fileprivate static func sequence(
    makeAnalysis: (Int) -> AcousticAnalysis
  ) -> [AcousticAnalysis] {
    (0..<7).map(makeAnalysis)
  }

  fileprivate static func evaluate(
    analyses: [AcousticAnalysis],
    plan: SourceFrequencyPlan
  ) -> SourceInvestigationEvaluation {
    let measurements = measurements(from: analyses)
    return SourceInvestigationEvaluator().evaluate(
      subjectName: "游戏暂停",
      baselineStateName: "游戏运行",
      changedStateName: "游戏暂停",
      plan: plan,
      measurements: measurements
    )
  }

  fileprivate static func measurements(
    from analyses: [AcousticAnalysis]
  ) -> [SourceInvestigationMeasurement] {
    analyses.enumerated().map { index, analysis in
      SourceInvestigationMeasurement(
        sequenceIndex: index,
        state: index.isMultiple(of: 2) ? .baseline : .changed,
        analysis: analysis,
        position: nil,
        positionConfirmedByUser: true
      )
    }
  }

  fileprivate static func analysis(
    level54DB: Double = -20,
    level216DB: Double = -20,
    guardLevelDB: Double = -40,
    guardBlockLevelsDB: [Double]? = nil,
    guardLevelSpreadDB: Double = 0.1,
    lowFrequencyLevelDB: Double = -10,
    detectedFrequencies: Set<Double> = [54, 216],
    inputRouteID: String = "built-in-mic"
  ) -> AcousticAnalysis {
    let targetDefinitions = [
      FrequencyBandDefinition(centerFrequencyHz: 54, halfWidthHz: 1),
      FrequencyBandDefinition(centerFrequencyHz: 216, halfWidthHz: 1),
    ]
    let levels = [54.0: level54DB, 216.0: level216DB]
    let targetBands = targetDefinitions.map { definition in
      Self.lockedBand(definition, levelDB: levels[definition.centerFrequencyHz] ?? -20)
    }
    let guardBands = guards.map {
      Self.lockedBand(
        $0,
        levelDB: guardLevelDB,
        blockLevelsDB: guardBlockLevelsDB,
        levelSpreadDB: guardLevelSpreadDB
      )
    }

    return AcousticAnalysis(
      durationSeconds: 20,
      sampleRate: 48_000,
      inputRouteID: inputRouteID,
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: 0.366_210_937_5,
      nominalFrequencyResolutionHz: 0.732_421_875,
      lowFrequencyLevelDB: lowFrequencyLevelDB,
      lowFrequencyIndependentBlockLevelsDB: Self.blocks(around: lowFrequencyLevelDB),
      spectrum: [],
      spectrogramFrequenciesHz: [],
      spectrogram: [],
      tone: nil,
      spectralComponents: detectedFrequencies.sorted().map {
        SpectralComponentEvidence(
          frequencyHz: $0,
          levelDB: levels[$0] ?? -20,
          prominenceDB: 16,
          persistence: 1,
          frequencySpreadHz: 0.05
        )
      },
      trackedBands: targetBands + guardBands,
      quality: MeasurementQuality(score: 1)
    )
  }

  fileprivate static func lockedBand(
    _ definition: FrequencyBandDefinition,
    levelDB: Double,
    blockLevelsDB: [Double]? = nil,
    levelSpreadDB: Double = 0.1
  ) -> LockedBandAnalysis {
    LockedBandAnalysis(
      centerFrequencyHz: definition.centerFrequencyHz,
      halfWidthHz: definition.halfWidthHz,
      levelDB: levelDB,
      independentBlockLevelsDB: blockLevelsDB ?? blocks(around: levelDB),
      levelSpreadDB: levelSpreadDB
    )
  }

  fileprivate static func blocks(around levelDB: Double) -> [Double] {
    [levelDB, levelDB - 0.1, levelDB + 0.1, levelDB, levelDB - 0.1, levelDB + 0.1]
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
