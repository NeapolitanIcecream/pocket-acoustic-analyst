import SwiftUI

struct HistoryView: View {
  @Environment(AppModel.self) private var appModel

  var body: some View {
    Group {
      if appModel.completedSpatialScans.isEmpty,
        appModel.completedComparisons.isEmpty,
        appModel.completedAnalyses.isEmpty
      {
        ContentUnavailableView(
          "还没有保存的调查",
          systemImage: "clock.arrow.circlepath",
          description: Text("完成一次声音检查、空间扫描或前后对比后，可以在这里查看。")
        )
      } else {
        List {
          if !appModel.completedComparisons.isEmpty {
            Section("前后对比") {
              ForEach(appModel.completedComparisons.sorted(by: { $0.measuredAt > $1.measuredAt })) {
                comparison in
                ComparisonHistoryRow(comparison: comparison)
              }
            }
          }
          if !appModel.completedSpatialScans.isEmpty {
            Section("位置扫描") {
              ForEach(appModel.completedSpatialScans.sorted(by: { $0.measuredAt > $1.measuredAt }))
              { scan in
                SpatialHistoryRow(scan: scan)
              }
            }
          }
          if !standaloneAnalyses.isEmpty {
            Section("声音检查") {
              ForEach(standaloneAnalyses.sorted(by: { $0.measuredAt > $1.measuredAt })) {
                analysis in
                NavigationLink(value: AppModel.Route.analysisDetails(analysisID: analysis.id)) {
                  AnalysisHistoryRow(analysis: analysis)
                }
              }
            }
          }
          if appModel.historyLoadError || appModel.historySaveError {
            Section {
              Label("部分记录未能从本地文件读取或保存。", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            }
          }
        }
        .scrollContentBackground(.hidden)
        .background(AppTheme.warmBackground)
      }
    }
    .navigationTitle("调查记录")
    .navigationBarTitleDisplayMode(.inline)
  }

  private var standaloneAnalyses: [AcousticAnalysis] {
    let nestedIDs = Set(
      appModel.completedSpatialScans.flatMap { scan in
        (scan.measurements + scan.allOriginChecks).map(\.analysis.id)
      }
    ).union(
      appModel.completedComparisons.flatMap { [$0.beforeID, $0.afterID] }
    )
    return appModel.completedAnalyses.filter { !nestedIDs.contains($0.id) }
  }
}

private struct AnalysisHistoryRow: View {
  let analysis: AcousticAnalysis

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "waveform").foregroundStyle(AppTheme.accent)
      VStack(alignment: .leading, spacing: 4) {
        Text(analysis.resultPresentation.title)
          .font(.headline)
        Text(analysis.resultPresentation.subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(analysis.measuredAt, format: .dateTime.year().month().day().hour().minute())
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }
}

private struct SpatialHistoryRow: View {
  let scan: SpatialScanEvaluation

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "mappin.and.ellipse").foregroundStyle(AppTheme.accent)
      VStack(alignment: .leading, spacing: 4) {
        if let recommendation = scan.recommendation,
          let point = scan.measurements.first(where: {
            $0.id == recommendation.recommendedMeasurementID
          })
        {
          Text(
            "\(point.label)：目标频率比起点低约 \(recommendation.improvementDB.formatted(.number.precision(.fractionLength(1)))) dB"
          )
          .font(.headline)
          if let overallDelta = scan.pointComparison(for: point.id)?.lowFrequencyDeltaDB {
            Text("10–500 Hz 整体：\(signed(overallDelta))")
              .font(.caption)
              .foregroundStyle(overallDelta >= 3 ? .orange : .secondary)
          }
        } else {
          Text(scan.canRankMeasuredPoints ? "没有明显更低的实测点" : "扫描不可比")
            .font(.headline)
        }
        Text("约 \(Int(scan.targetFrequencyHz.rounded())) Hz · \(scan.measurements.count) 个位置")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private func signed(_ value: Double) -> String {
    "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
  }
}

private struct ComparisonHistoryRow: View {
  let comparison: MeasurementComparison

  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: comparisonIcon).foregroundStyle(comparisonColor)
      VStack(alignment: .leading, spacing: 4) {
        Text(comparisonTitle).font(.headline)
        if let frequency = comparison.targetFrequencyHz, let delta = comparison.targetDeltaDB {
          Text("约 \(Int(frequency.rounded())) Hz · \(signed(delta))")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private var comparisonTitle: String {
    switch comparison.verdict {
    case .improved:
      comparison.lowFrequencyDeltaDB >= 3
        ? "目标频带降低，整体低频升高" : "第二次测量降低"
    case .littleChange: "变化较小"
    case .worsened: "第二次测量升高"
    case .inconclusive: "无法可靠比较"
    }
  }

  private var comparisonIcon: String {
    if comparison.verdict == .improved, comparison.lowFrequencyDeltaDB >= 3 {
      return "exclamationmark.triangle"
    }
    return switch comparison.verdict {
    case .improved: "arrow.down.circle"
    case .littleChange: "minus.circle"
    case .worsened: "arrow.up.circle"
    case .inconclusive: "questionmark.circle"
    }
  }

  private var comparisonColor: Color {
    comparison.verdict == .improved && comparison.lowFrequencyDeltaDB >= 3
      ? .orange : AppTheme.accent
  }

  private func signed(_ value: Double) -> String {
    "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
  }
}
