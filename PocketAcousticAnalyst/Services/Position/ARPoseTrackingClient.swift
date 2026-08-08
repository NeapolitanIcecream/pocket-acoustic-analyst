@preconcurrency import ARKit
import Foundation
import simd

@MainActor
final class ARPoseTrackingClient: NSObject, PoseTrackingClient {
  private let session = ARSession()
  private var originTransform: simd_float4x4?
  private var epoch = UUID()

  private(set) var status: PoseTrackingStatus = .unavailable

  override init() {
    super.init()
    session.delegate = self
    session.delegateQueue = .main
  }

  func start() {
    guard ARPositionalTrackingConfiguration.isSupported else {
      status = .unavailable
      return
    }
    epoch = UUID()
    originTransform = nil
    status = .initializing
    let configuration = ARPositionalTrackingConfiguration()
    configuration.worldAlignment = .gravity
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
  }

  func snapshot() -> TrackedDevicePose? {
    guard status == .normal, let transform = session.currentFrame?.camera.transform else {
      return nil
    }
    if originTransform == nil {
      originTransform = transform
    }
    guard let originTransform else { return nil }
    let relativeTransform = simd_mul(simd_inverse(originTransform), transform)
    let rotation = simd_quatf(relativeTransform)
    let worldTranslation = transform.columns.3 - originTransform.columns.3
    return TrackedDevicePose(
      coordinate: SpatialCoordinate(
        x: Double(worldTranslation.x),
        y: Double(worldTranslation.y),
        z: Double(worldTranslation.z)
      ),
      orientation: DeviceOrientation(
        x: Double(rotation.imag.x),
        y: Double(rotation.imag.y),
        z: Double(rotation.imag.z),
        w: Double(rotation.real)
      ),
      epoch: epoch
    )
  }

  func completeMeasurement() {}

  func stop() {
    session.pause()
    originTransform = nil
    status = .unavailable
  }

  private func restartAfterInterruption() {
    epoch = UUID()
    originTransform = nil
    status = .initializing
    let configuration = ARPositionalTrackingConfiguration()
    configuration.worldAlignment = .gravity
    session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
  }
}

extension ARPoseTrackingClient: @preconcurrency ARSessionDelegate {
  func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
    switch camera.trackingState {
    case .normal:
      status = .normal
    case .notAvailable:
      status = .unavailable
    case .limited(let reason):
      switch reason {
      case .initializing:
        status = .limited(.initializing)
      case .excessiveMotion:
        status = .limited(.excessiveMotion)
      case .insufficientFeatures:
        status = .limited(.insufficientFeatures)
      case .relocalizing:
        status = .limited(.relocalizing)
      @unknown default:
        status = .limited(.unknown)
      }
    }
  }

  func sessionWasInterrupted(_ session: ARSession) {
    status = .limited(.interrupted)
    originTransform = nil
    epoch = UUID()
  }

  func sessionInterruptionEnded(_ session: ARSession) {
    restartAfterInterruption()
  }

  func session(_ session: ARSession, didFailWithError error: Error) {
    status = .unavailable
    originTransform = nil
  }
}
