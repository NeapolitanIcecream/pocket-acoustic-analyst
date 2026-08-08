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
    case cancelled
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
