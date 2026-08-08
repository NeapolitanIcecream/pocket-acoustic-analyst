@preconcurrency import AVFoundation
import Foundation
import UIKit

@MainActor
final class AVAudioCaptureClient: AudioCaptureClient {
    private struct ActiveCapture {
        let id: UUID
        let engine: AVAudioEngine
        let accumulator: AudioSampleAccumulator
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
        guard format.sampleRate > 0, format.channelCount > 0, format.commonFormat == .pcmFormatFloat32 else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioCaptureError.unsupportedFormat
        }

        let id = UUID()
        let accumulator = AudioSampleAccumulator(
            expectedSampleCount: Int(ceil(format.sampleRate * durationSeconds))
        )
        inputNode.installTap(onBus: 0, bufferSize: 2_048, format: format) { buffer, _ in
            accumulator.append(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw AudioCaptureError.engineStartFailed(error.localizedDescription)
        }

        activeCapture = ActiveCapture(id: id, engine: engine, accumulator: accumulator)
        let route = currentInputRoute()
        let startedAt = Date.now

        defer {
            stopCapture(id: id)
        }

        let tickSeconds = 0.1
        let tickCount = max(1, Int(ceil(durationSeconds / tickSeconds)))
        for tick in 0 ..< tickCount {
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

        let snapshot = accumulator.snapshot()
        guard !snapshot.unsupportedFormat else {
            throw AudioCaptureError.unsupportedFormat
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

private extension AVAudioCaptureClient {
    func observeInvalidatingEvents() {
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVAudioSession.interruptionNotification, object: session, queue: .main) { [weak self] notification in
                guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                      AVAudioSession.InterruptionType(rawValue: rawType) == .began
                else { return }
                Task { @MainActor [weak self] in self?.invalidateActiveCapture(.interrupted) }
            },
            center.addObserver(forName: AVAudioSession.routeChangeNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidateActiveCapture(.routeChanged) }
            },
            center.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidateActiveCapture(.engineConfigurationChanged) }
            },
            center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidateActiveCapture(.mediaServicesReset) }
            },
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.invalidateActiveCapture(.appBackgrounded) }
            }
        ]
    }

    func invalidateActiveCapture(_ reason: AudioCaptureError) {
        guard activeCapture != nil else { return }
        activeCapture?.invalidation = reason
        activeCapture?.engine.stop()
    }

    func stopCapture(id: UUID) {
        guard let current = activeCapture, current.id == id else { return }
        current.engine.stop()
        current.engine.inputNode.removeTap(onBus: 0)
        activeCapture = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func currentInputRoute() -> (id: String, name: String) {
        let inputs = session.currentRoute.inputs
        let id = inputs
            .map { "\($0.portType.rawValue):\($0.uid)" }
            .sorted()
            .joined(separator: "|")
        let name = inputs.map(\.portName).joined(separator: "、")
        return (id, name)
    }
}

private final class AudioSampleAccumulator: @unchecked Sendable {
    struct Snapshot: Sendable {
        var samples: [Float]
        var unsupportedFormat: Bool
    }

    private let lock = NSLock()
    private var samples: [Float] = []
    private var unsupportedFormat = false

    init(expectedSampleCount: Int) {
        samples.reserveCapacity(max(0, expectedSampleCount))
    }

    func append(_ buffer: AVAudioPCMBuffer) {
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
        lock.withLock {
            for frame in 0 ..< frameCount {
                samples.append(selectedChannel[frame])
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.withLock { Snapshot(samples: samples, unsupportedFormat: unsupportedFormat) }
    }
}
