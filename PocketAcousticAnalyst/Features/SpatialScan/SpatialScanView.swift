import SwiftUI

struct SpatialScanView: View {
    @Environment(AppModel.self) private var appModel
    @State private var model: SpatialScanModel

    init(
        referenceAnalysis: AcousticAnalysis,
        captureClient: any AudioCaptureClient,
        poseClient: any PoseTrackingClient,
        analyzer: LowFrequencyAnalyzer
    ) {
        _model = State(
            initialValue: SpatialScanModel(
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
        .navigationTitle("比较房间位置")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { model.stop() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .introduction:
            introduction
        case .locating:
            locating
        case .ready:
            ready
        case let .recording(progress):
            recording(progress)
        case .analyzing:
            progressView("正在检查这个位置")
        case .closureRequired:
            closureRequired
        case let .result(result):
            resultView(result)
        case let .pointRejected(failure):
            rejected(failure)
        }
    }

    private var introduction: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 48))
                    .foregroundStyle(AppTheme.accent)
                Text("只比较你实际测过的位置")
                    .font(.largeTitle.bold())
                Text("目标是约 \(Int(model.targetFrequencyHz.rounded())) Hz 的持续声音。每个位置都要把手机放在相近高度和方向。")
                    .font(.title3)

                SpatialInfoCard(
                    icon: "mappin.and.ellipse",
                    title: "至少测量 3 个位置",
                    detail: "位置跟踪可显示相对距离；不可用时仍可按位置名称比较。"
                )
                SpatialInfoCard(
                    icon: "arrow.uturn.backward.circle",
                    title: "最后回到起点复测",
                    detail: "只有起点声音保持稳定，才会把时间变化解释为空间差异。"
                )

                Button("开始位置跟踪") {
                    Task { await model.startPositioning() }
                }
                .buttonStyle(SpatialPrimaryButtonStyle())
                .accessibilityIdentifier("startPositionTracking")
            }
            .padding(24)
        }
    }

    private var locating: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                ProgressView().controlSize(.large)
                Text(trackingTitle).font(.largeTitle.bold())
                Text("慢慢移动手机，让摄像头看到有纹理的墙面或家具。定位稳定前不会记录坐标。")

                Button("重新检查定位") { model.refreshPositioning() }
                    .buttonStyle(.bordered)
                Button("改用位置名称") { model.useManualPositions() }
                    .buttonStyle(SpatialPrimaryButtonStyle())
                    .accessibilityIdentifier("useManualPositions")
                Text("使用位置名称时不会显示米数，也不会绘制坐标图。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
        }
    }

    private var ready: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.measurements.isEmpty ? "先测当前位置" : "移动到下一个位置")
                    .font(.largeTitle.bold())
                Text(model.usesManualPositions
                    ? "给位置一个容易认出的名称，保持手机高度和方向不变。"
                    : "移动后停稳手机。录制期间不要走动或转动手机。")

                if !model.measurements.isEmpty {
                    measuredPointList(model.measurements)
                }

                TextField("位置名称", text: $model.draftLabel)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("spatialPointLabel")

                Button("测量这个位置") {
                    Task { await model.capturePoint() }
                }
                .buttonStyle(SpatialPrimaryButtonStyle())
                .accessibilityIdentifier("captureSpatialPoint")

                if model.canFinishSampling {
                    Button("位置已经足够，回到起点") { model.requestClosure() }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                        .accessibilityIdentifier("finishSpatialPoints")
                } else {
                    Text("还需测量 \(3 - model.measurements.count) 个位置")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(24)
        }
    }

    private var closureRequired: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("回到第一个位置")
                    .font(.largeTitle.bold())
                if let origin = model.measurements.first {
                    Text("回到“\(origin.label)”，把手机放到相同高度并保持原来的方向。")
                }
                Text("这次复测用于检查声源是否随时间变化，不会作为新的候选位置。")

                Button("我已回到起点，开始复测") {
                    Task { await model.capturePoint(isClosure: true) }
                }
                .buttonStyle(SpatialPrimaryButtonStyle())
                .accessibilityIdentifier("captureOriginClosure")
            }
            .padding(24)
        }
    }

    private func recording(_ progress: Double) -> some View {
        VStack(spacing: 24) {
            ProgressView(value: progress)
                .progressViewStyle(.circular)
                .controlSize(.large)
            Text("正在测量，请保持手机不动")
                .font(.title2.bold())
            Text("已完成 \(Int(progress * 100))%")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("取消测量") { model.cancelMeasurement() }
                .buttonStyle(.bordered)
        }
        .padding(24)
        .accessibilityIdentifier("spatialRecording")
    }

    private func rejected(_ failure: SpatialScanModel.Failure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text("这个点没有加入比较")
                    .font(.largeTitle.bold())
                Text(SpatialFailureCopy.detail(failure))
                Text("已有合格位置仍会保留。请在条件稳定后重测当前步骤。")
                    .foregroundStyle(.secondary)
                Button("重测当前步骤") { model.retryRejectedPoint() }
                    .buttonStyle(SpatialPrimaryButtonStyle())
            }
            .padding(24)
        }
        .accessibilityIdentifier("spatialPointRejected")
    }

    private func resultView(_ result: SpatialScanEvaluation) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let recommendation = result.recommendation,
                   let point = result.measurements.first(where: { $0.id == recommendation.recommendedMeasurementID })
                {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(AppTheme.accent)
                    Text("发现影响较小的实测位置")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("spatialRecommendationResult")
                    Text("“\(point.label)”的目标频率比起点低约 \(recommendation.improvementDB.formatted(.number.precision(.fractionLength(1)))) dB。")
                        .font(.title3)
                    if let distance = recommendation.distanceMeters {
                        Text("与起点的相对距离约 \(distance.formatted(.number.precision(.fractionLength(1)))) 米。")
                    }
                    Text("这是同一设备、同一次扫描中的相对差值。结果不能确定声源或房间驻波。")
                        .foregroundStyle(.secondary)
                } else if result.canRankMeasuredPoints {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("没有发现明显更低的实测点")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("spatialNoImprovementResult")
                    Text("各位置差异小于当前建议门槛。可以扩大移动范围后重新扫描。")
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.orange)
                    Text("这次扫描不能比较位置")
                        .font(.largeTitle.bold())
                        .accessibilityIdentifier("spatialInvalidResult")
                    Text(SpatialResultCopy.blockingReason(result.issues))
                    Text("未生成安静点或距离结论。")
                        .foregroundStyle(.secondary)
                }

                if result.measurements.allSatisfy({ $0.position.source == .arkit }) {
                    MeasuredPointMap(measurements: result.measurements)
                }
                measuredPointList(result.measurements)

                if result.recommendation != nil {
                    Button("保存结果并验证一次调整") {
                        appModel.store(result)
                        let recommendedID = result.recommendation?.recommendedMeasurementID
                        let analysisID = result.measurements.first { $0.id == recommendedID }?.analysis.id
                        appModel.path.append(.comparison(analysisID: analysisID))
                    }
                    .buttonStyle(SpatialPrimaryButtonStyle())
                    .accessibilityIdentifier("startBeforeAfterFromSpatial")
                }

                Button("只保存扫描结果") {
                    appModel.store(result)
                    appModel.path = []
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("saveSpatialScan")

                Button("重新扫描") {
                    Task { await model.restart() }
                }
                .buttonStyle(.bordered)
            }
            .padding(24)
        }
    }

    private func measuredPointList(_ measurements: [SpatialMeasurement]) -> some View {
        let baseline = measurements.first?.targetLevelDB ?? 0
        return VStack(alignment: .leading, spacing: 12) {
            Text("已实测位置").font(.headline)
            ForEach(measurements) { point in
                HStack {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(AppTheme.accent)
                    Text(point.label)
                    Spacer()
                    Text(relativeLevel(point.targetLevelDB - baseline))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Text("数值为相对起点的目标频率变化，不是校准声压级。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private func progressView(_ title: String) -> some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            Text(title).font(.headline)
        }
    }

    private var trackingTitle: String {
        switch model.trackingStatus {
        case .unavailable: "位置跟踪不可用"
        case .initializing: "正在建立相对位置"
        case .normal: "位置跟踪已稳定"
        case .limited: "位置跟踪暂时不稳定"
        }
    }

    private func relativeLevel(_ value: Double) -> String {
        if abs(value) < 0.05 { return "起点" }
        return "\(value >= 0 ? "+" : "")\(value.formatted(.number.precision(.fractionLength(1)))) dB"
    }
}

private struct SpatialInfoCard: View {
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

private struct MeasuredPointMap: View {
    let measurements: [SpatialMeasurement]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实测点位置图").font(.headline)
            GeometryReader { geometry in
                Canvas { context, size in
                    let xs = measurements.map(\.position.coordinate.x)
                    let zs = measurements.map(\.position.coordinate.z)
                    let minX = xs.min() ?? 0
                    let maxX = xs.max() ?? 0
                    let minZ = zs.min() ?? 0
                    let maxZ = zs.max() ?? 0
                    let baseline = measurements.first?.targetLevelDB ?? 0
                    for point in measurements {
                        let x = normalized(point.position.coordinate.x, min: minX, max: maxX)
                        let z = normalized(point.position.coordinate.z, min: minZ, max: maxZ)
                        let center = CGPoint(
                            x: 24 + x * max(0, size.width - 48),
                            y: 24 + z * max(0, size.height - 48)
                        )
                        let delta = point.targetLevelDB - baseline
                        let color = delta <= -3 ? AppTheme.accent : (delta >= 3 ? .orange : .gray)
                        context.fill(
                            Path(ellipseIn: CGRect(x: center.x - 10, y: center.y - 10, width: 20, height: 20)),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(height: 180)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            Text("仅显示测量点，不推算未测区域。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
    }

    private func normalized(_ value: Double, min: Double, max: Double) -> Double {
        guard max - min > 0.001 else { return 0.5 }
        return (value - min) / (max - min)
    }
}

private struct SpatialPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.white)
            .background(AppTheme.accent.opacity(configuration.isPressed ? 0.78 : 1), in: RoundedRectangle(cornerRadius: 16))
    }
}

private enum SpatialFailureCopy {
    static func detail(_ failure: SpatialScanModel.Failure) -> String {
        switch failure {
        case .microphoneUnavailable: "麦克风权限当前不可用。"
        case .audioCapture(.interrupted): "系统音频中断了这次测量。"
        case .audioCapture(.routeChanged): "麦克风或音频设备在测量期间发生了变化。"
        case .audioCapture: "录音没有完整结束。"
        case .positionUnavailable: "当前位置跟踪不稳定，无法保存坐标。"
        case .movedDuringMeasurement: "录制期间手机位置或方向变化过大。"
        case .lowMeasurementQuality: "声音过小、削波或环境变化使这个点不可用。"
        case .targetChanged: "原来的持续频率没有稳定出现。"
        case .targetBandUnavailable, .analysisFailed: "有效录音不足，无法计算目标频率的相对变化。"
        }
    }
}

private enum SpatialResultCopy {
    static func blockingReason(_ issues: Set<SpatialScanIssue>) -> String {
        if issues.contains(.originSoundDidNotClose) {
            return "回到起点后，目标声音与开始时差异过大；这可能是时间变化。"
        }
        if issues.contains(.originPositionDidNotClose) || issues.contains(.trackingEpochChanged) {
            return "位置跟踪没有回到同一坐标，或跟踪坐标在途中重置。"
        }
        if issues.contains(.routeOrConfigurationChanged) {
            return "扫描期间麦克风或分析配置发生了变化。"
        }
        if issues.contains(.targetFrequencyChanged) {
            return "扫描期间原来的持续频率发生了变化。"
        }
        if issues.contains(.lowMeasurementQuality) {
            return "至少一个位置的测量质量不足。"
        }
        return "合格的实测位置不足。"
    }
}
