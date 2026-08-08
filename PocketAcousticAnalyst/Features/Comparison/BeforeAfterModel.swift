import Foundation
import Observation

@MainActor
@Observable
final class BeforeAfterModel {
    enum Stage: Equatable {
        case before
        case after
    }

    enum Phase {
        case introduction
        case preparingPosition
        case readyBefore
        case recording(Stage, Double)
        case analyzing(Stage)
        case makeChange
        case readyAfter
        case result(MeasurementComparison, ComparisonMeasurement, ComparisonMeasurement)
        case invalid(Failure)
    }

    enum Failure: Equatable {
        case microphonePermissionDenied
        case positionUnavailable
        case movedDuringMeasurement
        case audioCapture(AudioCaptureError)
        case lowMeasurementQuality(Set<MeasurementQualityIssue>)
        case targetNotStable
        case targetChanged
        case analysisFailed
    }

    var phase: Phase = .introduction
    private(set) var trackingStatus: PoseTrackingStatus = .unavailable
    private(set) var usesManualPlacement = false
    var manualPlacementConfirmed = false

    @ObservationIgnored private let referenceAnalysis: AcousticAnalysis?
    @ObservationIgnored private let captureClient: any AudioCaptureClient
    @ObservationIgnored private let poseClient: any PoseTrackingClient
    @ObservationIgnored private let analyzer: LowFrequencyAnalyzer
    @ObservationIgnored private let comparator: MeasurementComparator
    @ObservationIgnored private var beforeMeasurement: ComparisonMeasurement?
    @ObservationIgnored private var rejectedStage: Stage = .before
    @ObservationIgnored private var userCancelled = false

    init(
        referenceAnalysis: AcousticAnalysis?,
        captureClient: any AudioCaptureClient,
        poseClient: any PoseTrackingClient,
        analyzer: LowFrequencyAnalyzer,
        comparator: MeasurementComparator = MeasurementComparator()
    ) {
        self.referenceAnalysis = referenceAnalysis
        self.captureClient = captureClient
        self.poseClient = poseClient
        self.analyzer = analyzer
        self.comparator = comparator
    }

    var targetFrequencyHz: Double? {
        beforeMeasurement?.analysis.tone?.frequencyHz ?? referenceAnalysis?.tone?.frequencyHz
    }

    var isActivelyMeasuring: Bool {
        switch phase {
        case .recording, .analyzing: true
        default: false
        }
    }

    func prepare() async {
        if captureClient.permission == .undetermined {
            let permission = await captureClient.requestPermission()
            guard permission == .granted else {
                phase = .invalid(.microphonePermissionDenied)
                return
            }
        } else if captureClient.permission != .granted {
            phase = .invalid(.microphonePermissionDenied)
            return
        }

        usesManualPlacement = false
        poseClient.start()
        phase = .preparingPosition
        for _ in 0 ..< 20 {
            trackingStatus = poseClient.status
            if trackingStatus == .normal {
                phase = .readyBefore
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        trackingStatus = poseClient.status
    }

    func refreshPosition() {
        trackingStatus = poseClient.status
        if trackingStatus == .normal {
            phase = beforeMeasurement == nil ? .readyBefore : .readyAfter
        }
    }

    func useManualPlacement() {
        poseClient.stop()
        usesManualPlacement = true
        manualPlacementConfirmed = false
        phase = beforeMeasurement == nil ? .readyBefore : .readyAfter
    }

    func capture(_ stage: Stage) async {
        rejectedStage = stage
        userCancelled = false
        guard !usesManualPlacement || manualPlacementConfirmed else {
            phase = .invalid(.positionUnavailable)
            return
        }

        let startPose: TrackedDevicePose?
        if usesManualPlacement {
            startPose = nil
        } else {
            trackingStatus = poseClient.status
            guard trackingStatus == .normal, let pose = poseClient.snapshot() else {
                phase = .invalid(.positionUnavailable)
                return
            }
            startPose = pose
        }

        phase = .recording(stage, 0)
        do {
            let captured = try await captureClient.capture(durationSeconds: 20) { [weak self] progress in
                self?.phase = .recording(stage, progress)
            }
            phase = .analyzing(stage)
            let analyzer = analyzer
            let analysis = try await Task.detached(priority: .userInitiated) {
                try analyzer.analyze(
                    samples: captured.samples,
                    sampleRate: captured.sampleRate,
                    inputRouteID: captured.inputRouteID,
                    inputChannelCount: captured.inputChannelCount,
                    selectedInputChannelIndex: captured.selectedInputChannelIndex
                )
            }.value

            guard analysis.quality.isUsable else {
                phase = .invalid(.lowMeasurementQuality(analysis.quality.issues))
                return
            }
            guard let tone = analysis.tone, tone.isStable, tone.confidence != .low else {
                phase = .invalid(.targetNotStable)
                return
            }
            if let targetFrequencyHz {
                let tolerance = max(1, analysis.nominalFrequencyResolutionHz)
                guard abs(tone.frequencyHz - targetFrequencyHz) <= tolerance else {
                    phase = .invalid(.targetChanged)
                    return
                }
            }

            let position: PositionSample?
            if usesManualPlacement {
                position = nil
            } else {
                guard let startPose, let endPose = poseClient.snapshot() else {
                    phase = .invalid(.positionUnavailable)
                    return
                }
                guard startPose.epoch == endPose.epoch,
                      startPose.coordinate.distance(to: endPose.coordinate) <= 0.08,
                      startPose.orientation.angularDistanceDegrees(to: endPose.orientation) <= 12
                else {
                    phase = .invalid(.movedDuringMeasurement)
                    return
                }
                position = PositionSample(
                    coordinate: startPose.coordinate,
                    orientation: startPose.orientation,
                    source: .arkit,
                    trackingEpoch: startPose.epoch,
                    quality: MeasurementQuality(score: 1)
                )
            }

            let measurement = ComparisonMeasurement(
                analysis: analysis,
                position: position,
                positionConfirmedByUser: usesManualPlacement && manualPlacementConfirmed
            )
            poseClient.completeMeasurement()
            manualPlacementConfirmed = false

            if stage == .before {
                beforeMeasurement = measurement
                phase = .makeChange
            } else if let beforeMeasurement {
                let result = comparator.compare(before: beforeMeasurement, after: measurement)
                poseClient.stop()
                phase = .result(result, beforeMeasurement, measurement)
            }
        } catch let error as AudioCaptureError {
            if error == .cancelled, userCancelled {
                phase = stage == .before ? .readyBefore : .readyAfter
            } else {
                phase = .invalid(.audioCapture(error))
            }
        } catch {
            phase = .invalid(.analysisFailed)
        }
    }

    func changeIsReady() {
        manualPlacementConfirmed = false
        phase = .readyAfter
    }

    func retry() {
        phase = rejectedStage == .before ? .readyBefore : .readyAfter
    }

    func cancelMeasurement() {
        userCancelled = true
        captureClient.cancel()
    }

    func stop() {
        if isActivelyMeasuring {
            cancelMeasurement()
        }
        poseClient.stop()
    }
}
