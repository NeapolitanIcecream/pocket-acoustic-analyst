import Foundation

struct InvestigationArchive: Codable, Equatable, Sendable {
    var schemaVersion: Int = 1
    var analyses: [AcousticAnalysis] = []
    var spatialScans: [SpatialScanEvaluation] = []
    var comparisons: [MeasurementComparison] = []
}

protocol InvestigationRepository: Sendable {
    func load() async throws -> InvestigationArchive
    func save(_ archive: InvestigationArchive) async throws
}

actor LocalInvestigationRepository: InvestigationRepository {
    private let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let applicationSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default.temporaryDirectory
            self.fileURL = applicationSupport
                .appendingPathComponent("PocketAcousticAnalyst", isDirectory: true)
                .appendingPathComponent("investigations-v1.json", isDirectory: false)
        }
    }

    func load() async throws -> InvestigationArchive {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return InvestigationArchive()
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder.archiveDecoder.decode(InvestigationArchive.self, from: data)
    }

    func save(_ archive: InvestigationArchive) async throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder.archiveEncoder.encode(archive)
        try data.write(to: fileURL, options: .atomic)
    }
}

actor InMemoryInvestigationRepository: InvestigationRepository {
    private var archive = InvestigationArchive()

    func load() async throws -> InvestigationArchive { archive }

    func save(_ archive: InvestigationArchive) async throws {
        self.archive = archive
    }
}

private extension JSONEncoder {
    static var archiveEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var archiveDecoder: JSONDecoder {
        JSONDecoder()
    }
}
