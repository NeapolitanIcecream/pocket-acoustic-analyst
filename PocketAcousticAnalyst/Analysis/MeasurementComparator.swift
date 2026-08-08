import Foundation

struct MeasurementComparator: Sendable {
    var bootstrapIterationCount = 10_000
    var minimumIndependentBlockCount = 6
    var maximumPositionDifferenceMeters = 0.15
    var maximumOrientationDifferenceDegrees = 20.0

    func compare(before: ComparisonMeasurement, after: ComparisonMeasurement) -> MeasurementComparison {
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
        let durationRatio = max(beforeAnalysis.durationSeconds, afterAnalysis.durationSeconds)
            / max(0.001, min(beforeAnalysis.durationSeconds, afterAnalysis.durationSeconds))
        if durationRatio > 1.2 {
            issues.insert(.durationMismatch)
        }
        if !isComparable(beforeAnalysis, afterAnalysis) {
            issues.insert(.routeOrConfigurationChanged)
        }

        let targetFrequency = beforeAnalysis.tone?.frequencyHz
        let tolerance = max(
            1,
            max(
                beforeAnalysis.nominalFrequencyResolutionHz,
                afterAnalysis.nominalFrequencyResolutionHz
            )
        )
        if beforeAnalysis.tone?.isStable != true
            || afterAnalysis.tone?.isStable != true
            || targetFrequency == nil
            || abs((afterAnalysis.tone?.frequencyHz ?? .infinity) - (targetFrequency ?? 0)) > tolerance
        {
            issues.insert(.targetFrequencyChanged)
        }

        let beforeBlocks = beforeAnalysis.tone?.independentBlockLevelsDB ?? []
        let afterBlocks = afterAnalysis.tone?.independentBlockLevelsDB ?? []
        if beforeBlocks.count < minimumIndependentBlockCount
            || afterBlocks.count < minimumIndependentBlockCount
        {
            issues.insert(.insufficientIndependentBlocks)
        }
        evaluatePlacement(before: before, after: after, issues: &issues)

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

private extension MeasurementComparator {
    func isComparable(_ lhs: AcousticAnalysis, _ rhs: AcousticAnalysis) -> Bool {
        lhs.inputRouteID == rhs.inputRouteID
            && lhs.inputChannelCount == rhs.inputChannelCount
            && lhs.selectedInputChannelIndex == rhs.selectedInputChannelIndex
            && abs(lhs.sampleRate - rhs.sampleRate) < 0.5
            && lhs.analysisVersion == rhs.analysisVersion
            && lhs.configuration == rhs.configuration
            && lhs.windowSampleCount == rhs.windowSampleCount
    }

    func evaluatePlacement(
        before: ComparisonMeasurement,
        after: ComparisonMeasurement,
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
                > maximumPositionDifferenceMeters
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

    func aggregateLevel(_ levelsDB: [Double]) -> Double {
        let meanPower = levelsDB.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(levelsDB.count)
        return 10 * log10(max(meanPower, 1e-16))
    }

    func bootstrapDifference(before: [Double], after: [Double]) -> ConfidenceInterval {
        var random = ComparisonRandomNumberGenerator(seed: 0xAC0A_571C)
        var differences = [Double]()
        differences.reserveCapacity(bootstrapIterationCount)
        for _ in 0 ..< bootstrapIterationCount {
            let beforeSample = (0 ..< before.count).map { _ in
                before[Int(random.next() % UInt64(before.count))]
            }
            let afterSample = (0 ..< after.count).map { _ in
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
