import Foundation

struct InvestigationArchive: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 2

  var schemaVersion: Int
  var analyses: [AcousticAnalysis] = []
  var spatialScans: [SpatialScanEvaluation] = []
  var comparisons: [MeasurementComparison] = []
  var sourceInvestigations: [SourceInvestigationEvaluation] = []

  init(
    schemaVersion: Int = Self.currentSchemaVersion,
    analyses: [AcousticAnalysis] = [],
    spatialScans: [SpatialScanEvaluation] = [],
    comparisons: [MeasurementComparison] = [],
    sourceInvestigations: [SourceInvestigationEvaluation] = []
  ) {
    self.schemaVersion = schemaVersion
    self.analyses = analyses
    self.spatialScans = spatialScans
    self.comparisons = comparisons
    self.sourceInvestigations = sourceInvestigations
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedSchemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    guard decodedSchemaVersion <= Self.currentSchemaVersion else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported investigation archive schema version \(decodedSchemaVersion)"
      )
    }

    schemaVersion = Self.currentSchemaVersion
    analyses = try container.decodeIfPresent([AcousticAnalysis].self, forKey: .analyses) ?? []
    spatialScans =
      try container.decodeIfPresent([SpatialScanEvaluation].self, forKey: .spatialScans) ?? []
    comparisons =
      try container.decodeIfPresent([MeasurementComparison].self, forKey: .comparisons) ?? []
    sourceInvestigations =
      try container.decodeIfPresent(
        [SourceInvestigationEvaluation].self,
        forKey: .sourceInvestigations
      ) ?? []
  }
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
      let applicationSupport =
        FileManager.default.urls(
          for: .applicationSupportDirectory,
          in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
      self.fileURL =
        applicationSupport
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

extension JSONEncoder {
  fileprivate static var archiveEncoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return encoder
  }
}

extension JSONDecoder {
  fileprivate static var archiveDecoder: JSONDecoder {
    JSONDecoder()
  }
}
