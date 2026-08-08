import Foundation
import Testing

@testable import PocketAcousticAnalyst

struct ScaffoldTests {
  @Test func qualityRejectsInterruptedMeasurement() {
    let quality = MeasurementQuality(score: 0.95, issues: [.externalInterruption])
    #expect(!quality.isUsable)
  }

  @Test func qualityRejectsEnvironmentThatChangesDuringMeasurement() {
    let quality = MeasurementQuality(score: 0.7, issues: [.unstableEnvironment])
    #expect(!quality.isUsable)
  }

  @Test func spatialDistanceUsesThreeDimensions() {
    let start = SpatialCoordinate(x: 0, y: 0, z: 0)
    let end = SpatialCoordinate(x: 0.3, y: 0.4, z: 0)
    #expect(abs(start.distance(to: end) - 0.5) < 0.000_001)
  }

  @Test func captureCompletenessRejectsWallClockCompletionWithTooFewSamples() {
    #expect(
      !AudioCaptureCompleteness.isSufficient(
        sampleCount: 3 * 48_000,
        sampleRate: 48_000,
        requestedDurationSeconds: 20
      )
    )
    #expect(
      AudioCaptureCompleteness.isSufficient(
        sampleCount: 18 * 48_000,
        sampleRate: 48_000,
        requestedDurationSeconds: 20
      )
    )
  }

  @Test func audioSampleContinuityDetectsAnInteriorBufferGap() {
    var tracker = AudioSampleContinuityTracker()
    tracker.observe(sampleTime: 10_000, frameCount: 2_048)
    tracker.observe(sampleTime: 12_048, frameCount: 2_048)
    tracker.observe(sampleTime: 16_144, frameCount: 2_048)

    #expect(!tracker.isContinuous)
  }

  @MainActor
  @Test func poseMonitorRemainsInvalidAfterPhoneMovesAwayAndReturns() {
    let epoch = UUID()
    let origin = TrackedDevicePose(
      coordinate: SpatialCoordinate(x: 0, y: 0, z: 0),
      orientation: .identity,
      epoch: epoch
    )
    let client = SequencePoseTrackingClient(poses: [
      TrackedDevicePose(
        coordinate: SpatialCoordinate(x: 0.4, y: 0, z: 0),
        orientation: .identity,
        epoch: epoch
      ),
      origin,
    ])
    let monitor = MeasurementPoseMonitor(origin: origin)

    monitor.observe(client)
    monitor.observe(client)

    #expect(monitor.invalidity == .moved)
  }
}

@MainActor
private final class SequencePoseTrackingClient: PoseTrackingClient {
  private var poses: [TrackedDevicePose]
  private var index = 0
  var status: PoseTrackingStatus = .normal

  init(poses: [TrackedDevicePose]) {
    self.poses = poses
  }

  func start() {}

  func snapshot() -> TrackedDevicePose? {
    guard !poses.isEmpty else { return nil }
    defer { index = min(index + 1, poses.count - 1) }
    return poses[index]
  }

  func completeMeasurement() {}
  func stop() {}
}
