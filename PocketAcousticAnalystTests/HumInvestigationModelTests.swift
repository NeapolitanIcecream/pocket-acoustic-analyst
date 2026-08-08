import Foundation
import Testing

@testable import PocketAcousticAnalyst

@MainActor
struct HumInvestigationModelTests {
  @Test func permissionDenialStopsBeforeMeasurement() async {
    let capture = StubAudioCaptureClient(permission: .undetermined, requestedPermission: .denied)
    let model = HumInvestigationModel(
      captureClient: capture,
      analyzer: LowFrequencyAnalyzer(),
      isDemoMode: true
    )

    await model.explainAndRequestPermission()

    guard case .permissionDenied = model.phase else {
      Issue.record("Expected permissionDenied, got \(String(describing: model.phase))")
      return
    }
    #expect(capture.captureCallCount == 0)
  }

  @Test func stableToneProducesDetectedOutcome() async {
    let capture = StubAudioCaptureClient(result: .success(Self.toneCapture()))
    let model = HumInvestigationModel(
      captureClient: capture,
      analyzer: LowFrequencyAnalyzer(),
      isDemoMode: true
    )

    await model.startMeasurement()

    guard case .result(.detected(let analysis)) = model.phase else {
      Issue.record("Expected a detected result, got \(String(describing: model.phase))")
      return
    }
    #expect(abs((analysis.tone?.frequencyHz ?? 0) - 53.17) < 0.2)
    #expect(analysis.inputRouteID == "test-built-in-mic")
  }

  @Test func broadbandNoiseProducesNotDetectedOutcome() async {
    let capture = StubAudioCaptureClient(result: .success(Self.noiseCapture()))
    let model = HumInvestigationModel(
      captureClient: capture,
      analyzer: LowFrequencyAnalyzer(),
      isDemoMode: true
    )

    await model.startMeasurement()

    guard case .result(.notDetected(let analysis)) = model.phase else {
      Issue.record("Expected a notDetected result, got \(String(describing: model.phase))")
      return
    }
    #expect(analysis.tone == nil)
    #expect(analysis.quality.isUsable)
    #expect(analysis.soundPattern == .distributedEnergy)
  }

  @Test func changingSoundReturnsAnExplanationInsteadOfAnInvalidMeasurement() async {
    let capture = StubAudioCaptureClient(result: .success(Self.changingLevelCapture()))
    let model = HumInvestigationModel(
      captureClient: capture,
      analyzer: LowFrequencyAnalyzer(),
      isDemoMode: true
    )

    await model.startMeasurement()

    guard case .result(.notDetected(let analysis)) = model.phase else {
      Issue.record(
        "Expected an explained notDetected result, got \(String(describing: model.phase))")
      return
    }
    #expect(analysis.soundPattern == .varyingLevelTone)
    #expect(analysis.quality.issues.contains(.unstableEnvironment))
    #expect(analysis.quality.isUsableForSoundCharacterization)
  }

  @Test func routeChangeProducesInvalidOutcomeInsteadOfAcousticResult() async {
    let capture = StubAudioCaptureClient(result: .failure(.routeChanged))
    let model = HumInvestigationModel(
      captureClient: capture,
      analyzer: LowFrequencyAnalyzer(),
      isDemoMode: true
    )

    await model.startMeasurement()

    guard case .result(.invalid(let failure)) = model.phase else {
      Issue.record("Expected an invalid result, got \(String(describing: model.phase))")
      return
    }
    #expect(failure == .routeChanged)
  }
}

@MainActor
private final class StubAudioCaptureClient: AudioCaptureClient {
  var permission: MicrophonePermission
  private let requestedPermission: MicrophonePermission
  private let result: Result<CapturedAudio, AudioCaptureError>
  private(set) var captureCallCount = 0

  init(
    permission: MicrophonePermission = .granted,
    requestedPermission: MicrophonePermission = .granted,
    result: Result<CapturedAudio, AudioCaptureError> = .failure(.noInput)
  ) {
    self.permission = permission
    self.requestedPermission = requestedPermission
    self.result = result
  }

  func requestPermission() async -> MicrophonePermission {
    permission = requestedPermission
    return requestedPermission
  }

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio {
    captureCallCount += 1
    progress(0.5)
    progress(1)
    return try result.get()
  }

  func cancel() {}
}

extension HumInvestigationModelTests {
  fileprivate static func toneCapture() -> CapturedAudio {
    let sampleRate = 48_000.0
    let samples = (0..<Int(sampleRate * 9)).map { index -> Float in
      let time = Double(index) / sampleRate
      return Float(0.12 * sin(2 * .pi * 53.17 * time))
    }
    return capturedAudio(samples: samples, sampleRate: sampleRate)
  }

  fileprivate static func noiseCapture() -> CapturedAudio {
    let sampleRate = 48_000.0
    var state: UInt64 = 0xA11CE
    let samples = (0..<Int(sampleRate * 9)).map { _ -> Float in
      state = state &* 6_364_136_223_846_793_005 &+ 1
      let normalized = Double(state >> 11) / Double(1 << 53)
      return Float((normalized * 2 - 1) * 0.06)
    }
    return capturedAudio(samples: samples, sampleRate: sampleRate)
  }

  fileprivate static func changingLevelCapture() -> CapturedAudio {
    let sampleRate = 48_000.0
    let samples = (0..<Int(sampleRate * 9)).map { index -> Float in
      let time = Double(index) / sampleRate
      let amplitude = time < 4.5 ? 0.12 : 0.03
      return Float(amplitude * sin(2 * .pi * 53.17 * time))
    }
    return capturedAudio(samples: samples, sampleRate: sampleRate)
  }

  fileprivate static func capturedAudio(samples: [Float], sampleRate: Double) -> CapturedAudio {
    CapturedAudio(
      samples: samples,
      sampleRate: sampleRate,
      inputRouteID: "test-built-in-mic",
      inputRouteName: "Test microphone",
      inputChannelCount: 1,
      selectedInputChannelIndex: 0,
      startedAt: .now
    )
  }
}
