import Foundation

enum DemoAudioProfile: Equatable, Sendable {
  case stableTone
  case intermittentTone
  case sourceExperiment
}

@MainActor
final class DemoAudioCaptureClient: AudioCaptureClient {
  private var captureCount = 0
  private var isCancelled = false
  private let stepDelay: Duration
  private let profile: DemoAudioProfile

  init(
    stepDelay: Duration = .milliseconds(35),
    profile: DemoAudioProfile = .stableTone
  ) {
    self.stepDelay = stepDelay
    self.profile = profile
  }

  var permission: MicrophonePermission { .granted }

  func requestPermission() async -> MicrophonePermission { .granted }

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio {
    isCancelled = false
    for step in 1...10 {
      try await Task.sleep(for: stepDelay)
      guard !isCancelled else { throw AudioCaptureError.cancelled }
      progress(Double(step) / 10)
    }

    let sampleRate = 48_000.0
    if profile == .sourceExperiment {
      let samples = sourceExperimentSamples(
        sampleRate: sampleRate,
        durationSeconds: durationSeconds,
        captureIndex: captureCount
      )
      captureCount += 1
      return CapturedAudio(
        samples: samples,
        sampleRate: sampleRate,
        inputRouteID: "demo-built-in-mic",
        inputRouteName: "演示麦克风",
        inputChannelCount: 1,
        selectedInputChannelIndex: 0,
        startedAt: .now
      )
    }

    // First item supports the hum check. Spatial candidates are bracketed by
    // origin checks: origin, candidate, origin, candidate, origin.
    let amplitudeSequence = [0.12, 0.10, 0.055, 0.10, 0.035, 0.10, 0.10, 0.05]
    let amplitude = amplitudeSequence[captureCount % amplitudeSequence.count]
    captureCount += 1
    let sampleCount = Int(sampleRate * durationSeconds)
    let samples = (0..<sampleCount).map { index -> Float in
      let time = Double(index) / sampleRate
      let isActive = profile == .stableTone || time < durationSeconds * 0.6
      guard isActive else { return 0 }
      let fundamental = amplitude * sin(2 * .pi * 53.17 * time)
      let second = amplitude * 0.35 * sin(2 * .pi * 106.34 * time)
      let third = amplitude * 0.16 * sin(2 * .pi * 159.51 * time)
      return Float(fundamental + second + third)
    }

    return CapturedAudio(
      samples: samples,
      sampleRate: sampleRate,
      inputRouteID: "demo-built-in-mic",
      inputRouteName: "演示麦克风",
      inputChannelCount: 1,
      selectedInputChannelIndex: 0,
      startedAt: .now
    )
  }

  func cancel() {
    isCancelled = true
  }

  private func sourceExperimentSamples(
    sampleRate: Double,
    durationSeconds: Double,
    captureIndex: Int
  ) -> [Float] {
    let sampleCount = Int(sampleRate * durationSeconds)
    let changedState = captureIndex > 0 && captureIndex.isMultiple(of: 2)
    let variableAmplitude = changedState ? 0.034 : 0.095
    var noiseState: UInt64 = 0xAC0A_571C
    var samples = [Float]()
    samples.reserveCapacity(sampleCount)
    for index in 0..<sampleCount {
      noiseState = noiseState &* 6_364_136_223_846_793_005 &+ 1
      let noiseUnit = Double(Int64(bitPattern: noiseState)) / Double(Int64.max)
      let time = Double(index) / sampleRate
      let stableTone = 0.10 * sin(2 * .pi * 53.17 * time)
      let changedTone = variableAmplitude * sin(2 * .pi * 216.4 * time)
      let relatedTone = variableAmplitude * 0.35 * sin(2 * .pi * 432.8 * time)
      samples.append(Float(stableTone + changedTone + relatedTone + 0.002 * noiseUnit))
    }
    return samples
  }
}
