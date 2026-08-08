import Foundation

enum ComparisonVerdict: String, Codable, Sendable {
    case improved
    case littleChange
    case worsened
    case inconclusive
}

enum ComparisonIssue: String, Codable, Hashable, Sendable {
    case targetFrequencyChanged
    case lowMeasurementQuality
    case unstableEnvironment
    case durationMismatch
    case positionMismatch
}

struct MeasurementComparison: Codable, Equatable, Sendable {
    var beforeID: UUID
    var afterID: UUID
    var verdict: ComparisonVerdict
    var targetFrequencyHz: Double?
    var targetDeltaDB: Double?
    var broadbandDeltaDB: Double
    var confidence: AnalysisConfidence
    var issues: Set<ComparisonIssue>
}

