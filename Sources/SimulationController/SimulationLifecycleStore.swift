import Foundation
import LocationDomain

public enum SimulationLifecyclePhase: String, Codable, Equatable, Sendable {
  case applyUncertain
  case applied
  case cleanupPending
}

public struct SimulationLifecycleRecord: Codable, Equatable, Sendable {
  public var activeDeviceIdentifier: String
  public let generationID: UUID
  public let applyRequestID: UUID
  public let location: SelectedLocation?
  public var leaseExpiresAt: Date
  public let serverOwnerID: UUID?
  public let serverOwnerHeartbeatRequiredSince: Date?
  public var phase: SimulationLifecyclePhase
  public var cleanupRequestID: UUID?
  public var retryAttempt: Int
  public var nextRetryAt: Date?
  public var lastFailure: InjectionBackendFailure?

  public init(
    activeDeviceIdentifier: String,
    generationID: UUID,
    applyRequestID: UUID,
    location: SelectedLocation?,
    leaseExpiresAt: Date,
    serverOwnerID: UUID? = nil,
    serverOwnerHeartbeatRequiredSince: Date? = nil,
    phase: SimulationLifecyclePhase,
    cleanupRequestID: UUID? = nil,
    retryAttempt: Int = 0,
    nextRetryAt: Date? = nil,
    lastFailure: InjectionBackendFailure? = nil
  ) {
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.generationID = generationID
    self.applyRequestID = applyRequestID
    self.location = location
    self.leaseExpiresAt = leaseExpiresAt
    self.serverOwnerID = serverOwnerID
    self.serverOwnerHeartbeatRequiredSince = serverOwnerHeartbeatRequiredSince
    self.phase = phase
    self.cleanupRequestID = cleanupRequestID
    self.retryAttempt = retryAttempt
    self.nextRetryAt = nextRetryAt
    self.lastFailure = lastFailure
  }
}

public enum SimulationLifecycleCompletionOutcome: String, Codable, Equatable, Sendable {
  case applied
  case leaseExtended
  case stopped
}

public struct SimulationLifecycleCompletion: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let outcome: SimulationLifecycleCompletionOutcome
  public let generationID: UUID?
  public let location: SelectedLocation?
  public let leaseExpiresAt: Date?

  public init(
    requestID: UUID,
    outcome: SimulationLifecycleCompletionOutcome,
    generationID: UUID? = nil,
    location: SelectedLocation? = nil,
    leaseExpiresAt: Date? = nil
  ) {
    self.requestID = requestID
    self.outcome = outcome
    self.generationID = generationID
    self.location = location
    self.leaseExpiresAt = leaseExpiresAt
  }
}

public struct SimulationLifecycleJournal: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 1

  public var schemaVersion: Int
  public var legacyCleanupCompleted: Bool
  public var active: SimulationLifecycleRecord?
  public var completions: [SimulationLifecycleCompletion]
  public var lastStoppedGenerationID: UUID?

  public init(
    schemaVersion: Int = SimulationLifecycleJournal.currentSchemaVersion,
    legacyCleanupCompleted: Bool = false,
    active: SimulationLifecycleRecord? = nil,
    completions: [SimulationLifecycleCompletion] = [],
    lastStoppedGenerationID: UUID? = nil
  ) {
    self.schemaVersion = schemaVersion
    self.legacyCleanupCompleted = legacyCleanupCompleted
    self.active = active
    self.completions = completions
    self.lastStoppedGenerationID = lastStoppedGenerationID
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case legacyCleanupCompleted
    case active
    case completions
    case lastStoppedGenerationID
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    legacyCleanupCompleted = try container.decode(
      Bool.self,
      forKey: .legacyCleanupCompleted
    )
    active = try container.decodeIfPresent(
      SimulationLifecycleRecord.self,
      forKey: .active
    )
    completions =
      try container.decodeIfPresent(
        [SimulationLifecycleCompletion].self,
        forKey: .completions
      ) ?? []
    lastStoppedGenerationID = try container.decodeIfPresent(
      UUID.self,
      forKey: .lastStoppedGenerationID
    )
  }
}

public protocol SimulationLifecycleStoring: Sendable {
  func load() async throws -> SimulationLifecycleJournal?
  func save(_ journal: SimulationLifecycleJournal) async throws
}

public actor InMemorySimulationLifecycleStore: SimulationLifecycleStoring {
  private var journal: SimulationLifecycleJournal?

  public init(journal: SimulationLifecycleJournal? = nil) {
    self.journal = journal
  }

  public func load() -> SimulationLifecycleJournal? {
    journal
  }

  public func save(_ journal: SimulationLifecycleJournal) {
    self.journal = journal
  }
}

public actor FileSimulationLifecycleStore: SimulationLifecycleStoring {
  public static let fileEnvironmentKey = "REMOTE_LOCATION_LIFECYCLE_FILE"

  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public static func defaultFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let path = environment[fileEnvironmentKey]?
      .trimmingCharacters(in: .whitespacesAndNewlines),
      !path.isEmpty
    {
      return URL(fileURLWithPath: path, isDirectory: false)
    }

    let applicationSupport =
      FileManager.default.urls(
        for: .applicationSupportDirectory,
        in: .userDomainMask
      ).first ?? FileManager.default.temporaryDirectory
    return
      applicationSupport
      .appendingPathComponent("Pinshift", isDirectory: true)
      .appendingPathComponent("SimulationLifecycle", isDirectory: true)
      .appendingPathComponent("lifecycle.json", isDirectory: false)
  }

  public func load() throws -> SimulationLifecycleJournal? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    let journal = try Self.decoder().decode(
      SimulationLifecycleJournal.self,
      from: Data(contentsOf: fileURL)
    )
    guard journal.schemaVersion == SimulationLifecycleJournal.currentSchemaVersion else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return journal
  }

  public func save(_ journal: SimulationLifecycleJournal) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try Self.encoder().encode(journal)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }
}
