import Foundation
import Observation

@MainActor
@Observable
final class AppModel {
    enum Route: Hashable {
        case humInvestigation
        case spatialScan(analysisID: UUID)
        case comparison(analysisID: UUID?)
        case history
        case aboutMeasurement
    }

    var path: [Route] = []
    var completedAnalyses: [AcousticAnalysis] = []

    func startHumInvestigation() {
        path.append(.humInvestigation)
    }
}
