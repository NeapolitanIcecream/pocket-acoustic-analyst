import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct MeasurementComparatorTests {
  @Test func reportsImprovementOnlyWhenEstimateAndIntervalClearThresholds() throws {
    let epoch = UUID()
    let before = Self.measurement(
      levels: [-19.9, -20.1, -20, -19.8, -20.2, -20, -20.1], epoch: epoch)
    let after = Self.measurement(
      levels: [-26.1, -25.9, -26, -26.2, -25.8, -26, -26.1], epoch: epoch)

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(try #require(result.targetDeltaDB) < -5.5)
    #expect(try #require(result.targetDeltaInterval).upperDB < -5)
    #expect(result.confidence == .medium)
    #expect(result.issues.contains(.positionSensitiveMeasurement))
  }

  @Test func distinguishesLittleChangeAndWorsening() {
    let epoch = UUID()
    let baseline = Self.measurement(
      levels: [-20, -20.1, -19.9, -20, -20, -20.1, -19.9], epoch: epoch)
    let similar = Self.measurement(
      levels: [-20.5, -20.4, -20.6, -20.5, -20.4, -20.6, -20.5], epoch: epoch)
    let louder = Self.measurement(
      levels: [-14, -14.1, -13.9, -14, -14, -14.1, -13.9], epoch: epoch)

    #expect(
      MeasurementComparator().compare(before: baseline, after: similar).verdict == .littleChange)
    #expect(MeasurementComparator().compare(before: baseline, after: louder).verdict == .worsened)
  }

  @Test func routeChangeMakesComparisonInconclusive() {
    let epoch = UUID()
    let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch, route: "built-in")
    let after = Self.measurement(levels: Self.quieterLevels, epoch: epoch, route: "usb")

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .inconclusive)
    #expect(result.targetDeltaDB == nil)
    #expect(result.issues.contains(ComparisonIssue.routeOrConfigurationChanged))
  }

  @Test func comparisonBandMustStayLocked() {
    let epoch = UUID()
    let before = Self.measurement(
      levels: Self.baselineLevels,
      epoch: epoch,
      comparisonBandCenterFrequencyHz: 53.17
    )
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      comparisonBandCenterFrequencyHz: 54.17
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .inconclusive)
    #expect(result.targetDeltaDB == nil)
    #expect(result.issues.contains(.routeOrConfigurationChanged))
  }

  @Test func missingAfterPeakStillReportsLockedBandReductionWithoutHighConfidence() throws {
    let epoch = UUID()
    let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch)
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      hasTone: false
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(try #require(result.targetDeltaDB) < -5.5)
    #expect(result.issues.contains(.targetNotDetectedAfter))
    #expect(result.confidence == .medium)
  }

  @Test func unrelatedUnstableAfterPeakCannotRaiseLockedBandResultToHighConfidence() {
    let epoch = UUID()
    let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch)
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      toneFrequencyHz: 80,
      toneIsStable: false,
      toneConfidence: .low
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(result.issues.contains(.targetNotDetectedAfter))
    #expect(result.confidence == .medium)
  }

  @Test func trackedPositionMismatchMakesComparisonInconclusive() {
    let epoch = UUID()
    let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch, x: 0)
    let after = Self.measurement(levels: Self.quieterLevels, epoch: epoch, x: 0.3)

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .inconclusive)
    #expect(result.issues.contains(ComparisonIssue.positionMismatch))
  }

  @Test func highFrequencyComparisonUsesWavelengthLimitedPositionTolerance() {
    let epoch = UUID()
    let before = Self.measurement(
      levels: Self.baselineLevels,
      epoch: epoch,
      comparisonBandCenterFrequencyHz: 500,
      toneFrequencyHz: 500
    )
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      x: 0.025,
      comparisonBandCenterFrequencyHz: 500,
      toneFrequencyHz: 500
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .inconclusive)
    #expect(result.issues.contains(.positionMismatch))
  }

  @Test func acceptedTrackedRepositioningStillCapsConfidenceAtMedium() {
    let epoch = UUID()
    let before = Self.measurement(
      levels: Self.baselineLevels,
      epoch: epoch,
      x: 0.005,
      comparisonBandCenterFrequencyHz: 500,
      toneFrequencyHz: 500
    )
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      x: 0.025,
      comparisonBandCenterFrequencyHz: 500,
      toneFrequencyHz: 500
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(result.confidence == .medium)
    #expect(result.issues.contains(.positionSensitiveMeasurement))
  }

  @Test func explicitManualPlacementConfirmationAllowsMediumConfidenceComparison() {
    let before = Self.measurement(levels: Self.baselineLevels, epoch: nil, userConfirmed: true)
    let after = Self.measurement(levels: Self.quieterLevels, epoch: nil, userConfirmed: true)

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(result.confidence == .medium)
    #expect(result.issues.contains(ComparisonIssue.positionUserConfirmedOnly))
  }

  @Test func overlappingWindowCountCannotSubstituteForIndependentBlocks() {
    let epoch = UUID()
    let before = Self.measurement(levels: Array(Self.baselineLevels.prefix(5)), epoch: epoch)
    let after = Self.measurement(levels: Array(Self.quieterLevels.prefix(5)), epoch: epoch)

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .inconclusive)
    #expect(result.issues.contains(ComparisonIssue.insufficientIndependentBlocks))
  }

  @Test func bootstrapIntervalIsDeterministic() {
    let epoch = UUID()
    let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch)
    let after = Self.measurement(levels: Self.quieterLevels, epoch: epoch)
    let comparator = MeasurementComparator()

    let first = comparator.compare(before: before, after: after)
    let second = comparator.compare(before: before, after: after)

    #expect(first.targetDeltaInterval == second.targetDeltaInterval)
    #expect(first.targetDeltaDB == second.targetDeltaDB)
  }

  @Test func targetBandImprovementDoesNotHideOverallLowFrequencyIncrease() {
    let epoch = UUID()
    let before = Self.measurement(
      levels: Self.baselineLevels,
      epoch: epoch,
      overallLevelDB: -18
    )
    let after = Self.measurement(
      levels: Self.quieterLevels,
      epoch: epoch,
      overallLevelDB: -10
    )

    let result = MeasurementComparator().compare(before: before, after: after)

    #expect(result.verdict == .improved)
    #expect(abs(result.lowFrequencyDeltaDB - 8) < 0.001)
  }
}

extension MeasurementComparatorTests {
  fileprivate static let baselineLevels = [-20.1, -19.8, -20, -20.2, -19.9, -20, -20.1]
  fileprivate static let quieterLevels = [-26.1, -25.8, -26, -26.2, -25.9, -26, -26.1]

  fileprivate static func measurement(
    levels: [Double],
    epoch: UUID?,
    route: String = "built-in",
    x: Double = 0,
    userConfirmed: Bool = false,
    comparisonBandCenterFrequencyHz: Double = 53.17,
    hasTone: Bool = true,
    toneFrequencyHz: Double = 53.17,
    toneIsStable: Bool = true,
    toneConfidence: AnalysisConfidence = .high,
    overallLevelDB: Double? = nil
  ) -> ComparisonMeasurement {
    ComparisonMeasurement(
      analysis: analysis(
        levels: levels,
        route: route,
        comparisonBandCenterFrequencyHz: comparisonBandCenterFrequencyHz,
        hasTone: hasTone,
        toneFrequencyHz: toneFrequencyHz,
        toneIsStable: toneIsStable,
        toneConfidence: toneConfidence,
        overallLevelDB: overallLevelDB
      ),
      position: epoch.map { epoch in
        PositionSample(
          coordinate: SpatialCoordinate(x: x, y: 0, z: 0),
          orientation: .identity,
          source: .arkit,
          trackingEpoch: epoch,
          quality: MeasurementQuality(score: 1)
        )
      },
      positionConfirmedByUser: userConfirmed
    )
  }

  fileprivate static func analysis(
    levels: [Double],
    route: String,
    comparisonBandCenterFrequencyHz: Double,
    hasTone: Bool,
    toneFrequencyHz: Double,
    toneIsStable: Bool,
    toneConfidence: AnalysisConfidence,
    overallLevelDB: Double?
  ) -> AcousticAnalysis {
    AcousticAnalysis(
      durationSeconds: 20,
      sampleRate: 48_000,
      inputRouteID: route,
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: 0.366_210_937_5,
      nominalFrequencyResolutionHz: 0.732_421_875,
      lowFrequencyLevelDB: overallLevelDB ?? levels.reduce(0, +) / Double(levels.count) + 2,
      spectrum: [SpectrumPoint(frequencyHz: 53.1, levelDB: levels[0])],
      spectrogramFrequenciesHz: [],
      spectrogram: [],
      tone: hasTone
        ? ToneAnalysis(
          frequencyHz: toneFrequencyHz,
          levelDB: levels.reduce(0, +) / Double(levels.count),
          prominenceDB: 20,
          persistence: 1,
          frequencySpreadHz: 0.02,
          levelSpreadDB: 0.2,
          harmonics: [],
          competingToneFrequenciesHz: [],
          frameTrace: [],
          independentBlockLevelsDB: levels,
          independentBlockBandCenterFrequencyHz: comparisonBandCenterFrequencyHz,
          independentBlockBandHalfWidthHz: 1,
          isStable: toneIsStable,
          confidence: toneConfidence
        ) : nil,
      lockedBand: LockedBandAnalysis(
        centerFrequencyHz: comparisonBandCenterFrequencyHz,
        halfWidthHz: 1,
        levelDB: levels.reduce(0, +) / Double(levels.count),
        independentBlockLevelsDB: levels,
        levelSpreadDB: 0.2
      ),
      quality: MeasurementQuality(score: 1)
    )
  }
}
