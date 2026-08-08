import SwiftUI
import UIKit

struct HumInvestigationView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.openURL) private var openURL
  @State private var model: HumInvestigationModel

  init(
    captureClient: any AudioCaptureClient,
    analyzer: LowFrequencyAnalyzer,
    isDemoMode: Bool
  ) {
    _model = State(
      initialValue: HumInvestigationModel(
        captureClient: captureClient,
        analyzer: analyzer,
        isDemoMode: isDemoMode
      )
    )
  }

  var body: some View {
    ZStack {
      AppTheme.warmBackground.ignoresSafeArea()
      content
    }
    .navigationTitle("检查持续嗡声")
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear {
      if model.isActivelyMeasuring {
        model.cancelMeasurement()
      }
    }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .introduction:
      introduction
    case .requestingPermission:
      centeredProgress(title: "正在检查麦克风权限")
    case .permissionDenied:
      permissionDenied
    case .ready:
      ready
    case .countdown(let count):
      countdown(count)
    case .recording(let progress):
      recording(progress)
    case .analyzing:
      centeredProgress(title: "正在检查这段声音")
    case .result(let outcome):
      result(outcome)
    }
  }

  private var introduction: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Image(systemName: "ear.badge.waveform")
          .font(.system(size: 52))
          .foregroundStyle(AppTheme.accent)

        Text("先录一段你实际听到的声音")
          .font(.largeTitle.bold())
        Text("应用会检查低频声音是否持续、主要集中在哪个频率，以及本次测量是否适合继续做房间位置比较。")
          .font(.title3)

        InfoPanel(
          icon: "lock.shield",
          title: "录音留在设备上",
          detail: "只有你开始测量后才会使用麦克风。分析完成后不保留原始录音。"
        )
        InfoPanel(
          icon: "scope",
          title: "结果是相对测量",
          detail: "手机没有校准时，结果不能代替专业声级计，也不能单独确定声源。"
        )

        Button("了解并继续") {
          Task { await model.explainAndRequestPermission() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("requestMicrophonePermission")
      }
      .padding(24)
    }
  }

  private var permissionDenied: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "mic.slash")
          .font(.system(size: 48))
          .foregroundStyle(.orange)
        Text("需要麦克风权限")
          .font(.largeTitle.bold())
        Text("没有权限时不会开始计时，也不会生成测量结果。你可以在系统设置中允许麦克风访问后回来重试。")
        Button("打开系统设置") {
          openURL(URL(string: UIApplication.openSettingsURLString)!)
        }
        .buttonStyle(PrimaryButtonStyle())
        Button("重新检查") {
          Task { await model.explainAndRequestPermission() }
        }
        .buttonStyle(.bordered)
      }
      .padding(24)
    }
    .accessibilityIdentifier("permissionDeniedView")
  }

  private var ready: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Text("把手机放到你平时听到声音的位置")
          .font(.largeTitle.bold())
        InstructionRow(number: 1, text: "让手机靠近你耳朵通常所在的高度。")
        InstructionRow(number: 2, text: "保持手机方向不变，不要遮住底部麦克风。")
        InstructionRow(number: 3, text: "开始后保持安静和静止约 20 秒。")

        Label("测量期间应用不会播放声音或触发振动", systemImage: "speaker.slash")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button("开始测量") {
          Task { await model.startMeasurement() }
        }
        .buttonStyle(PrimaryButtonStyle())
        .accessibilityIdentifier("startMeasurement")
      }
      .padding(24)
    }
  }

  private func countdown(_ count: Int) -> some View {
    VStack(spacing: 20) {
      Text("请放稳手机")
        .font(.title.bold())
      Text("\(count)")
        .font(.system(size: 92, weight: .bold, design: .rounded))
        .foregroundStyle(AppTheme.accent)
      Button("取消") { model.cancelMeasurement() }
        .buttonStyle(.bordered)
    }
    .accessibilityElement(children: .combine)
    .accessibilityLabel("测量将在 \(count) 秒后开始")
  }

  private func recording(_ progress: Double) -> some View {
    VStack(spacing: 28) {
      ZStack {
        Circle()
          .stroke(.black.opacity(0.08), lineWidth: 14)
        Circle()
          .trim(from: 0, to: progress)
          .stroke(AppTheme.accent, style: StrokeStyle(lineWidth: 14, lineCap: .round))
          .rotationEffect(.degrees(-90))
        Image(systemName: "waveform")
          .font(.system(size: 38))
          .foregroundStyle(AppTheme.accent)
      }
      .frame(width: 180, height: 180)

      Text("正在测量，请保持不动")
        .font(.title2.bold())
      Text("已完成 \(Int(progress * 100))%")
        .foregroundStyle(.secondary)
        .monospacedDigit()
      Button("取消测量") { model.cancelMeasurement() }
        .buttonStyle(.bordered)
    }
    .padding(24)
    .accessibilityIdentifier("recordingView")
  }

  private func result(_ outcome: HumInvestigationModel.Outcome) -> some View {
    ScrollView {
      switch outcome {
      case .detected(let analysis):
        detectedResult(analysis)
      case .notDetected(let analysis):
        notDetectedResult(analysis)
      case .invalid(let failure):
        invalidResult(failure)
      }
    }
  }

  private func detectedResult(_ analysis: AcousticAnalysis) -> some View {
    let tone = analysis.tone!
    let presentation = analysis.resultPresentation
    return VStack(alignment: .leading, spacing: 22) {
      ResultStatusHeader(
        icon: "checkmark.circle.fill",
        color: AppTheme.accent,
        title: presentation.title,
        subtitle: presentation.subtitle
      )
      .accessibilityIdentifier("detectedToneResult")

      ToneContinuityView(
        tone: tone,
        minimumPersistence: analysis.configuration.minimumTonePersistence
      )

      EvidenceSection(title: "这次测到了什么") {
        Text(presentation.evidence)
        if !tone.harmonics.isEmpty {
          Text(
            "还发现了约 \(tone.harmonics.map { AcousticResultFormatter.wholeFrequency($0.frequencyHz) }.joined(separator: "、")) 的倍数频率。"
          )
        }
      }
      EvidenceSection(title: "这能支持什么判断") {
        Text(presentation.action)
      }
      EvidenceSection(title: "还不能说明什么") {
        Text(presentation.limitation)
      }

      Button("寻找影响较小的位置") {
        appModel.path.append(.spatialScan(analysisID: analysis.id))
      }
      .buttonStyle(PrimaryButtonStyle())
      .accessibilityIdentifier("startSpatialScan")

      if SourceFrequencyPlanner().makePlan(from: analysis) != nil {
        Button("逐项排查设备状态") {
          appModel.path.append(.sourceInvestigation(analysisID: analysis.id))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("startSourceInvestigation")
      }

      relativeMeasurementNote
      measurementDetails(analysis)
    }
    .padding(24)
    .onAppear { appModel.store(analysis) }
  }

  private func notDetectedResult(_ analysis: AcousticAnalysis) -> some View {
    let presentation = analysis.resultPresentation
    return VStack(alignment: .leading, spacing: 22) {
      ResultStatusHeader(
        icon: analysis.resolvedSoundPattern == .distributedEnergy ? "waveform.slash" : "waveform",
        color: .orange,
        title: presentation.title,
        subtitle: presentation.subtitle
      )
      if let evidenceTone = analysis.bestToneEvidence {
        ToneContinuityView(
          tone: evidenceTone,
          minimumPersistence: analysis.configuration.minimumTonePersistence
        )
      }
      EvidenceSection(title: "这次测到了什么") {
        Text(presentation.evidence)
        if let evidenceTone = analysis.bestToneEvidence, !evidenceTone.harmonics.isEmpty {
          Text(
            "还发现了约 \(evidenceTone.harmonics.map { AcousticResultFormatter.wholeFrequency($0.frequencyHz) }.joined(separator: "、")) 的倍数频率。"
          )
        }
      }
      EvidenceSection(title: "为什么暂时不能比较位置") {
        Text(presentation.limitation)
      }
      EvidenceSection(title: "可以怎么做") {
        Text(presentation.action)
      }
      Button("重新测量") { model.retry() }
        .buttonStyle(PrimaryButtonStyle())
      if SourceFrequencyPlanner().makePlan(from: analysis) != nil {
        Button("逐项排查设备状态") {
          appModel.path.append(.sourceInvestigation(analysisID: analysis.id))
        }
        .buttonStyle(.borderedProminent)
        .accessibilityIdentifier("startSourceInvestigation")
      }
      relativeMeasurementNote
      measurementDetails(analysis)
    }
    .padding(24)
    .onAppear { appModel.store(analysis) }
  }

  private func invalidResult(_ failure: HumInvestigationModel.InvestigationFailure) -> some View {
    VStack(alignment: .leading, spacing: 22) {
      ResultStatusHeader(
        icon: "exclamationmark.triangle.fill",
        color: .orange,
        title: "这次测量不能使用",
        subtitle: FailureCopy.detail(failure)
      )
      EvidenceSection(title: "下一步") {
        Text(FailureCopy.action(failure))
      }
      Button("重新测量") { model.retry() }
        .buttonStyle(PrimaryButtonStyle())
    }
    .padding(24)
    .accessibilityIdentifier("invalidMeasurementResult")
  }

  private var relativeMeasurementNote: some View {
    Label("未经校准，只用于同一设备上的相对比较", systemImage: "ruler")
      .font(.footnote)
      .foregroundStyle(.secondary)
  }

  private func measurementDetails(_ analysis: AcousticAnalysis) -> some View {
    DisclosureGroup("查看测量依据") {
      VStack(alignment: .leading, spacing: 8) {
        Text("录音时长：\(analysis.durationSeconds.formatted(.number.precision(.fractionLength(1)))) 秒")
        Text("实际采样率：\(Int(analysis.sampleRate)) 次/秒")
        if let inputRouteName = analysis.inputRouteName, !inputRouteName.isEmpty {
          Text("麦克风：\(inputRouteName)")
        }
        Text("输入通道：\(analysis.inputChannelCount) 个，分析第 \(analysis.selectedInputChannelIndex + 1) 个")
        Text("声音类型：\(analysis.resultPresentation.title)")
        if let evidenceTone = analysis.bestToneEvidence {
          Text(
            "候选频率：\(AcousticResultFormatter.frequency(evidenceTone.frequencyHz, analysis: analysis))"
          )
          Text("出现时段：\(Int((evidenceTone.persistence * 100).rounded()))%")
          Text(
            "频率变化：\(evidenceTone.frequencySpreadHz.formatted(.number.precision(.fractionLength(2)))) Hz"
          )
          Text(
            "强弱离散：\(evidenceTone.levelSpreadDB.formatted(.number.precision(.fractionLength(1)))) dB"
          )
        }
        Text("结果可信度：\(combinedConfidence(for: analysis).userLabel)")
      }
      .font(.footnote)
      .foregroundStyle(.secondary)
      .padding(.top, 8)
    }
  }

  private func combinedConfidence(for analysis: AcousticAnalysis) -> AnalysisConfidence {
    analysis.bestToneEvidence?.confidence.constrained(by: analysis.quality.confidence)
      ?? analysis.quality.confidence
  }

  private func centeredProgress(title: String) -> some View {
    VStack(spacing: 18) {
      ProgressView().controlSize(.large)
      Text(title).font(.headline)
    }
  }
}

private struct InstructionRow: View {
  let number: Int
  let text: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Text("\(number)")
        .font(.headline)
        .foregroundStyle(.white)
        .frame(width: 30, height: 30)
        .background(AppTheme.accent, in: Circle())
      Text(text).font(.body)
    }
  }
}

private struct InfoPanel: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .font(.title2)
        .foregroundStyle(AppTheme.accent)
        .frame(width: 30)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct ResultStatusHeader: View {
  let icon: String
  let color: Color
  let title: String
  let subtitle: String

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Image(systemName: icon).font(.system(size: 44)).foregroundStyle(color)
      Text(title)
        .font(.largeTitle.bold())
        .lineLimit(2)
        .minimumScaleFactor(0.85)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
      Text(subtitle).font(.title3).foregroundStyle(.secondary)
    }
  }
}

private struct EvidenceSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      content
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct ToneContinuityView: View {
  let tone: ToneAnalysis
  let minimumPersistence: Double

  private var summary: String {
    if tone.persistence < minimumPersistence {
      return "只在部分时段检测到候选音调"
    }
    return tone.isStable ? "多数时段都能重复测到" : "频率或强弱随时间有明显变化"
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("这段时间里是否持续")
        .font(.headline)
      HStack(alignment: .bottom, spacing: 4) {
        ForEach(tone.frameTrace) { sample in
          Capsule()
            .fill(sample.levelDB == nil ? Color.gray.opacity(0.25) : AppTheme.accent)
            .frame(maxWidth: .infinity)
            .frame(height: sample.levelDB == nil ? 12 : 38)
        }
      }
      .frame(height: 42)
      Text(summary)
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(summary)
  }
}

private struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 15)
      .foregroundStyle(.white)
      .background(
        AppTheme.accent.opacity(configuration.isPressed ? 0.78 : 1),
        in: RoundedRectangle(cornerRadius: 16))
  }
}

private enum AcousticResultFormatter {
  static func frequency(_ frequency: Double, analysis: AcousticAnalysis) -> String {
    if analysis.nominalFrequencyResolutionHz <= 0.5, analysis.tone?.confidence == .high {
      return "\(frequency.formatted(.number.precision(.fractionLength(1)))) Hz"
    }
    return wholeFrequency(frequency)
  }

  static func wholeFrequency(_ frequency: Double) -> String {
    "\(Int(frequency.rounded())) Hz"
  }
}

private enum FailureCopy {
  static func detail(_ failure: HumInvestigationModel.InvestigationFailure) -> String {
    switch failure {
    case .noInput: "当前没有可用的麦克风输入。"
    case .unsupportedInput: "当前输入格式不能安全分析。"
    case .interrupted: "电话、Siri 或其他系统音频中断了测量。"
    case .routeChanged: "测量期间麦克风或音频设备发生了变化。"
    case .engineChanged: "系统改变了音频配置。"
    case .mediaReset: "系统音频服务在测量期间重新启动。"
    case .appBackgrounded: "应用在测量期间进入了后台。"
    case .incompleteCapture: "有效录音样本不足，未生成声学结果。"
    case .lowQuality: "声音过小、出现削波或环境变化过大。"
    case .setupFailed: "麦克风没有成功开始采集。"
    case .analysisFailed: "有效录音长度不足，无法完成分析。"
    }
  }

  static func action(_ failure: HumInvestigationModel.InvestigationFailure) -> String {
    switch failure {
    case .noInput: "检查外接设备后重试，或改用手机内置麦克风。"
    case .unsupportedInput: "断开当前外接输入后，使用手机内置麦克风重试。"
    case .interrupted, .routeChanged, .engineChanged, .mediaReset, .appBackgrounded,
      .incompleteCapture:
      "保持应用在前台，并在音频设备稳定后从头重测。已有部分录音不会生成结果。"
    case .lowQuality:
      "保持手机不动，不要遮挡麦克风，并在环境较稳定时重测。"
    case .setupFailed, .analysisFailed:
      "检查麦克风是否被其他应用占用，然后重新开始。"
    }
  }
}
