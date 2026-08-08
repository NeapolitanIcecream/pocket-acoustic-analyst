import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct InvestigationRepositoryTests {
  @Test func localArchiveRoundTripsWithoutRawAudioSamples() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("PocketAcousticAnalystTests-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("archive.json", isDirectory: false)
    let repository = LocalInvestigationRepository(fileURL: fileURL)
    let analysis = Self.analysisFixture()
    var intermittent = analysis
    intermittent.id = UUID()
    intermittent.tone = nil
    intermittent.candidateTone = analysis.tone
    intermittent.soundPattern = .intermittentTone
    let archive = InvestigationArchive(analyses: [analysis, intermittent])

    try await repository.save(archive)
    let loaded = try await repository.load()
    let encodedText = try #require(String(data: Data(contentsOf: fileURL), encoding: .utf8))

    #expect(loaded == archive)
    #expect(loaded.analyses.first?.id == analysis.id)
    #expect(loaded.analyses.first?.inputRouteName == "iPhone 麦克风 / 底部")
    #expect(loaded.analyses.first?.lockedBand?.centerFrequencyHz == 53.17)
    #expect(loaded.analyses.last?.candidateTone?.frequencyHz == 53.17)
    #expect(loaded.analyses.last?.soundPattern == .intermittentTone)
    #expect(!encodedText.contains("\"samples\""))
    #expect(encodedText.contains("\"schemaVersion\":1"))
  }

  @Test func archiveFromBeforeSoundPatternsStillDecodes() throws {
    let archive = InvestigationArchive(analyses: [Self.analysisFixture()])
    let encoded = try JSONEncoder().encode(archive)
    var root = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    var analyses = try #require(root["analyses"] as? [[String: Any]])
    analyses[0].removeValue(forKey: "candidateTone")
    analyses[0].removeValue(forKey: "soundPattern")
    root["analyses"] = analyses

    let legacyData = try JSONSerialization.data(withJSONObject: root)
    let decoded = try JSONDecoder().decode(InvestigationArchive.self, from: legacyData)
    let analysis = try #require(decoded.analyses.first)

    #expect(analysis.candidateTone == nil)
    #expect(analysis.soundPattern == nil)
    #expect(analysis.resolvedSoundPattern == .stableTone)
  }
}

extension InvestigationRepositoryTests {
  fileprivate static func analysisFixture() -> AcousticAnalysis {
    AcousticAnalysis(
      measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
      durationSeconds: 20,
      sampleRate: 48_000,
      inputRouteID: "built-in",
      inputRouteName: "iPhone 麦克风 / 底部",
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: 0.366_210_937_5,
      nominalFrequencyResolutionHz: 0.732_421_875,
      lowFrequencyLevelDB: -18,
      spectrum: [SpectrumPoint(frequencyHz: 53.1, levelDB: -20)],
      spectrogramFrequenciesHz: [50, 55],
      spectrogram: [SpectrogramSlice(offsetSeconds: 0, levelsDB: [-20, -30])],
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
        independentBlockLevelsDB: [-20, -20, -20, -20, -20, -20],
        independentBlockBandCenterFrequencyHz: 53.17,
        independentBlockBandHalfWidthHz: 1,
        isStable: true,
        confidence: .high
      ),
      soundPattern: .stableTone,
      lockedBand: LockedBandAnalysis(
        centerFrequencyHz: 53.17,
        halfWidthHz: 1,
        levelDB: -20,
        independentBlockLevelsDB: [-20, -20, -20, -20, -20, -20],
        levelSpreadDB: 0
      ),
      quality: MeasurementQuality(score: 1)
    )
  }
}
