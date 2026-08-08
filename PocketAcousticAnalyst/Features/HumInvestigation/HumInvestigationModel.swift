import Foundation
import Observation

@MainActor
@Observable
final class HumInvestigationModel {
  enum Phase {
    case introduction
    case requestingPermission
    case permissionDenied
    case ready
    case countdown(Int)
    case recording(Double)
    case analyzing
    case result(Outcome)
  }

  enum Outcome {
    case detected(AcousticAnalysis)
    case notDetected(AcousticAnalysis)
    case invalid(InvestigationFailure)
  }

  enum InvestigationFailure: Equatable {
    case noInput
    case unsupportedInput
    case interrupted
    case routeChanged
    case engineChanged
    case mediaReset
    case appBackgrounded
    case incompleteCapture
    case lowQuality(Set<MeasurementQualityIssue>)
    case setupFailed
    case analysisFailed
  }

  var phase: Phase = .introduction

  @ObservationIgnored private let captureClient: any AudioCaptureClient
  @ObservationIgnored private let analyzer: LowFrequencyAnalyzer
  @ObservationIgnored private let isDemoMode: Bool
  @ObservationIgnored private var userCancelled = false

  init(
    captureClient: any AudioCaptureClient,
    analyzer: LowFrequencyAnalyzer,
    isDemoMode: Bool
  ) {
    self.captureClient = captureClient
    self.analyzer = analyzer
    self.isDemoMode = isDemoMode
  }

  var isActivelyMeasuring: Bool {
    switch phase {
    case .countdown, .recording, .analyzing: true
    default: false
    }
  }

  func explainAndRequestPermission() async {
    phase = .requestingPermission
    let permission: MicrophonePermission
    if captureClient.permission == .undetermined {
      permission = await captureClient.requestPermission()
    } else {
      permission = captureClient.permission
    }
    phase = permission == .granted ? .ready : .permissionDenied
  }

  func startMeasurement() async {
    guard captureClient.permission == .granted else {
      phase = .permissionDenied
      return
    }

    userCancelled = false
    for count in stride(from: 3, through: 1, by: -1) {
      phase = .countdown(count)
      do {
        try await Task.sleep(for: isDemoMode ? .milliseconds(60) : .seconds(1))
      } catch {
        phase = .ready
        return
      }
      if userCancelled {
        phase = .ready
        return
      }
    }

    phase = .recording(0)
    do {
      let capture = try await captureClient.capture(durationSeconds: 20) { [weak self] progress in
        self?.phase = .recording(progress)
      }
      phase = .analyzing

      let analyzer = analyzer
      let analysis = try await Task.detached(priority: .userInitiated) {
        try analyzer.analyze(
          samples: capture.samples,
          sampleRate: capture.sampleRate,
          inputRouteID: capture.inputRouteID,
          inputRouteName: capture.inputRouteName,
          inputChannelCount: capture.inputChannelCount,
          selectedInputChannelIndex: capture.selectedInputChannelIndex,
          measuredAt: capture.startedAt
        )
      }.value

      guard analysis.quality.isUsableForSoundCharacterization else {
        phase = .result(.invalid(.lowQuality(analysis.quality.issues)))
        return
      }
      if analysis.soundPattern == .stableTone,
        let tone = analysis.tone,
        tone.isStable,
        tone.confidence != .low
      {
        phase = .result(.detected(analysis))
      } else {
        phase = .result(.notDetected(analysis))
      }
    } catch let error as AudioCaptureError {
      if error == .cancelled, userCancelled {
        phase = .ready
      } else {
        phase = .result(.invalid(failure(for: error)))
      }
    } catch is AcousticAnalysisError {
      phase = .result(.invalid(.analysisFailed))
    } catch {
      phase = .result(.invalid(.setupFailed))
    }
  }

  func cancelMeasurement() {
    userCancelled = true
    captureClient.cancel()
    if case .countdown = phase {
      phase = .ready
    }
  }

  func retry() {
    phase = captureClient.permission == .granted ? .ready : .permissionDenied
  }
}

extension HumInvestigationModel {
  fileprivate func failure(for error: AudioCaptureError) -> InvestigationFailure {
    switch error {
    case .permissionDenied: .setupFailed
    case .noInput: .noInput
    case .unsupportedFormat: .unsupportedInput
    case .sessionConfigurationFailed, .engineStartFailed: .setupFailed
    case .interrupted: .interrupted
    case .routeChanged: .routeChanged
    case .engineConfigurationChanged: .engineChanged
    case .mediaServicesReset: .mediaReset
    case .appBackgrounded: .appBackgrounded
    case .discontinuousSamples, .insufficientSamples: .incompleteCapture
    case .cancelled: .setupFailed
    }
  }
}
