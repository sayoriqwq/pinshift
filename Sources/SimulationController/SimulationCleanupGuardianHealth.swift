import Foundation

public struct SimulationCleanupGuardianHealth: Codable, Equatable, Sendable {
  public let guardianID: UUID
  public let activeDeviceIdentifier: String
  public let recordedAt: Date

  public init(
    guardianID: UUID,
    activeDeviceIdentifier: String,
    recordedAt: Date
  ) {
    self.guardianID = guardianID
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.recordedAt = recordedAt
  }
}

public protocol SimulationCleanupGuardianHealthStoring: Sendable {
  func load() async throws -> SimulationCleanupGuardianHealth?
  func save(_ health: SimulationCleanupGuardianHealth) async throws
}

public actor InMemorySimulationCleanupGuardianHealthStore:
  SimulationCleanupGuardianHealthStoring
{
  private var health: SimulationCleanupGuardianHealth?

  public init(health: SimulationCleanupGuardianHealth? = nil) {
    self.health = health
  }

  public func load() -> SimulationCleanupGuardianHealth? {
    health
  }

  public func save(_ health: SimulationCleanupGuardianHealth) {
    self.health = health
  }
}

public actor FileSimulationCleanupGuardianHealthStore:
  SimulationCleanupGuardianHealthStoring
{
  public static let fileEnvironmentKey = "PINSHIFT_GUARDIAN_HEALTH_FILE"

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
      .appendingPathComponent("cleanup-guardian-health.json", isDirectory: false)
  }

  public func load() throws -> SimulationCleanupGuardianHealth? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    return try Self.decoder().decode(
      SimulationCleanupGuardianHealth.self,
      from: Data(contentsOf: fileURL)
    )
  }

  public func save(_ health: SimulationCleanupGuardianHealth) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try Self.encoder().encode(health)
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
