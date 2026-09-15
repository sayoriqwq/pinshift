import Darwin
import Foundation

/// The two local processes intentionally keep separate diagnostic records.
public enum SimulationDiagnosticSide: String, Codable, Equatable, Sendable {
  case pinshiftApp = "pinshift-app"
  case macController = "mac-controller"

  public var fileName: String {
    "\(rawValue).jsonl"
  }
}

/// A small JSON value type keeps event fields structured without allowing an
/// arbitrary object (and, in particular, an accidental secret-bearing object)
/// to be handed to the recorder.
public enum SimulationDiagnosticValue: Codable, Equatable, Sendable {
  case string(String)
  case number(Double)
  case integer(Int64)
  case boolean(Bool)
  case array([SimulationDiagnosticValue])
  case object([String: SimulationDiagnosticValue])
  case null

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let object = try? container.decode([String: Self].self) {
      self = .object(object)
      return
    }
    if let array = try? container.decode([Self].self) {
      self = .array(array)
      return
    }
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }

  public func encode(to encoder: Encoder) throws {
    switch self {
    case .string(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .number(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .integer(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .boolean(let value):
      var container = encoder.singleValueContainer()
      try container.encode(value)
    case .array(let values):
      var container = encoder.unkeyedContainer()
      try container.encode(contentsOf: values)
    case .object(let values):
      var container = encoder.container(keyedBy: StringCodingKey.self)
      for key in values.keys.sorted() {
        try container.encode(values[key], forKey: StringCodingKey(stringValue: key)!)
      }
    case .null:
      var container = encoder.singleValueContainer()
      try container.encodeNil()
    }
  }

  public static func date(_ value: Date) -> Self {
    .string(SimulationDiagnosticDateFormatter.string(from: value))
  }

  public static func text(_ value: String) -> Self {
    .string(SimulationDiagnosticText.sanitized(value))
  }
}

public typealias SimulationDiagnosticFields = [String: SimulationDiagnosticValue]

public struct SimulationDiagnosticEvent: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let timestamp: Date
  public let sessionID: UUID
  public let sequence: UInt64
  public let kind: String
  public let requestID: UUID?
  public let fields: SimulationDiagnosticFields

  public init(
    schemaVersion: Int = SimulationDiagnosticRecorder.currentSchemaVersion,
    timestamp: Date,
    sessionID: UUID,
    sequence: UInt64,
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) {
    self.schemaVersion = schemaVersion
    self.timestamp = timestamp
    self.sessionID = sessionID
    self.sequence = sequence
    self.kind = kind
    self.requestID = requestID
    self.fields = fields
  }
}

public struct SimulationDiagnosticExport: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let side: SimulationDiagnosticSide
  public let generationID: UUID
  public let createdAt: Date
  public let events: [SimulationDiagnosticEvent]

  public init(
    schemaVersion: Int = SimulationDiagnosticRecorder.currentSchemaVersion,
    side: SimulationDiagnosticSide,
    generationID: UUID,
    createdAt: Date,
    events: [SimulationDiagnosticEvent]
  ) {
    self.schemaVersion = schemaVersion
    self.side = side
    self.generationID = generationID
    self.createdAt = createdAt
    self.events = events
  }
}

public struct SimulationDiagnosticRecordStatus: Equatable, Sendable {
  public let side: SimulationDiagnosticSide
  public let fileURL: URL
  public let sessionID: UUID
  public let generationID: UUID
  public let approximateSizeBytes: Int
  public let eventCount: Int
  public let maximumBytes: Int
  public let lastErrorDescription: String?

  public init(
    side: SimulationDiagnosticSide,
    fileURL: URL,
    sessionID: UUID,
    generationID: UUID,
    approximateSizeBytes: Int,
    eventCount: Int,
    maximumBytes: Int,
    lastErrorDescription: String?
  ) {
    self.side = side
    self.fileURL = fileURL
    self.sessionID = sessionID
    self.generationID = generationID
    self.approximateSizeBytes = approximateSizeBytes
    self.eventCount = eventCount
    self.maximumBytes = maximumBytes
    self.lastErrorDescription = lastErrorDescription
  }
}

/// A local, append-oriented, bounded recorder. Recording is deliberately a
/// non-throwing side effect: callers can observe its status, but simulation
/// commands never depend on a successful diagnostic write.
public actor SimulationDiagnosticRecorder {
  public static let currentSchemaVersion = 1
  public static let defaultMaximumBytes = 10 * 1_024 * 1_024
  public static let directoryEnvironmentKey = "PINSHIFT_DIAGNOSTICS_DIRECTORY"

  public let side: SimulationDiagnosticSide
  public let fileURL: URL
  public let sessionID: UUID
  public let maximumBytes: Int

  private let metadataURL: URL
  private let lockURL: URL
  private let fileManager: FileManager
  private var generationID: UUID
  private var createdAt: Date
  private var nextSequence: UInt64 = 1
  private var lastErrorDescription: String?

  /// A target-internal test seam that guards the append path against accidental
  /// reintroduction of whole-file maintenance scans.
  internal private(set) var maintenanceFullFileReadCount = 0

  public init(
    side: SimulationDiagnosticSide,
    fileURL: URL? = nil,
    directory: URL? = nil,
    maximumBytes: Int = SimulationDiagnosticRecorder.defaultMaximumBytes,
    sessionID: UUID = UUID(),
    fileManager: FileManager = .default
  ) {
    self.side = side
    self.fileManager = fileManager
    self.maximumBytes = max(1, maximumBytes)
    self.sessionID = sessionID

    let resolvedDirectory =
      directory
      ?? Self.defaultDirectory(environment: ProcessInfo.processInfo.environment)
    let resolvedFileURL =
      fileURL
      ?? resolvedDirectory.appendingPathComponent(side.fileName, isDirectory: false)
    self.fileURL = resolvedFileURL
    self.metadataURL =
      resolvedFileURL
      .deletingPathExtension()
      .appendingPathExtension("metadata.json")
    self.lockURL = resolvedFileURL.appendingPathExtension("lock")

    if let metadata = try? Self.readMetadata(at: self.metadataURL),
      metadata.schemaVersion == Self.currentSchemaVersion
    {
      self.generationID = metadata.generationID
      self.createdAt = metadata.createdAt
    } else {
      self.generationID = UUID()
      self.createdAt = Date()
    }

    self.nextSequence = Self.nextSequence(
      for: sessionID,
      in: (try? Data(contentsOf: resolvedFileURL)) ?? Data()
    )
  }

  public static func defaultDirectory(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    if let override = environment[directoryEnvironmentKey] {
      let trimmed = override.trimmingCharacters(in: .whitespacesAndNewlines)
      if !trimmed.isEmpty {
        return URL(fileURLWithPath: trimmed, isDirectory: true)
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
      .appendingPathComponent("SimulationDiagnostics", isDirectory: true)
  }

  public static func defaultFileURL(
    for side: SimulationDiagnosticSide,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> URL {
    defaultDirectory(environment: environment)
      .appendingPathComponent(side.fileName, isDirectory: false)
  }

  public func record(
    kind: String,
    timestamp: Date = Date(),
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) {
    let normalizedKind = kind.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedKind.isEmpty else {
      lastErrorDescription = "Diagnostic event kind was empty."
      return
    }

    do {
      try append(
        kind: normalizedKind,
        timestamp: timestamp,
        requestID: requestID,
        fields: Self.sanitizedFields(fields)
      )
      lastErrorDescription = nil
    } catch {
      lastErrorDescription = String(describing: error)
    }
  }

  public func status() -> SimulationDiagnosticRecordStatus {
    refreshMetadataFromDiskIfPresent()
    let data = (try? Data(contentsOf: fileURL)) ?? Data()
    return SimulationDiagnosticRecordStatus(
      side: side,
      fileURL: fileURL,
      sessionID: sessionID,
      generationID: generationID,
      approximateSizeBytes: data.count,
      eventCount: Self.decodeEvents(from: data).count,
      maximumBytes: maximumBytes,
      lastErrorDescription: lastErrorDescription
    )
  }

  public func events() -> [SimulationDiagnosticEvent] {
    Self.decodeEvents(from: (try? Data(contentsOf: fileURL)) ?? Data())
  }

  public func exportData() throws -> Data {
    refreshMetadataFromDiskIfPresent()
    let export = SimulationDiagnosticExport(
      side: side,
      generationID: generationID,
      createdAt: createdAt,
      events: events()
    )
    return try Self.encoder().encode(export)
  }

  @discardableResult
  public func export(to destinationURL: URL) throws -> URL {
    let data = try exportData()
    try fileManager.createDirectory(
      at: destinationURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try data.write(to: destinationURL, options: .atomic)
    return destinationURL
  }

  @discardableResult
  public func clear() -> Bool {
    do {
      try withExclusiveFileLock {
        if fileManager.fileExists(atPath: fileURL.path) {
          try fileManager.removeItem(at: fileURL)
        }
        generationID = UUID()
        createdAt = Date()
        nextSequence = 1
        lastErrorDescription = nil
        try writeMetadata()
      }
      return true
    } catch {
      lastErrorDescription = String(describing: error)
      return false
    }
  }

  private func append(
    kind: String,
    timestamp: Date,
    requestID: UUID?,
    fields: SimulationDiagnosticFields
  ) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )

    try withExclusiveFileLock {
      try synchronizeMetadataFromDisk()
      let event = SimulationDiagnosticEvent(
        timestamp: timestamp,
        sessionID: sessionID,
        sequence: nextSequence,
        kind: kind,
        requestID: requestID,
        fields: fields
      )
      nextSequence += 1
      let data = try Self.encoder().encode(event) + Data([0x0A])
      if !fileManager.fileExists(atPath: fileURL.path) {
        try Data().write(to: fileURL, options: .atomic)
      }

      let handle = try FileHandle(forUpdating: fileURL)
      defer { try? handle.close() }
      try repairTornTail(using: handle)
      try handle.seekToEnd()
      try handle.write(contentsOf: data)
      try handle.synchronize()
      try trimIfNeeded()
    }
  }

  private func trimIfNeeded() throws {
    let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
    let fileSize = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard fileSize > maximumBytes else { return }

    maintenanceFullFileReadCount &+= 1
    let data = try Data(contentsOf: fileURL)
    let retentionTargetBytes = max(1, maximumBytes - maximumBytes / 4)

    // Appends encode complete events and torn-tail repair restores newline
    // framing, so retention can choose its byte boundary without decoding every
    // historical JSON object on the write path.
    var retained: [Data] = []
    var retainedBytes = 0
    for rawLine in data.split(separator: 0x0A, omittingEmptySubsequences: true).reversed() {
      var line = Data(rawLine)
      line.append(0x0A)
      guard line.count <= maximumBytes else { continue }
      if retained.isEmpty, line.count > retentionTargetBytes {
        retained.append(line)
        retainedBytes = line.count
        break
      }
      guard retainedBytes + line.count <= retentionTargetBytes else { break }
      retained.append(line)
      retainedBytes += line.count
    }

    var output = Data()
    output.reserveCapacity(retainedBytes)
    for line in retained.reversed() {
      output.append(line)
    }
    try output.write(to: fileURL, options: .atomic)
  }

  private func repairTornTail(using handle: FileHandle) throws {
    let fileSize = try handle.seekToEnd()
    guard fileSize > 0 else { return }

    try handle.seek(toOffset: fileSize - 1)
    if try handle.read(upToCount: 1)?.first == 0x0A {
      return
    }

    let chunkSize: UInt64 = 4_096
    var searchEnd = fileSize
    while searchEnd > 0 {
      let searchStart = searchEnd > chunkSize ? searchEnd - chunkSize : 0
      try handle.seek(toOffset: searchStart)
      let chunk = try handle.read(upToCount: Int(searchEnd - searchStart)) ?? Data()
      if let newline = chunk.lastIndex(of: 0x0A) {
        let newlineOffset = UInt64(chunk.distance(from: chunk.startIndex, to: newline))
        try handle.truncate(atOffset: searchStart + newlineOffset + 1)
        return
      }
      searchEnd = searchStart
    }
    try handle.truncate(atOffset: 0)
  }

  private func withExclusiveFileLock<T>(_ body: () throws -> T) throws -> T {
    try fileManager.createDirectory(
      at: lockURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let descriptor = lockURL.path.withCString {
      Darwin.open($0, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    }
    guard descriptor >= 0 else {
      throw posixError()
    }
    defer {
      var unlock = Darwin.flock()
      unlock.l_type = Int16(F_UNLCK)
      unlock.l_whence = Int16(SEEK_SET)
      _ = Darwin.fcntl(descriptor, F_SETLK, &unlock)
      _ = Darwin.close(descriptor)
    }

    var lock = Darwin.flock()
    lock.l_type = Int16(F_WRLCK)
    lock.l_whence = Int16(SEEK_SET)
    while Darwin.fcntl(descriptor, F_SETLKW, &lock) != 0 {
      guard errno == EINTR else { throw posixError() }
    }
    return try body()
  }

  private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
  }

  private static func decodeEvents(from data: Data) -> [SimulationDiagnosticEvent] {
    let completeData: Data
    if data.last == 0x0A {
      completeData = data
    } else if let lastNewline = data.lastIndex(of: 0x0A) {
      completeData = Data(data.prefix(through: lastNewline))
    } else {
      completeData = Data()
    }
    return completeData.split(separator: 0x0A, omittingEmptySubsequences: true).compactMap { line in
      try? Self.decoder().decode(SimulationDiagnosticEvent.self, from: Data(line))
    }
  }

  private static func nextSequence(for sessionID: UUID, in data: Data) -> UInt64 {
    let completeData: Data
    if data.last == 0x0A {
      completeData = data
    } else if let lastNewline = data.lastIndex(of: 0x0A) {
      completeData = Data(data.prefix(through: lastNewline))
    } else {
      return 1
    }

    let sessionIDBytes = Data(sessionID.uuidString.utf8)
    var maximumSequence: UInt64 = 0
    for line in completeData.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard line.range(of: sessionIDBytes) != nil,
        let event = try? decoder().decode(SimulationDiagnosticEvent.self, from: Data(line)),
        event.sessionID == sessionID
      else { continue }
      maximumSequence = max(maximumSequence, event.sequence)
    }
    return maximumSequence + 1
  }

  private static func sanitizedFields(
    _ fields: SimulationDiagnosticFields
  ) -> SimulationDiagnosticFields {
    fields.mapValues(sanitizedValue)
  }

  private static func sanitizedValue(
    _ value: SimulationDiagnosticValue
  ) -> SimulationDiagnosticValue {
    switch value {
    case .string(let value):
      return .string(SimulationDiagnosticText.sanitized(value))
    case .number, .integer, .boolean, .null:
      return value
    case .array(let values):
      return .array(values.map(sanitizedValue))
    case .object(let values):
      var sanitized: [String: SimulationDiagnosticValue] = [:]
      for (key, value) in values {
        if SimulationDiagnosticText.isSensitiveFieldName(key) {
          sanitized[key] = .string("<redacted>")
        } else {
          sanitized[key] = sanitizedValue(value)
        }
      }
      return .object(sanitized)
    }
  }

  private func writeMetadata() throws {
    try fileManager.createDirectory(
      at: metadataURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let metadata = Metadata(
      schemaVersion: Self.currentSchemaVersion,
      generationID: generationID,
      createdAt: createdAt
    )
    try Self.encoder().encode(metadata).write(to: metadataURL, options: .atomic)
  }

  private func synchronizeMetadataFromDisk() throws {
    guard let metadata = try? Self.readMetadata(at: metadataURL),
      metadata.schemaVersion == Self.currentSchemaVersion
    else {
      try writeMetadata()
      return
    }
    adopt(metadata)
  }

  private func refreshMetadataFromDiskIfPresent() {
    guard let metadata = try? Self.readMetadata(at: metadataURL),
      metadata.schemaVersion == Self.currentSchemaVersion
    else { return }
    adopt(metadata)
  }

  private func adopt(_ metadata: Metadata) {
    if generationID != metadata.generationID {
      nextSequence = 1
    }
    generationID = metadata.generationID
    createdAt = metadata.createdAt
  }

  private static func readMetadata(at url: URL) throws -> Metadata {
    try decoder().decode(Metadata.self, from: Data(contentsOf: url))
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .custom { date, encoder in
      var container = encoder.singleValueContainer()
      try container.encode(SimulationDiagnosticDateFormatter.string(from: date))
    }
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)
      guard let date = SimulationDiagnosticDateFormatter.date(from: value) else {
        throw DecodingError.dataCorruptedError(
          in: container,
          debugDescription: "Invalid diagnostic timestamp."
        )
      }
      return date
    }
    return decoder
  }

  private struct Metadata: Codable {
    let schemaVersion: Int
    let generationID: UUID
    let createdAt: Date
  }
}

public enum SimulationDiagnosticText {
  public static let maximumCapturedTextLength = 64 * 1_024

  static func isSensitiveFieldName(_ value: String) -> Bool {
    let normalized = value.lowercased().filter { $0.isLetter || $0.isNumber }
    let markers = [
      "pairingcode",
      "authorization",
      "auth",
      "privatekey",
      "apikey",
      "password",
      "secret",
      "token",
      "credential",
    ]
    return markers.contains { normalized == $0 || normalized.contains($0) }
  }

  /// Only explicitly supplied local text is recorded. This final guard removes
  /// obvious credential-shaped values if a subprocess fixture unexpectedly
  /// echoes one, while preserving ordinary devicectl failure diagnostics.
  public static func sanitized(_ value: String) -> String {
    var result = String(value.prefix(maximumCapturedTextLength))
    let sensitiveMarkers = [
      "pairing code",
      "pairing-code",
      "pairing_code",
      "pairingcode",
      "authorization",
      "auth",
      "private key",
      "private-key",
      "private_key",
      "privatekey",
      "api key",
      "api-key",
      "api_key",
      "apikey",
      "password",
      "secret",
      "token",
    ]
    for marker in sensitiveMarkers {
      result = redactValue(after: marker, in: result)
    }
    if result.contains("-----BEGIN") && result.contains("PRIVATE KEY-----") {
      result = "<redacted private key material>"
    }
    return result
  }

  private static func redactValue(after marker: String, in value: String) -> String {
    let pattern =
      "(?i)"
      + NSRegularExpression.escapedPattern(for: marker)
      + "(?:[^\\r\\n:=]*[:=][^\\r\\n]*|\\s+[^\\r\\n]*)"
    guard let expression = try? NSRegularExpression(pattern: pattern) else {
      return value
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.stringByReplacingMatches(
      in: value,
      range: range,
      withTemplate: "(marker): <redacted>"
    )
  }
}

private enum SimulationDiagnosticDateFormatter {
  private static let formatOptions: ISO8601DateFormatter.Options = [
    .withInternetDateTime,
    .withFractionalSeconds,
  ]

  static func string(from date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = formatOptions
    return formatter.string(from: date)
  }

  static func date(from value: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = formatOptions
    return formatter.date(from: value)
  }
}

private struct StringCodingKey: CodingKey, Hashable {
  let stringValue: String
  let intValue: Int? = nil

  init?(stringValue: String) {
    self.stringValue = stringValue
  }

  init?(intValue: Int) {
    return nil
  }
}
