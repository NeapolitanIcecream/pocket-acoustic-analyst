import SwiftUI

struct BeforeAfterView: View {
    @Environment(AppModel.self) private var appModel
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
        case let .recording(stage, progress):
            recording(stage: stage, progress: progress)
        case let .analyzing(stage):
            comparisonProgress(stage == .before ? "正在检查调整前" : "正在检查调整后")
        case .makeChange:
            makeChange
        case .readyAfter:
            ready(stage: .after)
        case let .result(result, before, after):
            resultView(result, before: before, after: after)
        case let .invalid(failure):
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
                ComparisonInfoCard(icon: "slider.horizontal.3", title: "一次只改一个条件", detail: "例如关闭设备、移动枕头或改变空调模式。")
                ComparisonInfoCard(icon: "clock", title: "每次约 20 秒", detail: "电话中断、换麦克风或目标声音变化都会使对比无效。")

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
                Text(stage == .before
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
                Text("已有的调整前测量会保留；重测当前步骤后再比较。")
                    .foregroundStyle(.secondary)
                Button("重测当前步骤") { model.retry() }
                    .buttonStyle(ComparisonPrimaryButtonStyle())
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
                Text("结果为同一设备上的相对变化，不是校准声压级。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                DisclosureGroup("查看可比性依据") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("两次实际采样率：\(Int(before.analysis.sampleRate)) / \(Int(after.analysis.sampleRate)) 次/秒")
                        Text("不重叠时间块：\(before.analysis.tone?.independentBlockLevelsDB.count ?? 0) / \(after.analysis.tone?.independentBlockLevelsDB.count ?? 0)")
                        if let interval = result.targetDeltaInterval {
                            Text("重采样区间：\(signedDelta(interval.lowerDB)) 至 \(signedDelta(interval.upperDB))")
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
        case .limited: "位置跟踪暂时不稳定"
        }
    }

    private func signedDelta(_ value: Double) -> String {
        "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
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
            .background(AppTheme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum ComparisonFailureCopy {
    static func detail(_ failure: BeforeAfterModel.Failure) -> String {
        switch failure {
        case .microphonePermissionDenied: "需要麦克风权限才能开始。"
        case .positionUnavailable: "手机位置没有稳定记录；可等待定位恢复或改用手动位置标记。"
        case .movedDuringMeasurement: "录制期间手机位置或方向变化过大。"
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
        case .improved: "调整后目标声音降低"
        case .littleChange: "变化小于当前判断门槛"
        case .worsened: "调整后目标声音升高"
        case .inconclusive: "两次测量不能可靠比较"
        }
    }

    static func detail(_ result: MeasurementComparison) -> String {
        switch result.verdict {
        case .improved: return "目标频率降低至少达到 3 dB，重采样区间也支持下降。"
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
            return "数据区间跨过当前判断门槛，需要再测一次。"
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
