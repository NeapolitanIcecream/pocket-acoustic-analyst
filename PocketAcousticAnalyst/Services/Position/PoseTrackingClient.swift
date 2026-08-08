import Foundation

enum PoseTrackingLimitation: Equatable, Sendable {
  case initializing
  case excessiveMotion
  case insufficientFeatures
  case relocalizing
  case interrupted
  case unknown
}

enum PoseTrackingStatus: Equatable, Sendable {
  case unavailable
  case initializing
  case normal
  case limited(PoseTrackingLimitation)
}

struct TrackedDevicePose: Equatable, Sendable {
  var coordinate: SpatialCoordinate
  var orientation: DeviceOrientation
  var epoch: UUID
}

@MainActor
protocol PoseTrackingClient: AnyObject {
  var status: PoseTrackingStatus { get }

  func start()
  func snapshot() -> TrackedDevicePose?
  func completeMeasurement()
  func stop()
}

@MainActor
final class MeasurementPoseMonitor {
  enum Invalidity: Equatable {
    case trackingUnavailable
    case trackingEpochChanged
    case moved
  }

  private let origin: TrackedDevicePose
  private let maximumDistanceMeters: Double
  private let maximumOrientationDifferenceDegrees: Double
  private(set) var invalidity: Invalidity?

  init(
    origin: TrackedDevicePose,
    maximumDistanceMeters: Double = 0.08,
    maximumOrientationDifferenceDegrees: Double = 12
  ) {
    self.origin = origin
    self.maximumDistanceMeters = maximumDistanceMeters
    self.maximumOrientationDifferenceDegrees = maximumOrientationDifferenceDegrees
  }

  func observe(_ client: any PoseTrackingClient) {
    guard invalidity == nil else { return }
    guard client.status == .normal, let current = client.snapshot() else {
      invalidity = .trackingUnavailable
      return
    }
    guard current.epoch == origin.epoch else {
      invalidity = .trackingEpochChanged
      return
    }
    guard origin.coordinate.distance(to: current.coordinate) <= maximumDistanceMeters,
      origin.orientation.angularDistanceDegrees(to: current.orientation)
        <= maximumOrientationDifferenceDegrees
    else {
      invalidity = .moved
      return
    }
  }
}
