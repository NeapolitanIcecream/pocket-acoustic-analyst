import Foundation

struct TargetBandLevel: Equatable, Sendable {
  var centerFrequencyHz: Double
  var halfWidthHz: Double
  var levelDB: Double
}

struct TargetBandLevelCalculator: Sendable {
  func measure(
    in analysis: AcousticAnalysis,
    targetFrequencyHz: Double,
    halfWidthHz requestedHalfWidthHz: Double? = nil
  ) -> TargetBandLevel? {
    guard targetFrequencyHz.isFinite, targetFrequencyHz > 0 else { return nil }
    let spread = analysis.tone?.frequencySpreadHz ?? 0
    let halfWidth = min(max(requestedHalfWidthHz ?? max(1, 3 * spread), 1), 3)
    let selected = analysis.spectrum.filter {
      abs($0.frequencyHz - targetFrequencyHz) <= halfWidth
    }
    guard !selected.isEmpty else { return nil }
    let power = selected.reduce(0.0) { $0 + pow(10, $1.levelDB / 10) }
    guard power > 0 else { return nil }
    return TargetBandLevel(
      centerFrequencyHz: targetFrequencyHz,
      halfWidthHz: halfWidth,
      levelDB: 10 * log10(power)
    )
  }
}
