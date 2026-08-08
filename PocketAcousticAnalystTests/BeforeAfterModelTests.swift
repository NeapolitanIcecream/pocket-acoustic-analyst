import Foundation
import Testing

@testable import PocketAcousticAnalyst

@MainActor
struct BeforeAfterModelTests {
  @Test func directComparisonRequiresAUniqueStableTarget() async {
    let capture = ComparisonAudioCaptureStub(audio: Self.multipleToneCapture())
    let model = BeforeAfterModel(
      referenceAnalysis: nil,
      captureClient: capture,
      poseClient: DemoPoseTrackingClient(),
      analyzer: LowFrequencyAnalyzer()
    )
    await model.prepare()
    model.useManualPlacement()
    model.manualPlacementConfirmed = true

    await model.capture(.before)

    guard case .invalid(let failure) = model.phase else {
      Issue.record("Expected the multiple-tone scene to be rejected as a comparison target")
      return
    }
    #expect(failure == .targetNotStable)
  }
}

@MainActor
private final class ComparisonAudioCaptureStub: AudioCaptureClient {
  let audio: CapturedAudio

  init(audio: CapturedAudio) {
    self.audio = audio
  }

  var permission: MicrophonePermission { .granted }

  func requestPermission() async -> MicrophonePermission { .granted }

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio {
    progress(1)
    return audio
  }

  func cancel() {}
}

extension BeforeAfterModelTests {
  fileprivate static func multipleToneCapture() -> CapturedAudio {
    let sampleRate = 48_000.0
    let samples = (0..<Int(sampleRate * 9)).map { index -> Float in
      let time = Double(index) / sampleRate
      return Float(
        0.1 * sin(2 * .pi * 53.17 * time)
          + 0.095 * sin(2 * .pi * 83.4 * time)
      )
    }
    return CapturedAudio(
      samples: samples,
      sampleRate: sampleRate,
      inputRouteID: "test",
      inputRouteName: "Test microphone",
      inputChannelCount: 1,
      selectedInputChannelIndex: 0,
      startedAt: .now
    )
  }
}
