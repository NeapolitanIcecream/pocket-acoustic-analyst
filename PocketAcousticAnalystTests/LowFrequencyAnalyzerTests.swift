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
            #expect(abs(result.frequencyResolutionHz - sampleRate / Double(result.windowSampleCount)) < 1e-12)
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

        let result = try analyzer.analyze(samples: signal, sampleRate: sampleRate)

        #expect(result.tone == nil)
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

        #expect(tone.competingToneFrequenciesHz.contains { abs($0 - 83.4) < 0.3 || abs($0 - 53.1) < 0.3 })
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
}

private enum SignalFixture {
    static func stationary(
        duration: Double,
        sampleRate: Double,
        tones: [(frequency: Double, amplitude: Double)],
        noiseAmplitude: Double = 0
    ) -> [Float] {
        var random = SeededNoise(seed: 0xC0FFEE)
        return (0 ..< Int(duration * sampleRate)).map { sampleIndex in
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
        return (0 ..< Int(duration * sampleRate)).map { sampleIndex in
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
        return (0 ..< Int(duration * sampleRate)).map { sampleIndex in
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
