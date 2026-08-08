@preconcurrency import AVFoundation
import Foundation
import UIKit

@MainActor
final class AVAudioCaptureClient: AudioCaptureClient {
  private struct ActiveCapture {
    let id: UUID
    let engine: AVAudioEngine
    let accumulator: AudioSampleAccumulator
    let inputRouteID: String
    var invalidation: AudioCaptureError?
  }

  private let session: AVAudioSession
  private var activeCapture: ActiveCapture?
  private var notificationTokens: [NSObjectProtocol] = []

  init(session: AVAudioSession = .sharedInstance()) {
    self.session = session
    observeInvalidatingEvents()
  }

  var permission: MicrophonePermission {
    switch AVAudioApplication.shared.recordPermission {
    case .undetermined: .undetermined
    case .denied: .denied
    case .granted: .granted
    @unknown default: .denied
    }
  }

  func requestPermission() async -> MicrophonePermission {
    guard permission == .undetermined else { return permission }
    let granted = await withCheckedContinuation { continuation in
      AVAudioApplication.requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
    return granted ? .granted : .denied
  }

  func capture(
    durationSeconds: Double,
    progress: @escaping @MainActor (Double) -> Void
  ) async throws -> CapturedAudio {
    guard permission == .granted else {
      throw AudioCaptureError.permissionDenied
    }
    guard activeCapture == nil else {
      throw AudioCaptureError.engineStartFailed("已有测量正在进行")
    }

    do {
      try session.setCategory(.record, mode: .measurement, options: [])
      try session.setPreferredSampleRate(48_000)
      try session.setPreferredIOBufferDuration(0.02)
      try session.setActive(true)
    } catch {
      throw AudioCaptureError.sessionConfigurationFailed(error.localizedDescription)
    }

    guard session.isInputAvailable, !session.currentRoute.inputs.isEmpty else {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw AudioCaptureError.noInput
    }

    let engine = AVAudioEngine()
    let inputNode = engine.inputNode
    let format = inputNode.outputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32
    else {
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw AudioCaptureError.unsupportedFormat
    }

    let id = UUID()
    let accumulator = AudioSampleAccumulator(
      expectedSampleCount: Int(ceil(format.sampleRate * durationSeconds))
    )
    let tapHandler: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = { buffer, time in
      accumulator.append(buffer, at: time)
    }
    inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format, block: tapHandler)

    do {
      engine.prepare()
      try engine.start()
    } catch {
      inputNode.removeTap(onBus: 0)
      try? session.setActive(false, options: .notifyOthersOnDeactivation)
      throw AudioCaptureError.engineStartFailed(error.localizedDescription)
    }

    let route = currentInputRoute()
    activeCapture = ActiveCapture(
      id: id,
      engine: engine,
      accumulator: accumulator,
      inputRouteID: route.id
    )
    let startedAt = Date.now

    defer {
      stopCapture(id: id)
    }

    let tickSeconds = 0.1
    let tickCount = max(1, Int(ceil(durationSeconds / tickSeconds)))
    for tick in 0..<tickCount {
      do {
        try await Task.sleep(for: .seconds(tickSeconds))
      } catch {
        invalidateActiveCapture(.cancelled)
      }

      guard let current = activeCapture, current.id == id else {
        throw AudioCaptureError.cancelled
      }
      if let invalidation = current.invalidation {
        throw invalidation
      }
      progress(min(Double(tick + 1) * tickSeconds / durationSeconds, 1))
    }

    guard let current = activeCapture, current.id == id else {
      throw AudioCaptureError.cancelled
    }
    if let invalidation = current.invalidation {
      throw invalidation
    }
    current.engine.stop()

    let endingRoute = currentInputRoute()
    guard endingRoute.id == route.id else {
      throw AudioCaptureError.routeChanged
    }
    let endingFormat = inputNode.outputFormat(forBus: 0)
    guard abs(endingFormat.sampleRate - format.sampleRate) < 0.5,
      endingFormat.channelCount == format.channelCount,
      endingFormat.commonFormat == format.commonFormat,
      endingFormat.isInterleaved == format.isInterleaved
    else {
      throw AudioCaptureError.engineConfigurationChanged
    }

    let snapshot = accumulator.snapshot()
    guard !snapshot.unsupportedFormat else {
      throw AudioCaptureError.unsupportedFormat
    }
    guard !snapshot.hasDiscontinuity else {
      throw AudioCaptureError.discontinuousSamples
    }
    let minimumSampleCount = AudioCaptureCompleteness.minimumSampleCount(
      sampleRate: format.sampleRate,
      requestedDurationSeconds: durationSeconds
    )
    guard snapshot.samples.count >= minimumSampleCount else {
      throw AudioCaptureError.insufficientSamples(
        requiredMinimum: minimumSampleCount,
        actual: snapshot.samples.count
      )
    }

    return CapturedAudio(
      samples: snapshot.samples,
      sampleRate: format.sampleRate,
      inputRouteID: route.id,
      inputRouteName: route.name,
      inputChannelCount: Int(format.channelCount),
      selectedInputChannelIndex: 0,
      startedAt: startedAt
    )
  }

  func cancel() {
    invalidateActiveCapture(.cancelled)
  }
}

extension AVAudioCaptureClient {
  fileprivate func observeInvalidatingEvents() {
    let center = NotificationCenter.default
    notificationTokens = [
      center.addObserver(
        forName: AVAudioSession.interruptionNotification, object: session, queue: .main
      ) { [weak self] notification in
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          AVAudioSession.InterruptionType(rawValue: rawType) == .began
        else { return }
        Task { @MainActor [weak self] in self?.invalidateActiveCapture(.interrupted) }
      },
      center.addObserver(
        forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.handleRouteChange() }
      },
      center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor [weak self] in self?.invalidateActiveCapture(.engineConfigurationChanged)
        }
      },
      center.addObserver(
        forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.invalidateActiveCapture(.mediaServicesReset) }
      },
      center.addObserver(
        forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor [weak self] in self?.invalidateActiveCapture(.appBackgrounded) }
      },
    ]
  }

  fileprivate func invalidateActiveCapture(_ reason: AudioCaptureError) {
    guard activeCapture != nil else { return }
    activeCapture?.invalidation = reason
    activeCapture?.engine.stop()
  }

  fileprivate func handleRouteChange() {
    guard let activeCapture,
      AudioRouteContinuity.hasChanged(
        from: activeCapture.inputRouteID,
        to: currentInputRoute().id
      )
    else { return }
    invalidateActiveCapture(.routeChanged)
  }

  fileprivate func stopCapture(id: UUID) {
    guard let current = activeCapture, current.id == id else { return }
    current.engine.stop()
    current.engine.inputNode.removeTap(onBus: 0)
    activeCapture = nil
    try? session.setActive(false, options: .notifyOthersOnDeactivation)
  }

  fileprivate func currentInputRoute() -> (id: String, name: String) {
    let inputs = session.currentRoute.inputs
    let id =
      inputs
      .map { input in
        let dataSource = input.selectedDataSource
        let dataSourceID = dataSource.map { "\($0.dataSourceID):\($0.dataSourceName)" } ?? "default"
        return "\(input.portType.rawValue):\(input.uid):\(dataSourceID)"
      }
      .sorted()
      .joined(separator: "|")
    let name = inputs.map { input in
      input.selectedDataSource.map { "\(input.portName) / \($0.dataSourceName)" } ?? input.portName
    }.joined(separator: "、")
    return (id, name)
  }
}

private final class AudioSampleAccumulator: @unchecked Sendable {
  struct Snapshot: Sendable {
    var samples: [Float]
    var unsupportedFormat: Bool
    var hasDiscontinuity: Bool
  }

  private let lock = NSLock()
  private var samples: [Float] = []
  private var unsupportedFormat = false
  private var continuity = AudioSampleContinuityTracker()

  init(expectedSampleCount: Int) {
    samples.reserveCapacity(max(0, expectedSampleCount))
  }

  func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
    guard let channels = buffer.floatChannelData else {
      lock.withLock { unsupportedFormat = true }
      return
    }
    let frameCount = Int(buffer.frameLength)
    guard frameCount > 0, buffer.format.channelCount > 0 else { return }

    // Measurement mode chooses the built-in primary microphone. For external
    // multichannel routes, P0 uses channel 0 and records that policy instead
    // of waveform averaging, which can cancel phase-opposed low frequencies.
    let selectedChannel = channels[0]
    let stride = Int(buffer.stride)
    lock.withLock {
      continuity.observe(
        sampleTime: time.isSampleTimeValid ? time.sampleTime : nil,
        frameCount: frameCount
      )
      for frame in 0..<frameCount {
        samples.append(selectedChannel[frame * stride])
      }
    }
  }

  func snapshot() -> Snapshot {
    lock.withLock {
      Snapshot(
        samples: samples,
        unsupportedFormat: unsupportedFormat,
        hasDiscontinuity: !continuity.isContinuous
      )
    }
  }
}
