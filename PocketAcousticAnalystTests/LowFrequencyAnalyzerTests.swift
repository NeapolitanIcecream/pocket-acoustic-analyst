import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct LowFrequencyAnalyzerTests {
  private let analyzer = LowFrequencyAnalyzer()

  @Test func estimatesNonBinCenteredToneAtCommonHardwareSampleRates() throws {
    for sampleRate in [44_100.0, 48_000.0] {
      let signal = SignalFixture.stationary(
        duration: 9,
        sampleRate: sampleRate,
        tones: [(53.17, 0.12)],
        noiseAmplitude: 0.003
      )

      let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
      let tone = try #require(result.tone)

      #expect(abs(tone.frequencyHz - 53.17) < 0.2)
      #expect(tone.isStable)
      #expect(result.sampleRate == sampleRate)
      #expect(abs(result.binSpacingHz - sampleRate / Double(result.windowSampleCount)) < 1e-12)
    }
  }

  @Test func groupsIntegerHarmonicsUnderTheFundamental() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(53.2, 0.07), (106.4, 0.12), (159.6, 0.04)],
      noiseAmplitude: 0.002
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let tone = try #require(result.tone)

    #expect(abs(tone.frequencyHz - 53.2) < 0.25)
    #expect(tone.harmonics.map(\.order).contains(2))
    #expect(tone.harmonics.map(\.order).contains(3))
  }

  @Test func preservesRelativeLevelAcrossMeasurements() throws {
    let sampleRate = 48_000.0
    let louder = SignalFixture.stationary(
      duration: 7,
      sampleRate: sampleRate,
      tones: [(71.3, 0.12)]
    )
    let quieter = SignalFixture.stationary(
      duration: 7,
      sampleRate: sampleRate,
      tones: [(71.3, 0.06)]
    )

    let loudAnalysis = try analyzer.analyze(samples: louder, sampleRate: sampleRate)
    let quietAnalysis = try analyzer.analyze(samples: quieter, sampleRate: sampleRate)
    let delta = try #require(quietAnalysis.tone).levelDB - #require(loudAnalysis.tone).levelDB

    #expect(abs(delta + 6.0206) < 0.15)
  }

  @Test func locksIndependentBlocksToRequestedComparisonBand() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(53.6, 0.12)],
      noiseAmplitude: 0.003
    )

    let result = try analyzer.analyze(
      samples: signal,
      sampleRate: sampleRate,
      comparisonTargetFrequencyHz: 53.17
    )
    let lockedBand = try #require(result.lockedBand)

    #expect(lockedBand.centerFrequencyHz == 53.17)
    #expect(lockedBand.halfWidthHz == 1)
    #expect(!lockedBand.independentBlockLevelsDB.isEmpty)
  }

  @Test func tracksLockedBandWhenTargetNoLongerFormsPeak() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 20,
      sampleRate: sampleRate,
      tones: [],
      noiseAmplitude: 0.01
    )

    let result = try analyzer.analyze(
      samples: signal,
      sampleRate: sampleRate,
      comparisonTargetFrequencyHz: 53.17
    )
    let lockedBand = try #require(result.lockedBand)

    #expect(result.tone == nil)
    #expect(lockedBand.centerFrequencyHz == 53.17)
    #expect(lockedBand.independentBlockLevelsDB.count >= 6)
  }

  @Test func equalAmplitudeFrequencyShiftAtLockedBandEdgeIsNotAnImprovement() throws {
    for sampleRate in [44_100.0, 48_000.0] {
      let beforeSignal = SignalFixture.stationary(
        duration: 20,
        sampleRate: sampleRate,
        tones: [(53.17, 0.1)]
      )
      let afterSignal = SignalFixture.stationary(
        duration: 20,
        sampleRate: sampleRate,
        tones: [(54.10, 0.1)]
      )
      let before = try analyzer.analyze(
        samples: beforeSignal,
        sampleRate: sampleRate,
        comparisonTargetFrequencyHz: 53.17
      )
      let after = try analyzer.analyze(
        samples: afterSignal,
        sampleRate: sampleRate,
        comparisonTargetFrequencyHz: 53.17
      )
      let result = MeasurementComparator().compare(
        before: ComparisonMeasurement(
          analysis: before,
          position: nil,
          positionConfirmedByUser: true
        ),
        after: ComparisonMeasurement(
          analysis: after,
          position: nil,
          positionConfirmedByUser: true
        )
      )

      #expect(result.verdict == .inconclusive)
      #expect(result.issues.contains(.targetFrequencyChanged))
      #expect(result.targetDeltaDB == nil)
    }
  }

  @Test func symmetricGuardBinsPreventFalseLevelDropAtPublicBandEdges() throws {
    let sampleRate = 48_000.0
    for (target, shifted) in [(10.1, 9.85), (499.7, 499.95)] {
      let before = try analyzer.analyze(
        samples: SignalFixture.stationary(
          duration: 20,
          sampleRate: sampleRate,
          tones: [(target, 0.1)]
        ),
        sampleRate: sampleRate,
        comparisonTargetFrequencyHz: target
      )
      let after = try analyzer.analyze(
        samples: SignalFixture.stationary(
          duration: 20,
          sampleRate: sampleRate,
          tones: [(shifted, 0.1)]
        ),
        sampleRate: sampleRate,
        comparisonTargetFrequencyHz: target
      )
      let result = MeasurementComparator().compare(
        before: ComparisonMeasurement(
          analysis: before,
          position: nil,
          positionConfirmedByUser: true
        ),
        after: ComparisonMeasurement(
          analysis: after,
          position: nil,
          positionConfirmedByUser: true
        )
      )

      #expect(result.verdict != .improved)
      #expect(abs(try #require(result.targetDeltaDB)) < 1)
    }
  }

  @Test func broadbandGuardBinsPreventFalseLevelChangeAtPublicBandEdges() throws {
    for sampleRate in [44_100.0, 48_000.0] {
      for (beforeFrequency, afterFrequency) in [(10.0, 10.4), (499.6, 500.0)] {
        let before = try analyzer.analyze(
          samples: SignalFixture.stationary(
            duration: 9,
            sampleRate: sampleRate,
            tones: [(beforeFrequency, 0.1)]
          ),
          sampleRate: sampleRate
        )
        let after = try analyzer.analyze(
          samples: SignalFixture.stationary(
            duration: 9,
            sampleRate: sampleRate,
            tones: [(afterFrequency, 0.1)]
          ),
          sampleRate: sampleRate
        )

        #expect(abs(after.lowFrequencyLevelDB - before.lowFrequencyLevelDB) < 0.25)
      }
    }
  }

  @Test func rejectsShortTransientAsPersistentHum() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.gatedTone(
      duration: 10,
      activeUntil: 0.8,
      sampleRate: sampleRate,
      frequency: 53,
      amplitude: 0.15,
      noiseAmplitude: 0.004
    )

    let result = try analyzer.analyze(
      samples: signal,
      sampleRate: sampleRate,
      comparisonTargetFrequencyHz: 53.17
    )

    #expect(result.tone == nil)
    #expect(try #require(result.lockedBand).levelSpreadDB > 3)
    #expect(result.quality.issues.contains(.unstableEnvironment))
  }

  @Test func doesNotCallFrequencyDriftStable() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.chirp(
      duration: 10,
      sampleRate: sampleRate,
      startFrequency: 50,
      endFrequency: 60,
      amplitude: 0.12,
      noiseAmplitude: 0.002
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)

    #expect(result.tone?.isStable != true)
  }

  @Test func doesNotInventPersistentToneFromWhiteNoise() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [],
      noiseAmplitude: 0.06
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)

    #expect(result.tone == nil)
  }

  @Test func exposesCompetingIndependentTone() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(53.1, 0.1), (83.4, 0.095)],
      noiseAmplitude: 0.002
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let tone = try #require(result.tone)

    #expect(
      tone.competingToneFrequenciesHz.contains { abs($0 - 83.4) < 0.3 || abs($0 - 53.1) < 0.3 })
    #expect(tone.confidence != .high)
  }

  @Test func clippingLowersMeasurementQuality() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 7,
      sampleRate: sampleRate,
      tones: [(53, 1.2)]
    ).map { min(max($0, -1), 1) }

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)

    #expect(result.quality.issues.contains(.clipping))
    #expect(!result.quality.isUsable)
  }

  @Test func rejectsInputShorterThanAnalysisWindow() {
    let sampleRate = 48_000.0
    let signal = [Float](repeating: 0, count: 10_000)

    #expect(throws: AcousticAnalysisError.self) {
      try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    }
  }

  @Test func spectrogramBucketRetainsNonGridToneEnergy() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(53.17, 0.1)]
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let tone = try #require(result.tone)
    let bucketIndex = try #require(
      result.spectrogramFrequenciesHz.indices.min {
        abs(result.spectrogramFrequenciesHz[$0] - tone.frequencyHz)
          < abs(result.spectrogramFrequenciesHz[$1] - tone.frequencyHz)
      }
    )

    for slice in result.spectrogram {
      #expect(abs(slice.levelsDB[bucketIndex] - tone.levelDB) < 0.2)
    }
  }

  @Test func oneSidedBinPowerObeysParsevalForBandLimitedTone() throws {
    let sampleRate = 48_000.0
    let amplitude = 0.2
    let signal = SignalFixture.stationary(
      duration: 7,
      sampleRate: sampleRate,
      tones: [(53.17, amplitude)]
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let spectralPower = result.spectrum.reduce(0.0) { $0 + pow(10, $1.levelDB / 10) }
    let expectedMeanSquare = amplitude * amplitude / 2

    #expect(abs(spectralPower - expectedMeanSquare) / expectedMeanSquare < 1e-5)
  }

  @Test func detectsTonesAtBothPublicBandEdges() throws {
    let sampleRate = 48_000.0
    for frequency in [10.1, 499.7] {
      let signal = SignalFixture.stationary(
        duration: 9,
        sampleRate: sampleRate,
        tones: [(frequency, 0.12)]
      )
      let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
      let tone = try #require(result.tone)
      #expect(abs(tone.frequencyHz - frequency) < 0.25)
    }
  }

  @Test func dcOffsetDoesNotChangeLowFrequencyResult() throws {
    let sampleRate = 48_000.0
    let original = SignalFixture.stationary(
      duration: 7,
      sampleRate: sampleRate,
      tones: [(53.17, 0.1)]
    )
    let offset = original.map { $0 + 0.35 }

    let originalResult = try analyzer.analyze(samples: original, sampleRate: sampleRate)
    let offsetResult = try analyzer.analyze(samples: offset, sampleRate: sampleRate)

    #expect(abs(offsetResult.lowFrequencyLevelDB - originalResult.lowFrequencyLevelDB) < 0.001)
    #expect(
      abs(try #require(offsetResult.tone).frequencyHz - #require(originalResult.tone).frequencyHz)
        < 0.01)
  }

  @Test func twelveSecondsOutOfTwentyIsNotCalledPersistent() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.gatedTone(
      duration: 20,
      activeUntil: 12,
      sampleRate: sampleRate,
      frequency: 53.17,
      amplitude: 0.12,
      noiseAmplitude: 0.002
    )

    let result = try analyzer.analyze(
      samples: signal,
      sampleRate: sampleRate,
      comparisonTargetFrequencyHz: 53.17
    )

    #expect(result.tone == nil)
    #expect(try #require(result.lockedBand).levelSpreadDB > 3)
  }

  @Test func slowTwoHertzDriftIsNotHighStability() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.chirp(
      duration: 20,
      sampleRate: sampleRate,
      startFrequency: 52,
      endFrequency: 54,
      amplitude: 0.12,
      noiseAmplitude: 0.002
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)

    #expect(result.tone?.confidence != .high)
    #expect(result.tone?.isStable != true)
  }

  @Test func looseNearMultipleIsNotGroupedAsHarmonic() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(200, 0.1), (404, 0.08)]
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let tone = try #require(result.tone)

    #expect(tone.harmonics.isEmpty)
  }

  @Test func missingFundamentalIsNotInvented() throws {
    let sampleRate = 48_000.0
    let signal = SignalFixture.stationary(
      duration: 9,
      sampleRate: sampleRate,
      tones: [(106.2, 0.1), (159.3, 0.08), (212.4, 0.06)]
    )

    let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)
    let tone = try #require(result.tone)

    #expect(tone.frequencyHz > 100)
  }
}

private enum SignalFixture {
  static func stationary(
    duration: Double,
    sampleRate: Double,
    tones: [(frequency: Double, amplitude: Double)],
    noiseAmplitude: Double = 0
  ) -> [Float] {
    var random = SeededNoise(seed: 0xC0FFEE)
    return (0..<Int(duration * sampleRate)).map { sampleIndex in
      let time = Double(sampleIndex) / sampleRate
      let tonal = tones.reduce(0.0) { partial, tone in
        partial + tone.amplitude * sin(2 * .pi * tone.frequency * time)
      }
      return Float(tonal + noiseAmplitude * random.next())
    }
  }

  static func gatedTone(
    duration: Double,
    activeUntil: Double,
    sampleRate: Double,
    frequency: Double,
    amplitude: Double,
    noiseAmplitude: Double
  ) -> [Float] {
    var random = SeededNoise(seed: 0xBAD5EED)
    return (0..<Int(duration * sampleRate)).map { sampleIndex in
      let time = Double(sampleIndex) / sampleRate
      let tonal = time < activeUntil ? amplitude * sin(2 * .pi * frequency * time) : 0
      return Float(tonal + noiseAmplitude * random.next())
    }
  }

  static func chirp(
    duration: Double,
    sampleRate: Double,
    startFrequency: Double,
    endFrequency: Double,
    amplitude: Double,
    noiseAmplitude: Double
  ) -> [Float] {
    var random = SeededNoise(seed: 0xD1A1F7)
    let slope = (endFrequency - startFrequency) / duration
    return (0..<Int(duration * sampleRate)).map { sampleIndex in
      let time = Double(sampleIndex) / sampleRate
      let phase = 2 * Double.pi * (startFrequency * time + 0.5 * slope * time * time)
      return Float(amplitude * sin(phase) + noiseAmplitude * random.next())
    }
  }
}

private struct SeededNoise {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> Double {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    let normalized = Double(state >> 11) / Double(1 << 53)
    return normalized * 2 - 1
  }
}
