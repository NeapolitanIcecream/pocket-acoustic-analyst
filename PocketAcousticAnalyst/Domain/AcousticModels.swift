import Foundation

struct AnalysisConfiguration: Codable, Equatable, Sendable {
  var minimumFrequencyHz: Double = 10
  var maximumFrequencyHz: Double = 500
  var minimumWindowDurationSeconds: Double = 2
  var hopFraction: Double = 0.5
  var minimumToneProminenceDB: Double = 8
  var minimumFrameProminenceDB: Double = 6
  var minimumTonePersistence: Double = 0.8
  var highConfidencePersistence: Double = 0.9
  var stableFrequencySpreadHz: Double = 0.5
  var highConfidenceFrequencySpreadHz: Double = 0.25
  var stableLevelSpreadDB: Double = 3
  var highConfidenceLevelSpreadDB: Double = 1.5
  var harmonicToleranceFloorHz: Double = 0.5
  var harmonicCoOccurrence: Double = 0.7
  var spectrogramStepHz: Double = 5

  static let p0 = AnalysisConfiguration()
}

enum AnalysisConfidence: String, Codable, CaseIterable, Sendable {
  case low
  case medium
  case high

  var userLabel: String {
    switch self {
    case .low: "较低"
    case .medium: "中等"
    case .high: "较高"
    }
  }

  func constrained(by other: AnalysisConfidence) -> AnalysisConfidence {
    let order: [AnalysisConfidence] = [.low, .medium, .high]
    return order[min(order.firstIndex(of: self) ?? 0, order.firstIndex(of: other) ?? 0)]
  }
}

enum MeasurementQualityIssue: String, Codable, Hashable, Sendable {
  case inputTooQuiet
  case clipping
  case externalInterruption
  case unstableEnvironment
  case deviceMoving
  case positionUnavailable
  case trackingLimited
  case insufficientDuration
  case routeChanged
  case engineConfigurationChanged
  case mediaServicesReset
  case appBackgrounded
}

struct MeasurementQuality: Codable, Equatable, Sendable {
  var score: Double
  var issues: Set<MeasurementQualityIssue>

  init(score: Double, issues: Set<MeasurementQualityIssue> = []) {
    self.score = min(max(score, 0), 1)
    self.issues = issues
  }

  var isUsable: Bool {
    score >= 0.6 && !issues.contains(.externalInterruption)
      && !issues.contains(.insufficientDuration)
      && !issues.contains(.unstableEnvironment)
      && !issues.contains(.routeChanged) && !issues.contains(.engineConfigurationChanged)
      && !issues.contains(.mediaServicesReset) && !issues.contains(.appBackgrounded)
  }

  var confidence: AnalysisConfidence {
    switch score {
    case 0.82...: .high
    case 0.6...: .medium
    default: .low
    }
  }
}

struct SpectrumPoint: Codable, Equatable, Sendable, Identifiable {
  var frequencyHz: Double
  var levelDB: Double

  var id: Double { frequencyHz }
}

struct SpectrogramSlice: Codable, Equatable, Sendable, Identifiable {
  var offsetSeconds: Double
  var levelsDB: [Double]

  var id: Double { offsetSeconds }
}

struct HarmonicEvidence: Codable, Equatable, Sendable, Identifiable {
  var order: Int
  var frequencyHz: Double
  var levelDB: Double
  var prominenceDB: Double

  var id: Int { order }
}

struct ToneFrameSample: Codable, Equatable, Sendable, Identifiable {
  var offsetSeconds: Double
  var frequencyHz: Double?
  var levelDB: Double?

  var id: Double { offsetSeconds }
}

struct ToneAnalysis: Codable, Equatable, Sendable {
  var frequencyHz: Double
  var levelDB: Double
  var prominenceDB: Double
  var persistence: Double
  var frequencySpreadHz: Double
  var levelSpreadDB: Double
  var harmonics: [HarmonicEvidence]
  var competingToneFrequenciesHz: [Double]
  var frameTrace: [ToneFrameSample]
  var independentBlockLevelsDB: [Double]
  var independentBlockBandCenterFrequencyHz: Double? = nil
  var independentBlockBandHalfWidthHz: Double? = nil
  var isStable: Bool
  var confidence: AnalysisConfidence
}

struct LockedBandAnalysis: Codable, Equatable, Sendable {
  var centerFrequencyHz: Double
  var halfWidthHz: Double
  var levelDB: Double
  var independentBlockLevelsDB: [Double]
  var levelSpreadDB: Double

  func contains(
    frequencyHz: Double,
    nominalFrequencyResolutionHz: Double
  ) -> Bool {
    let interiorHalfWidth = max(0, halfWidthHz - nominalFrequencyResolutionHz)
    return abs(frequencyHz - centerFrequencyHz) <= interiorHalfWidth + 1e-9
  }
}

struct AcousticAnalysis: Codable, Equatable, Sendable, Identifiable {
  var id: UUID
  var measuredAt: Date
  var durationSeconds: Double
  var sampleRate: Double
  var inputRouteID: String
  var inputRouteName: String?
  var inputChannelCount: Int
  var selectedInputChannelIndex: Int
  var analysisVersion: String
  var configuration: AnalysisConfiguration
  var windowSampleCount: Int
  var binSpacingHz: Double
  var nominalFrequencyResolutionHz: Double
  var lowFrequencyLevelDB: Double
  var spectrum: [SpectrumPoint]
  var spectrogramFrequenciesHz: [Double]
  var spectrogram: [SpectrogramSlice]
  var tone: ToneAnalysis?
  var lockedBand: LockedBandAnalysis?
  var quality: MeasurementQuality

  init(
    id: UUID = UUID(),
    measuredAt: Date = .now,
    durationSeconds: Double,
    sampleRate: Double,
    inputRouteID: String,
    inputRouteName: String? = nil,
    inputChannelCount: Int = 1,
    selectedInputChannelIndex: Int = 0,
    analysisVersion: String,
    configuration: AnalysisConfiguration,
    windowSampleCount: Int,
    binSpacingHz: Double,
    nominalFrequencyResolutionHz: Double,
    lowFrequencyLevelDB: Double,
    spectrum: [SpectrumPoint],
    spectrogramFrequenciesHz: [Double],
    spectrogram: [SpectrogramSlice],
    tone: ToneAnalysis?,
    lockedBand: LockedBandAnalysis? = nil,
    quality: MeasurementQuality
  ) {
    self.id = id
    self.measuredAt = measuredAt
    self.durationSeconds = durationSeconds
    self.sampleRate = sampleRate
    self.inputRouteID = inputRouteID
    self.inputRouteName = inputRouteName
    self.inputChannelCount = inputChannelCount
    self.selectedInputChannelIndex = selectedInputChannelIndex
    self.analysisVersion = analysisVersion
    self.configuration = configuration
    self.windowSampleCount = windowSampleCount
    self.binSpacingHz = binSpacingHz
    self.nominalFrequencyResolutionHz = nominalFrequencyResolutionHz
    self.lowFrequencyLevelDB = lowFrequencyLevelDB
    self.spectrum = spectrum
    self.spectrogramFrequenciesHz = spectrogramFrequenciesHz
    self.spectrogram = spectrogram
    self.tone = tone
    self.lockedBand = lockedBand
    self.quality = quality
  }
}
