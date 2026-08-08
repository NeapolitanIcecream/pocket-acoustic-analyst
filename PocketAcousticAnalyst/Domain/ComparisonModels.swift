import Foundation

enum ComparisonVerdict: String, Codable, Sendable {
  case improved
  case littleChange
  case worsened
  case inconclusive
}

enum ComparisonIssue: String, Codable, Hashable, Sendable {
  case targetFrequencyChanged
  case targetNotDetectedAfter
  case lowMeasurementQuality
  case unstableEnvironment
  case durationMismatch
  case positionMismatch
  case orientationMismatch
  case positionUserConfirmedOnly
  case positionSensitiveMeasurement
  case routeOrConfigurationChanged
  case insufficientIndependentBlocks
}

struct ComparisonMeasurement: Codable, Equatable, Sendable {
  var analysis: AcousticAnalysis
  var position: PositionSample?
  var positionConfirmedByUser: Bool
}

struct ConfidenceInterval: Codable, Equatable, Sendable {
  var lowerDB: Double
  var upperDB: Double
  var probability: Double
}

struct MeasurementComparison: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var measuredAt: Date
  var beforeID: UUID
  var afterID: UUID
  var verdict: ComparisonVerdict
  var targetFrequencyHz: Double?
  var targetDeltaDB: Double?
  var targetDeltaInterval: ConfidenceInterval?
  var lowFrequencyDeltaDB: Double
  var confidence: AnalysisConfidence
  var issues: Set<ComparisonIssue>

  init(
    id: UUID = UUID(),
    measuredAt: Date = .now,
    beforeID: UUID,
    afterID: UUID,
    verdict: ComparisonVerdict,
    targetFrequencyHz: Double?,
    targetDeltaDB: Double?,
    targetDeltaInterval: ConfidenceInterval?,
    lowFrequencyDeltaDB: Double,
    confidence: AnalysisConfidence,
    issues: Set<ComparisonIssue>
  ) {
    self.id = id
    self.measuredAt = measuredAt
    self.beforeID = beforeID
    self.afterID = afterID
    self.verdict = verdict
    self.targetFrequencyHz = targetFrequencyHz
    self.targetDeltaDB = targetDeltaDB
    self.targetDeltaInterval = targetDeltaInterval
    self.lowFrequencyDeltaDB = lowFrequencyDeltaDB
    self.confidence = confidence
    self.issues = issues
  }
}
