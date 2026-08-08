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
                        HumInvestigationView(
                            captureClient: appModel.audioCapture,
                            analyzer: appModel.analyzer,
                            isDemoMode: appModel.isDemoMode
                        )
                    case let .spatialScan(analysisID):
                        if let analysis = appModel.analysis(id: analysisID) {
                            SpatialScanView(
                                referenceAnalysis: analysis,
                                captureClient: appModel.audioCapture,
                                poseClient: appModel.isDemoMode
                                    ? DemoPoseTrackingClient()
                                    : ARPoseTrackingClient(),
                                analyzer: appModel.analyzer
                            )
                        } else {
                            ContentUnavailableView(
                                "找不到起始测量",
                                systemImage: "exclamationmark.triangle",
                                description: Text("请返回首页重新检查持续嗡声。")
                            )
                        }
                    case let .comparison(analysisID):
                        BeforeAfterView(
                            referenceAnalysis: analysisID.flatMap { appModel.analysis(id: $0) },
                            captureClient: appModel.audioCapture,
                            poseClient: appModel.isDemoMode
                                ? DemoPoseTrackingClient(poses: [
                                    SpatialCoordinate(x: 0, y: 0, z: 0),
                                    SpatialCoordinate(x: 0.02, y: 0, z: 0),
                                ])
                                : ARPoseTrackingClient(),
                            analyzer: appModel.analyzer
                        )
                    case .history:
                        HistoryView()
                    case .aboutMeasurement:
                        MeasurementLimitsView()
                    }
                }
        }
        .tint(AppTheme.accent)
        .task { await appModel.loadHistory() }
    }
}
