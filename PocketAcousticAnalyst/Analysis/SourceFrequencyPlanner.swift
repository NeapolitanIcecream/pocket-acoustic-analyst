import Foundation

struct SourceFrequencyPlan: Equatable, Sendable {
  var targetBands: [SourceFrequencyBand]
  var guardBands: [FrequencyBandDefinition]

  var trackedBands: [FrequencyBandDefinition] {
    targetBands.map {
      FrequencyBandDefinition(
        centerFrequencyHz: $0.centerFrequencyHz,
        halfWidthHz: $0.halfWidthHz
      )
    } + guardBands
  }
}

struct SourceFrequencyPlanner: Sendable {
  var maximumTargetBandCount = 4
  var minimumComponentPersistence = 0.25
  var maximumTargetHalfWidthHz = 3.0

  func makePlan(from analysis: AcousticAnalysis) -> SourceFrequencyPlan? {
    let resolution = analysis.nominalFrequencyResolutionHz
    let tolerance = max(1, resolution)
    let boundaryTolerance = max(analysis.nominalFrequencyResolutionHz, 1e-9)
    let components = componentCandidates(from: analysis)
      .compactMap { component -> SpectralComponentEvidence? in
        guard
          component.frequencyHz >= analysis.configuration.minimumFrequencyHz - boundaryTolerance,
          component.frequencyHz <= analysis.configuration.maximumFrequencyHz + boundaryTolerance
        else { return nil }
        var bounded = component
        bounded.frequencyHz = min(
          max(component.frequencyHz, analysis.configuration.minimumFrequencyHz),
          analysis.configuration.maximumFrequencyHz
        )
        return bounded
      }
      .filter {
        $0.prominenceDB >= analysis.configuration.minimumToneProminenceDB
          && $0.persistence >= minimumComponentPersistence
      }
      .sorted { $0.frequencyHz < $1.frequencyHz }
    guard !components.isEmpty else { return nil }

    var completeLinkageGroups: [[SpectralComponentEvidence]] = []
    for component in components {
      if let last = completeLinkageGroups.indices.last,
        completeLinkageGroups[last].allSatisfy({
          abs($0.frequencyHz - component.frequencyHz) <= tolerance
        })
      {
        completeLinkageGroups[last].append(component)
      } else {
        completeLinkageGroups.append([component])
      }
    }

    var grouped = completeLinkageGroups.map { makeCandidateGroup($0, resolution: resolution) }
    grouped.sort { $0.band.centerFrequencyHz < $1.band.centerFrequencyHz }

    var merged: [CandidateGroup] = []
    for candidate in grouped {
      guard let last = merged.last else {
        merged.append(candidate)
        continue
      }
      let lastUpper = last.band.centerFrequencyHz + last.band.halfWidthHz
      let candidateLower = candidate.band.centerFrequencyHz - candidate.band.halfWidthHz
      if candidateLower <= lastUpper {
        let combined = last.components + candidate.components
        merged[merged.count - 1] = makeCandidateGroup(combined, resolution: resolution)
      } else {
        merged.append(candidate)
      }
    }

    let trackable = merged.filter { $0.requiredHalfWidthHz <= maximumTargetHalfWidthHz }
    let selected =
      trackable
      .sorted { $0.strongestLevelDB > $1.strongestLevelDB }
      .prefix(maximumTargetBandCount)
      .map(\.band)
      .sorted { $0.centerFrequencyHz < $1.centerFrequencyHz }
    guard !selected.isEmpty else { return nil }

    let exclusionRanges = merged.map { candidate in
      (
        candidate.band.centerFrequencyHz - candidate.band.halfWidthHz - 2,
        candidate.band.centerFrequencyHz + candidate.band.halfWidthHz + 2
      )
    }
    let guardBands = makeGuardBands(
      minimumFrequencyHz: analysis.configuration.minimumFrequencyHz,
      maximumFrequencyHz: analysis.configuration.maximumFrequencyHz,
      excluding: exclusionRanges
    )
    guard guardBands.count >= 3 else { return nil }
    return SourceFrequencyPlan(targetBands: selected, guardBands: guardBands)
  }
}

extension SourceFrequencyPlanner {
  fileprivate struct CandidateGroup {
    var components: [SpectralComponentEvidence]
    var band: SourceFrequencyBand
    var requiredHalfWidthHz: Double
    var strongestLevelDB: Double
  }

  fileprivate func componentCandidates(from analysis: AcousticAnalysis)
    -> [SpectralComponentEvidence]
  {
    if let components = analysis.spectralComponents, !components.isEmpty {
      return components
    }
    guard let tone = analysis.bestToneEvidence else { return [] }
    var fallback = [
      SpectralComponentEvidence(
        frequencyHz: tone.frequencyHz,
        levelDB: tone.levelDB,
        prominenceDB: tone.prominenceDB,
        persistence: tone.persistence,
        frequencySpreadHz: tone.frequencySpreadHz
      )
    ]
    fallback += tone.harmonics.map {
      SpectralComponentEvidence(
        frequencyHz: $0.frequencyHz,
        levelDB: $0.levelDB,
        prominenceDB: $0.prominenceDB,
        persistence: tone.persistence,
        frequencySpreadHz: tone.frequencySpreadHz
      )
    }
    fallback += tone.competingToneFrequenciesHz.map { frequency in
      SpectralComponentEvidence(
        frequencyHz: frequency,
        levelDB: tone.levelDB,
        prominenceDB: tone.prominenceDB,
        persistence: tone.persistence,
        frequencySpreadHz: tone.frequencySpreadHz
      )
    }
    return fallback
  }

  fileprivate func makeCandidateGroup(
    _ components: [SpectralComponentEvidence],
    resolution: Double
  ) -> CandidateGroup {
    let frequencies = components.map(\.frequencyHz).sorted()
    let middle = frequencies.count / 2
    let center =
      frequencies.count.isMultiple(of: 2)
      ? (frequencies[middle - 1] + frequencies[middle]) / 2
      : frequencies[middle]
    let requiredHalfWidth = max(
      1,
      (frequencies.map { abs($0 - center) }.max() ?? 0) + resolution
    )
    return CandidateGroup(
      components: components,
      band: SourceFrequencyBand(
        centerFrequencyHz: center,
        halfWidthHz: min(maximumTargetHalfWidthHz, requiredHalfWidth),
        memberFrequenciesHz: frequencies,
        containsUnresolvedComponents: frequencies.count > 1
      ),
      requiredHalfWidthHz: requiredHalfWidth,
      strongestLevelDB: components.map(\.levelDB).max() ?? -.infinity
    )
  }

  fileprivate func makeGuardBands(
    minimumFrequencyHz: Double,
    maximumFrequencyHz: Double,
    excluding ranges: [(Double, Double)]
  ) -> [FrequencyBandDefinition] {
    let halfWidth = 10.0
    let firstCenter = minimumFrequencyHz + halfWidth
    guard firstCenter <= maximumFrequencyHz else { return [] }
    return stride(from: firstCenter, through: maximumFrequencyHz - halfWidth, by: 40)
      .compactMap { center in
        let lower = center - halfWidth
        let upper = center + halfWidth
        guard ranges.allSatisfy({ upper < $0.0 || lower > $0.1 }) else { return nil }
        return FrequencyBandDefinition(centerFrequencyHz: center, halfWidthHz: halfWidth)
      }
  }
}
