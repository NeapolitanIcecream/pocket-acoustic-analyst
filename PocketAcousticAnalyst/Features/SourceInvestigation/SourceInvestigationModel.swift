import Foundation
import Observation

@MainActor
@Observable
final class SourceInvestigationModel {
  enum Phase {
    case introduction
    case preparingPosition
    case ready(Int)
    case countdown(Int, Int)
    case recording(Int, Double)
    case analyzing(Int)
    case changeState(Int)
    case result(SourceInvestigationEvaluation)
    case invalid(Failure)
  }

  enum Failure: Equatable {
    case microphonePermissionDenied
    case noTrackableFrequency
    case positionUnavailable
    case movedDuringMeasurement
    case audioCapture(AudioCaptureError)
    case lowMeasurementQuality(Set<MeasurementQualityIssue>)
    case baselineTargetNotDetected
    case trackedBandsUnavailable
    case analysisFailed
  }

  var phase: Phase = .introduction
  var subjectName = ""
  var baselineStateName = ""
  var changedStateName = ""
  private(set) var trackingStatus: PoseTrackingStatus = .unavailable
  private(set) var usesManualPlacement = false
  var manualPlacementConfirmed = false

  @ObservationIgnored private let captureClient: any AudioCaptureClient
  @ObservationIgnored private let poseClient: any PoseTrackingClient
  @ObservationIgnored private let analyzer: LowFrequencyAnalyzer
  @ObservationIgnored private let evaluator: SourceInvestigationEvaluator
  @ObservationIgnored private let plan: SourceFrequencyPlan?
  @ObservationIgnored private let isDemoMode: Bool
  @ObservationIgnored private var measurements: [SourceInvestigationMeasurement] = []
  @ObservationIgnored private var rejectedSequenceIndex = 0
  @ObservationIgnored private var userCancelled = false

  init(
    referenceAnalysis: AcousticAnalysis,
    captureClient: any AudioCaptureClient,
    poseClient: any PoseTrackingClient,
    analyzer: LowFrequencyAnalyzer,
    evaluator: SourceInvestigationEvaluator = SourceInvestigationEvaluator(),
    planner: SourceFrequencyPlanner = SourceFrequencyPlanner(),
    isDemoMode: Bool
  ) {
    self.captureClient = captureClient
    self.poseClient = poseClient
    self.analyzer = analyzer
    self.evaluator = evaluator
    self.isDemoMode = isDemoMode
    plan = planner.makePlan(from: referenceAnalysis)
    if isDemoMode {
      subjectName = "游戏与电脑状态"
      baselineStateName = "游戏运行"
      changedStateName = "游戏暂停"
    }
  }

  var canPrepare: Bool {
    !trimmed(subjectName).isEmpty
      && !trimmed(baselineStateName).isEmpty
      && !trimmed(changedStateName).isEmpty
      && trimmed(baselineStateName) != trimmed(changedStateName)
      && plan != nil
  }

  var targetBands: [SourceFrequencyBand] {
    plan?.targetBands ?? []
  }

  var completedMeasurementCount: Int { measurements.count }

  var totalMeasurementCount: Int {
    evaluator.requiredRoundCount * 2 + 1
  }

  var isActivelyMeasuring: Bool {
    switch phase {
    case .countdown, .recording, .analyzing: true
    default: false
    }
  }

  var hasProgressToProtect: Bool {
    completedMeasurementCount > 0 || isActivelyMeasuring
  }

  func prepare() async {
    guard canPrepare, plan != nil else {
      phase = .invalid(.noTrackableFrequency)
      return
    }
    if captureClient.permission == .undetermined {
      let permission = await captureClient.requestPermission()
      guard permission == .granted else {
        phase = .invalid(.microphonePermissionDenied)
        return
      }
    } else if captureClient.permission != .granted {
      phase = .invalid(.microphonePermissionDenied)
      return
    }

    usesManualPlacement = false
    poseClient.start()
    phase = .preparingPosition
    for _ in 0..<20 {
      trackingStatus = poseClient.status
      if trackingStatus == .normal {
        phase = .ready(0)
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    trackingStatus = poseClient.status
  }

  func refreshPosition() {
    trackingStatus = poseClient.status
    if trackingStatus == .normal {
      phase = .ready(rejectedSequenceIndex)
    }
  }

  func useManualPlacement() {
    poseClient.stop()
    if !measurements.isEmpty {
      measurements.removeAll()
      rejectedSequenceIndex = 0
    }
    usesManualPlacement = true
    manualPlacementConfirmed = false
    phase = .ready(0)
  }

  func capture(sequenceIndex: Int) async {
    rejectedSequenceIndex = sequenceIndex
    userCancelled = false
    guard sequenceIndex == measurements.count, sequenceIndex < totalMeasurementCount else {
      phase = .invalid(.analysisFailed)
      return
    }
    guard !usesManualPlacement || manualPlacementConfirmed else {
      phase = .invalid(.positionUnavailable)
      return
    }
    guard let plan else {
      phase = .invalid(.noTrackableFrequency)
      return
    }
    let strictestTarget = plan.targetBands.map(\.centerFrequencyHz).max()

    let startPose: TrackedDevicePose?
    if usesManualPlacement {
      startPose = nil
    } else {
      trackingStatus = poseClient.status
      guard trackingStatus == .normal, let pose = poseClient.snapshot() else {
        phase = .invalid(.positionUnavailable)
        return
      }
      startPose = pose
    }
    if let failure = placementFailure(
      for: startPose,
      targetFrequencyHz: strictestTarget
    ) {
      phase = .invalid(failure)
      return
    }
    let poseMonitor = startPose.map {
      MeasurementPoseMonitor(
        origin: $0,
        maximumDistanceMeters: AcousticPositionTolerance.maximumMeters(for: strictestTarget),
        maximumOrientationDifferenceDegrees: 8
      )
    }

    for count in stride(from: 3, through: 1, by: -1) {
      phase = .countdown(sequenceIndex, count)
      do {
        try await Task.sleep(for: isDemoMode ? .milliseconds(40) : .seconds(1))
      } catch {
        phase = .ready(sequenceIndex)
        return
      }
      if userCancelled {
        phase = .ready(sequenceIndex)
        return
      }
    }

    phase = .recording(sequenceIndex, 0)
    do {
      let captured = try await captureClient.capture(durationSeconds: 20) { [weak self] progress in
        if let self, let poseMonitor {
          poseMonitor.observe(self.poseClient)
        }
        self?.phase = .recording(sequenceIndex, progress)
      }
      guard !userCancelled, !Task.isCancelled else {
        phase = .ready(sequenceIndex)
        return
      }
      if let poseMonitor {
        poseMonitor.observe(poseClient)
        if let invalidity = poseMonitor.invalidity {
          phase =
            invalidity == .trackingUnavailable
            ? .invalid(.positionUnavailable)
            : .invalid(.movedDuringMeasurement)
          return
        }
      }
      phase = .analyzing(sequenceIndex)
      let analyzer = analyzer
      let trackedFrequencyBands = plan.trackedBands
      let analysis = try await Task.detached(priority: .userInitiated) {
        try analyzer.analyze(
          samples: captured.samples,
          sampleRate: captured.sampleRate,
          inputRouteID: captured.inputRouteID,
          inputRouteName: captured.inputRouteName,
          inputChannelCount: captured.inputChannelCount,
          selectedInputChannelIndex: captured.selectedInputChannelIndex,
          trackedFrequencyBands: trackedFrequencyBands,
          measuredAt: captured.startedAt
        )
      }.value
      guard !userCancelled, !Task.isCancelled else {
        phase = .ready(sequenceIndex)
        return
      }

      guard analysis.quality.isUsable else {
        phase = .invalid(.lowMeasurementQuality(analysis.quality.issues))
        return
      }
      guard analysis.trackedBands?.count == trackedFrequencyBands.count else {
        phase = .invalid(.trackedBandsUnavailable)
        return
      }
      if let firstAnalysis = measurements.first?.analysis,
        analysis.inputRouteID != firstAnalysis.inputRouteID
      {
        phase = .invalid(.audioCapture(.routeChanged))
        return
      }
      if let firstAnalysis = measurements.first?.analysis,
        !hasMatchingAudioConfiguration(analysis, firstAnalysis)
      {
        phase = .invalid(.audioCapture(.engineConfigurationChanged))
        return
      }
      let state = state(for: sequenceIndex)
      if state == .baseline, !detectsAnyTarget(in: analysis, targetBands: plan.targetBands) {
        phase = .invalid(.baselineTargetNotDetected)
        return
      }

      let position: PositionSample?
      if let startPose {
        position = PositionSample(
          coordinate: startPose.coordinate,
          orientation: startPose.orientation,
          source: .arkit,
          trackingEpoch: startPose.epoch,
          quality: MeasurementQuality(score: 1)
        )
      } else {
        position = nil
      }
      measurements.append(
        SourceInvestigationMeasurement(
          sequenceIndex: sequenceIndex,
          state: state,
          analysis: analysis,
          position: position,
          positionConfirmedByUser: usesManualPlacement && manualPlacementConfirmed
        )
      )
      poseClient.completeMeasurement()
      manualPlacementConfirmed = false

      let nextIndex = sequenceIndex + 1
      if nextIndex == totalMeasurementCount {
        poseClient.stop()
        phase = .result(
          evaluator.evaluate(
            subjectName: trimmed(subjectName),
            baselineStateName: trimmed(baselineStateName),
            changedStateName: trimmed(changedStateName),
            plan: plan,
            measurements: measurements
          )
        )
      } else {
        phase = .changeState(nextIndex)
      }
    } catch let error as AudioCaptureError {
      if error == .cancelled, userCancelled {
        phase = .ready(sequenceIndex)
      } else {
        phase = .invalid(.audioCapture(error))
      }
    } catch {
      phase = .invalid(.analysisFailed)
    }
  }

  func stateChangeCompleted(nextSequenceIndex: Int) {
    manualPlacementConfirmed = false
    phase = .ready(nextSequenceIndex)
  }

  func retry() {
    phase = .ready(rejectedSequenceIndex)
  }

  func restart() {
    if isActivelyMeasuring { cancelMeasurement() }
    poseClient.stop()
    measurements.removeAll()
    rejectedSequenceIndex = 0
    usesManualPlacement = false
    manualPlacementConfirmed = false
    trackingStatus = .unavailable
    phase = .introduction
  }

  func cancelMeasurement() {
    userCancelled = true
    captureClient.cancel()
  }

  func stop() {
    if isActivelyMeasuring { cancelMeasurement() }
    poseClient.stop()
  }

  func state(for sequenceIndex: Int) -> SourceExperimentState {
    sequenceIndex.isMultiple(of: 2) ? .baseline : .changed
  }
}

extension SourceInvestigationModel {
  fileprivate func detectsAnyTarget(
    in analysis: AcousticAnalysis,
    targetBands: [SourceFrequencyBand]
  ) -> Bool {
    let components = analysis.spectralComponents ?? []
    return targetBands.contains { target in
      let interiorHalfWidth = max(
        0,
        target.halfWidthHz - analysis.nominalFrequencyResolutionHz
      )
      return components.contains { component in
        component.persistence >= analysis.configuration.minimumTonePersistence
          && component.frequencySpreadHz <= analysis.configuration.stableFrequencySpreadHz
          && abs(component.frequencyHz - target.centerFrequencyHz) <= interiorHalfWidth
      }
    }
  }

  fileprivate func trimmed(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  fileprivate func placementFailure(
    for currentPose: TrackedDevicePose?,
    targetFrequencyHz: Double?
  ) -> Failure? {
    guard let firstMeasurement = measurements.first else { return nil }
    if usesManualPlacement {
      return firstMeasurement.position == nil ? nil : .positionUnavailable
    }
    guard let origin = firstMeasurement.position,
      origin.source == .arkit,
      let currentPose,
      origin.trackingEpoch == currentPose.epoch
    else { return .positionUnavailable }
    let tolerance = AcousticPositionTolerance.maximumMeters(for: targetFrequencyHz)
    guard origin.coordinate.distance(to: currentPose.coordinate) <= tolerance,
      origin.orientation.angularDistanceDegrees(to: currentPose.orientation) <= 10
    else { return .movedDuringMeasurement }
    return nil
  }

  fileprivate func hasMatchingAudioConfiguration(
    _ analysis: AcousticAnalysis,
    _ reference: AcousticAnalysis
  ) -> Bool {
    analysis.inputChannelCount == reference.inputChannelCount
      && analysis.selectedInputChannelIndex == reference.selectedInputChannelIndex
      && abs(analysis.sampleRate - reference.sampleRate) < 0.01
      && analysis.analysisVersion == reference.analysisVersion
      && analysis.configuration == reference.configuration
      && analysis.windowSampleCount == reference.windowSampleCount
  }
}
