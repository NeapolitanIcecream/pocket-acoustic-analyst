import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct AcousticResultPresentationTests {
  @Test func everySoundPatternExplainsEvidenceLimitsAndNextAction() {
    var analysis = Self.fixture()

    for pattern in [
      LowFrequencySoundPattern.stableTone,
      .intermittentTone,
      .driftingTone,
      .varyingLevelTone,
      .multipleTones,
      .distributedEnergy,
    ] {
      analysis.soundPattern = pattern
      let presentation = analysis.resultPresentation

      #expect(!presentation.title.isEmpty)
      #expect(!presentation.subtitle.isEmpty)
      #expect(!presentation.evidence.isEmpty)
      #expect(!presentation.limitation.isEmpty)
      #expect(!presentation.action.isEmpty)
    }

    analysis.soundPattern = .distributedEnergy
    #expect(analysis.resultPresentation.limitation.contains("不代表环境安静"))
    analysis.soundPattern = .multipleTones
    #expect(analysis.resultPresentation.action.contains("每次只改变一台设备"))
    analysis.soundPattern = .intermittentTone
    #expect(analysis.resultPresentation.limitation.contains("不能把不同时间或位置"))
  }
}

extension AcousticResultPresentationTests {
  fileprivate static func fixture() -> AcousticAnalysis {
    let tone = ToneAnalysis(
      frequencyHz: 53.17,
      levelDB: -20,
      prominenceDB: 16,
      persistence: 0.6,
      frequencySpreadHz: 0.8,
      levelSpreadDB: 4,
      harmonics: [],
      competingToneFrequenciesHz: [83.4],
      frameTrace: [
        ToneFrameSample(offsetSeconds: 0, frequencyHz: 52.8, levelDB: -20),
        ToneFrameSample(offsetSeconds: 1, frequencyHz: 53.6, levelDB: -24),
      ],
      independentBlockLevelsDB: [],
      isStable: false,
      confidence: .medium
    )
    return AcousticAnalysis(
      durationSeconds: 20,
      sampleRate: 48_000,
      inputRouteID: "test",
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: 0.366,
      nominalFrequencyResolutionHz: 0.732,
      lowFrequencyLevelDB: -18,
      spectrum: [],
      spectrogramFrequenciesHz: [],
      spectrogram: [],
      tone: nil,
      candidateTone: tone,
      soundPattern: .intermittentTone,
      quality: MeasurementQuality(score: 0.7, issues: [.unstableEnvironment])
    )
  }
}
