import Foundation

enum MicrophonePermission: Equatable, Sendable {
  case undetermined
  case denied
  case granted
}

struct CapturedAudio: Sendable {
  var samples: [Float]
  var sampleRate: Double
  var inputRouteID: String
  var inputRouteName: String
  var inputChannelCount: Int
  var selectedInputChannelIndex: Int
  var startedAt: Date
}

enum AudioCaptureError: Error, Equatable, Sendable {
  case permissionDenied
  case noInput
  case unsupportedFormat
  case sessionConfigurationFailed(String)
  case engineStartFailed(String)
  case interrupted
  case routeChanged
  case engineConfigurationChanged
  case mediaServicesReset
  case appBackgrounded
  case discontinuousSamples
  case insufficientSamples(requiredMinimum: Int, actual: Int)
  case cancelled
}

struct AudioSampleContinuityTracker: Sendable {
  private(set) var expectedNextSampleTime: Int64?
  private(set) var isContinuous = true

  mutating func observe(sampleTime: Int64?, frameCount: Int) {
    guard isContinuous, frameCount > 0, let sampleTime else {
      if frameCount > 0 { isContinuous = false }
      return
    }
    if let expectedNextSampleTime, sampleTime != expectedNextSampleTime {
      isContinuous = false
      return
    }
    expectedNextSampleTime = sampleTime + Int64(frameCount)
  }
}

struct AudioCaptureCompleteness: Sendable {
  static let minimumCapturedFraction = 0.9

  static func minimumSampleCount(
    sampleRate: Double,
    requestedDurationSeconds: Double
  ) -> Int {
    Int((sampleRate * requestedDurationSeconds * minimumCapturedFraction).rounded(.down))
  }

  static func isSufficient(
    sampleCount: Int,
    sampleRate: Double,
    requestedDurationSeconds: Double
  ) -> Bool {
    guard sampleCount >= 0, sampleRate > 0, requestedDurationSeconds > 0 else { return false }
    return sampleCount
      >= minimumSampleCount(
        sampleRate: sampleRate,
        requestedDurationSeconds: requestedDurationSeconds
      )
  }
}

@MainActor
protocol AudioCaptureClient: AnyObject {
  var permission: MicrophonePermission { get }

  func requestPermission() async -> MicrophonePermission

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio

  func cancel()
}
