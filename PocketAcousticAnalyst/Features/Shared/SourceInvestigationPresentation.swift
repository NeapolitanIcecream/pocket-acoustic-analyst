import Foundation

struct SourceInvestigationPresentation: Equatable, Sendable {
  var title: String
  var subtitle: String
  var evidence: String
  var interpretation: String
  var limitation: String
  var action: String
}

enum SourceInvestigationAccessibilityCopy {
  static func completed(_ completed: Int, total: Int) -> String {
    "已完成 \(completed) 次，共 \(total) 次"
  }

  static func countdown(_ seconds: Int) -> String {
    "距离开始还有 \(seconds) 秒"
  }

  static func recordingLabel(sequenceIndex: Int) -> String {
    "第 \(sequenceIndex + 1) 次录音进度"
  }

  static func recordingValue(progress: Double) -> String {
    "已完成 \(Int(progress * 100))%"
  }
}

extension SourceInvestigationRound {
  var overallEvidenceText: String {
    guard lowFrequencyRelationship != nil,
      lowFrequencyRelationship != .inconclusive,
      let lowFrequencyDeltaDB
    else {
      return "第 \(roundNumber) 轮：整体低频变化没有足够证据"
    }
    let delta =
      "\(lowFrequencyDeltaDB >= 0 ? "+" : "")"
      + lowFrequencyDeltaDB.formatted(.number.precision(.fractionLength(1)))
    return "第 \(roundNumber) 轮整体低频：\(delta) dB"
  }
}

extension SourceInvestigationEvaluation {
  var resultPresentation: SourceInvestigationPresentation {
    switch verdict {
    case .frequencySpecificSynchronization:
      guard let band = strongestSynchronizedBand,
        let delta = band.meanChangedDeltaDB
      else { return inconclusivePresentation }
      let direction = delta < 0 ? "降低" : "升高"
      return SourceInvestigationPresentation(
        title: "发现重复同步的频率变化",
        subtitle:
          "“\(changedStateName)”时，约 \(wholeFrequency(band.frequencyHz)) 连续三轮\(direction)",
        evidence:
          "三轮都按“\(baselineStateName) → \(changedStateName) → \(baselineStateName)”测量。这个频率组在中间状态平均变化 \(signed(delta))，恢复原状态后回到允许范围内。",
        interpretation: "这个频率组与本次记录的状态变化重复同步，是下一步最值得继续验证的线索。",
        limitation:
          "同步变化不能证明“\(subjectName)”是声源，也不能确定唯一来源。操作时同时发生的负载、风扇、音频输出或其他环境变化仍可能影响结果。",
        action: "保持手机和其他条件不变，再把这项变化拆得更小，或用相同流程逐项测试另一台设备。"
      )

    case .overallLowFrequencySynchronization:
      let deltas = rounds.compactMap(\.lowFrequencyDeltaDB)
      let mean = deltas.isEmpty ? 0 : deltas.reduce(0, +) / Double(deltas.count)
      let direction = mean < 0 ? "降低" : "升高"
      return SourceInvestigationPresentation(
        title: "整体低频与状态变化同步",
        subtitle: "“\(changedStateName)”时，10–500 Hz 整体连续三轮\(direction)",
        evidence:
          "多个不重叠频段一起变化，没有一个候选频率表现出足够独立的变化。三轮整体平均变化约为 \(signed(mean))。",
        interpretation: "本次状态变化与整体低频读数同步，但还不能把变化归到某一个频率组。",
        limitation: "整体变化也可能来自输入增益、其他同时变化的声音或环境条件，不能据此确定设备来源。",
        action: "保持设备状态不变做一次对照复测，或把这项操作拆成更单一的变化。"
      )

    case .noConsistentSynchronization:
      return SourceInvestigationPresentation(
        title: "没有找到稳定同步的变化",
        subtitle: "三轮结果没有在同一频率组保持相同方向",
        evidence: "至少有可用测量，但候选频率的变化较小、方向不一致，或只在部分轮次出现。",
        interpretation: "这次实验没有提供足够证据把某个低频线索与“\(changedStateName)”稳定联系起来。",
        limitation: "这不能排除“\(subjectName)”；设备负载可能没有改变，其他来源也可能遮住了变化。",
        action: "确认每轮只改变同一项并等待运行稳定，或改测一个差异更明确的状态。"
      )

    case .inconclusive:
      return inconclusivePresentation
    }
  }

  private var inconclusivePresentation: SourceInvestigationPresentation {
    SourceInvestigationPresentation(
      title: "这次状态调查不能判断",
      subtitle: "至少一项测量条件或恢复检查没有通过",
      evidence: "应用没有把不完整或不可比的批次合并成状态结论。",
      interpretation: "当前数据不足以判断候选频率是否与“\(changedStateName)”同步。",
      limitation: "未通过的批次不能用其他轮次补齐，也不能被解释为没有变化。",
      action: "按结果中的失败原因修正位置、麦克风或状态恢复后，从头完成三轮。"
    )
  }

  private func wholeFrequency(_ value: Double) -> String {
    "\(Int(value.rounded())) Hz"
  }

  private func signed(_ value: Double) -> String {
    "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
  }
}
