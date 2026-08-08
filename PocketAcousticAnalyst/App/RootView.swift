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
          case .sourceInvestigation(let analysisID):
            if let analysis = appModel.analysis(id: analysisID) {
              SourceInvestigationView(
                referenceAnalysis: analysis,
                captureClient: appModel.audioCapture,
                poseClient: appModel.usesDemoPoseTracking
                  ? DemoPoseTrackingClient(poses: [SpatialCoordinate(x: 0, y: 0, z: 0)])
                  : ARPoseTrackingClient(),
                analyzer: appModel.analyzer,
                isDemoMode: appModel.isDemoMode
              )
            } else {
              ContentUnavailableView(
                "找不到起始测量",
                systemImage: "exclamationmark.triangle",
                description: Text("请返回首页重新检查这段声音。")
              )
            }
          case .sourceInvestigationDetails(let investigationID):
            if let evaluation = appModel.sourceInvestigation(id: investigationID) {
              SourceInvestigationDetailView(evaluation: evaluation)
            } else {
              ContentUnavailableView(
                "找不到状态调查",
                systemImage: "exclamationmark.triangle",
                description: Text("这条记录可能已被移除，请返回调查记录。")
              )
            }
          case .spatialScan(let analysisID):
            if let analysis = appModel.analysis(id: analysisID) {
              SpatialScanView(
                referenceAnalysis: analysis,
                captureClient: appModel.audioCapture,
                poseClient: appModel.usesDemoPoseTracking
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
          case .comparison(let analysisID):
            BeforeAfterView(
              referenceAnalysis: analysisID.flatMap { appModel.analysis(id: $0) },
              captureClient: appModel.audioCapture,
              poseClient: appModel.usesDemoPoseTracking
                ? DemoPoseTrackingClient(poses: [
                  SpatialCoordinate(x: 0, y: 0, z: 0),
                  SpatialCoordinate(x: 0.02, y: 0, z: 0),
                ])
                : ARPoseTrackingClient(),
              analyzer: appModel.analyzer
            )
          case .history:
            HistoryView()
          case .analysisDetails(let analysisID):
            if let analysis = appModel.analysis(id: analysisID) {
              AcousticAnalysisDetailView(analysis: analysis)
            } else {
              ContentUnavailableView(
                "找不到测量记录",
                systemImage: "exclamationmark.triangle",
                description: Text("这条记录可能已被移除，请返回调查记录。")
              )
            }
          case .aboutMeasurement:
            MeasurementLimitsView()
          }
        }
    }
    .tint(AppTheme.accent)
    .task { await appModel.loadHistory() }
  }
}
