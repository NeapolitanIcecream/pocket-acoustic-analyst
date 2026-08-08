import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationStack(path: $appModel.path) {
            HomeView()
                .navigationDestination(for: AppModel.Route.self) { route in
                    switch route {
                    case .humInvestigation:
                        Text("嗡声调查")
                    case let .spatialScan(analysisID):
                        Text("空间复测 \(analysisID.uuidString)")
                    case .comparison:
                        Text("前后对比")
                    case .history:
                        Text("调查记录")
                    case .aboutMeasurement:
                        MeasurementLimitsView()
                    }
                }
        }
        .tint(AppTheme.accent)
    }
}

