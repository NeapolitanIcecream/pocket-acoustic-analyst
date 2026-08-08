import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct SpatialScanEvaluatorTests {
  @Test func recommendsOnlyAnActuallyMeasuredPoint() throws {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "左侧", levelDB: -27, x: -0.5, epoch: epoch),
      Self.fixture(label: "床尾", levelDB: -23, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20.4, x: 0.03, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)
    let recommendation = try #require(result.recommendation)

    #expect(points.contains { $0.id == recommendation.recommendedMeasurementID })
    #expect(recommendation.recommendedMeasurementID == points[1].id)
    #expect(abs(recommendation.improvementDB - 7) < 0.001)
    #expect(abs(try #require(recommendation.distanceMeters) - 0.5) < 0.001)
    #expect(recommendation.confidence == .medium)
  }

  @Test func acousticOriginDriftSuppressesSpatialRanking() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "左侧", levelDB: -28, x: -0.5, epoch: epoch),
      Self.fixture(label: "床尾", levelDB: -24, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -24, x: 0.02, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(SpatialScanIssue.originSoundDidNotClose))
    #expect(result.recommendation == nil)
    #expect(!result.canRankMeasuredPoints)
  }

  @Test func coordinateClosureFailureSuppressesDistanceAndRanking() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "左侧", levelDB: -28, x: -0.5, epoch: epoch),
      Self.fixture(label: "床尾", levelDB: -24, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20, x: 0.35, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(SpatialScanIssue.originPositionDidNotClose))
    #expect(result.recommendation == nil)
  }

  @Test func manualFallbackCanCompareNamedPointsButNeverReportsDistance() throws {
    let points = [
      Self.fixture(label: "床头", levelDB: -20, x: 0, source: .guidedManual),
      Self.fixture(label: "窗边", levelDB: -27, x: 1, source: .guidedManual),
      Self.fixture(label: "门边", levelDB: -23, x: 2, source: .guidedManual),
    ]
    let closure = Self.fixture(label: "床头复测", levelDB: -20.2, x: 0, source: .guidedManual)

    let result = Self.evaluate(measurements: points, closure: closure)
    let recommendation = try #require(result.recommendation)

    #expect(recommendation.recommendedMeasurementID == points[1].id)
    #expect(recommendation.distanceMeters == nil)
    #expect(recommendation.confidence == .medium)
  }

  @Test func middlePointWithoutDetectablePeakIsRetainedButNotAttributedToPosition() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "低谷", levelDB: -31, x: -0.5, epoch: epoch, hasTone: false),
      Self.fixture(label: "床尾", levelDB: -23, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20.2, x: 0.02, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(!result.issues.contains(.targetFrequencyChanged))
    #expect(result.issues.contains(.lowestPointTargetNotDetected))
    #expect(result.recommendation == nil)
  }

  @Test func changedHeightOrOrientationSuppressesSpatialRanking() {
    let epoch = UUID()
    let rotated = DeviceOrientation(
      x: 0,
      y: sin(15 * .pi / 180),
      z: 0,
      w: cos(15 * .pi / 180)
    )
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(
        label: "不一致",
        levelDB: -30,
        x: -0.5,
        y: 0.25,
        orientation: rotated,
        epoch: epoch
      ),
      Self.fixture(label: "床尾", levelDB: -23, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20, x: 0.02, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(.measurementHeightChanged))
    #expect(result.issues.contains(.measurementOrientationChanged))
    #expect(result.recommendation == nil)
  }

  @Test func badQualityExtremeCannotBecomeARecommendation() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(
        label: "受干扰点",
        levelDB: -50,
        x: -0.5,
        epoch: epoch,
        quality: MeasurementQuality(score: 0.2, issues: [.externalInterruption])
      ),
      Self.fixture(label: "床尾", levelDB: -24, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20, x: 0.02, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(SpatialScanIssue.lowMeasurementQuality))
    #expect(result.recommendation == nil)
  }

  @Test func targetBandLevelSumsLinearPowerInsideLockedBand() throws {
    var analysis = Self.analysisFixture()
    analysis.spectrum = [
      SpectrumPoint(frequencyHz: 52.5, levelDB: -20),
      SpectrumPoint(frequencyHz: 53.2, levelDB: -20),
      SpectrumPoint(frequencyHz: 56, levelDB: 0),
    ]

    let result = try #require(
      TargetBandLevelCalculator().measure(
        in: analysis,
        targetFrequencyHz: 53,
        halfWidthHz: 1
      )
    )

    #expect(abs(result.levelDB - (-16.9897)) < 0.001)
    #expect(result.halfWidthHz == 1)
  }

  @Test func everyCandidateRequiresAnAdjacentOriginCheck() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "左侧", levelDB: -27, x: -0.5, epoch: epoch),
      Self.fixture(label: "床尾", levelDB: -23, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20, x: 0.01, epoch: epoch)

    let result = SpatialScanEvaluator().evaluate(
      measurements: points,
      originChecks: [],
      closure: closure
    )

    #expect(result.issues.contains(.missingAdjacentOriginChecks))
    #expect(result.recommendation == nil)
  }

  @Test func candidateDeltaUsesItsTwoAdjacentOriginChecks() throws {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(label: "左侧", levelDB: -20, x: -0.5, epoch: epoch),
      Self.fixture(label: "床尾", levelDB: -22, x: 0.4, epoch: epoch),
    ]
    let intermediate = Self.fixture(label: "起点复测 1", levelDB: -18, x: 0.005, epoch: epoch)
    let closure = Self.fixture(label: "起点复测 2", levelDB: -16, x: 0.01, epoch: epoch)

    let result = SpatialScanEvaluator().evaluate(
      measurements: points,
      originChecks: [intermediate],
      closure: closure
    )
    let recommendation = try #require(result.recommendation)
    let comparison = try #require(result.pointComparison(for: points[2].id))

    #expect(recommendation.recommendedMeasurementID == points[2].id)
    #expect(comparison.targetDeltaDB < -4)
  }

  @Test func stableToneOutsideLockedBandInteriorInvalidatesSpatialScan() {
    let epoch = UUID()
    let points = [
      Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
      Self.fixture(
        label: "偏频点",
        levelDB: -27,
        x: -0.5,
        epoch: epoch,
        toneFrequencyHz: 54.1
      ),
      Self.fixture(label: "床尾", levelDB: -23, x: 0.4, epoch: epoch),
    ]
    let closure = Self.fixture(label: "起点复测", levelDB: -20, x: 0.01, epoch: epoch)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(.targetFrequencyChanged))
    #expect(result.recommendation == nil)
  }

  @Test func highFrequencyHeightToleranceIsLimitedByWavelength() {
    let epoch = UUID()
    let points = [
      Self.fixture(
        label: "起点", levelDB: -20, x: 0, epoch: epoch, targetFrequencyHz: 500),
      Self.fixture(
        label: "高度变化",
        levelDB: -27,
        x: -0.5,
        y: 0.025,
        epoch: epoch,
        targetFrequencyHz: 500
      ),
      Self.fixture(
        label: "床尾", levelDB: -23, x: 0.4, epoch: epoch, targetFrequencyHz: 500),
    ]
    let closure = Self.fixture(
      label: "起点复测", levelDB: -20, x: 0.01, epoch: epoch, targetFrequencyHz: 500)

    let result = Self.evaluate(measurements: points, closure: closure)

    #expect(result.issues.contains(.measurementHeightChanged))
    #expect(result.recommendation == nil)
  }
}

extension SpatialScanEvaluatorTests {
  fileprivate static func evaluate(
    measurements: [SpatialMeasurement],
    closure: SpatialMeasurement,
    evaluator: SpatialScanEvaluator = SpatialScanEvaluator()
  ) -> SpatialScanEvaluation {
    guard let origin = measurements.first else {
      return evaluator.evaluate(measurements: measurements, originChecks: [], closure: closure)
    }
    let intermediateCount = max(0, measurements.count - 2)
    let intermediateChecks = (0..<intermediateCount).map { index -> SpatialMeasurement in
      var check = origin
      check.id = UUID()
      check.label = "起点复测 \(index + 1)"
      if check.position.source == .arkit {
        check.position.coordinate.x += 0.005
      }
      return check
    }
    return evaluator.evaluate(
      measurements: measurements,
      originChecks: intermediateChecks,
      closure: closure
    )
  }

  fileprivate static func fixture(
    label: String,
    levelDB: Double,
    x: Double,
    y: Double = 0,
    orientation: DeviceOrientation = .identity,
    source: PositionSource = .arkit,
    epoch: UUID? = nil,
    quality: MeasurementQuality = MeasurementQuality(score: 1),
    hasTone: Bool = true,
    targetFrequencyHz: Double = 53.17,
    toneFrequencyHz: Double? = nil
  ) -> SpatialMeasurement {
    var analysis = analysisFixture(
      levelDB: levelDB,
      hasTone: hasTone,
      targetFrequencyHz: targetFrequencyHz,
      toneFrequencyHz: toneFrequencyHz ?? targetFrequencyHz
    )
    analysis.quality = quality
    return SpatialMeasurement(
      label: label,
      position: PositionSample(
        coordinate: SpatialCoordinate(x: x, y: y, z: 0),
        orientation: orientation,
        source: source,
        trackingEpoch: epoch,
        quality: quality
      ),
      analysis: analysis,
      targetFrequencyHz: targetFrequencyHz,
      targetBandHalfWidthHz: 1,
      targetLevelDB: levelDB
    )
  }

  fileprivate static func analysisFixture(
    levelDB: Double = -20,
    hasTone: Bool = true,
    targetFrequencyHz: Double = 53.17,
    toneFrequencyHz: Double = 53.17
  ) -> AcousticAnalysis {
    AcousticAnalysis(
      durationSeconds: 9,
      sampleRate: 48_000,
      inputRouteID: "built-in-mic",
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: 0.366_210_937_5,
      nominalFrequencyResolutionHz: 0.732_421_875,
      lowFrequencyLevelDB: levelDB + 2,
      spectrum: [SpectrumPoint(frequencyHz: targetFrequencyHz, levelDB: levelDB)],
      spectrogramFrequenciesHz: [],
      spectrogram: [],
      tone: hasTone
        ? ToneAnalysis(
          frequencyHz: toneFrequencyHz,
          levelDB: levelDB,
          prominenceDB: 20,
          persistence: 1,
          frequencySpreadHz: 0.02,
          levelSpreadDB: 0.2,
          harmonics: [],
          competingToneFrequenciesHz: [],
          frameTrace: [],
          independentBlockLevelsDB: [
            levelDB, levelDB - 0.1, levelDB + 0.1, levelDB, levelDB - 0.1, levelDB + 0.1,
          ],
          independentBlockBandCenterFrequencyHz: targetFrequencyHz,
          independentBlockBandHalfWidthHz: 1,
          isStable: true,
          confidence: .high
        ) : nil,
      lockedBand: LockedBandAnalysis(
        centerFrequencyHz: targetFrequencyHz,
        halfWidthHz: 1,
        levelDB: levelDB,
        independentBlockLevelsDB: [
          levelDB, levelDB - 0.1, levelDB + 0.1, levelDB, levelDB - 0.1, levelDB + 0.1,
        ],
        levelSpreadDB: 0.1
      ),
      quality: MeasurementQuality(score: 1)
    )
  }
}
