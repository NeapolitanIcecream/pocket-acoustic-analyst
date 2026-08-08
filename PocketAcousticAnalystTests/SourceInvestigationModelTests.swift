import Foundation
import Testing

@testable import PocketAcousticAnalyst

@MainActor
struct SourceInvestigationModelTests {
  @Test func sevenStepExperimentFindsTheRepeatedChangedComponent() async throws {
    let analyzer = LowFrequencyAnalyzer()
    let reference = try analyzer.analyze(
      samples: Self.samples(changedState: false),
      sampleRate: Self.sampleRate,
      inputRouteID: "test-mic"
    )
    #expect(reference.resolvedSoundPattern == .multipleTones)

    let captures = (0..<7).map { index in
      CapturedAudio(
        samples: Self.samples(changedState: !index.isMultiple(of: 2)),
        sampleRate: Self.sampleRate,
        inputRouteID: "test-mic",
        inputRouteName: "Test microphone",
        inputChannelCount: 1,
        selectedInputChannelIndex: 0,
        startedAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let model = SourceInvestigationModel(
      referenceAnalysis: reference,
      captureClient: SourceSequenceCaptureStub(captures: captures),
      poseClient: DemoPoseTrackingClient(poses: [SpatialCoordinate(x: 0, y: 0, z: 0)]),
      analyzer: analyzer,
      isDemoMode: true
    )

    await model.prepare()
    for index in 0..<7 {
      guard case .ready(index) = model.phase else {
        Issue.record("Expected step \(index) to be ready")
        return
      }
      await model.capture(sequenceIndex: index)
      if index < 6 {
        guard case .changeState(index + 1) = model.phase else {
          Issue.record("Expected a state transition after step \(index)")
          return
        }
        model.stateChangeCompleted(nextSequenceIndex: index + 1)
      }
    }

    guard case .result(let result) = model.phase else {
      Issue.record("Expected a completed source investigation")
      return
    }
    #expect(result.verdict == .frequencySpecificSynchronization)
    let changedBand = try #require(
      result.bandSummaries.first { abs($0.frequencyHz - 216.4) < 2 }
    )
    let unchangedBand = try #require(
      result.bandSummaries.first { abs($0.frequencyHz - 53.17) < 2 }
    )
    #expect(changedBand.relationship == .lowerInChangedState)
    #expect(changedBand.synchronizedRoundCount == 3)
    #expect(unchangedBand.relationship == .littleChange)
    #expect(result.measurements.count == 7)
  }

  @Test func switchingFromTrackedToManualPlacementRestartsTheSequence() async throws {
    let analyzer = LowFrequencyAnalyzer()
    let reference = try analyzer.analyze(
      samples: Self.samples(changedState: false),
      sampleRate: Self.sampleRate,
      inputRouteID: "test-mic"
    )
    let captures = (0..<7).map { index in
      CapturedAudio(
        samples: Self.samples(changedState: !index.isMultiple(of: 2)),
        sampleRate: Self.sampleRate,
        inputRouteID: "test-mic",
        inputRouteName: "Test microphone",
        inputChannelCount: 1,
        selectedInputChannelIndex: 0,
        startedAt: Date(timeIntervalSince1970: Double(index))
      )
    }
    let model = SourceInvestigationModel(
      referenceAnalysis: reference,
      captureClient: SourceSequenceCaptureStub(captures: captures),
      poseClient: DemoPoseTrackingClient(poses: [SpatialCoordinate(x: 0, y: 0, z: 0)]),
      analyzer: analyzer,
      isDemoMode: true
    )

    await model.prepare()
    await model.capture(sequenceIndex: 0)
    #expect(model.completedMeasurementCount == 1)

    model.useManualPlacement()

    #expect(model.completedMeasurementCount == 0)
    #expect(model.usesManualPlacement)
    guard case .ready(0) = model.phase else {
      Issue.record("Expected manual placement to restart at the first capture")
      return
    }
  }

  @Test func routeChangeBetweenCapturesIsRejectedImmediately() async throws {
    let analyzer = LowFrequencyAnalyzer()
    let reference = try analyzer.analyze(
      samples: Self.samples(changedState: false),
      sampleRate: Self.sampleRate,
      inputRouteID: "first-mic"
    )
    let captures = [
      Self.capture(changedState: false, routeID: "first-mic", index: 0),
      Self.capture(changedState: true, routeID: "second-mic", index: 1),
    ]
    let model = SourceInvestigationModel(
      referenceAnalysis: reference,
      captureClient: SourceSequenceCaptureStub(captures: captures),
      poseClient: DemoPoseTrackingClient(poses: [SpatialCoordinate(x: 0, y: 0, z: 0)]),
      analyzer: analyzer,
      isDemoMode: true
    )

    await model.prepare()
    await model.capture(sequenceIndex: 0)
    model.stateChangeCompleted(nextSequenceIndex: 1)
    await model.capture(sequenceIndex: 1)

    #expect(model.completedMeasurementCount == 1)
    guard case .invalid(.audioCapture(.routeChanged)) = model.phase else {
      Issue.record("Expected the changed route to stop the sequence immediately")
      return
    }
    model.restart()
    #expect(model.completedMeasurementCount == 0)
    guard case .introduction = model.phase else {
      Issue.record("Expected a full restart after choosing a new route")
      return
    }
  }

  @Test func trackingEpochChangeBetweenCapturesIsRejectedBeforeRecording() async throws {
    let analyzer = LowFrequencyAnalyzer()
    let reference = try analyzer.analyze(
      samples: Self.samples(changedState: false),
      sampleRate: Self.sampleRate,
      inputRouteID: "test-mic"
    )
    let poseClient = MutableEpochPoseStub()
    let model = SourceInvestigationModel(
      referenceAnalysis: reference,
      captureClient: SourceSequenceCaptureStub(captures: [
        Self.capture(changedState: false, routeID: "test-mic", index: 0),
        Self.capture(changedState: true, routeID: "test-mic", index: 1),
      ]),
      poseClient: poseClient,
      analyzer: analyzer,
      isDemoMode: true
    )

    await model.prepare()
    await model.capture(sequenceIndex: 0)
    model.stateChangeCompleted(nextSequenceIndex: 1)
    poseClient.changeEpoch()
    await model.capture(sequenceIndex: 1)

    #expect(model.completedMeasurementCount == 1)
    guard case .invalid(.positionUnavailable) = model.phase else {
      Issue.record("Expected the changed tracking epoch to stop before recording")
      return
    }
  }

  @Test func leavingDuringAnalysisDoesNotAppendAHiddenMeasurement() async throws {
    let analyzer = LowFrequencyAnalyzer()
    let reference = try analyzer.analyze(
      samples: Self.samples(changedState: false),
      sampleRate: Self.sampleRate,
      inputRouteID: "test-mic"
    )
    let model = SourceInvestigationModel(
      referenceAnalysis: reference,
      captureClient: SourceSequenceCaptureStub(captures: [
        Self.capture(changedState: false, routeID: "test-mic", index: 0)
      ]),
      poseClient: DemoPoseTrackingClient(poses: [SpatialCoordinate(x: 0, y: 0, z: 0)]),
      analyzer: analyzer,
      isDemoMode: true
    )

    await model.prepare()
    let captureTask = Task { await model.capture(sequenceIndex: 0) }
    for _ in 0..<100 {
      if case .analyzing = model.phase { break }
      try? await Task.sleep(for: .milliseconds(5))
    }
    guard case .analyzing = model.phase else {
      Issue.record("Expected analysis to be in progress before leaving")
      return
    }

    model.stop()
    await captureTask.value

    #expect(model.completedMeasurementCount == 0)
    guard case .ready(0) = model.phase else {
      Issue.record("Expected cancellation to leave the first step unrecorded")
      return
    }
  }
}

@MainActor
private final class SourceSequenceCaptureStub: AudioCaptureClient {
  private var captures: [CapturedAudio]

  init(captures: [CapturedAudio]) {
    self.captures = captures
  }

  var permission: MicrophonePermission { .granted }

  func requestPermission() async -> MicrophonePermission { .granted }

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio {
    progress(1)
    return captures.removeFirst()
  }

  func cancel() {}
}

@MainActor
private final class MutableEpochPoseStub: PoseTrackingClient {
  private var epoch = UUID()
  private(set) var status: PoseTrackingStatus = .unavailable

  func start() { status = .normal }

  func snapshot() -> TrackedDevicePose? {
    guard status == .normal else { return nil }
    return TrackedDevicePose(
      coordinate: SpatialCoordinate(x: 0, y: 0, z: 0),
      orientation: .identity,
      epoch: epoch
    )
  }

  func completeMeasurement() {}
  func stop() { status = .unavailable }
  func changeEpoch() { epoch = UUID() }
}

extension SourceInvestigationModelTests {
  fileprivate static let sampleRate = 4_000.0

  fileprivate static func samples(changedState: Bool) -> [Float] {
    let sampleCount = Int(sampleRate * 14)
    let variableAmplitude = changedState ? 0.035 : 0.095
    var state: UInt64 = 0xAC0A_571C
    return (0..<sampleCount).map { index in
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let noise = Double(Int64(bitPattern: state)) / Double(Int64.max)
      let time = Double(index) / sampleRate
      return Float(
        0.10 * sin(2 * .pi * 53.17 * time)
          + variableAmplitude * sin(2 * .pi * 216.4 * time)
          + 0.002 * noise
      )
    }
  }

  fileprivate static func capture(
    changedState: Bool,
    routeID: String,
    index: Int
  ) -> CapturedAudio {
    CapturedAudio(
      samples: samples(changedState: changedState),
      sampleRate: sampleRate,
      inputRouteID: routeID,
      inputRouteName: "Test microphone",
      inputChannelCount: 1,
      selectedInputChannelIndex: 0,
      startedAt: Date(timeIntervalSince1970: Double(index))
    )
  }
}
