import Foundation
import LocationDomain

public enum TemporarySimulationPhase: String, Codable, Equatable, Sendable {
  case armed
  case active
  case clearPending
}

public struct TemporarySimulationRecord: Codable, Equatable, Sendable {
  public var activeDeviceIdentifier: String
  public let operationID: UUID
  public let location: SelectedLocation?
  public let automaticClearAt: Date
  public var phase: TemporarySimulationPhase
  public var retryAttempt: Int
  public var nextClearAttemptAt: Date?
  public var lastClearFailure: InjectionBackendFailure?

  public init(
    activeDeviceIdentifier: String,
    operationID: UUID,
    location: SelectedLocation?,
    automaticClearAt: Date,
    phase: TemporarySimulationPhase,
    retryAttempt: Int = 0,
    nextClearAttemptAt: Date? = nil,
    lastClearFailure: InjectionBackendFailure? = nil
  ) {
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.operationID = operationID
    self.location = location
    self.automaticClearAt = automaticClearAt
    self.phase = phase
    self.retryAttempt = retryAttempt
    self.nextClearAttemptAt = nextClearAttemptAt
    self.lastClearFailure = lastClearFailure
  }
}

public struct TemporaryApplyReceipt: Codable, Equatable, Sendable {
  public let operationID: UUID
  public let location: SelectedLocation
  public let automaticClearAt: Date

  public init(
    operationID: UUID,
    location: SelectedLocation,
    automaticClearAt: Date
  ) {
    self.operationID = operationID
    self.location = location
    self.automaticClearAt = automaticClearAt
  }
}

public struct TemporarySimulationState: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var current: TemporarySimulationRecord?
  public var recentApplyReceipts: [TemporaryApplyReceipt]

  public init(
    schemaVersion: Int = TemporarySimulationState.currentSchemaVersion,
    current: TemporarySimulationRecord? = nil,
    recentApplyReceipts: [TemporaryApplyReceipt] = []
  ) {
    self.schemaVersion = schemaVersion
    self.current = current
    self.recentApplyReceipts = recentApplyReceipts
  }
}

public protocol TemporarySimulationStoring: Sendable {
  func load() async throws -> TemporarySimulationState?
  func save(_ state: TemporarySimulationState) async throws
}

public actor InMemoryTemporarySimulationStore: TemporarySimulationStoring {
  private var state: TemporarySimulationState?

  public init(state: TemporarySimulationState? = nil) {
    self.state = state
  }

  public func load() -> TemporarySimulationState? {
    state
  }

  public func save(_ state: TemporarySimulationState) {
    self.state = state
  }
}

public actor FileTemporarySimulationStore: TemporarySimulationStoring {
  public static let fileEnvironmentKey = "PINSHIFT_TEMPORARY_SIMULATION_FILE"
  public static let legacyFileEnvironmentKey = "PINSHIFT_LIFECYCLE_FILE"

  public let fileURL: URL
  private let fileManager: FileManager

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public static func defaultFileURL(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    for key in [fileEnvironmentKey, legacyFileEnvironmentKey] {
      if let path = environment[key]?
        .trimmingCharacters(in: .whitespacesAndNewlines),
        !path.isEmpty
      {
        return URL(fileURLWithPath: path, isDirectory: false)
      }
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

  public func load() throws -> TemporarySimulationState? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    let data = try Data(contentsOf: fileURL)

    if let state = try? Self.decoder().decode(TemporarySimulationState.self, from: data),
      state.schemaVersion == TemporarySimulationState.currentSchemaVersion
    {
      return state
    }

    let legacy = try Self.decoder().decode(LegacySimulationLifecycleJournal.self, from: data)
    guard legacy.schemaVersion == 1 else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return Self.migrate(legacy)
  }

  public func save(_ state: TemporarySimulationState) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try Self.encoder().encode(state)
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private static func migrate(
    _ legacy: LegacySimulationLifecycleJournal
  ) -> TemporarySimulationState {
    let current: TemporarySimulationRecord?
    if let active = legacy.active {
      current = TemporarySimulationRecord(
        activeDeviceIdentifier: active.activeDeviceIdentifier,
        operationID: active.generationID,
        location: active.location,
        automaticClearAt: .distantPast,
        phase: .clearPending
      )
    } else if !legacy.legacyCleanupCompleted {
      let migrationID = UUID()
      current = TemporarySimulationRecord(
        activeDeviceIdentifier: "",
        operationID: migrationID,
        location: nil,
        automaticClearAt: .distantPast,
        phase: .clearPending
      )
    } else {
      current = nil
    }
    return TemporarySimulationState(current: current)
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

private struct LegacySimulationLifecycleJournal: Decodable {
  let schemaVersion: Int
  let legacyCleanupCompleted: Bool
  let active: LegacySimulationLifecycleRecord?
}

private struct LegacySimulationLifecycleRecord: Decodable {
  let activeDeviceIdentifier: String
  let generationID: UUID
  let location: SelectedLocation?
  let leaseExpiresAt: Date
  let phase: LegacySimulationLifecyclePhase
  let retryAttempt: Int
  let nextRetryAt: Date?
  let lastFailure: String?

  private enum CodingKeys: String, CodingKey {
    case activeDeviceIdentifier
    case generationID
    case location
    case leaseExpiresAt
    case phase
    case retryAttempt
    case nextRetryAt
    case lastFailure
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    activeDeviceIdentifier =
      try container.decodeIfPresent(String.self, forKey: .activeDeviceIdentifier) ?? ""
    generationID = try container.decode(UUID.self, forKey: .generationID)
    location = try container.decodeIfPresent(SelectedLocation.self, forKey: .location)
    leaseExpiresAt = try container.decode(Date.self, forKey: .leaseExpiresAt)
    phase = try container.decode(LegacySimulationLifecyclePhase.self, forKey: .phase)
    retryAttempt = try container.decodeIfPresent(Int.self, forKey: .retryAttempt) ?? 0
    nextRetryAt = try container.decodeIfPresent(Date.self, forKey: .nextRetryAt)
    lastFailure = try container.decodeIfPresent(String.self, forKey: .lastFailure)
  }
}

private enum LegacySimulationLifecyclePhase: String, Decodable {
  case applyUncertain
  case applied
  case cleanupPending
}
