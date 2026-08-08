import SwiftUI

struct SourceInvestigationDetailView: View {
  @Environment(AppModel.self) private var appModel
  let evaluation: SourceInvestigationEvaluation

  var body: some View {
    SourceInvestigationResultView(
      evaluation: evaluation,
      onRestart: {
        guard let reference = evaluation.measurements.first?.analysis else { return }
        appModel.path.append(.sourceInvestigation(analysisID: reference.id))
      }
    )
    .background(AppTheme.warmBackground)
    .navigationTitle("状态调查详情")
    .navigationBarTitleDisplayMode(.inline)
  }
}
