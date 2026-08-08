import SwiftUI
import UIKit

struct SourceInvestigationView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.openURL) private var openURL
  @State private var model: SourceInvestigationModel
  @State private var showsExitConfirmation = false

  init(
    referenceAnalysis: AcousticAnalysis,
    captureClient: any AudioCaptureClient,
    poseClient: any PoseTrackingClient,
    analyzer: LowFrequencyAnalyzer,
    isDemoMode: Bool
  ) {
    _model = State(
      initialValue: SourceInvestigationModel(
        referenceAnalysis: referenceAnalysis,
        captureClient: captureClient,
        poseClient: poseClient,
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
    .navigationTitle("逐项排查状态")
    .navigationBarTitleDisplayMode(.inline)
    .navigationBarBackButtonHidden(model.hasProgressToProtect)
    .toolbar {
      if model.hasProgressToProtect {
        ToolbarItem(placement: .topBarLeading) {
          Button("退出") { showsExitConfirmation = true }
        }
      }
    }
    .alert("退出状态调查？", isPresented: $showsExitConfirmation) {
      Button("继续调查", role: .cancel) {}
      Button("退出并丢弃进度", role: .destructive) {
        model.stop()
        if !appModel.path.isEmpty { appModel.path.removeLast() }
      }
    } message: {
      Text("已经完成的步骤尚未保存；退出后需要从第一次重新开始。")
    }
    .onDisappear { model.stop() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .introduction:
      introduction
    case .preparingPosition:
      preparingPosition
    case .ready(let index):
      ready(index)
    case .countdown(let index, let count):
      countdown(index: index, count: count)
    case .recording(let index, let progress):
      recording(index: index, progress: progress)
    case .analyzing(let index):
      centeredProgress("正在检查第 \(index + 1) 次测量")
    case .changeState(let nextIndex):
      changeState(nextIndex)
    case .result(let evaluation):
      SourceInvestigationResultView(
        evaluation: evaluation,
        onRestart: { model.restart() },
        onSave: {
          appModel.store(evaluation)
          appModel.path = []
        }
      )
    case .invalid(let failure):
      invalid(failure)
    }
  }

  private var introduction: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "switch.2")
          .font(.system(size: 48))
          .foregroundStyle(AppTheme.accent)
        Text("一次只改变一个状态")
          .font(.largeTitle.bold())
        Text("应用会连续完成三轮夹测，检查哪些低频在状态改变时变化，并在恢复原状态后回来。")
          .font(.title3)

        VStack(alignment: .leading, spacing: 14) {
          sourceField(
            title: "要测试的设备或条件",
            example: "例如：空调",
            text: $model.subjectName,
            identifier: "sourceSubjectField"
          )
          sourceField(
            title: "原状态",
            example: "例如：制冷运行",
            text: $model.baselineStateName,
            identifier: "sourceBaselineField"
          )
          sourceField(
            title: "改变后",
            example: "例如：关闭",
            text: $model.changedStateName,
            identifier: "sourceChangedField"
          )
        }

        if !model.targetBands.isEmpty {
          VStack(alignment: .leading, spacing: 8) {
            Text("本次跟踪的低频线索").font(.headline)
            Text(model.targetBands.map(bandLabel).joined(separator: "、"))
              .foregroundStyle(.secondary)
          }
          .padding(16)
          .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        }

        SourceInfoCard(
          icon: "repeat.3",
          title: "至少约 3 分钟",
          detail: "共 7 次、每次约 20 秒；设备状态稳定所需的等待时间另计。"
        )
        SourceInfoCard(
          icon: "iphone.gen3",
          title: "手机全程不要移动",
          detail: "相机只检查位置是否一致，不保存图像。不要拿起手机去操作设备。"
        )
        SourceInfoCard(
          icon: "exclamationmark.triangle",
          title: "结果是线索，不是设备定论",
          detail: "应用只会报告与状态重复同步的变化，不会声称这个设备就是声源。"
        )

        Button("准备第一轮") {
          Task { await model.prepare() }
        }
        .buttonStyle(SourcePrimaryButtonStyle())
        .disabled(!model.canPrepare)
        .accessibilityIdentifier("prepareSourceInvestigation")
      }
      .padding(24)
    }
  }

  private var preparingPosition: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ProgressView().controlSize(.large)
        Text(sourceTrackingTitle).font(.largeTitle.bold())
        Text("位置参考会检查 7 次录音是否都在同一位置和方向。")
        Button("重新检查定位") { model.refreshPosition() }
          .buttonStyle(.bordered)
        Button("改用手动固定确认") { model.useManualPlacement() }
          .buttonStyle(SourcePrimaryButtonStyle())
          .accessibilityIdentifier("useManualSourcePlacement")
      }
      .padding(24)
    }
  }

  private func ready(_ index: Int) -> some View {
    let state = model.state(for: index)
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(stepTitle(index)).font(.largeTitle.bold())
        Text("当前应保持：\(state == .baseline ? model.baselineStateName : model.changedStateName)")
          .font(.title3)
        Text("手机保持固定，其他设备状态不要同时改变。开始后请远离手机并保持安静。")
        ProgressView(value: Double(index), total: Double(model.totalMeasurementCount))
          .accessibilityLabel("状态调查进度")
          .accessibilityValue(
            SourceInvestigationAccessibilityCopy.completed(
              index,
              total: model.totalMeasurementCount
            )
          )
        Text("已完成 \(index) / \(model.totalMeasurementCount) 次")
          .font(.footnote)
          .foregroundStyle(.secondary)

        if model.usesManualPlacement {
          Toggle("我确认手机位置、高度和方向没有改变", isOn: $model.manualPlacementConfirmed)
            .accessibilityIdentifier("confirmManualSourcePlacement")
          Text("手动确认不能验证实际位移，最终结果仍只作为中等可信线索。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Button("开始第 \(index + 1) 次测量") {
          Task { await model.capture(sequenceIndex: index) }
        }
        .buttonStyle(SourcePrimaryButtonStyle())
        .disabled(model.usesManualPlacement && !model.manualPlacementConfirmed)
        .accessibilityIdentifier("captureSourceStep\(index)")
      }
      .padding(24)
    }
  }

  private func countdown(index: Int, count: Int) -> some View {
    VStack(spacing: 20) {
      Text("请离开手机并保持安静")
        .font(.title.bold())
      Text("\(count)")
        .font(.system(size: 92, weight: .bold, design: .rounded))
        .foregroundStyle(AppTheme.accent)
        .accessibilityLabel(SourceInvestigationAccessibilityCopy.countdown(count))
      Text("第 \(index + 1) / \(model.totalMeasurementCount) 次")
        .foregroundStyle(.secondary)
      Button("取消") { model.cancelMeasurement() }.buttonStyle(.bordered)
    }
  }

  private func recording(index: Int, progress: Double) -> some View {
    VStack(spacing: 22) {
      ProgressView(value: progress).controlSize(.large)
        .accessibilityLabel(
          SourceInvestigationAccessibilityCopy.recordingLabel(sequenceIndex: index)
        )
        .accessibilityValue(SourceInvestigationAccessibilityCopy.recordingValue(progress: progress))
      Text("正在记录第 \(index + 1) 次")
        .font(.title2.bold())
      Text("已完成 \(Int(progress * 100))%")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Text("不要触碰手机或改变其他设备")
        .foregroundStyle(.secondary)
      Button("取消测量") { model.cancelMeasurement() }.buttonStyle(.bordered)
    }
    .padding(24)
  }

  private func changeState(_ nextIndex: Int) -> some View {
    let nextState = model.state(for: nextIndex)
    let round = nextState == .changed ? (nextIndex + 1) / 2 : nextIndex / 2
    let fromState = nextState == .changed ? model.baselineStateName : model.changedStateName
    let toState = nextState == .changed ? model.changedStateName : model.baselineStateName
    return ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(AppTheme.accent)
        Text(nextState == .changed ? "第 \(round) 轮：改变一项" : "第 \(round) 轮：恢复原状态")
          .font(.largeTitle.bold())
        Text("把“\(model.subjectName)”从“\(fromState)”改为“\(toState)”。")
          .font(.title3)
        Text("不要移动手机，也不要同时改变房门、电脑负载或其他设备。等待运行状态稳定后再继续。")
        Text("观察工作声、风扇转速或指示灯连续稳定；如果不能确认，继续等待，不要马上测量。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Button("状态已稳定，继续") {
          model.stateChangeCompleted(nextSequenceIndex: nextIndex)
        }
        .buttonStyle(SourcePrimaryButtonStyle())
        .accessibilityIdentifier("completeSourceStateChange\(nextIndex)")
      }
      .padding(24)
    }
  }

  private func invalid(_ failure: SourceInvestigationModel.Failure) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.orange)
        Text("这一步不能加入状态调查")
          .font(.largeTitle.bold())
        Text(SourceFailureCopy.detail(failure))
        if model.completedMeasurementCount > 0, failure != .positionUnavailable {
          Text("已经通过的步骤会保留；修正问题后重测当前步骤。")
            .foregroundStyle(.secondary)
        }
        if model.completedMeasurementCount > 0, failure == .positionUnavailable {
          Text("改用手动固定确认会清除已完成步骤并从第一次重新开始，避免混用两套位置依据。")
            .foregroundStyle(.secondary)
        }
        if model.completedMeasurementCount > 0, isAudioConfigurationFailure(failure) {
          Text("接回第一次使用的麦克风后可以重测当前步骤；若要继续使用当前麦克风，必须从第一次重新开始。")
            .foregroundStyle(.secondary)
        }
        if failure == .microphonePermissionDenied || failure == .audioCapture(.permissionDenied) {
          Button("打开系统设置") {
            openURL(URL(string: UIApplication.openSettingsURLString)!)
          }
          .buttonStyle(SourcePrimaryButtonStyle())
        } else if failure == .positionUnavailable {
          Button(
            model.completedMeasurementCount > 0 ? "改用手动并重新开始" : "改用手动固定确认"
          ) {
            model.useManualPlacement()
          }
          .buttonStyle(SourcePrimaryButtonStyle())
          if model.completedMeasurementCount > 0 {
            Button("重新建立位置并从头开始") { model.restart() }
              .buttonStyle(.bordered)
          }
        } else if model.completedMeasurementCount > 0, isAudioConfigurationFailure(failure) {
          Button("已恢复原麦克风，重测当前步骤") { model.retry() }
            .buttonStyle(SourcePrimaryButtonStyle())
          Button("使用当前麦克风重新开始") { model.restart() }
            .buttonStyle(.bordered)
        } else {
          Button("重测当前步骤") { model.retry() }
            .buttonStyle(SourcePrimaryButtonStyle())
        }
      }
      .padding(24)
    }
    .accessibilityIdentifier("sourceInvestigationInvalidStep")
  }

  private func centeredProgress(_ title: String) -> some View {
    VStack(spacing: 18) {
      ProgressView().controlSize(.large)
      Text(title).font(.headline)
    }
  }

  private func stepTitle(_ index: Int) -> String {
    if index == 0 { return "记录初始状态" }
    let state = model.state(for: index)
    let round = state == .changed ? (index + 1) / 2 : index / 2
    return state == .changed ? "第 \(round) 轮：改变后" : "第 \(round) 轮：恢复检查"
  }

  private func bandLabel(_ band: SourceFrequencyBand) -> String {
    if band.containsUnresolvedComponents,
      let minimum = band.memberFrequenciesHz.min(),
      let maximum = band.memberFrequenciesHz.max()
    {
      return "约 \(Int(minimum.rounded()))–\(Int(maximum.rounded())) Hz 频率组"
    }
    return "约 \(Int(band.centerFrequencyHz.rounded())) Hz"
  }

  private var sourceTrackingTitle: String {
    switch model.trackingStatus {
    case .unavailable: "位置跟踪不可用"
    case .initializing: "正在建立位置参考"
    case .normal: "位置参考已建立"
    case .limited(let reason):
      switch reason {
      case .initializing: "正在识别周围环境"
      case .excessiveMotion: "手机移动过快，请放慢"
      case .insufficientFeatures: "请对准有纹理的墙面或家具"
      case .relocalizing: "正在恢复位置参考"
      case .interrupted: "相机跟踪被系统中断"
      case .unknown: "位置跟踪暂时不稳定"
      }
    }
  }

  private func isAudioConfigurationFailure(
    _ failure: SourceInvestigationModel.Failure
  ) -> Bool {
    failure == .audioCapture(.routeChanged)
      || failure == .audioCapture(.engineConfigurationChanged)
      || failure == .audioCapture(.mediaServicesReset)
  }
}

struct SourceInvestigationResultView: View {
  let evaluation: SourceInvestigationEvaluation
  var onRestart: (() -> Void)?
  var onSave: (() -> Void)?

  var body: some View {
    let presentation = evaluation.resultPresentation
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: resultIcon)
          .font(.system(size: 48))
          .foregroundStyle(
            evaluation.verdict == .frequencySpecificSynchronization
              ? AppTheme.accent : .orange)
        Text(presentation.title)
          .font(.largeTitle.bold())
          .accessibilityIdentifier("sourceInvestigationResult")
        Text(presentation.subtitle).font(.title3)

        SourceEvidenceCard(title: "这次测到了什么", text: presentation.evidence)
        if evaluation.verdict != .inconclusive {
          bandSummaryCard
        }
        SourceEvidenceCard(title: "这能支持什么判断", text: presentation.interpretation)
        SourceEvidenceCard(title: "还不能说明什么", text: presentation.limitation)
        SourceEvidenceCard(title: "下一步", text: presentation.action)

        Label("结果来自同一设备上的相对变化，三轮结论最高为中等可信度", systemImage: "scope")
          .font(.footnote)
          .foregroundStyle(.secondary)

        DisclosureGroup("查看三轮检查依据") {
          VStack(alignment: .leading, spacing: 8) {
            Text("测量顺序：原状态 → 改变后 → 原状态，共 3 轮")
            Text("有效录音：\(evaluation.measurements.count) / 7")
            ForEach(evaluation.rounds) { round in
              if evaluation.verdict == .inconclusive {
                Text("第 \(round.roundNumber) 轮：不可用于状态结论")
              } else {
                VStack(alignment: .leading, spacing: 3) {
                  Text(round.overallEvidenceText)
                  ForEach(round.bandEvidence) { evidence in
                    Text(bandRoundLabel(evidence))
                  }
                }
                .accessibilityElement(children: .combine)
              }
            }
            ForEach(evaluation.issues.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) {
              Text(SourceIssueCopy.detail($0))
            }
            Text("结果可信度：\(evaluation.confidence.userLabel)")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.top, 8)
        }

        if let onRestart {
          Button("使用同一低频线索重新调查") { onRestart() }
            .buttonStyle(SourcePrimaryButtonStyle())
            .accessibilityIdentifier("restartSourceInvestigation")
        }

        if let onSave {
          Button("保存并返回首页") { onSave() }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("saveSourceInvestigation")
        }
      }
      .padding(24)
    }
  }

  private var bandSummaryCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("各频率组").font(.headline)
      ForEach(evaluation.bandSummaries) { summary in
        VStack(alignment: .leading, spacing: 3) {
          Text("约 \(Int(summary.frequencyHz.rounded())) Hz")
          Text(summaryLabel(summary))
            .foregroundStyle(summary.relationship == .littleChange ? .secondary : .primary)
        }
        .accessibilityElement(children: .combine)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }

  private var resultIcon: String {
    switch evaluation.verdict {
    case .frequencySpecificSynchronization: "link.circle.fill"
    case .overallLowFrequencySynchronization: "waveform.badge.magnifyingglass"
    case .noConsistentSynchronization: "questionmark.circle.fill"
    case .inconclusive: "exclamationmark.triangle.fill"
    }
  }

  private func summaryLabel(_ summary: SourceBandSummary) -> String {
    switch summary.relationship {
    case .lowerInChangedState: "三轮均降低 \(signed(summary.meanChangedDeltaDB))"
    case .higherInChangedState: "三轮均升高 \(signed(summary.meanChangedDeltaDB))"
    case .littleChange: "三轮变化都较小"
    case .inconclusive: "没有稳定同步"
    }
  }

  private func signed(_ value: Double?) -> String {
    guard let value else { return "无法计算" }
    return "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
  }

  private func bandRoundLabel(_ evidence: SourceBandRoundEvidence) -> String {
    let frequency = "约 \(Int(evidence.frequencyHz.rounded())) Hz"
    switch evidence.relationship {
    case .lowerInChangedState, .higherInChangedState:
      let delta = signed(evidence.frequencySpecificDeltaDB)
      let baselineReturn = signed(evidence.baselineReturnDifferenceDB)
      return "\(frequency)：目标频带 \(delta)；恢复差 \(baselineReturn)"
    case .littleChange:
      return "\(frequency)：目标频带变化较小"
    case .inconclusive:
      return "\(frequency)：这一轮不能形成频率结论"
    }
  }
}

extension SourceInvestigationView {
  fileprivate func sourceField(
    title: String,
    example: String,
    text: Binding<String>,
    identifier: String
  ) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.subheadline.weight(.semibold))
      TextField(example, text: text)
        .textFieldStyle(.roundedBorder)
        .accessibilityIdentifier(identifier)
    }
  }
}

private struct SourceInfoCard: View {
  let icon: String
  let title: String
  let detail: String

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon).font(.title2).foregroundStyle(AppTheme.accent).frame(width: 30)
      VStack(alignment: .leading, spacing: 5) {
        Text(title).font(.headline)
        Text(detail).font(.subheadline).foregroundStyle(.secondary)
      }
    }
    .padding(16)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct SourceEvidenceCard: View {
  let title: String
  let text: String

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.headline)
      Text(text)
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
  }
}

private struct SourcePrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .frame(maxWidth: .infinity)
      .padding(.vertical, 15)
      .foregroundStyle(.white)
      .background(
        AppTheme.accent.opacity(isEnabled ? (configuration.isPressed ? 0.78 : 1) : 0.35),
        in: RoundedRectangle(cornerRadius: 16)
      )
  }
}

private enum SourceFailureCopy {
  static func detail(_ failure: SourceInvestigationModel.Failure) -> String {
    switch failure {
    case .microphonePermissionDenied: "需要麦克风权限才能开始。"
    case .noTrackableFrequency: "起始测量中没有可安全追踪的低频线索。"
    case .positionUnavailable: "手机位置没有稳定记录；可以等待恢复或改用手动固定确认。"
    case .movedDuringMeasurement: "录制期间手机位置或方向变化过大。"
    case .audioCapture(.permissionDenied): "需要麦克风权限才能开始。"
    case .audioCapture(.routeChanged): "录制期间麦克风或外接音频设备发生了变化。"
    case .audioCapture(.engineConfigurationChanged): "麦克风格式与第一次测量不同。"
    case .audioCapture(.mediaServicesReset): "系统重新启动了音频服务，原测量条件已失效。"
    case .audioCapture(.interrupted): "系统音频中断了本次录制。"
    case .audioCapture: "录音没有完整结束。"
    case .lowMeasurementQuality: "声音过小、削波或测量期间变化过大。"
    case .baselineTargetNotDetected: "恢复原状态后，没有再次检测到可追踪的低频线索。"
    case .trackedBandsUnavailable: "至少一个候选频率或参考频段无法安全计算。"
    case .analysisFailed: "有效录音不足，无法完成本次分析。"
    }
  }
}

private enum SourceIssueCopy {
  static func detail(_ issue: SourceInvestigationIssue) -> String {
    switch issue {
    case .incompleteSequence: "7 次测量顺序不完整"
    case .lowMeasurementQuality: "至少一次测量质量不足"
    case .unstableEnvironment: "至少一个频段在单次测量中变化过大"
    case .routeOrConfigurationChanged: "麦克风或分析配置发生变化"
    case .positionMismatch: "手机位置未保持一致"
    case .orientationMismatch: "手机方向未保持一致"
    case .positionUserConfirmedOnly: "位置只由用户手动确认"
    case .missingTrackedBand: "候选频率或参考频段不足"
    case .baselineTargetNotDetected: "恢复状态时没有再次检测到候选频率"
    case .baselineDidNotReturn: "恢复状态后的读数没有回到允许范围"
    case .insufficientIndependentBlocks: "独立时间段不足"
    case .inconsistentRoundDirection: "三轮变化方向不一致"
    }
  }
}
