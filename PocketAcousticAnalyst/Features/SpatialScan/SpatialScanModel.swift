import Foundation
import Observation

@MainActor
@Observable
final class SpatialScanModel {
  enum Phase {
    case introduction
    case locating
    case ready
    case recording(Double)
    case analyzing
    case closureRequired
    case result(SpatialScanEvaluation)
    case pointRejected(Failure)
  }

  enum Failure: Equatable {
    case microphoneUnavailable
    case audioCapture(AudioCaptureError)
    case positionUnavailable
    case movedDuringMeasurement
    case lowMeasurementQuality(Set<MeasurementQualityIssue>)
    case targetChanged
    case targetBandUnavailable
    case analysisFailed
  }

  var phase: Phase = .introduction
  var measurements: [SpatialMeasurement] = []
  private(set) var originChecks: [SpatialMeasurement] = []
  var draftLabel = "当前位置"
  private(set) var trackingStatus: PoseTrackingStatus = .unavailable
  private(set) var usesManualPositions = false

  let targetFrequencyHz: Double
  let targetBandHalfWidthHz: Double

  @ObservationIgnored private let captureClient: any AudioCaptureClient
  @ObservationIgnored private let poseClient: any PoseTrackingClient
  @ObservationIgnored private let analyzer: LowFrequencyAnalyzer
  @ObservationIgnored private let evaluator: SpatialScanEvaluator
  @ObservationIgnored private var userCancelled = false
  @ObservationIgnored private var rejectedPointWasClosure = false

  init(
    referenceAnalysis: AcousticAnalysis,
    captureClient: any AudioCaptureClient,
    poseClient: any PoseTrackingClient,
    analyzer: LowFrequencyAnalyzer,
    evaluator: SpatialScanEvaluator = SpatialScanEvaluator()
  ) {
    targetFrequencyHz = referenceAnalysis.tone?.frequencyHz ?? 0
    targetBandHalfWidthHz = min(
      max(1, 3 * (referenceAnalysis.tone?.frequencySpreadHz ?? 0)),
      3
    )
    self.captureClient = captureClient
    self.poseClient = poseClient
    self.analyzer = analyzer
    self.evaluator = evaluator
  }

  var canFinishSampling: Bool {
    measurements.count >= evaluator.minimumMeasuredPointCount
      && originChecks.count == measurements.count - 1
  }

  var isActivelyMeasuring: Bool {
    switch phase {
    case .recording, .analyzing: true
    default: false
    }
  }

  func startPositioning() async {
    usesManualPositions = false
    poseClient.start()
    phase = .locating
    for _ in 0..<20 {
      trackingStatus = poseClient.status
      if trackingStatus == .normal {
        phase = .ready
        return
      }
      try? await Task.sleep(for: .milliseconds(250))
    }
    trackingStatus = poseClient.status
  }

  func refreshPositioning() {
    trackingStatus = poseClient.status
    if trackingStatus == .normal {
      phase = .ready
    }
  }

  func useManualPositions() {
    poseClient.stop()
    usesManualPositions = true
    trackingStatus = .unavailable
    phase = .ready
  }

  func capturePoint(isClosure: Bool = false) async {
    rejectedPointWasClosure = isClosure
    guard captureClient.permission == .granted else {
      phase = .pointRejected(.microphoneUnavailable)
      return
    }

    userCancelled = false
    let startPose: TrackedDevicePose?
    if usesManualPositions {
      startPose = nil
    } else {
      trackingStatus = poseClient.status
      guard trackingStatus == .normal, let pose = poseClient.snapshot() else {
        phase = .pointRejected(.positionUnavailable)
        return
      }
      startPose = pose
    }
    let poseMonitor = startPose.map {
      MeasurementPoseMonitor(
        origin: $0,
        maximumDistanceMeters: AcousticPositionTolerance.maximumMeters(for: targetFrequencyHz),
        maximumOrientationDifferenceDegrees: 8
      )
    }

    phase = .recording(0)
    do {
      let capture = try await captureClient.capture(durationSeconds: 20) { [weak self] progress in
        if let self, let poseMonitor {
          poseMonitor.observe(self.poseClient)
        }
        self?.phase = .recording(progress)
      }
      if let poseMonitor {
        poseMonitor.observe(poseClient)
        if let invalidity = poseMonitor.invalidity {
          phase =
            invalidity == .trackingUnavailable
            ? .pointRejected(.positionUnavailable)
            : .pointRejected(.movedDuringMeasurement)
          return
        }
      }
      phase = .analyzing

      let analyzer = analyzer
      let comparisonTargetFrequencyHz = targetFrequencyHz
      let comparisonBandHalfWidthHz = targetBandHalfWidthHz
      let analysis = try await Task.detached(priority: .userInitiated) {
        try analyzer.analyze(
          samples: capture.samples,
          sampleRate: capture.sampleRate,
          inputRouteID: capture.inputRouteID,
          inputRouteName: capture.inputRouteName,
          inputChannelCount: capture.inputChannelCount,
          selectedInputChannelIndex: capture.selectedInputChannelIndex,
          comparisonTargetFrequencyHz: comparisonTargetFrequencyHz,
          comparisonBandHalfWidthHz: comparisonBandHalfWidthHz,
          measuredAt: capture.startedAt
        )
      }.value

      guard analysis.quality.isUsable,
        !analysis.quality.issues.contains(.unstableEnvironment)
      else {
        phase = .pointRejected(.lowMeasurementQuality(analysis.quality.issues))
        return
      }
      guard let band = analysis.lockedBand,
        abs(band.centerFrequencyHz - targetFrequencyHz) < 0.01,
        abs(band.halfWidthHz - targetBandHalfWidthHz) < 0.01,
        band.levelSpreadDB <= analysis.configuration.stableLevelSpreadDB
      else {
        phase = .pointRejected(.targetBandUnavailable)
        return
      }
      let reliableTone = analysis.tone.flatMap { tone in
        tone.isStable && tone.confidence != .low ? tone : nil
      }
      let mustVerifySourceContinuity = measurements.isEmpty || isClosure
      if mustVerifySourceContinuity {
        guard let reliableTone,
          band.contains(
            frequencyHz: reliableTone.frequencyHz,
            nominalFrequencyResolutionHz: analysis.nominalFrequencyResolutionHz
          )
        else {
          phase = .pointRejected(.targetChanged)
          return
        }
      } else if let reliableTone,
        !band.contains(
          frequencyHz: reliableTone.frequencyHz,
          nominalFrequencyResolutionHz: analysis.nominalFrequencyResolutionHz
        )
      {
        phase = .pointRejected(.targetChanged)
        return
      }

      let position: PositionSample
      if usesManualPositions {
        position = manualPosition(isClosure: isClosure)
      } else {
        guard let startPose else {
          phase = .pointRejected(.positionUnavailable)
          return
        }
        position = PositionSample(
          coordinate: startPose.coordinate,
          orientation: startPose.orientation,
          source: .arkit,
          trackingEpoch: startPose.epoch,
          quality: MeasurementQuality(score: 1)
        )
      }

      let measurement = SpatialMeasurement(
        label: isClosure ? "起点复测" : resolvedLabel,
        position: position,
        analysis: analysis,
        targetFrequencyHz: targetFrequencyHz,
        targetBandHalfWidthHz: band.halfWidthHz,
        targetLevelDB: band.levelDB
      )
      poseClient.completeMeasurement()

      if isClosure {
        originChecks.append(measurement)
        phase = .ready
      } else {
        measurements.append(measurement)
        draftLabel = "实测点 \(measurements.count + 1)"
        phase = measurements.count == 1 ? .ready : .closureRequired
      }
    } catch let error as AudioCaptureError {
      if error == .cancelled, userCancelled {
        phase = isClosure ? .closureRequired : .ready
      } else {
        phase = .pointRejected(.audioCapture(error))
      }
    } catch is AcousticAnalysisError {
      phase = .pointRejected(.analysisFailed)
    } catch {
      phase = .pointRejected(.analysisFailed)
    }
  }

  func requestClosure() {
    guard canFinishSampling, let closure = originChecks.last else { return }
    let result = evaluator.evaluate(
      measurements: measurements,
      originChecks: Array(originChecks.dropLast()),
      closure: closure
    )
    poseClient.stop()
    phase = .result(result)
  }

  func retryRejectedPoint() {
    phase = rejectedPointWasClosure ? .closureRequired : .ready
  }

  func restart() async {
    measurements = []
    originChecks = []
    draftLabel = "当前位置"
    rejectedPointWasClosure = false
    await startPositioning()
  }

  func cancelMeasurement() {
    userCancelled = true
    captureClient.cancel()
  }

  func stop() {
    if isActivelyMeasuring {
      cancelMeasurement()
    }
    poseClient.stop()
  }
}

extension SpatialScanModel {
  fileprivate var resolvedLabel: String {
    let trimmed = draftLabel.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? "实测点 \(measurements.count + 1)" : trimmed
  }

  fileprivate func manualPosition(isClosure: Bool) -> PositionSample {
    PositionSample(
      coordinate: SpatialCoordinate(
        x: isClosure ? 0 : Double(measurements.count),
        y: 0,
        z: 0
      ),
      orientation: .identity,
      source: .guidedManual,
      trackingEpoch: nil,
      quality: MeasurementQuality(score: 0.82)
    )
  }
}
