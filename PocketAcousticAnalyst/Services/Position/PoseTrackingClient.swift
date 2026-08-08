import Foundation

enum PoseTrackingStatus: Equatable, Sendable {
    case unavailable
    case initializing
    case normal
    case limited
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
