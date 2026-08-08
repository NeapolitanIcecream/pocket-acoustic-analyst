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
        let archive = InvestigationArchive(analyses: [analysis])

        try await repository.save(archive)
        let loaded = try await repository.load()
        let encodedText = try #require(String(data: Data(contentsOf: fileURL), encoding: .utf8))

        #expect(loaded == archive)
        #expect(loaded.analyses.first?.id == analysis.id)
        #expect(!encodedText.contains("\"samples\""))
        #expect(encodedText.contains("\"schemaVersion\":1"))
    }
}

private extension InvestigationRepositoryTests {
    static func analysisFixture() -> AcousticAnalysis {
        AcousticAnalysis(
            measuredAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationSeconds: 20,
            sampleRate: 48_000,
            inputRouteID: "built-in",
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
                isStable: true,
                confidence: .high
            ),
            quality: MeasurementQuality(score: 1)
        )
    }
}
