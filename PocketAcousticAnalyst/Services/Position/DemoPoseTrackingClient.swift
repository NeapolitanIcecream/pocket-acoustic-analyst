import Foundation

@MainActor
final class DemoPoseTrackingClient: PoseTrackingClient {
  private let poses: [SpatialCoordinate]
  private var index = 0
  private var epoch = UUID()

  private(set) var status: PoseTrackingStatus = .unavailable

  init(poses: [SpatialCoordinate]? = nil) {
    self.poses =
      poses ?? [
        SpatialCoordinate(x: 0, y: 0, z: 0),
        SpatialCoordinate(x: -0.4, y: 0, z: 0),
        SpatialCoordinate(x: 0.015, y: 0, z: 0),
        SpatialCoordinate(x: -0.8, y: 0, z: 0),
        SpatialCoordinate(x: 0.018, y: 0.005, z: 0),
      ]
  }

  func start() {
    index = 0
    epoch = UUID()
    status = .normal
  }

  func snapshot() -> TrackedDevicePose? {
    guard status == .normal, !poses.isEmpty else { return nil }
    return TrackedDevicePose(
      coordinate: poses[min(index, poses.count - 1)],
      orientation: .identity,
      epoch: epoch
    )
  }

  func completeMeasurement() {
    index = min(index + 1, poses.count - 1)
  }

  func stop() {
    status = .unavailable
  }
}
