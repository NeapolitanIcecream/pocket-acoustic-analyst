import Foundation

struct SpatialScanEvaluator: Sendable {
    var minimumMeasuredPointCount = 3
    var minimumRecommendationImprovementDB = 3.0
    var maximumOriginTargetDifferenceDB = 2.0
    var maximumOriginDistanceMeters = 0.2

    func evaluate(
        measurements: [SpatialMeasurement],
        closure: SpatialMeasurement
    ) -> SpatialScanEvaluation {
        let targetFrequency = measurements.first?.targetFrequencyHz ?? closure.targetFrequencyHz
        var issues: Set<SpatialScanIssue> = []

        if measurements.count < minimumMeasuredPointCount {
            issues.insert(.insufficientMeasuredPoints)
        }
        if measurements.contains(where: { !$0.analysis.quality.isUsable || !$0.position.quality.isUsable })
            || !closure.analysis.quality.isUsable || !closure.position.quality.isUsable
        {
            issues.insert(.lowMeasurementQuality)
        }

        let allMeasurements = measurements + [closure]
        if allMeasurements.contains(where: {
            abs($0.targetFrequencyHz - targetFrequency) > frequencyTolerance(for: $0.analysis)
                || $0.analysis.tone?.isStable != true
                || abs(($0.analysis.tone?.frequencyHz ?? .infinity) - targetFrequency)
                    > frequencyTolerance(for: $0.analysis)
        }) {
            issues.insert(.targetFrequencyChanged)
        }

        if let reference = measurements.first,
           allMeasurements.contains(where: { !isComparable($0.analysis, to: reference.analysis) })
        {
            issues.insert(.routeOrConfigurationChanged)
        }

        if let origin = measurements.first {
            if origin.position.source == .arkit, closure.position.source == .arkit {
                if origin.position.trackingEpoch == nil
                    || origin.position.trackingEpoch != closure.position.trackingEpoch
                {
                    issues.insert(.trackingEpochChanged)
                }
                if origin.position.coordinate.distance(to: closure.position.coordinate)
                    > maximumOriginDistanceMeters
                {
                    issues.insert(.originPositionDidNotClose)
                }
            }
            if abs(origin.targetLevelDB - closure.targetLevelDB) > maximumOriginTargetDifferenceDB {
                issues.insert(.originSoundDidNotClose)
            }
        }

        var recommendation: QuietPointRecommendation?
        let blockingIssues: Set<SpatialScanIssue> = [
            .insufficientMeasuredPoints,
            .lowMeasurementQuality,
            .targetFrequencyChanged,
            .routeOrConfigurationChanged,
            .trackingEpochChanged,
            .originPositionDidNotClose,
            .originSoundDidNotClose,
        ]
        if issues.isDisjoint(with: blockingIssues),
           let origin = measurements.first,
           let quietest = measurements.min(by: { $0.targetLevelDB < $1.targetLevelDB })
        {
            let improvement = origin.targetLevelDB - quietest.targetLevelDB
            if quietest.id == origin.id || improvement < minimumRecommendationImprovementDB {
                issues.insert(.improvementTooSmall)
            } else {
                let hasDistance = origin.position.source == .arkit
                    && quietest.position.source == .arkit
                    && !issues.contains(.originPositionDidNotClose)
                let confidence: AnalysisConfidence = improvement >= 6
                    && abs(origin.targetLevelDB - closure.targetLevelDB) <= 1 ? .high : .medium
                recommendation = QuietPointRecommendation(
                    currentMeasurementID: origin.id,
                    recommendedMeasurementID: quietest.id,
                    targetFrequencyHz: targetFrequency,
                    improvementDB: improvement,
                    distanceMeters: hasDistance
                        ? origin.position.coordinate.distance(to: quietest.position.coordinate)
                        : nil,
                    confidence: confidence
                )
            }
        }

        return SpatialScanEvaluation(
            targetFrequencyHz: targetFrequency,
            measurements: measurements,
            closureMeasurement: closure,
            recommendation: recommendation,
            issues: issues
        )
    }
}

private extension SpatialScanEvaluator {
    func frequencyTolerance(for analysis: AcousticAnalysis) -> Double {
        max(1, analysis.nominalFrequencyResolutionHz)
    }

    func isComparable(_ analysis: AcousticAnalysis, to reference: AcousticAnalysis) -> Bool {
        analysis.inputRouteID == reference.inputRouteID
            && analysis.inputChannelCount == reference.inputChannelCount
            && analysis.selectedInputChannelIndex == reference.selectedInputChannelIndex
            && abs(analysis.sampleRate - reference.sampleRate) < 0.5
            && analysis.analysisVersion == reference.analysisVersion
            && analysis.configuration == reference.configuration
            && analysis.windowSampleCount == reference.windowSampleCount
    }
}
