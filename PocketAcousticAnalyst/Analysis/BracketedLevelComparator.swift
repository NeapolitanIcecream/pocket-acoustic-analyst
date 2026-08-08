import Foundation

struct BracketedLevelSamples: Equatable, Sendable {
  var precedingBaseline: [Double]
  var changed: [Double]
  var followingBaseline: [Double]
}

struct BracketedLevelComparison: Equatable, Sendable {
  var baselineLevelDB: Double
  var changedLevelDB: Double
  var rawDeltaDB: Double
  var adjustedDeltaDB: Double
  var adjustedInterval: ConfidenceInterval
  var baselineReturnDifferenceDB: Double
  var relationship: SourceBandRelationship
}

struct BracketedLevelComparator: Sendable {
  var bootstrapIterationCount = 10_000
  var minimumIndependentBlockCount = 6
  var maximumBaselineReturnDifferenceDB = 2.0
  var minimumEffectDB = 3.0
  var minimumIntervalSeparationDB = 1.0

  func compare(
    precedingBaseline: [Double],
    changed: [Double],
    followingBaseline: [Double]
  ) -> BracketedLevelComparison? {
    let samples = BracketedLevelSamples(
      precedingBaseline: precedingBaseline,
      changed: changed,
      followingBaseline: followingBaseline
    )
    guard let point = pointEstimate(for: samples) else { return nil }
    var random = SourceComparisonRandomNumberGenerator(seed: 0x50A1_CE42)
    var differences = [Double]()
    differences.reserveCapacity(bootstrapIterationCount)
    for _ in 0..<bootstrapIterationCount {
      differences.append(resampledDifference(for: samples, random: &random))
    }
    let interval = confidenceInterval(for: differences)
    return BracketedLevelComparison(
      baselineLevelDB: point.baselineLevelDB,
      changedLevelDB: point.changedLevelDB,
      rawDeltaDB: point.rawDeltaDB,
      adjustedDeltaDB: point.rawDeltaDB,
      adjustedInterval: interval,
      baselineReturnDifferenceDB: point.baselineReturnDifferenceDB,
      relationship: classify(deltaDB: point.rawDeltaDB, interval: interval)
    )
  }

  func compareFrequencySpecific(
    target: BracketedLevelSamples,
    guards: [BracketedLevelSamples]
  ) -> BracketedLevelComparison? {
    guard let targetPoint = pointEstimate(for: target) else { return nil }
    let guardPoints = guards.compactMap(pointEstimate)
    guard guardPoints.count >= 3 else { return nil }
    let guardAdjustmentDB = median(guardPoints.map(\.rawDeltaDB))
    let adjustedDelta = targetPoint.rawDeltaDB - guardAdjustmentDB

    var random = SourceComparisonRandomNumberGenerator(seed: 0x50A1_CE42)
    var rawDifferences = [Double]()
    var adjustedDifferences = [Double]()
    rawDifferences.reserveCapacity(bootstrapIterationCount)
    adjustedDifferences.reserveCapacity(bootstrapIterationCount)
    for _ in 0..<bootstrapIterationCount {
      let targetDifference = resampledDifference(for: target, random: &random)
      let guardDifferences = guards.map {
        resampledDifference(for: $0, random: &random)
      }
      rawDifferences.append(targetDifference)
      adjustedDifferences.append(targetDifference - median(guardDifferences))
    }

    let rawInterval = confidenceInterval(for: rawDifferences)
    let adjustedInterval = confidenceInterval(for: adjustedDifferences)
    let rawRelationship = classify(deltaDB: targetPoint.rawDeltaDB, interval: rawInterval)
    let adjustedRelationship = classify(deltaDB: adjustedDelta, interval: adjustedInterval)
    return BracketedLevelComparison(
      baselineLevelDB: targetPoint.baselineLevelDB,
      changedLevelDB: targetPoint.changedLevelDB,
      rawDeltaDB: targetPoint.rawDeltaDB,
      adjustedDeltaDB: adjustedDelta,
      adjustedInterval: adjustedInterval,
      baselineReturnDifferenceDB: targetPoint.baselineReturnDifferenceDB,
      relationship: frequencySpecificRelationship(
        raw: rawRelationship,
        adjusted: adjustedRelationship
      )
    )
  }

  func aggregateLevel(_ levelsDB: [Double]) -> Double {
    guard !levelsDB.isEmpty else { return -.infinity }
    let meanPower = levelsDB.reduce(0.0) { $0 + pow(10, $1 / 10) } / Double(levelsDB.count)
    return 10 * log10(max(meanPower, 1e-16))
  }
}

extension BracketedLevelComparator {
  fileprivate struct PointEstimate {
    var baselineLevelDB: Double
    var changedLevelDB: Double
    var rawDeltaDB: Double
    var baselineReturnDifferenceDB: Double
  }

  fileprivate func pointEstimate(for samples: BracketedLevelSamples) -> PointEstimate? {
    guard samples.precedingBaseline.count >= minimumIndependentBlockCount,
      samples.changed.count >= minimumIndependentBlockCount,
      samples.followingBaseline.count >= minimumIndependentBlockCount
    else { return nil }

    let precedingLevel = aggregateLevel(samples.precedingBaseline)
    let followingLevel = aggregateLevel(samples.followingBaseline)
    let closure = followingLevel - precedingLevel
    guard abs(closure) <= maximumBaselineReturnDifferenceDB else { return nil }
    let baselineLevel = aggregateLevel(
      samples.precedingBaseline + samples.followingBaseline)
    let changedLevel = aggregateLevel(samples.changed)
    return PointEstimate(
      baselineLevelDB: baselineLevel,
      changedLevelDB: changedLevel,
      rawDeltaDB: changedLevel - baselineLevel,
      baselineReturnDifferenceDB: closure
    )
  }

  fileprivate func resampledDifference(
    for samples: BracketedLevelSamples,
    random: inout SourceComparisonRandomNumberGenerator
  ) -> Double {
    let baseline = samples.precedingBaseline + samples.followingBaseline
    let baselineSample = (0..<baseline.count).map { _ in
      baseline[Int(random.next() % UInt64(baseline.count))]
    }
    let changedSample = (0..<samples.changed.count).map { _ in
      samples.changed[Int(random.next() % UInt64(samples.changed.count))]
    }
    return aggregateLevel(changedSample) - aggregateLevel(baselineSample)
  }

  fileprivate func confidenceInterval(for differences: [Double]) -> ConfidenceInterval {
    let sorted = differences.sorted()
    let lowerIndex = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.05))
    let upperIndex = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
    return ConfidenceInterval(
      lowerDB: sorted[lowerIndex],
      upperDB: sorted[upperIndex],
      probability: 0.9
    )
  }

  fileprivate func classify(
    deltaDB: Double,
    interval: ConfidenceInterval
  ) -> SourceBandRelationship {
    if deltaDB <= -minimumEffectDB,
      interval.upperDB <= -minimumIntervalSeparationDB
    {
      return .lowerInChangedState
    }
    if deltaDB >= minimumEffectDB,
      interval.lowerDB >= minimumIntervalSeparationDB
    {
      return .higherInChangedState
    }
    if abs(deltaDB) < minimumEffectDB,
      interval.lowerDB >= -minimumEffectDB,
      interval.upperDB <= minimumEffectDB
    {
      return .littleChange
    }
    return .inconclusive
  }

  fileprivate func frequencySpecificRelationship(
    raw: SourceBandRelationship,
    adjusted: SourceBandRelationship
  ) -> SourceBandRelationship {
    if raw == .littleChange { return .littleChange }
    if adjusted == .littleChange,
      raw == .lowerInChangedState || raw == .higherInChangedState
    {
      return .littleChange
    }
    if raw == adjusted,
      raw == .lowerInChangedState || raw == .higherInChangedState
    {
      return raw
    }
    return .inconclusive
  }

  fileprivate func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    let middle = sorted.count / 2
    if sorted.count.isMultiple(of: 2) {
      return (sorted[middle - 1] + sorted[middle]) / 2
    }
    return sorted[middle]
  }
}

private struct SourceComparisonRandomNumberGenerator {
  private var state: UInt64

  init(seed: UInt64) {
    state = seed
  }

  mutating func next() -> UInt64 {
    state = state &* 6_364_136_223_846_793_005 &+ 1
    return state
  }
}
