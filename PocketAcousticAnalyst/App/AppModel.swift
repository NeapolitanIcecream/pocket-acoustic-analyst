import Foundation
import Observation

struct AppRuntimeConfiguration: Equatable, Sendable {
  let usesDemoAudio: Bool
  let usesDemoPoseTracking: Bool
  let usesInMemoryRepository: Bool
  let pacesDemoCaptureInRealTime: Bool
  let demoAudioProfile: DemoAudioProfile

  init(arguments: [String]) {
    let isUITesting = arguments.contains("-uiTesting")
    let isDemoMode = arguments.contains("-demoMode")
    let isRealPoseTest = isUITesting && arguments.contains("-realPoseTest")
    usesDemoAudio = isDemoMode || isRealPoseTest
    usesDemoPoseTracking = isDemoMode
    usesInMemoryRepository = isDemoMode || isUITesting
    pacesDemoCaptureInRealTime = isRealPoseTest
    demoAudioProfile =
      isDemoMode && arguments.contains("-intermittentDemo")
      ? .intermittentTone : .stableTone
  }
}

@MainActor
@Observable
final class AppModel {
  enum Route: Hashable {
    case humInvestigation
    case spatialScan(analysisID: UUID)
    case comparison(analysisID: UUID?)
    case history
    case analysisDetails(analysisID: UUID)
    case aboutMeasurement
  }

  var path: [Route] = []
  var completedAnalyses: [AcousticAnalysis] = []
  var completedSpatialScans: [SpatialScanEvaluation] = []
  var completedComparisons: [MeasurementComparison] = []
  var historyLoadError = false
  var historySaveError = false
  @ObservationIgnored let audioCapture: any AudioCaptureClient
  @ObservationIgnored let analyzer: LowFrequencyAnalyzer
  @ObservationIgnored let isDemoMode: Bool
  @ObservationIgnored let usesDemoPoseTracking: Bool
  @ObservationIgnored private let repository: any InvestigationRepository
  @ObservationIgnored private var didLoadHistory = false
  @ObservationIgnored private var persistenceTask: Task<Void, Never>?

  init(
    audioCapture: (any AudioCaptureClient)? = nil,
    analyzer: LowFrequencyAnalyzer = LowFrequencyAnalyzer(),
    isDemoMode: Bool? = nil,
    repository: (any InvestigationRepository)? = nil
  ) {
    let runtime = AppRuntimeConfiguration(arguments: ProcessInfo.processInfo.arguments)
    let requestedDemoMode = isDemoMode ?? runtime.usesDemoAudio
    self.isDemoMode = requestedDemoMode
    usesDemoPoseTracking = isDemoMode ?? runtime.usesDemoPoseTracking
    self.analyzer = analyzer
    self.repository =
      repository
      ?? (runtime.usesInMemoryRepository || requestedDemoMode
        ? InMemoryInvestigationRepository() : LocalInvestigationRepository())
    if let audioCapture {
      self.audioCapture = audioCapture
    } else if requestedDemoMode {
      self.audioCapture = DemoAudioCaptureClient(
        stepDelay: runtime.pacesDemoCaptureInRealTime ? .seconds(2) : .milliseconds(35),
        profile: runtime.demoAudioProfile
      )
    } else {
      self.audioCapture = AVAudioCaptureClient()
    }
  }

  func startHumInvestigation() {
    path.append(.humInvestigation)
  }

  func store(_ analysis: AcousticAnalysis) {
    completedAnalyses.removeAll { $0.id == analysis.id }
    completedAnalyses.append(analysis)
    persistHistory()
  }

  func analysis(id: UUID) -> AcousticAnalysis? {
    completedAnalyses.first { $0.id == id }
  }

  func store(_ scan: SpatialScanEvaluation) {
    completedSpatialScans.removeAll { $0.id == scan.id }
    completedSpatialScans.append(scan)
    for point in scan.measurements + scan.allOriginChecks {
      completedAnalyses.removeAll { $0.id == point.analysis.id }
      completedAnalyses.append(point.analysis)
    }
    persistHistory()
  }

  func store(_ comparison: MeasurementComparison) {
    completedComparisons.removeAll { $0.id == comparison.id }
    completedComparisons.append(comparison)
    persistHistory()
  }

  func loadHistory() async {
    guard !didLoadHistory else { return }
    didLoadHistory = true
    do {
      let archive = try await repository.load()
      completedAnalyses = archive.analyses
      completedSpatialScans = archive.spatialScans
      completedComparisons = archive.comparisons
      historyLoadError = false
    } catch {
      historyLoadError = true
    }
  }

  private func persistHistory() {
    let archive = InvestigationArchive(
      analyses: completedAnalyses,
      spatialScans: completedSpatialScans,
      comparisons: completedComparisons
    )
    let repository = repository
    let previousTask = persistenceTask
    persistenceTask = Task { [weak self] in
      await previousTask?.value
      guard let self else { return }
      do {
        try await repository.save(archive)
        self.historySaveError = false
      } catch {
        self.historySaveError = true
      }
    }
  }
}
