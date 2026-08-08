import Foundation

enum SourceExperimentState: String, Codable, Sendable {
  case baseline
  case changed
}

struct SourceInvestigationMeasurement: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var sequenceIndex: Int
  var state: SourceExperimentState
  var analysis: AcousticAnalysis
  var position: PositionSample?
  var positionConfirmedByUser: Bool

  init(
    id: UUID = UUID(),
    sequenceIndex: Int,
    state: SourceExperimentState,
    analysis: AcousticAnalysis,
    position: PositionSample?,
    positionConfirmedByUser: Bool
  ) {
    self.id = id
    self.sequenceIndex = sequenceIndex
    self.state = state
    self.analysis = analysis
    self.position = position
    self.positionConfirmedByUser = positionConfirmedByUser
  }
}

struct SourceFrequencyBand: Codable, Equatable, Sendable, Identifiable {
  var centerFrequencyHz: Double
  var halfWidthHz: Double
  var memberFrequenciesHz: [Double]
  var containsUnresolvedComponents: Bool

  var id: Double { centerFrequencyHz }
}

enum SourceBandRelationship: String, Codable, Sendable {
  case lowerInChangedState
  case higherInChangedState
  case littleChange
  case inconclusive
}

enum SourceInvestigationIssue: String, Codable, Hashable, Sendable {
  case incompleteSequence
  case lowMeasurementQuality
  case unstableEnvironment
  case routeOrConfigurationChanged
  case positionMismatch
  case orientationMismatch
  case positionUserConfirmedOnly
  case missingTrackedBand
  case baselineTargetNotDetected
  case baselineDidNotReturn
  case insufficientIndependentBlocks
  case inconsistentRoundDirection
}

struct SourceBandRoundEvidence: Codable, Equatable, Sendable, Identifiable {
  var frequencyHz: Double
  var baselineLevelDB: Double?
  var changedLevelDB: Double?
  var changedDeltaDB: Double?
  var frequencySpecificDeltaDB: Double?
  var changedDeltaInterval: ConfidenceInterval?
  var baselineReturnDifferenceDB: Double?
  var relationship: SourceBandRelationship
  var issues: Set<SourceInvestigationIssue>

  var id: Double { frequencyHz }
}

struct SourceInvestigationRound: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var roundNumber: Int
  var precedingBaselineMeasurementID: UUID
  var changedMeasurementID: UUID
  var followingBaselineMeasurementID: UUID
  var bandEvidence: [SourceBandRoundEvidence]
  var lowFrequencyDeltaDB: Double?
  var lowFrequencyRelationship: SourceBandRelationship?
  var guardBandMedianDeltaDB: Double?
  var issues: Set<SourceInvestigationIssue>

  init(
    id: UUID = UUID(),
    roundNumber: Int,
    precedingBaselineMeasurementID: UUID,
    changedMeasurementID: UUID,
    followingBaselineMeasurementID: UUID,
    bandEvidence: [SourceBandRoundEvidence],
    lowFrequencyDeltaDB: Double?,
    lowFrequencyRelationship: SourceBandRelationship? = nil,
    guardBandMedianDeltaDB: Double?,
    issues: Set<SourceInvestigationIssue>
  ) {
    self.id = id
    self.roundNumber = roundNumber
    self.precedingBaselineMeasurementID = precedingBaselineMeasurementID
    self.changedMeasurementID = changedMeasurementID
    self.followingBaselineMeasurementID = followingBaselineMeasurementID
    self.bandEvidence = bandEvidence
    self.lowFrequencyDeltaDB = lowFrequencyDeltaDB
    self.lowFrequencyRelationship = lowFrequencyRelationship
    self.guardBandMedianDeltaDB = guardBandMedianDeltaDB
    self.issues = issues
  }
}

struct SourceBandSummary: Codable, Equatable, Sendable, Identifiable {
  var frequencyHz: Double
  var relationship: SourceBandRelationship
  var meanChangedDeltaDB: Double?
  var synchronizedRoundCount: Int
  var validRoundCount: Int
  var roundDeltasDB: [Double]

  var id: Double { frequencyHz }
}

enum SourceInvestigationVerdict: String, Codable, Sendable {
  case frequencySpecificSynchronization
  case overallLowFrequencySynchronization
  case noConsistentSynchronization
  case inconclusive
}

struct SourceInvestigationEvaluation: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var measuredAt: Date
  var subjectName: String
  var baselineStateName: String
  var changedStateName: String
  var targetBands: [SourceFrequencyBand]
  var measurements: [SourceInvestigationMeasurement]
  var rounds: [SourceInvestigationRound]
  var bandSummaries: [SourceBandSummary]
  var verdict: SourceInvestigationVerdict
  var confidence: AnalysisConfidence
  var issues: Set<SourceInvestigationIssue>

  init(
    id: UUID = UUID(),
    measuredAt: Date = .now,
    subjectName: String,
    baselineStateName: String,
    changedStateName: String,
    targetBands: [SourceFrequencyBand],
    measurements: [SourceInvestigationMeasurement],
    rounds: [SourceInvestigationRound],
    bandSummaries: [SourceBandSummary],
    verdict: SourceInvestigationVerdict,
    confidence: AnalysisConfidence,
    issues: Set<SourceInvestigationIssue>
  ) {
    self.id = id
    self.measuredAt = measuredAt
    self.subjectName = subjectName
    self.baselineStateName = baselineStateName
    self.changedStateName = changedStateName
    self.targetBands = targetBands
    self.measurements = measurements
    self.rounds = rounds
    self.bandSummaries = bandSummaries
    self.verdict = verdict
    self.confidence = confidence
    self.issues = issues
  }

  var strongestSynchronizedBand: SourceBandSummary? {
    guard verdict == .frequencySpecificSynchronization else { return nil }
    return
      bandSummaries
      .filter {
        $0.relationship == .lowerInChangedState || $0.relationship == .higherInChangedState
      }
      .max { abs($0.meanChangedDeltaDB ?? 0) < abs($1.meanChangedDeltaDB ?? 0) }
  }
}
