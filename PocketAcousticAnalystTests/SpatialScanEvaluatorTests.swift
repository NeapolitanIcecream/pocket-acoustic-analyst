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

        let result = SpatialScanEvaluator().evaluate(measurements: points, closure: closure)
        let recommendation = try #require(result.recommendation)

        #expect(points.contains { $0.id == recommendation.recommendedMeasurementID })
        #expect(recommendation.recommendedMeasurementID == points[1].id)
        #expect(abs(recommendation.improvementDB - 7) < 0.001)
        #expect(abs(try #require(recommendation.distanceMeters) - 0.5) < 0.001)
    }

    @Test func acousticOriginDriftSuppressesSpatialRanking() {
        let epoch = UUID()
        let points = [
            Self.fixture(label: "起点", levelDB: -20, x: 0, epoch: epoch),
            Self.fixture(label: "左侧", levelDB: -28, x: -0.5, epoch: epoch),
            Self.fixture(label: "床尾", levelDB: -24, x: 0.4, epoch: epoch),
        ]
        let closure = Self.fixture(label: "起点复测", levelDB: -24, x: 0.02, epoch: epoch)

        let result = SpatialScanEvaluator().evaluate(measurements: points, closure: closure)

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

        let result = SpatialScanEvaluator().evaluate(measurements: points, closure: closure)

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

        let result = SpatialScanEvaluator().evaluate(measurements: points, closure: closure)
        let recommendation = try #require(result.recommendation)

        #expect(recommendation.recommendedMeasurementID == points[1].id)
        #expect(recommendation.distanceMeters == nil)
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

        let result = SpatialScanEvaluator().evaluate(measurements: points, closure: closure)

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
}

private extension SpatialScanEvaluatorTests {
    static func fixture(
        label: String,
        levelDB: Double,
        x: Double,
        source: PositionSource = .arkit,
        epoch: UUID? = nil,
        quality: MeasurementQuality = MeasurementQuality(score: 1)
    ) -> SpatialMeasurement {
        var analysis = analysisFixture()
        analysis.quality = quality
        return SpatialMeasurement(
            label: label,
            position: PositionSample(
                coordinate: SpatialCoordinate(x: x, y: 0, z: 0),
                orientation: .identity,
                source: source,
                trackingEpoch: epoch,
                quality: quality
            ),
            analysis: analysis,
            targetFrequencyHz: 53.17,
            targetBandHalfWidthHz: 1,
            targetLevelDB: levelDB
        )
    }

    static func analysisFixture() -> AcousticAnalysis {
        AcousticAnalysis(
            durationSeconds: 9,
            sampleRate: 48_000,
            inputRouteID: "built-in-mic",
            analysisVersion: LowFrequencyAnalyzer.version,
            configuration: .p0,
            windowSampleCount: 131_072,
            binSpacingHz: 0.366_210_937_5,
            nominalFrequencyResolutionHz: 0.732_421_875,
            lowFrequencyLevelDB: -18,
            spectrum: [SpectrumPoint(frequencyHz: 53.1, levelDB: -20)],
            spectrogramFrequenciesHz: [],
            spectrogram: [],
            tone: ToneAnalysis(
                frequencyHz: 53.17,
                levelDB: -20,
                prominenceDB: 20,
                persistence: 1,
                frequencySpreadHz: 0.02,
                levelSpreadDB: 0.2,
                harmonics: [],
                competingToneFrequenciesHz: [],
                frameTrace: [],
                independentBlockLevelsDB: [-20, -20.1, -19.9, -20, -20.1, -19.9],
                isStable: true,
                confidence: .high
            ),
            quality: MeasurementQuality(score: 1)
        )
    }
}
