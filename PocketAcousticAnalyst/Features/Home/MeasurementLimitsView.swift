import SwiftUI

struct MeasurementLimitsView: View {
  var body: some View {
    List {
      Section("可以帮助判断") {
        Label("持续声音的主要频率", systemImage: "waveform")
        Label("同一房间不同位置的相对差异", systemImage: "point.3.connected.trianglepath.dotted")
        Label("一次调整前后的相对变化", systemImage: "arrow.left.arrow.right")
      }

      Section("不能单独证明") {
        Label("准确的绝对声压级", systemImage: "gauge.with.dots.needle.50percent")
        Label("具体是哪台设备产生声音", systemImage: "questionmark.circle")
        Label("声音一定通过哪条路径传播", systemImage: "arrow.triangle.branch")
      }

      Section {
        Text("默认结果来自未经校准的手机麦克风，只适合在同一台设备上做相对比较。")
      }
    }
    .navigationTitle("测量边界")
  }
}
