import Accelerate
import Foundation

enum AcousticAnalysisError: Error, Equatable, Sendable {
    case invalidSampleRate
    case analysisRangeExceedsNyquist
    case insufficientSamples(required: Int, actual: Int)
    case transformUnavailable
}

struct LowFrequencyAnalyzer: Sendable {
    static let version = "low-frequency-v1"

    let configuration: AnalysisConfiguration

    init(configuration: AnalysisConfiguration = .p0) {
        self.configuration = configuration
    }

    func analyze(
        samples: [Float],
        sampleRate: Double,
        inputRouteID: String = "unknown",
        inputChannelCount: Int = 1,
        captureIssues: Set<MeasurementQualityIssue> = []
    ) throws -> AcousticAnalysis {
        guard sampleRate.isFinite, sampleRate > 0 else {
            throw AcousticAnalysisError.invalidSampleRate
        }
        guard configuration.maximumFrequencyHz < sampleRate / 2 else {
            throw AcousticAnalysisError.analysisRangeExceedsNyquist
        }

        let windowSampleCount = nextPowerOfTwo(
            max(16, Int((sampleRate * configuration.minimumWindowDurationSeconds).rounded(.up)))
        )
        guard samples.count >= windowSampleCount else {
            throw AcousticAnalysisError.insufficientSamples(
                required: windowSampleCount,
                actual: samples.count
            )
        }

        let dft: vDSP.DiscreteFourierTransform<Float>
        do {
            dft = try vDSP.DiscreteFourierTransform(
                previous: nil,
                count: windowSampleCount,
                direction: .forward,
                transformType: .complexComplex,
                ofType: Float.self
            )
        } catch {
            throw AcousticAnalysisError.transformUnavailable
        }

        let hopSampleCount = max(1, Int(Double(windowSampleCount) * configuration.hopFraction))
        let window = vDSP.window(
            ofType: Float.self,
            usingSequence: .hanningDenormalized,
            count: windowSampleCount,
            isHalfWindow: false
        )
        let amplitudeScale = 2 / max(Double(window.reduce(0, +)), Double.leastNonzeroMagnitude)
        let binWidth = sampleRate / Double(windowSampleCount)
        let minimumBin = max(1, Int(ceil(configuration.minimumFrequencyHz / binWidth)))
        let maximumBin = min(windowSampleCount / 2, Int(floor(configuration.maximumFrequencyHz / binWidth)))
        let bandCount = maximumBin - minimumBin + 1
        let zeroImaginary = [Float](repeating: 0, count: windowSampleCount)

        var framePowers: [[Double]] = []
        var frameBroadbandLevels: [Double] = []
        var offset = 0

        while offset + windowSampleCount <= samples.count {
            let frame = Array(samples[offset ..< offset + windowSampleCount])
            let mean = frame.reduce(0.0) { $0 + Double($1) } / Double(windowSampleCount)
            let centered = frame.map { Float(Double($0) - mean) }
            let windowed = vDSP.multiply(centered, window)
            let transformed = dft.transform(real: windowed, imaginary: zeroImaginary)

            var powers = [Double](repeating: 0, count: bandCount)
            for bin in minimumBin ... maximumBin {
                let real = Double(transformed.real[bin])
                let imaginary = Double(transformed.imaginary[bin])
                powers[bin - minimumBin] = (real * real + imaginary * imaginary) * amplitudeScale * amplitudeScale
            }
            framePowers.append(powers)
            frameBroadbandLevels.append(levelDB(forMeanSquare: meanSquare(centered)))
            offset += hopSampleCount
        }

        let averagePowers = average(framePowers)
        let averageLevels = averagePowers.map(levelDB(forPower:))
        let spectrum = averageLevels.enumerated().map { localIndex, level in
            SpectrumPoint(
                frequencyHz: Double(localIndex + minimumBin) * binWidth,
                levelDB: level
            )
        }
        let tone = detectTone(
            averageLevels: averageLevels,
            framePowers: framePowers,
            minimumBin: minimumBin,
            binWidth: binWidth
        )

        var qualityIssues = captureIssues
        let broadbandMeanSquare = meanSquare(samples)
        let broadbandLevel = levelDB(forMeanSquare: broadbandMeanSquare)
        if broadbandLevel < -80 {
            qualityIssues.insert(.inputTooQuiet)
        }
        let clippingFraction = Double(samples.lazy.filter { abs($0) >= 0.995 }.count) / Double(samples.count)
        if clippingFraction > 0.001 {
            qualityIssues.insert(.clipping)
        }
        if standardDeviation(frameBroadbandLevels) > 4 {
            qualityIssues.insert(.unstableEnvironment)
        }

        let quality = quality(for: qualityIssues)
        let spectrogramFrequencies = spectrogramFrequencies(
            minimum: configuration.minimumFrequencyHz,
            maximum: configuration.maximumFrequencyHz,
            step: configuration.spectrogramStepHz
        )
        let spectrogram = makeSpectrogram(
            framePowers: framePowers,
            frequencies: spectrogramFrequencies,
            minimumBin: minimumBin,
            binWidth: binWidth,
            hopSeconds: Double(hopSampleCount) / sampleRate
        )

        return AcousticAnalysis(
            durationSeconds: Double(samples.count) / sampleRate,
            sampleRate: sampleRate,
            inputRouteID: inputRouteID,
            inputChannelCount: inputChannelCount,
            analysisVersion: Self.version,
            configuration: configuration,
            windowSampleCount: windowSampleCount,
            frequencyResolutionHz: binWidth,
            broadbandLevelDB: broadbandLevel,
            spectrum: spectrum,
            spectrogramFrequenciesHz: spectrogramFrequencies,
            spectrogram: spectrogram,
            tone: tone,
            quality: quality
        )
    }
}

private extension LowFrequencyAnalyzer {
    struct Peak {
        var index: Int
        var frequencyHz: Double
        var levelDB: Double
        var prominenceDB: Double
    }

    func detectTone(
        averageLevels: [Double],
        framePowers: [[Double]],
        minimumBin: Int,
        binWidth: Double
    ) -> ToneAnalysis? {
        let peaks = findPeaks(
            levels: averageLevels,
            minimumBin: minimumBin,
            binWidth: binWidth,
            minimumProminenceDB: configuration.minimumToneProminenceDB
        )
        guard !peaks.isEmpty else { return nil }

        let strongestLevel = peaks.map(\.levelDB).max() ?? -160
        let scored = peaks.map { peak -> (Peak, Double, [HarmonicEvidence]) in
            let harmonics = harmonicEvidence(for: peak, among: peaks)
            let relativeStrength = (peak.levelDB - strongestLevel) / 10
            let harmonicSupport = Double(harmonics.count) * 0.8
            return (peak, relativeStrength + harmonicSupport, harmonics)
        }
        let selected = scored.max { lhs, rhs in lhs.1 < rhs.1 } ?? scored[0]
        let primary = selected.0
        let frameObservations = framePowers.compactMap { powers -> Peak? in
            let levels = powers.map(levelDB(forPower:))
            let searchRadius = max(2, Int(ceil(max(1.5, binWidth * 2) / binWidth)))
            let lower = max(1, primary.index - searchRadius)
            let upper = min(levels.count - 2, primary.index + searchRadius)
            guard lower <= upper else { return nil }
            let index = (lower ... upper).max { levels[$0] < levels[$1] } ?? primary.index
            guard levels[index] >= levels[max(0, index - 1)], levels[index] >= levels[min(levels.count - 1, index + 1)] else {
                return nil
            }
            let prominence = localProminence(levels: levels, at: index, binWidth: binWidth)
            guard prominence >= configuration.minimumToneProminenceDB else { return nil }
            return interpolatedPeak(levels: levels, at: index, minimumBin: minimumBin, binWidth: binWidth, prominence: prominence)
        }

        let persistence = Double(frameObservations.count) / Double(framePowers.count)
        guard persistence >= configuration.minimumTonePersistence else { return nil }

        let observedFrequencies = frameObservations.map(\.frequencyHz)
        let spread = standardDeviation(observedFrequencies)
        let stable = spread <= max(configuration.stableFrequencySpreadHz, binWidth * 2)
        let competitors = peaks
            .filter { peak in
                peak.index != primary.index &&
                    peak.levelDB >= primary.levelDB - 3 &&
                    !isHarmonic(peak.frequencyHz, of: primary.frequencyHz)
            }
            .map(\.frequencyHz)

        let confidence: AnalysisConfidence
        if primary.prominenceDB >= 12, persistence >= 0.85, stable, competitors.isEmpty {
            confidence = .high
        } else if primary.prominenceDB >= configuration.minimumToneProminenceDB,
                  persistence >= configuration.minimumTonePersistence,
                  stable {
            confidence = .medium
        } else {
            confidence = .low
        }

        return ToneAnalysis(
            frequencyHz: primary.frequencyHz,
            levelDB: primary.levelDB,
            prominenceDB: primary.prominenceDB,
            persistence: persistence,
            frequencySpreadHz: spread,
            harmonics: selected.2,
            competingToneFrequenciesHz: competitors,
            isStable: stable,
            confidence: confidence
        )
    }

    func findPeaks(
        levels: [Double],
        minimumBin: Int,
        binWidth: Double,
        minimumProminenceDB: Double
    ) -> [Peak] {
        guard levels.count >= 3 else { return [] }
        var peaks: [Peak] = []
        for index in 1 ..< levels.count - 1 where levels[index] > levels[index - 1] && levels[index] >= levels[index + 1] {
            let prominence = localProminence(levels: levels, at: index, binWidth: binWidth)
            guard prominence >= minimumProminenceDB else { continue }
            peaks.append(
                interpolatedPeak(
                    levels: levels,
                    at: index,
                    minimumBin: minimumBin,
                    binWidth: binWidth,
                    prominence: prominence
                )
            )
        }
        return peaks.sorted { $0.levelDB > $1.levelDB }
    }

    func interpolatedPeak(
        levels: [Double],
        at index: Int,
        minimumBin: Int,
        binWidth: Double,
        prominence: Double
    ) -> Peak {
        let left = levels[index - 1]
        let center = levels[index]
        let right = levels[index + 1]
        let denominator = left - 2 * center + right
        let rawOffset = abs(denominator) > 1e-12 ? 0.5 * (left - right) / denominator : 0
        let offset = min(max(rawOffset, -0.5), 0.5)
        let interpolatedLevel = center - 0.25 * (left - right) * offset
        return Peak(
            index: index,
            frequencyHz: Double(index + minimumBin) * binWidth + offset * binWidth,
            levelDB: interpolatedLevel,
            prominenceDB: prominence
        )
    }

    func localProminence(levels: [Double], at index: Int, binWidth: Double) -> Double {
        let radius = max(8, Int(ceil(12 / binWidth)))
        let lower = max(0, index - radius)
        let upper = min(levels.count - 1, index + radius)
        let excludedRadius = max(2, Int(ceil(1.5 / binWidth)))
        var background: [Double] = []
        for candidate in lower ... upper where abs(candidate - index) > excludedRadius {
            background.append(levels[candidate])
        }
        guard let median = median(background) else { return 0 }
        return levels[index] - median
    }

    func harmonicEvidence(for fundamental: Peak, among peaks: [Peak]) -> [HarmonicEvidence] {
        guard fundamental.frequencyHz > 0 else { return [] }
        let maximumOrder = min(8, Int(configuration.maximumFrequencyHz / fundamental.frequencyHz))
        guard maximumOrder >= 2 else { return [] }
        return (2 ... maximumOrder).compactMap { order in
            let expected = fundamental.frequencyHz * Double(order)
            let tolerance = max(configuration.harmonicToleranceHz, expected * 0.012)
            guard let match = peaks
                .filter({ abs($0.frequencyHz - expected) <= tolerance })
                .min(by: { abs($0.frequencyHz - expected) < abs($1.frequencyHz - expected) })
            else { return nil }
            return HarmonicEvidence(
                order: order,
                frequencyHz: match.frequencyHz,
                levelDB: match.levelDB,
                prominenceDB: match.prominenceDB
            )
        }
    }

    func isHarmonic(_ frequency: Double, of fundamental: Double) -> Bool {
        guard fundamental > 0 else { return false }
        let ratio = frequency / fundamental
        let order = ratio.rounded()
        guard order >= 2 else { return false }
        return abs(frequency - order * fundamental) <= max(configuration.harmonicToleranceHz, frequency * 0.012)
    }

    func makeSpectrogram(
        framePowers: [[Double]],
        frequencies: [Double],
        minimumBin: Int,
        binWidth: Double,
        hopSeconds: Double
    ) -> [SpectrogramSlice] {
        framePowers.enumerated().map { frameIndex, powers in
            let levels = frequencies.map { frequency -> Double in
                let globalBin = Int((frequency / binWidth).rounded())
                let localBin = min(max(globalBin - minimumBin, 0), powers.count - 1)
                return levelDB(forPower: powers[localBin])
            }
            return SpectrogramSlice(offsetSeconds: Double(frameIndex) * hopSeconds, levelsDB: levels)
        }
    }

    func spectrogramFrequencies(minimum: Double, maximum: Double, step: Double) -> [Double] {
        guard step > 0 else { return [] }
        return stride(from: minimum, through: maximum, by: step).map { $0 }
    }

    func quality(for issues: Set<MeasurementQualityIssue>) -> MeasurementQuality {
        var score = 1.0
        for issue in issues {
            switch issue {
            case .externalInterruption, .insufficientDuration:
                score = 0
            case .clipping, .inputTooQuiet:
                score -= 0.45
            case .unstableEnvironment, .deviceMoving:
                score -= 0.3
            case .positionUnavailable, .trackingLimited:
                score -= 0.15
            }
        }
        return MeasurementQuality(score: score, issues: issues)
    }

    func average(_ frames: [[Double]]) -> [Double] {
        guard let first = frames.first else { return [] }
        var result = [Double](repeating: 0, count: first.count)
        for frame in frames {
            for index in result.indices {
                result[index] += frame[index]
            }
        }
        return result.map { $0 / Double(frames.count) }
    }

    func meanSquare<C: Collection>(_ values: C) -> Double where C.Element == Float {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0.0) { partial, value in
            partial + Double(value) * Double(value)
        } / Double(values.count)
    }

    func levelDB(forMeanSquare value: Double) -> Double {
        10 * log10(max(value, 1e-16))
    }

    func levelDB(forPower value: Double) -> Double {
        10 * log10(max(value, 1e-16))
    }

    func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    func standardDeviation(_ values: [Double]) -> Double {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return variance.squareRoot()
    }

    func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value {
            result <<= 1
        }
        return result
    }
}
