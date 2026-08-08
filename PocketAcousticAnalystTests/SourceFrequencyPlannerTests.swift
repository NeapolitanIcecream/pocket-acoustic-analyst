import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct SourceFrequencyPlannerTests {
  @Test func completeLinkageChainBecomesOneUnresolvedBandOnlyWhenBandsOverlap() throws {
    let analysis = Self.analysis(
      components: [
        Self.component(at: 100.0),
        Self.component(at: 100.8),
        Self.component(at: 101.6),
        Self.component(at: 140.0),
      ],
      nominalResolutionHz: 0.2
    )

    let plan = try #require(SourceFrequencyPlanner().makePlan(from: analysis))
    let chainedBand = try #require(
      plan.targetBands.first { $0.memberFrequenciesHz.contains(100.0) })

    #expect(chainedBand.memberFrequenciesHz == [100.0, 100.8, 101.6])
    #expect(chainedBand.containsUnresolvedComponents)
    #expect(abs(chainedBand.centerFrequencyHz - 100.8) < 0.001)
    #expect(plan.targetBands.contains { $0.memberFrequenciesHz == [140.0] })
  }

  @Test func overlappingBandsMergeEvenWhenComponentsExceedLinkageTolerance() throws {
    let analysis = Self.analysis(
      components: [
        Self.component(at: 100.0),
        Self.component(at: 101.5),
      ],
      nominalResolutionHz: 0.2
    )

    let plan = try #require(SourceFrequencyPlanner().makePlan(from: analysis))
    let band = try #require(plan.targetBands.only)

    #expect(band.memberFrequenciesHz == [100.0, 101.5])
    #expect(band.containsUnresolvedComponents)
    #expect(abs(band.centerFrequencyHz - 100.75) < 0.001)
    #expect(abs(band.halfWidthHz - 1) < 0.001)
  }
}

extension SourceFrequencyPlannerTests {
  fileprivate static func component(at frequencyHz: Double) -> SpectralComponentEvidence {
    SpectralComponentEvidence(
      frequencyHz: frequencyHz,
      levelDB: -20,
      prominenceDB: 16,
      persistence: 1,
      frequencySpreadHz: 0.05
    )
  }

  fileprivate static func analysis(
    components: [SpectralComponentEvidence],
    nominalResolutionHz: Double
  ) -> AcousticAnalysis {
    AcousticAnalysis(
      durationSeconds: 20,
      sampleRate: 48_000,
      inputRouteID: "built-in-mic",
      analysisVersion: LowFrequencyAnalyzer.version,
      configuration: .p0,
      windowSampleCount: 131_072,
      binSpacingHz: nominalResolutionHz / 2,
      nominalFrequencyResolutionHz: nominalResolutionHz,
      lowFrequencyLevelDB: -12,
      spectrum: [],
      spectrogramFrequenciesHz: [],
      spectrogram: [],
      tone: nil,
      spectralComponents: components,
      quality: MeasurementQuality(score: 1)
    )
  }
}

extension Array {
  fileprivate var only: Element? { count == 1 ? first : nil }
}
