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

enum PositionSource: String, Codable, Sendable {
    case arkit
    case guidedManual
}

struct PositionSample: Codable, Equatable, Sendable {
    var coordinate: SpatialCoordinate
    var source: PositionSource
    var quality: MeasurementQuality
}

struct SpatialMeasurement: Codable, Equatable, Sendable, Identifiable {
    var id: UUID
    var label: String
    var position: PositionSample
    var analysis: AcousticAnalysis
    var targetLevelDB: Double

    init(
        id: UUID = UUID(),
        label: String,
        position: PositionSample,
        analysis: AcousticAnalysis,
        targetLevelDB: Double
    ) {
        self.id = id
        self.label = label
        self.position = position
        self.analysis = analysis
        self.targetLevelDB = targetLevelDB
    }
}

struct QuietPointRecommendation: Codable, Equatable, Sendable {
    var currentMeasurementID: UUID
    var recommendedMeasurementID: UUID
    var targetFrequencyHz: Double
    var improvementDB: Double
    var distanceMeters: Double
    var confidence: AnalysisConfidence
}

