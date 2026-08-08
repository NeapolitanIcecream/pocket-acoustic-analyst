import Accelerate
import Foundation

enum AcousticAnalysisError: Error, Equatable, Sendable {
  case invalidSampleRate
  case analysisRangeExceedsNyquist
  case insufficientSamples(required: Int, actual: Int)
  case transformUnavailable
}

struct LowFrequencyAnalyzer: Sendable {
  static let version = "low-frequency-v4"
  static let comparisonBandHalfWidthHz = 1.0

  let configuration: AnalysisConfiguration

  init(configuration: AnalysisConfiguration = .p0) {
    self.configuration = configuration
  }

  func analyze(
    samples: [Float],
    sampleRate: Double,
    inputRouteID: String = "unknown",
    inputRouteName: String? = nil,
    inputChannelCount: Int = 1,
    selectedInputChannelIndex: Int = 0,
    comparisonTargetFrequencyHz: Double? = nil,
    comparisonBandHalfWidthHz: Double = Self.comparisonBandHalfWidthHz,
    measuredAt: Date = .now,
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
    let windowEnergy = window.reduce(0.0) { $0 + Double($1) * Double($1) }
    let positiveFrequencyPowerScale = 2 / (Double(windowSampleCount) * windowEnergy)
    let binSpacing = sampleRate / Double(windowSampleCount)

    // Keep enough bins outside the public 10–500 Hz band to detect edge peaks
    // and estimate each edge peak's local background.
    let transformMinimumBin = 1
    let guardFrequencyHz = 14.0
    let transformMaximumBin = min(
      windowSampleCount / 2 - 1,
      Int(ceil((configuration.maximumFrequencyHz + guardFrequencyHz) / binSpacing))
    )
    let transformBandCount = transformMaximumBin - transformMinimumBin + 1
    let zeroImaginary = [Float](repeating: 0, count: windowSampleCount)

    var framePowers: [[Double]] = []
    var offset = 0

    while offset + windowSampleCount <= samples.count {
      let frame = Array(samples[offset..<offset + windowSampleCount])
      let mean = frame.reduce(0.0) { $0 + Double($1) } / Double(windowSampleCount)
      let centered = frame.map { Float(Double($0) - mean) }
      let windowed = vDSP.multiply(centered, window)
      let transformed = dft.transform(real: windowed, imaginary: zeroImaginary)

      var powers = [Double](repeating: 0, count: transformBandCount)
      for bin in transformMinimumBin...transformMaximumBin {
        let real = Double(transformed.real[bin])
        let imaginary = Double(transformed.imaginary[bin])
        powers[bin - transformMinimumBin] =
          (real * real + imaginary * imaginary) * positiveFrequencyPowerScale
      }
      framePowers.append(powers)
      offset += hopSampleCount
    }

    let averagePowers = average(framePowers)
    let publicIndices = indices(
      from: configuration.minimumFrequencyHz,
      through: configuration.maximumFrequencyHz,
      minimumBin: transformMinimumBin,
      binSpacing: binSpacing,
      count: averagePowers.count
    )
    // A Hann-windowed tone spreads across two bins on either side of its
    // frequency. Include that main-lobe width beyond the public band edges so
    // a small in-band shift near 10 or 500 Hz is not reported as a broadband
    // level change merely because window energy crossed the display boundary.
    let broadbandEdgeGuardHz = 2 * binSpacing
    let broadbandIndices = indices(
      from: max(0, configuration.minimumFrequencyHz - broadbandEdgeGuardHz),
      through: configuration.maximumFrequencyHz + broadbandEdgeGuardHz,
      minimumBin: transformMinimumBin,
      binSpacing: binSpacing,
      count: averagePowers.count
    )
    let spectrum = publicIndices.map { localIndex in
      SpectrumPoint(
        frequencyHz: Double(localIndex + transformMinimumBin) * binSpacing,
        levelDB: levelDB(forPower: averagePowers[localIndex])
      )
    }

    let toneDetection = detectTone(
      averagePowers: averagePowers,
      framePowers: framePowers,
      minimumBin: transformMinimumBin,
      binSpacing: binSpacing,
      hopSeconds: Double(hopSampleCount) / sampleRate
    )
    var tone = toneDetection.tone
    var candidateTone = toneDetection.candidateTone
    let lockedBand = makeLockedBand(
      centerFrequencyHz:
        comparisonTargetFrequencyHz ?? tone?.frequencyHz ?? candidateTone?.frequencyHz,
      halfWidthHz: comparisonBandHalfWidthHz,
      averagePowers: averagePowers,
      framePowers: framePowers,
      minimumBin: transformMinimumBin,
      binSpacing: binSpacing
    )
    if let lockedBand {
      tone?.independentBlockLevelsDB = lockedBand.independentBlockLevelsDB
      tone?.independentBlockBandCenterFrequencyHz = lockedBand.centerFrequencyHz
      tone?.independentBlockBandHalfWidthHz = lockedBand.halfWidthHz
      candidateTone?.independentBlockLevelsDB = lockedBand.independentBlockLevelsDB
      candidateTone?.independentBlockBandCenterFrequencyHz = lockedBand.centerFrequencyHz
      candidateTone?.independentBlockBandHalfWidthHz = lockedBand.halfWidthHz
    }

    let lowFrequencyPower = broadbandIndices.reduce(0.0) { $0 + averagePowers[$1] }
    let lowFrequencyLevel = levelDB(forPower: lowFrequencyPower)
    let frameLowFrequencyLevels = framePowers.map { powers in
      levelDB(forPower: broadbandIndices.reduce(0.0) { $0 + powers[$1] })
    }

    var qualityIssues = captureIssues
    if lowFrequencyLevel < -90 {
      qualityIssues.insert(.inputTooQuiet)
    }
    let clippedSampleCount = samples.lazy.filter { abs($0) >= 0.995 }.count
    if clippedSampleCount >= 3 {
      qualityIssues.insert(.clipping)
    }
    if standardDeviation(frameLowFrequencyLevels) > 4 {
      qualityIssues.insert(.unstableEnvironment)
    }
    if let lockedBand,
      lockedBand.levelSpreadDB > configuration.stableLevelSpreadDB
    {
      qualityIssues.insert(.unstableEnvironment)
    }

    let spectrogramFrequencies = spectrogramFrequencies(
      minimum: configuration.minimumFrequencyHz,
      maximum: configuration.maximumFrequencyHz,
      step: configuration.spectrogramStepHz
    )
    let spectrogram = makeSpectrogram(
      framePowers: framePowers,
      frequencies: spectrogramFrequencies,
      minimumBin: transformMinimumBin,
      binSpacing: binSpacing,
      bucketWidthHz: configuration.spectrogramStepHz,
      hopSeconds: Double(hopSampleCount) / sampleRate
    )

    return AcousticAnalysis(
      measuredAt: measuredAt,
      durationSeconds: Double(samples.count) / sampleRate,
      sampleRate: sampleRate,
      inputRouteID: inputRouteID,
      inputRouteName: inputRouteName,
      inputChannelCount: inputChannelCount,
      selectedInputChannelIndex: selectedInputChannelIndex,
      analysisVersion: Self.version,
      configuration: configuration,
      windowSampleCount: windowSampleCount,
      binSpacingHz: binSpacing,
      nominalFrequencyResolutionHz: 2 * binSpacing,
      lowFrequencyLevelDB: lowFrequencyLevel,
      spectrum: spectrum,
      spectrogramFrequenciesHz: spectrogramFrequencies,
      spectrogram: spectrogram,
      tone: tone,
      candidateTone: candidateTone,
      soundPattern: toneDetection.pattern,
      lockedBand: lockedBand,
      quality: quality(for: qualityIssues)
    )
  }
}

extension LowFrequencyAnalyzer {
  fileprivate struct Peak {
    var index: Int
    var frequencyHz: Double
    var binLevelDB: Double
    var levelDB: Double
    var prominenceDB: Double
  }

  fileprivate struct FrameObservation {
    var frameIndex: Int
    var peak: Peak
    var levelDB: Double
  }

  fileprivate struct ToneDetection {
    var tone: ToneAnalysis?
    var candidateTone: ToneAnalysis?
    var pattern: LowFrequencySoundPattern
  }

  fileprivate func detectTone(
    averagePowers: [Double],
    framePowers: [[Double]],
    minimumBin: Int,
    binSpacing: Double,
    hopSeconds: Double
  ) -> ToneDetection {
    let peaks = findPeaks(
      powers: averagePowers,
      minimumBin: minimumBin,
      binSpacing: binSpacing,
      minimumProminenceDB: configuration.minimumToneProminenceDB
    )
    guard !peaks.isEmpty else {
      return ToneDetection(tone: nil, candidateTone: nil, pattern: .distributedEnergy)
    }

    let strongestLevel = peaks.map(\.levelDB).max() ?? -160
    let scored = peaks.map { peak -> (Peak, Double) in
      let approximateHarmonics = averageHarmonicMatches(
        for: peak, among: peaks, binSpacing: binSpacing)
      let relativeStrength = (peak.levelDB - strongestLevel) / 10
      return (peak, relativeStrength + Double(approximateHarmonics.count) * 0.8)
    }
    let primary = scored.max { $0.1 < $1.1 }?.0 ?? peaks[0]

    let localObservations = framePowers.enumerated().compactMap { frameIndex, powers in
      frameObservation(
        frameIndex: frameIndex,
        powers: powers,
        near: primary.index,
        minimumBin: minimumBin,
        binSpacing: binSpacing
      )
    }
    let driftingObservations = coherentDriftingObservations(
      framePowers: framePowers,
      minimumBin: minimumBin,
      binSpacing: binSpacing
    )
    let initialObservations = driftingObservations ?? localObservations
    guard !initialObservations.isEmpty else {
      return ToneDetection(tone: nil, candidateTone: nil, pattern: .distributedEnergy)
    }
    let persistence = Double(initialObservations.count) / Double(framePowers.count)

    let frequencySpread = robustSpread(initialObservations.map(\.peak.frequencyHz))
    let targetHalfWidthHz = min(max(max(1, 3 * frequencySpread), 1), 3)
    let observations = initialObservations.map { observation in
      var updated = observation
      updated.levelDB = bandLevel(
        powers: framePowers[observation.frameIndex],
        centerIndex: observation.peak.index,
        halfWidthHz: targetHalfWidthHz,
        binSpacing: binSpacing
      )
      return updated
    }
    let levelSpread = standardDeviation(observations.map(\.levelDB))
    let stable =
      frequencySpread <= configuration.stableFrequencySpreadHz
      && levelSpread <= configuration.stableLevelSpreadDB

    let targetLevel = bandLevel(
      powers: averagePowers,
      centerIndex: primary.index,
      halfWidthHz: targetHalfWidthHz,
      binSpacing: binSpacing
    )
    let harmonics = confirmedHarmonics(
      for: primary,
      among: peaks,
      framePowers: framePowers,
      fundamentalObservations: observations,
      minimumBin: minimumBin,
      binSpacing: binSpacing
    )
    let competitors =
      peaks
      .filter { peak in
        peak.index != primary.index
          && peak.levelDB >= targetLevel - 3
          && !isHarmonic(peak.frequencyHz, of: primary.frequencyHz, binSpacing: binSpacing)
      }
      .map(\.frequencyHz)

    let confidence: AnalysisConfidence
    if primary.prominenceDB >= 12,
      persistence >= configuration.highConfidencePersistence,
      frequencySpread <= configuration.highConfidenceFrequencySpreadHz,
      levelSpread <= configuration.highConfidenceLevelSpreadDB,
      competitors.isEmpty
    {
      confidence = .high
    } else if primary.prominenceDB >= configuration.minimumToneProminenceDB,
      persistence >= configuration.minimumTonePersistence,
      stable
    {
      confidence = .medium
    } else {
      confidence = .low
    }

    let observationsByFrame = Dictionary(
      uniqueKeysWithValues: observations.map { ($0.frameIndex, $0) })
    let frameTrace = framePowers.indices.map { frameIndex in
      let observation = observationsByFrame[frameIndex]
      return ToneFrameSample(
        offsetSeconds: Double(frameIndex) * hopSeconds,
        frequencyHz: observation?.peak.frequencyHz,
        levelDB: observation?.levelDB
      )
    }
    let candidate = ToneAnalysis(
      frequencyHz: primary.frequencyHz,
      levelDB: targetLevel,
      prominenceDB: primary.prominenceDB,
      persistence: persistence,
      frequencySpreadHz: frequencySpread,
      levelSpreadDB: levelSpread,
      harmonics: harmonics,
      competingToneFrequenciesHz: competitors,
      frameTrace: frameTrace,
      independentBlockLevelsDB: [],
      isStable: stable,
      confidence: confidence
    )
    let pattern: LowFrequencySoundPattern
    if persistence < configuration.minimumTonePersistence {
      pattern = .intermittentTone
    } else if !competitors.isEmpty {
      pattern = .multipleTones
    } else if frequencySpread > configuration.stableFrequencySpreadHz {
      pattern = .driftingTone
    } else if levelSpread > configuration.stableLevelSpreadDB {
      pattern = .varyingLevelTone
    } else {
      pattern = .stableTone
    }
    return ToneDetection(
      tone: persistence >= configuration.minimumTonePersistence ? candidate : nil,
      candidateTone: persistence < configuration.minimumTonePersistence ? candidate : nil,
      pattern: pattern
    )
  }

  fileprivate func makeLockedBand(
    centerFrequencyHz: Double?,
    halfWidthHz: Double,
    averagePowers: [Double],
    framePowers: [[Double]],
    minimumBin: Int,
    binSpacing: Double
  ) -> LockedBandAnalysis? {
    guard let centerFrequencyHz,
      centerFrequencyHz.isFinite,
      centerFrequencyHz >= configuration.minimumFrequencyHz,
      centerFrequencyHz <= configuration.maximumFrequencyHz,
      halfWidthHz.isFinite,
      halfWidthHz > 0
    else { return nil }

    // The transform includes guard bins beyond the public 10–500 Hz search
    // range. Keep a symmetric locked band at either edge so a small frequency
    // shift cannot look like a level change merely because half the band was
    // clipped by the public range.
    let lowerFrequency = max(0, centerFrequencyHz - halfWidthHz)
    let upperFrequency = centerFrequencyHz + halfWidthHz
    let bandIndices = indices(
      from: lowerFrequency,
      through: upperFrequency,
      minimumBin: minimumBin,
      binSpacing: binSpacing,
      count: averagePowers.count
    )
    guard !bandIndices.isEmpty else { return nil }

    let independentBlockLevels = framePowers.indices
      .filter { $0.isMultiple(of: 2) }
      .map { frameIndex in
        levelDB(forPower: bandIndices.reduce(0.0) { $0 + framePowers[frameIndex][$1] })
      }
    return LockedBandAnalysis(
      centerFrequencyHz: centerFrequencyHz,
      halfWidthHz: halfWidthHz,
      levelDB: levelDB(forPower: bandIndices.reduce(0.0) { $0 + averagePowers[$1] }),
      independentBlockLevelsDB: independentBlockLevels,
      levelSpreadDB: standardDeviation(independentBlockLevels)
    )
  }

  fileprivate func findPeaks(
    powers: [Double],
    minimumBin: Int,
    binSpacing: Double,
    minimumProminenceDB: Double
  ) -> [Peak] {
    guard powers.count >= 3 else { return [] }
    let levels = powers.map(levelDB(forPower:))
    var peaks: [Peak] = []
    for index in 1..<powers.count - 1
    where levels[index] > levels[index - 1] && levels[index] >= levels[index + 1] {
      let frequency = Double(index + minimumBin) * binSpacing
      guard frequency >= configuration.minimumFrequencyHz,
        frequency <= configuration.maximumFrequencyHz
      else { continue }
      let prominence = bandProminence(powers: powers, at: index, binSpacing: binSpacing)
      guard prominence >= minimumProminenceDB else { continue }
      peaks.append(
        interpolatedPeak(
          powers: powers,
          levels: levels,
          at: index,
          minimumBin: minimumBin,
          binSpacing: binSpacing,
          prominence: prominence
        )
      )
    }
    return peaks.sorted { $0.levelDB > $1.levelDB }
  }

  fileprivate func frameObservation(
    frameIndex: Int,
    powers: [Double],
    near primaryIndex: Int,
    minimumBin: Int,
    binSpacing: Double
  ) -> FrameObservation? {
    let levels = powers.map(levelDB(forPower:))
    let searchRadius = max(2, Int(ceil(max(1.5, 2 * binSpacing) / binSpacing)))
    let lower = max(1, primaryIndex - searchRadius)
    let upper = min(levels.count - 2, primaryIndex + searchRadius)
    guard lower <= upper else { return nil }
    let index = (lower...upper).max { levels[$0] < levels[$1] } ?? primaryIndex
    guard levels[index] >= levels[index - 1], levels[index] >= levels[index + 1] else { return nil }
    let prominence = bandProminence(powers: powers, at: index, binSpacing: binSpacing)
    guard prominence >= configuration.minimumFrameProminenceDB else { return nil }
    let peak = interpolatedPeak(
      powers: powers,
      levels: levels,
      at: index,
      minimumBin: minimumBin,
      binSpacing: binSpacing,
      prominence: prominence
    )
    return FrameObservation(
      frameIndex: frameIndex,
      peak: peak,
      levelDB: bandLevel(powers: powers, centerIndex: index, halfWidthHz: 1, binSpacing: binSpacing)
    )
  }

  fileprivate func coherentDriftingObservations(
    framePowers: [[Double]],
    minimumBin: Int,
    binSpacing: Double
  ) -> [FrameObservation]? {
    let observations: [FrameObservation] = framePowers.enumerated().compactMap {
      pair -> FrameObservation? in
      let (frameIndex, powers) = pair
      guard
        let peak = findPeaks(
          powers: powers,
          minimumBin: minimumBin,
          binSpacing: binSpacing,
          minimumProminenceDB: configuration.minimumFrameProminenceDB
        ).first
      else { return nil }
      return FrameObservation(
        frameIndex: frameIndex,
        peak: peak,
        levelDB: bandLevel(
          powers: powers,
          centerIndex: peak.index,
          halfWidthHz: 1,
          binSpacing: binSpacing
        )
      )
    }
    let persistence = Double(observations.count) / Double(framePowers.count)
    guard persistence >= configuration.minimumTonePersistence,
      robustSpread(observations.map(\.peak.frequencyHz))
        > configuration.stableFrequencySpreadHz
    else { return nil }

    let maximumStepHz = max(2.5, 7 * binSpacing)
    let isContinuous = zip(observations, observations.dropFirst()).allSatisfy { pair in
      let (before, after) = pair
      let frameGap = max(1, after.frameIndex - before.frameIndex)
      return abs(after.peak.frequencyHz - before.peak.frequencyHz)
        <= maximumStepHz * Double(frameGap)
    }
    return isContinuous ? observations : nil
  }

  fileprivate func interpolatedPeak(
    powers: [Double],
    levels: [Double],
    at index: Int,
    minimumBin: Int,
    binSpacing: Double,
    prominence: Double
  ) -> Peak {
    let left = levels[index - 1]
    let center = levels[index]
    let right = levels[index + 1]
    let denominator = left - 2 * center + right
    let rawOffset = denominator < -1e-12 ? 0.5 * (left - right) / denominator : 0
    let offset = min(max(rawOffset, -0.5), 0.5)
    let interpolatedBinLevel = center - 0.25 * (left - right) * offset
    return Peak(
      index: index,
      frequencyHz: Double(index + minimumBin) * binSpacing + offset * binSpacing,
      binLevelDB: interpolatedBinLevel,
      levelDB: bandLevel(
        powers: powers, centerIndex: index, halfWidthHz: 1, binSpacing: binSpacing),
      prominenceDB: prominence
    )
  }

  fileprivate func bandProminence(powers: [Double], at index: Int, binSpacing: Double) -> Double {
    let centerRadius = max(1, Int(ceil(1 / binSpacing)))
    let centerLower = max(0, index - centerRadius)
    let centerUpper = min(powers.count - 1, index + centerRadius)
    let centerPower = powers[centerLower...centerUpper].reduce(0, +)
    let centerCount = centerUpper - centerLower + 1

    let innerRadius = max(centerRadius + 1, Int(ceil(3 / binSpacing)))
    let outerRadius = max(innerRadius, Int(floor(12 / binSpacing)))
    var background: [Double] = []
    for candidate in max(0, index - outerRadius)...min(powers.count - 1, index + outerRadius) {
      let distance = abs(candidate - index)
      if distance >= innerRadius, distance <= outerRadius {
        background.append(powers[candidate])
      }
    }
    guard let backgroundMedian = median(background), backgroundMedian > 0 else { return 0 }
    return 10 * log10(max(centerPower, 1e-16) / (Double(centerCount) * backgroundMedian))
  }

  fileprivate func bandLevel(
    powers: [Double],
    centerIndex: Int,
    halfWidthHz: Double,
    binSpacing: Double
  ) -> Double {
    let radius = max(1, Int(ceil(halfWidthHz / binSpacing)))
    let lower = max(0, centerIndex - radius)
    let upper = min(powers.count - 1, centerIndex + radius)
    return levelDB(forPower: powers[lower...upper].reduce(0, +))
  }

  fileprivate func averageHarmonicMatches(
    for fundamental: Peak, among peaks: [Peak], binSpacing: Double
  ) -> [Peak] {
    guard fundamental.frequencyHz > 0 else { return [] }
    let maximumOrder = min(8, Int(configuration.maximumFrequencyHz / fundamental.frequencyHz))
    guard maximumOrder >= 2 else { return [] }
    let tolerance = max(configuration.harmonicToleranceFloorHz, 2 * binSpacing)
    return (2...maximumOrder).compactMap { order in
      let expected = fundamental.frequencyHz * Double(order)
      return
        peaks
        .filter { abs($0.frequencyHz - expected) <= tolerance }
        .min { abs($0.frequencyHz - expected) < abs($1.frequencyHz - expected) }
    }
  }

  fileprivate func confirmedHarmonics(
    for fundamental: Peak,
    among peaks: [Peak],
    framePowers: [[Double]],
    fundamentalObservations: [FrameObservation],
    minimumBin: Int,
    binSpacing: Double
  ) -> [HarmonicEvidence] {
    let matches = averageHarmonicMatches(for: fundamental, among: peaks, binSpacing: binSpacing)
    let tolerance = max(configuration.harmonicToleranceFloorHz, 2 * binSpacing)
    guard !fundamentalObservations.isEmpty else { return [] }

    return matches.compactMap { match in
      let order = Int((match.frequencyHz / fundamental.frequencyHz).rounded())
      guard order >= 2 else { return nil }
      var coOccurrences = 0
      var prominences: [Double] = []

      for observation in fundamentalObservations {
        let expected = observation.peak.frequencyHz * Double(order)
        let expectedLocalIndex = Int((expected / binSpacing).rounded()) - minimumBin
        let radius = max(1, Int(ceil(tolerance / binSpacing)))
        let powers = framePowers[observation.frameIndex]
        let lower = max(1, expectedLocalIndex - radius)
        let upper = min(powers.count - 2, expectedLocalIndex + radius)
        guard lower <= upper else { continue }
        let levels = powers.map(levelDB(forPower:))
        let index = (lower...upper).max { levels[$0] < levels[$1] } ?? expectedLocalIndex
        guard levels[index] >= levels[index - 1], levels[index] >= levels[index + 1] else {
          continue
        }
        let prominence = bandProminence(powers: powers, at: index, binSpacing: binSpacing)
        guard prominence >= configuration.minimumFrameProminenceDB else { continue }
        let frequency = interpolatedPeak(
          powers: powers,
          levels: levels,
          at: index,
          minimumBin: minimumBin,
          binSpacing: binSpacing,
          prominence: prominence
        ).frequencyHz
        guard abs(frequency - expected) <= tolerance else { continue }
        coOccurrences += 1
        prominences.append(prominence)
      }

      let coOccurrenceRate = Double(coOccurrences) / Double(fundamentalObservations.count)
      guard coOccurrenceRate >= configuration.harmonicCoOccurrence,
        let medianProminence = median(prominences),
        medianProminence >= configuration.minimumFrameProminenceDB
      else { return nil }
      return HarmonicEvidence(
        order: order,
        frequencyHz: match.frequencyHz,
        levelDB: match.levelDB,
        prominenceDB: medianProminence
      )
    }
    .sorted { $0.order < $1.order }
  }

  fileprivate func isHarmonic(_ frequency: Double, of fundamental: Double, binSpacing: Double)
    -> Bool
  {
    guard fundamental > 0 else { return false }
    let order = (frequency / fundamental).rounded()
    guard order >= 2 else { return false }
    let tolerance = max(configuration.harmonicToleranceFloorHz, 2 * binSpacing)
    return abs(frequency - order * fundamental) <= tolerance
  }

  fileprivate func makeSpectrogram(
    framePowers: [[Double]],
    frequencies: [Double],
    minimumBin: Int,
    binSpacing: Double,
    bucketWidthHz: Double,
    hopSeconds: Double
  ) -> [SpectrogramSlice] {
    let halfWidth = bucketWidthHz / 2
    return framePowers.enumerated().map { frameIndex, powers in
      let levels = frequencies.map { frequency -> Double in
        let lowerFrequency = max(configuration.minimumFrequencyHz, frequency - halfWidth)
        let upperFrequency = min(configuration.maximumFrequencyHz, frequency + halfWidth)
        let bucketIndices = indices(
          from: lowerFrequency,
          below: upperFrequency,
          minimumBin: minimumBin,
          binSpacing: binSpacing,
          count: powers.count
        )
        return levelDB(forPower: bucketIndices.reduce(0.0) { $0 + powers[$1] })
      }
      return SpectrogramSlice(offsetSeconds: Double(frameIndex) * hopSeconds, levelsDB: levels)
    }
  }

  fileprivate func spectrogramFrequencies(minimum: Double, maximum: Double, step: Double)
    -> [Double]
  {
    guard step > 0 else { return [] }
    return stride(from: minimum, to: maximum, by: step).map { lowerEdge in
      min(lowerEdge + step / 2, maximum)
    }
  }

  fileprivate func indices(
    from lowerFrequency: Double,
    through upperFrequency: Double,
    minimumBin: Int,
    binSpacing: Double,
    count: Int
  ) -> [Int] {
    let lower = max(0, Int(ceil(lowerFrequency / binSpacing)) - minimumBin)
    let upper = min(count - 1, Int(floor(upperFrequency / binSpacing)) - minimumBin)
    guard lower <= upper else { return [] }
    return Array(lower...upper)
  }

  fileprivate func indices(
    from lowerFrequency: Double,
    below upperFrequency: Double,
    minimumBin: Int,
    binSpacing: Double,
    count: Int
  ) -> [Int] {
    let lower = max(0, Int(ceil(lowerFrequency / binSpacing)) - minimumBin)
    let upper = min(count - 1, Int(ceil(upperFrequency / binSpacing)) - minimumBin - 1)
    guard lower <= upper else { return [] }
    return Array(lower...upper)
  }

  fileprivate func quality(for issues: Set<MeasurementQualityIssue>) -> MeasurementQuality {
    var score = 1.0
    for issue in issues {
      switch issue {
      case .externalInterruption, .insufficientDuration, .routeChanged,
        .engineConfigurationChanged, .mediaServicesReset, .appBackgrounded:
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

  fileprivate func average(_ frames: [[Double]]) -> [Double] {
    guard let first = frames.first else { return [] }
    var result = [Double](repeating: 0, count: first.count)
    for frame in frames {
      for index in result.indices {
        result[index] += frame[index]
      }
    }
    return result.map { $0 / Double(frames.count) }
  }

  fileprivate func levelDB(forPower value: Double) -> Double {
    10 * log10(max(value, 1e-16))
  }

  fileprivate func median(_ values: [Double]) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }

  fileprivate func robustSpread(_ values: [Double]) -> Double {
    guard let center = median(values), !values.isEmpty else { return 0 }
    let deviations = values.map { abs($0 - center) }
    return 1.4826 * (median(deviations) ?? 0)
  }

  fileprivate func standardDeviation(_ values: [Double]) -> Double {
    guard values.count > 1 else { return 0 }
    let mean = values.reduce(0, +) / Double(values.count)
    let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
    return variance.squareRoot()
  }

  fileprivate func nextPowerOfTwo(_ value: Int) -> Int {
    var result = 1
    while result < value {
      result <<= 1
    }
    return result
  }
}
