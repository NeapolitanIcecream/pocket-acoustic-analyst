import SwiftUI

struct HomeView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        ZStack {
            AppTheme.warmBackground.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    humCard
                    otherProblems
                    measurementNote
                }
                .padding(20)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("声音调查助手")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("记录", systemImage: "clock.arrow.circlepath") {
                    appModel.path.append(.history)
                }
                .accessibilityIdentifier("historyButton")
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("你遇到了什么声音问题？")
                .font(.largeTitle.bold())
                .accessibilityIdentifier("homeTitle")
            Text("选择最接近的情况。应用会告诉你怎么测，并说明结果能证明什么。")
                .font(.body)
                .foregroundStyle(.secondary)
        }
    }

    private var humCard: some View {
        Button {
            appModel.startHumInvestigation()
        } label: {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "waveform.path")
                    .font(.title)
                    .foregroundStyle(AppTheme.accent)
                Text("我听到持续的嗡嗡声")
                    .font(.title2.bold())
                    .foregroundStyle(.primary)
                Text("测出主要频率，检查它是否持续，并寻找房间里影响较小的位置。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                Label("开始约 20 秒的引导测量", systemImage: "arrow.right.circle.fill")
                    .font(.headline)
                    .foregroundStyle(AppTheme.accent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(22)
            .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 24))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("startHumInvestigation")
    }

    private var otherProblems: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("其他调查")
                .font(.headline)

            ProblemRow(icon: "arrow.left.and.right", title: "比较调整前后", detail: "复测一次变化是否真实") {
                appModel.path.append(.comparison(analysisID: nil))
            }

            ProblemRow(icon: "speaker.wave.2", title: "回声或振动问题", detail: "后续版本提供", isEnabled: false) {}
        }
    }

    private var measurementNote: some View {
        Button {
            appModel.path.append(.aboutMeasurement)
        } label: {
            Label("了解手机测量能说明什么", systemImage: "info.circle")
                .font(.subheadline.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(AppTheme.accent)
    }
}

private struct ProblemRow: View {
    let icon: String
    let title: String
    let detail: String
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.headline)
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isEnabled ? "chevron.right" : "lock")
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .background(AppTheme.cardBackground, in: RoundedRectangle(cornerRadius: 18))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.58)
    }
}

