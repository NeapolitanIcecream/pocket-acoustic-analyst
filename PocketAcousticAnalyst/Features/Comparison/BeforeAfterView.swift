import SwiftUI
import UIKit

struct BeforeAfterView: View {
  @Environment(AppModel.self) private var appModel
  @Environment(\.openURL) private var openURL
  @State private var model: BeforeAfterModel

  init(
    referenceAnalysis: AcousticAnalysis?,
    captureClient: any AudioCaptureClient,
    poseClient: any PoseTrackingClient,
    analyzer: LowFrequencyAnalyzer
  ) {
    _model = State(
      initialValue: BeforeAfterModel(
        referenceAnalysis: referenceAnalysis,
        captureClient: captureClient,
        poseClient: poseClient,
        analyzer: analyzer
      )
    )
  }

  var body: some View {
    ZStack {
      AppTheme.warmBackground.ignoresSafeArea()
      content
    }
    .navigationTitle("验证一次调整")
    .navigationBarTitleDisplayMode(.inline)
    .onDisappear { model.stop() }
  }

  @ViewBuilder
  private var content: some View {
    switch model.phase {
    case .introduction:
      introduction
    case .preparingPosition:
      preparingPosition
    case .readyBefore:
      ready(stage: .before)
    case .recording(let stage, let progress):
      recording(stage: stage, progress: progress)
    case .analyzing(let stage):
      comparisonProgress(stage == .before ? "正在检查调整前" : "正在检查调整后")
    case .makeChange:
      makeChange
    case .readyAfter:
      ready(stage: .after)
    case .result(let result, let before, let after):
      resultView(result, before: before, after: after)
    case .invalid(let failure):
      invalid(failure)
    }
  }

  private var introduction: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        Image(systemName: "arrow.left.arrow.right.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(AppTheme.accent)
        Text("用两次同条件测量检查变化")
          .font(.largeTitle.bold())
        Text("先测调整前，再完成一个改动并回到同一位置复测。应用会检查两次结果是否可比。")
          .font(.title3)
        ComparisonInfoCard(icon: "mappin", title: "标记手机位置", detail: "高度、位置和方向都应保持一致。")
        ComparisonInfoCard(
          icon: "slider.horizontal.3", title: "一次只改一个条件", detail: "例如关闭设备、移动枕头或改变空调模式。")
        ComparisonInfoCard(icon: "clock", title: "每次约 20 秒", detail: "电话中断、换麦克风或目标声音变化都会使对比无效。")
        Text("应用会拒绝明显的位置差异；但在声音低谷附近，厘米级复位误差仍可能明显改变读数，因此前后对比的可信度最高为中等。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        Button("准备调整前测量") {
          Task { await model.prepare() }
        }
        .buttonStyle(ComparisonPrimaryButtonStyle())
        .accessibilityIdentifier("prepareBeforeAfter")
      }
      .padding(24)
    }
  }

  private var preparingPosition: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        ProgressView().controlSize(.large)
        Text(comparisonTrackingTitle).font(.largeTitle.bold())
        Text("位置稳定后应用会记录两次测量之间的相对位移和方向。")
        Button("重新检查定位") { model.refreshPosition() }
          .buttonStyle(.bordered)
        Button("改用手动位置标记") { model.useManualPlacement() }
          .buttonStyle(ComparisonPrimaryButtonStyle())
          .accessibilityIdentifier("useManualComparisonPlacement")
      }
      .padding(24)
    }
  }

  private func ready(stage: BeforeAfterModel.Stage) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Text(stage == .before ? "测量调整前" : "回到标记位置复测")
          .font(.largeTitle.bold())
        Text(
          stage == .before
            ? "把手机放在要比较的位置，记录高度和方向，然后保持静止。"
            : "把手机放回同一标记，恢复相同高度和方向，再开始测量。")

        if model.usesManualPlacement {
          Toggle("我已核对手机位置、高度和方向", isOn: $model.manualPlacementConfirmed)
            .accessibilityIdentifier("confirmManualPlacement")
          Text("手动确认不能验证实际距离，因此结果可信度最高为中等。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }

        Button(stage == .before ? "开始调整前测量" : "开始调整后测量") {
          Task { await model.capture(stage) }
        }
        .buttonStyle(ComparisonPrimaryButtonStyle())
        .disabled(model.usesManualPlacement && !model.manualPlacementConfirmed)
        .accessibilityIdentifier(stage == .before ? "captureBefore" : "captureAfter")
      }
      .padding(24)
    }
  }

  private var makeChange: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "checkmark.circle.fill")
          .font(.system(size: 48))
          .foregroundStyle(AppTheme.accent)
        Text("调整前已记录")
          .font(.largeTitle.bold())
        if let frequency = model.targetFrequencyHz {
          Text("这次将比较约 \(Int(frequency.rounded())) Hz 的持续声音。")
        }
        Text("现在完成一个调整。不要移动手机位置标记，也不要更换麦克风或外接音频设备。")
        Button("调整完成，准备复测") { model.changeIsReady() }
          .buttonStyle(ComparisonPrimaryButtonStyle())
          .accessibilityIdentifier("changeCompleted")
      }
      .padding(24)
    }
  }

  private func recording(stage: BeforeAfterModel.Stage, progress: Double) -> some View {
    VStack(spacing: 22) {
      ProgressView(value: progress).controlSize(.large)
      Text(stage == .before ? "正在记录调整前" : "正在记录调整后")
        .font(.title2.bold())
      Text("已完成 \(Int(progress * 100))%")
        .monospacedDigit()
        .foregroundStyle(.secondary)
      Button("取消测量") { model.cancelMeasurement() }.buttonStyle(.bordered)
    }
    .padding(24)
  }

  private func invalid(_ failure: BeforeAfterModel.Failure) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 48))
          .foregroundStyle(.orange)
        Text("这一步测量不能使用")
          .font(.largeTitle.bold())
        Text(ComparisonFailureCopy.detail(failure))
        if model.hasBeforeMeasurement {
          Text("已有的调整前测量会保留；重测当前步骤后再比较。")
            .foregroundStyle(.secondary)
        }
        if isPermissionFailure(failure) {
          Button("打开系统设置") {
            openURL(URL(string: UIApplication.openSettingsURLString)!)
          }
          .buttonStyle(ComparisonPrimaryButtonStyle())
          Button("重新检查权限") {
            Task { await model.prepare() }
          }
          .buttonStyle(.bordered)
        } else {
          Button("重测当前步骤") { model.retry() }
            .buttonStyle(ComparisonPrimaryButtonStyle())
        }
      }
      .padding(24)
    }
    .accessibilityIdentifier("comparisonInvalidStep")
  }

  private func resultView(
    _ result: MeasurementComparison,
    before: ComparisonMeasurement,
    after: ComparisonMeasurement
  ) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        Image(systemName: ComparisonResultCopy.icon(result.verdict))
          .font(.system(size: 48))
          .foregroundStyle(result.verdict == .improved ? AppTheme.accent : .orange)
        Text(ComparisonResultCopy.title(result.verdict))
          .font(.largeTitle.bold())
          .accessibilityIdentifier("comparisonResult")
        Text(ComparisonResultCopy.detail(result))
          .font(.title3)

        if let delta = result.targetDeltaDB, let frequency = result.targetFrequencyHz {
          VStack(alignment: .leading, spacing: 10) {
            Text("约 \(Int(frequency.rounded())) Hz").font(.headline)
            Text(signedDelta(delta)).font(.system(.title, design: .rounded).bold())
            Text("10–500 Hz 整体：\(signedDelta(result.lowFrequencyDeltaDB))")
              .foregroundStyle(.secondary)
          }
          .padding(16)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        }

        if result.issues.contains(.positionUserConfirmedOnly) {
          Label("手机位置由你手动确认，未验证实际距离", systemImage: "hand.raised")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        if result.issues.contains(.positionSensitiveMeasurement) {
          Label(
            "声音低谷附近的厘米级复位误差也可能明显改变读数，因此结果可信度最高为中等。",
            systemImage: "ruler"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if result.issues.contains(.targetNotDetectedAfter) {
          Label(
            "第二次未再检测到目标峰；频带数值仍可比较，但不能单独归因于这次调整。",
            systemImage: "exclamationmark.triangle"
          )
          .font(.footnote)
          .foregroundStyle(.secondary)
        }
        if result.verdict == .improved, result.lowFrequencyDeltaDB >= 3 {
          Label(
            "目标频带降低，但 10–500 Hz 整体升高。不要把结果理解为整体更安静。",
            systemImage: "exclamationmark.triangle.fill"
          )
          .foregroundStyle(.orange)
        }
        Text("结果只能说明两次读数的变化，不能单独证明是这次调整造成。")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text("结果为同一设备上的相对变化，不是校准声压级。")
          .font(.footnote)
          .foregroundStyle(.secondary)

        DisclosureGroup("查看可比性依据") {
          VStack(alignment: .leading, spacing: 8) {
            Text(
              "两次实际采样率：\(Int(before.analysis.sampleRate)) / \(Int(after.analysis.sampleRate)) 次/秒")
            Text(
              "不重叠时间块：\(before.analysis.lockedBand?.independentBlockLevelsDB.count ?? 0) / \(after.analysis.lockedBand?.independentBlockLevelsDB.count ?? 0)"
            )
            if let interval = result.targetDeltaInterval {
              Text("重采样区间：\(signedDelta(interval.lowerDB)) 至 \(signedDelta(interval.upperDB))")
            }
            ForEach(result.issues.sorted(by: { $0.rawValue < $1.rawValue }), id: \.rawValue) {
              issue in
              Text(ComparisonResultCopy.issueDetail(issue))
            }
            Text("结果可信度：\(result.confidence.userLabel)")
          }
          .font(.footnote)
          .foregroundStyle(.secondary)
          .padding(.top, 8)
        }

        Button("保存对比结果") {
          appModel.store(before.analysis)
          appModel.store(after.analysis)
          appModel.store(result)
          appModel.path = []
        }
        .buttonStyle(ComparisonPrimaryButtonStyle())
        .accessibilityIdentifier("saveComparison")
      }
      .padding(24)
    }
  }

  private func comparisonProgress(_ title: String) -> some View {
    VStack(spacing: 18) {
      ProgressView().controlSize(.large)
      Text(title).font(.headline)
    }
  }

  private var comparisonTrackingTitle: String {
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

  private func signedDelta(_ value: Double) -> String {
    "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
  }

  private func isPermissionFailure(_ failure: BeforeAfterModel.Failure) -> Bool {
    switch failure {
    case .microphonePermissionDenied, .audioCapture(.permissionDenied): true
    default: false
    }
  }
}

private struct ComparisonInfoCard: View {
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

private struct ComparisonPrimaryButtonStyle: ButtonStyle {
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

private enum ComparisonFailureCopy {
  static func detail(_ failure: BeforeAfterModel.Failure) -> String {
    switch failure {
    case .microphonePermissionDenied: "需要麦克风权限才能开始。"
    case .positionUnavailable: "手机位置没有稳定记录；可等待定位恢复或改用手动位置标记。"
    case .movedDuringMeasurement: "录制期间手机位置或方向变化过大。"
    case .audioCapture(.permissionDenied): "需要麦克风权限才能开始。"
    case .audioCapture(.routeChanged): "两次测量之间或录制期间更换了麦克风。"
    case .audioCapture(.interrupted): "系统音频中断了录制。"
    case .audioCapture: "录音没有完整结束。"
    case .lowMeasurementQuality: "声音过小、削波或环境变化使这次录音不可用。"
    case .targetNotStable: "没有找到可重复的持续音调。"
    case .targetChanged: "持续音调与调整前的目标频率不同。"
    case .analysisFailed: "有效录音长度不足，无法完成分析。"
    }
  }
}

private enum ComparisonResultCopy {
  static func title(_ verdict: ComparisonVerdict) -> String {
    switch verdict {
    case .improved: "第二次测量的目标频带降低"
    case .littleChange: "变化小于当前判断门槛"
    case .worsened: "第二次测量的目标频带升高"
    case .inconclusive: "两次测量不能可靠比较"
    }
  }

  static func detail(_ result: MeasurementComparison) -> String {
    switch result.verdict {
    case .improved:
      if result.issues.contains(.targetNotDetectedAfter) {
        return "同一目标频带降低至少达到 3 dB；第二次没有再次形成可检测的峰。"
      }
      return "目标频率降低至少达到 3 dB，重采样区间也支持下降。"
    case .littleChange: return "目标频率的变化不足 3 dB，当前数据支持变化较小。"
    case .worsened: return "目标频率升高至少达到 3 dB，重采样区间也支持上升。"
    case .inconclusive:
      if result.issues.contains(.positionMismatch) || result.issues.contains(.orientationMismatch) {
        return "手机位置或方向不一致，未生成改善结论。"
      }
      if result.issues.contains(.routeOrConfigurationChanged) {
        return "麦克风或分析条件不一致，未生成改善结论。"
      }
      if result.issues.contains(.targetFrequencyChanged) {
        return "目标声音没有在两次测量中稳定出现。"
      }
      if result.issues.contains(.lowMeasurementQuality)
        || result.issues.contains(.unstableEnvironment)
      {
        return "至少一次录音过弱、削波或环境变化过大。"
      }
      if result.issues.contains(.durationMismatch) {
        return "两次有效录音时长差异过大。"
      }
      if result.issues.contains(.insufficientIndependentBlocks) {
        return "可用的独立时间段不足，需要重测。"
      }
      return "数据区间跨过当前判断门槛，需要再测一次。"
    }
  }

  static func issueDetail(_ issue: ComparisonIssue) -> String {
    switch issue {
    case .targetFrequencyChanged: "目标频率未匹配"
    case .targetNotDetectedAfter: "第二次未检测到目标峰，结论最高为中等可信度"
    case .lowMeasurementQuality: "至少一次测量质量不足"
    case .unstableEnvironment: "至少一次测量期间环境变化过大"
    case .durationMismatch: "两次有效录音时长未匹配"
    case .positionMismatch: "手机位置未匹配"
    case .orientationMismatch: "手机方向未匹配"
    case .positionUserConfirmedOnly: "位置只由用户手动确认"
    case .positionSensitiveMeasurement: "厘米级复位误差仍可能影响读数"
    case .routeOrConfigurationChanged: "麦克风或分析配置未匹配"
    case .insufficientIndependentBlocks: "独立时间段不足"
    }
  }

  static func icon(_ verdict: ComparisonVerdict) -> String {
    switch verdict {
    case .improved: "arrow.down.circle.fill"
    case .littleChange: "minus.circle.fill"
    case .worsened: "arrow.up.circle.fill"
    case .inconclusive: "questionmark.circle.fill"
    }
  }
}
