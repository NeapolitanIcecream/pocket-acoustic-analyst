import SwiftUI

struct AcousticAnalysisDetailView: View {
  let analysis: AcousticAnalysis

  var body: some View {
    let presentation = analysis.resultPresentation
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        VStack(alignment: .leading, spacing: 8) {
          Text(presentation.title)
            .font(.largeTitle.bold())
            .lineLimit(2)
            .minimumScaleFactor(0.85)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
          Text(presentation.subtitle).font(.title3).foregroundStyle(.secondary)
        }

        DetailCard(title: "这次测到了什么", text: presentation.evidence)
        if let tone = analysis.bestToneEvidence {
          toneTimeline(tone)
          toneDetails(tone)
        }
        DetailCard(title: "为什么不能多说", text: presentation.limitation)
        DetailCard(title: "下一步", text: presentation.action)
        captureDetails
      }
      .padding(20)
    }
    .background(AppTheme.warmBackground)
    .navigationTitle("测量详情")
    .navigationBarTitleDisplayMode(.inline)
    .accessibilityIdentifier("analysisDetailView")
  }

  private func toneTimeline(_ tone: ToneAnalysis) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("音调出现时段").font(.headline)
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(tone.frameTrace) { sample in
          Capsule()
            .fill(sample.frequencyHz == nil ? Color.gray.opacity(0.25) : AppTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: sample.frequencyHz == nil ? 12 : 38)
        }
      }
      .frame(height: 42)
      Text("约 \(Int((tone.persistence * 100).rounded()))% 的分析时段找到候选音调")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }

  private func toneDetails(_ tone: ToneAnalysis) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("候选声音依据").font(.headline)
      Text("主要频率：\(Int(tone.frequencyHz.rounded())) Hz")
      Text("出现时段：\(Int((tone.persistence * 100).rounded()))%")
      Text(
        "频率变化：\(tone.frequencySpreadHz.formatted(.number.precision(.fractionLength(2)))) Hz"
      )
      Text(
        "强弱离散：\(tone.levelSpreadDB.formatted(.number.precision(.fractionLength(1)))) dB"
      )
      if !tone.competingToneFrequenciesHz.isEmpty {
        Text(
          "强度接近的其他频率：\(tone.competingToneFrequenciesHz.map { "\(Int($0.rounded())) Hz" }.joined(separator: "、"))"
        )
      }
      if !tone.harmonics.isEmpty {
        Text(
          "可能的倍数频率：\(tone.harmonics.map { "\(Int($0.frequencyHz.rounded())) Hz" }.joined(separator: "、"))"
        )
      }
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }

  private var captureDetails: some View {
    VStack(alignment: .leading, spacing: 7) {
      Text("测量条件").font(.headline)
      Text(analysis.measuredAt, format: .dateTime.year().month().day().hour().minute().second())
      Text("录音时长：\(analysis.durationSeconds.formatted(.number.precision(.fractionLength(1)))) 秒")
      Text("实际采样率：\(Int(analysis.sampleRate)) 次/秒")
      if let inputRouteName = analysis.inputRouteName, !inputRouteName.isEmpty {
        Text("麦克风：\(inputRouteName)")
      }
      Text("未经校准，只用于同一设备上的相对比较")
        .foregroundStyle(.secondary)
    }
    .font(.subheadline)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct DetailCard: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(text)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}
