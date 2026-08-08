import Testing
@testable import PocketAcousticAnalyst

struct ScaffoldTests {
    @Test func qualityRejectsInterruptedMeasurement() {
        let quality = MeasurementQuality(score: 0.95, issues: [.externalInterruption])
        #expect(!quality.isUsable)
    }

    @Test func spatialDistanceUsesThreeDimensions() {
        let start = SpatialCoordinate(x: 0, y: 0, z: 0)
        let end = SpatialCoordinate(x: 0.3, y: 0.4, z: 0)
        #expect(abs(start.distance(to: end) - 0.5) < 0.000_001)
    }
}

