import Foundation

struct SpatialCoordinate: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double

    func distance(to other: SpatialCoordinate) -> Double {
        let dx = x - other.x
        let dy = y - other.y
        let dz = z - other.z
        return (dx * dx + dy * dy + dz * dz).squareRoot()
    }
}

struct DeviceOrientation: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var z: Double
    var w: Double

    static let identity = DeviceOrientation(x: 0, y: 0, z: 0, w: 1)

    func angularDistanceDegrees(to other: DeviceOrientation) -> Double {
        let lhsLength = (x * x + y * y + z * z + w * w).squareRoot()
        let rhsLength = (other.x * other.x + other.y * other.y + other.z * other.z + other.w * other.w).squareRoot()
        guard lhsLength > 0, rhsLength > 0 else { return 180 }
        let normalizedDot = abs(
            (x * other.x + y * other.y + z * other.z + w * other.w) / (lhsLength * rhsLength)
        )
        return 2 * acos(min(1, normalizedDot)) * 180 / .pi
    }
}

enum PositionSource: String, Codable, Sendable {
    case arkit
    case guidedManual
}

struct PositionSample: Codable, Equatable, Sendable {
    var coordinate: SpatialCoordinate
    var orientation: DeviceOrientation
    var source: PositionSource
    var trackingEpoch: UUID?
    var quality: MeasurementQuality
}

struct SpatialMeasurement: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var label: String
    var position: PositionSample
    var analysis: AcousticAnalysis
    var targetFrequencyHz: Double
    var targetBandHalfWidthHz: Double
    var targetLevelDB: Double

    init(
        id: UUID = UUID(),
        label: String,
        position: PositionSample,
        analysis: AcousticAnalysis,
        targetFrequencyHz: Double,
        targetBandHalfWidthHz: Double,
        targetLevelDB: Double
    ) {
        self.id = id
        self.label = label
        self.position = position
        self.analysis = analysis
        self.targetFrequencyHz = targetFrequencyHz
        self.targetBandHalfWidthHz = targetBandHalfWidthHz
        self.targetLevelDB = targetLevelDB
    }
}

struct QuietPointRecommendation: Codable, Equatable, Sendable {
    var currentMeasurementID: UUID
    var recommendedMeasurementID: UUID
    var targetFrequencyHz: Double
    var improvementDB: Double
    var distanceMeters: Double?
    var confidence: AnalysisConfidence
}

enum SpatialScanIssue: String, Codable, Hashable, Sendable {
    case insufficientMeasuredPoints
    case lowMeasurementQuality
    case targetFrequencyChanged
    case routeOrConfigurationChanged
    case trackingEpochChanged
    case originPositionDidNotClose
    case originSoundDidNotClose
    case improvementTooSmall
}

struct SpatialScanEvaluation: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var measuredAt: Date
    var targetFrequencyHz: Double
    var measurements: [SpatialMeasurement]
    var closureMeasurement: SpatialMeasurement
    var recommendation: QuietPointRecommendation?
    var issues: Set<SpatialScanIssue>

    init(
        id: UUID = UUID(),
        measuredAt: Date = .now,
        targetFrequencyHz: Double,
        measurements: [SpatialMeasurement],
        closureMeasurement: SpatialMeasurement,
        recommendation: QuietPointRecommendation?,
        issues: Set<SpatialScanIssue>
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.targetFrequencyHz = targetFrequencyHz
        self.measurements = measurements
        self.closureMeasurement = closureMeasurement
        self.recommendation = recommendation
        self.issues = issues
    }

    var canRankMeasuredPoints: Bool {
        issues.isDisjoint(with: [
            .insufficientMeasuredPoints,
            .lowMeasurementQuality,
            .targetFrequencyChanged,
            .routeOrConfigurationChanged,
            .trackingEpochChanged,
            .originPositionDidNotClose,
            .originSoundDidNotClose,
        ])
    }
}
