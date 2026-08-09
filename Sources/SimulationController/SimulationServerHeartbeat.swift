import Foundation

public struct SimulationServerHeartbeat: Codable, Equatable, Sendable {
  public let ownerID: UUID
  public let recordedAt: Date

  public init(ownerID: UUID, recordedAt: Date) {
    self.ownerID = ownerID
    self.recordedAt = recordedAt
  }
}

public protocol SimulationServerHeartbeatStoring: Sendable {
  func load() async throws -> SimulationServerHeartbeat?
  func save(_ heartbeat: SimulationServerHeartbeat) async throws
}

public actor SimulationServerHeartbeatEmitter {
  public let ownerID: UUID
  private let store: any SimulationServerHeartbeatStoring
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let interval: TimeInterval

  public init(
    ownerID: UUID,
    store: any SimulationServerHeartbeatStoring,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    interval: TimeInterval = 5
  ) {
    self.ownerID = ownerID
    self.store = store
    self.now = now
    self.sleep = sleep
    self.interval = max(1, interval)
  }

  public func recordNow() async throws {
    try await store.save(
      SimulationServerHeartbeat(ownerID: ownerID, recordedAt: now())
    )
  }

  public func run() async throws {
    while !Task.isCancelled {
      try await recordNow()
      try await sleep(interval)
    }
  }
}

public actor InMemorySimulationServerHeartbeatStore: SimulationServerHeartbeatStoring {
  private var heartbeat: SimulationServerHeartbeat?

  public init(heartbeat: SimulationServerHeartbeat? = nil) {
    self.heartbeat = heartbeat
  }

  public func load() -> SimulationServerHeartbeat? {
    heartbeat
  }

  public func save(_ heartbeat: SimulationServerHeartbeat) {
    self.heartbeat = heartbeat
  }
}

public actor FileSimulationServerHeartbeatStore: SimulationServerHeartbeatStoring {
  public static let fileEnvironmentKey = "REMOTE_LOCATION_SERVER_HEARTBEAT_FILE"

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
      .appendingPathComponent("server-owner-heartbeat.json", isDirectory: false)
  }

  public func load() throws -> SimulationServerHeartbeat? {
    guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
    return try Self.decoder().decode(
      SimulationServerHeartbeat.self,
      from: Data(contentsOf: fileURL)
    )
  }

  public func save(_ heartbeat: SimulationServerHeartbeat) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try Self.encoder().encode(heartbeat)
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
