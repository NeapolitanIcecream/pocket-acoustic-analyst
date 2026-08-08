import Foundation
import Testing
@testable import PocketAcousticAnalyst

struct MeasurementComparatorTests {
    @Test func reportsImprovementOnlyWhenEstimateAndIntervalClearThresholds() throws {
        let epoch = UUID()
        let before = Self.measurement(levels: [-19.9, -20.1, -20, -19.8, -20.2, -20, -20.1], epoch: epoch)
        let after = Self.measurement(levels: [-26.1, -25.9, -26, -26.2, -25.8, -26, -26.1], epoch: epoch)

        let result = MeasurementComparator().compare(before: before, after: after)

        #expect(result.verdict == .improved)
        #expect(try #require(result.targetDeltaDB) < -5.5)
        #expect(try #require(result.targetDeltaInterval).upperDB < -5)
        #expect(result.confidence == .high)
    }

    @Test func distinguishesLittleChangeAndWorsening() {
        let epoch = UUID()
        let baseline = Self.measurement(levels: [-20, -20.1, -19.9, -20, -20, -20.1, -19.9], epoch: epoch)
        let similar = Self.measurement(levels: [-20.5, -20.4, -20.6, -20.5, -20.4, -20.6, -20.5], epoch: epoch)
        let louder = Self.measurement(levels: [-14, -14.1, -13.9, -14, -14, -14.1, -13.9], epoch: epoch)

        #expect(MeasurementComparator().compare(before: baseline, after: similar).verdict == .littleChange)
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

    @Test func trackedPositionMismatchMakesComparisonInconclusive() {
        let epoch = UUID()
        let before = Self.measurement(levels: Self.baselineLevels, epoch: epoch, x: 0)
        let after = Self.measurement(levels: Self.quieterLevels, epoch: epoch, x: 0.3)

        let result = MeasurementComparator().compare(before: before, after: after)

        #expect(result.verdict == .inconclusive)
        #expect(result.issues.contains(ComparisonIssue.positionMismatch))
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
}

private extension MeasurementComparatorTests {
    static let baselineLevels = [-20.1, -19.8, -20, -20.2, -19.9, -20, -20.1]
    static let quieterLevels = [-26.1, -25.8, -26, -26.2, -25.9, -26, -26.1]

    static func measurement(
        levels: [Double],
        epoch: UUID?,
        route: String = "built-in",
        x: Double = 0,
        userConfirmed: Bool = false
    ) -> ComparisonMeasurement {
        ComparisonMeasurement(
            analysis: analysis(levels: levels, route: route),
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

    static func analysis(levels: [Double], route: String) -> AcousticAnalysis {
        AcousticAnalysis(
            durationSeconds: 20,
            sampleRate: 48_000,
            inputRouteID: route,
            analysisVersion: LowFrequencyAnalyzer.version,
            configuration: .p0,
            windowSampleCount: 131_072,
            binSpacingHz: 0.366_210_937_5,
            nominalFrequencyResolutionHz: 0.732_421_875,
            lowFrequencyLevelDB: levels.reduce(0, +) / Double(levels.count) + 2,
            spectrum: [SpectrumPoint(frequencyHz: 53.1, levelDB: levels[0])],
            spectrogramFrequenciesHz: [],
            spectrogram: [],
            tone: ToneAnalysis(
                frequencyHz: 53.17,
                levelDB: levels.reduce(0, +) / Double(levels.count),
                prominenceDB: 20,
                persistence: 1,
                frequencySpreadHz: 0.02,
                levelSpreadDB: 0.2,
                harmonics: [],
                competingToneFrequenciesHz: [],
                frameTrace: [],
                independentBlockLevelsDB: levels,
                isStable: true,
                confidence: .high
            ),
            quality: MeasurementQuality(score: 1)
        )
    }
}
