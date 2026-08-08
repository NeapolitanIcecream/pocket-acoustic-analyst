import Foundation

struct AnalysisConfiguration: Codable, Equatable, Sendable {
    var minimumFrequencyHz: Double = 10
    var maximumFrequencyHz: Double = 500
    var minimumWindowDurationSeconds: Double = 2
    var hopFraction: Double = 0.5
    var minimumToneProminenceDB: Double = 8
    var minimumTonePersistence: Double = 0.68
    var stableFrequencySpreadHz: Double = 1.5
    var harmonicToleranceHz: Double = 1.5
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
}

struct MeasurementQuality: Codable, Equatable, Sendable {
    var score: Double
    var issues: Set<MeasurementQualityIssue>

    init(score: Double, issues: Set<MeasurementQualityIssue> = []) {
        self.score = min(max(score, 0), 1)
        self.issues = issues
    }

    var isUsable: Bool {
        score >= 0.6 && !issues.contains(.externalInterruption) && !issues.contains(.insufficientDuration)
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

struct ToneAnalysis: Codable, Equatable, Sendable {
    var frequencyHz: Double
    var levelDB: Double
    var prominenceDB: Double
    var persistence: Double
    var frequencySpreadHz: Double
    var harmonics: [HarmonicEvidence]
    var competingToneFrequenciesHz: [Double]
    var isStable: Bool
    var confidence: AnalysisConfidence
}

struct AcousticAnalysis: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var measuredAt: Date
    var durationSeconds: Double
    var sampleRate: Double
    var inputRouteID: String
    var inputChannelCount: Int
    var analysisVersion: String
    var configuration: AnalysisConfiguration
    var windowSampleCount: Int
    var frequencyResolutionHz: Double
    var broadbandLevelDB: Double
    var spectrum: [SpectrumPoint]
    var spectrogramFrequenciesHz: [Double]
    var spectrogram: [SpectrogramSlice]
    var tone: ToneAnalysis?
    var quality: MeasurementQuality

    init(
        id: UUID = UUID(),
        measuredAt: Date = .now,
        durationSeconds: Double,
        sampleRate: Double,
        inputRouteID: String,
        inputChannelCount: Int = 1,
        analysisVersion: String,
        configuration: AnalysisConfiguration,
        windowSampleCount: Int,
        frequencyResolutionHz: Double,
        broadbandLevelDB: Double,
        spectrum: [SpectrumPoint],
        spectrogramFrequenciesHz: [Double],
        spectrogram: [SpectrogramSlice],
        tone: ToneAnalysis?,
        quality: MeasurementQuality
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.durationSeconds = durationSeconds
        self.sampleRate = sampleRate
        self.inputRouteID = inputRouteID
        self.inputChannelCount = inputChannelCount
        self.analysisVersion = analysisVersion
        self.configuration = configuration
        self.windowSampleCount = windowSampleCount
        self.frequencyResolutionHz = frequencyResolutionHz
        self.broadbandLevelDB = broadbandLevelDB
        self.spectrum = spectrum
        self.spectrogramFrequenciesHz = spectrogramFrequenciesHz
        self.spectrogram = spectrogram
        self.tone = tone
        self.quality = quality
    }
}
