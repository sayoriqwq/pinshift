import Foundation

public enum SimulationLeaseDuration: Int, Codable, CaseIterable, Equatable, Hashable, Sendable,
  Identifiable
{
  case fifteenMinutes = 900
  case thirtyMinutes = 1_800
  case sixtyMinutes = 3_600

  public static let defaultDuration = SimulationLeaseDuration.fifteenMinutes

  public var timeInterval: TimeInterval {
    TimeInterval(rawValue)
  }

  public var id: Int { rawValue }

  public var minutes: Int { rawValue / 60 }
}

public struct ManualSimulationRequest: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let generationID: UUID
  public let location: SelectedLocation
  public let requestedAt: Date
  public let requestedLeaseDuration: TimeInterval
  public let leaseExpiresAt: Date?

  public init(
    requestID: UUID,
    generationID: UUID? = nil,
    location: SelectedLocation,
    requestedAt: Date,
    requestedLeaseDuration: TimeInterval = SimulationLeaseDuration.defaultDuration.timeInterval,
    leaseExpiresAt: Date? = nil
  ) {
    self.requestID = requestID
    self.generationID = generationID ?? requestID
    self.location = location
    self.requestedAt = requestedAt
    self.requestedLeaseDuration = requestedLeaseDuration
    self.leaseExpiresAt = leaseExpiresAt
  }

  private enum CodingKeys: String, CodingKey {
    case requestID
    case generationID
    case location
    case requestedAt
    case requestedLeaseDuration
    case leaseExpiresAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    requestID = try container.decode(UUID.self, forKey: .requestID)
    generationID = try container.decodeIfPresent(UUID.self, forKey: .generationID) ?? requestID
    location = try container.decode(SelectedLocation.self, forKey: .location)
    requestedAt = try container.decode(Date.self, forKey: .requestedAt)
    requestedLeaseDuration =
      try container.decodeIfPresent(TimeInterval.self, forKey: .requestedLeaseDuration)
      ?? SimulationLeaseDuration.defaultDuration.timeInterval
    leaseExpiresAt = try container.decodeIfPresent(Date.self, forKey: .leaseExpiresAt)
  }
}

public enum ManualSimulationSessionError: String, Codable, Error, Equatable, Sendable {
  case noSelectedLocation
  case cleanupPending
}

public enum ManualSimulationFailure: Codable, Equatable, Sendable {
  case responseIdentityMismatch
  case controllerUnavailable
  case requestRejected(stableCode: String)
}

public enum AppliedVerificationIssue: Codable, Equatable, Sendable {
  case notAfterRequest
  case timedOut(elapsedSeconds: TimeInterval)
  case tooFar(distanceMeters: Double)
}

public enum ManualSimulationStatus: Codable, Equatable, Sendable {
  case noSelection
  case selected(SelectedLocation)
  case applying(ManualSimulationRequest)
  case applied(ManualSimulationRequest)
  case appliedNotVerified(ManualSimulationRequest, AppliedVerificationIssue)
  case verified(ManualSimulationRequest, ObservationMatchEvidence)
  case failed(ManualSimulationRequest, ManualSimulationFailure)
  case stopped
}

public struct ManualSimulationStopIntent: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let generationID: UUID
  public let requestedAt: Date

  public init(requestID: UUID, generationID: UUID, requestedAt: Date) {
    self.requestID = requestID
    self.generationID = generationID
    let milliseconds = Int64((requestedAt.timeIntervalSince1970 * 1_000).rounded(.down))
    self.requestedAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
  }
}

public struct ManualSimulationLeaseExtensionIntent: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let generationID: UUID
  public let requestedAt: Date
  public let extensionDuration: TimeInterval

  public init(
    requestID: UUID,
    generationID: UUID,
    requestedAt: Date,
    extensionDuration: TimeInterval = 900
  ) {
    self.requestID = requestID
    self.generationID = generationID
    let milliseconds = Int64((requestedAt.timeIntervalSince1970 * 1_000).rounded(.down))
    self.requestedAt = Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    self.extensionDuration = extensionDuration
  }
}

public enum ManualSimulationStopStatus: Codable, Equatable, Sendable {
  case idle
  case stopping(requestID: UUID)
  case stopped(requestID: UUID)
  case failed(requestID: UUID, ManualSimulationFailure)
}

public enum ManualSimulationLeaseExtensionStatus: Codable, Equatable, Sendable {
  case idle
  case extending(requestID: UUID)
  case extended(requestID: UUID)
  case failed(requestID: UUID, ManualSimulationFailure)
}

public enum ManualSimulationCleanupStatus: Codable, Equatable, Sendable {
  case inactive
  case protected
  case restoreRequested(requestID: UUID)
  case pending(ManualSimulationFailure?)
  case cleared
}

public struct ManualSimulationSession: Codable, Equatable, Sendable {
  public private(set) var selected: SelectedLocation?
  public private(set) var latestObservation: LocationObservation?
  public private(set) var activeAppliedRequest: ManualSimulationRequest?
  public private(set) var status: ManualSimulationStatus = .noSelection
  public private(set) var stopStatus: ManualSimulationStopStatus = .idle
  public private(set) var pendingStopIntent: ManualSimulationStopIntent?
  public private(set) var leaseExtensionStatus: ManualSimulationLeaseExtensionStatus = .idle
  public private(set) var pendingLeaseExtension: ManualSimulationLeaseExtensionIntent?
  public private(set) var cleanupStatus: ManualSimulationCleanupStatus = .inactive

  public init() {}

  private enum CodingKeys: String, CodingKey {
    case selected
    case activeAppliedRequest
    case status
    case stopStatus
    case pendingStopIntent
    case leaseExtensionStatus
    case pendingLeaseExtension
    case cleanupStatus
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    selected = try container.decodeIfPresent(SelectedLocation.self, forKey: .selected)
    latestObservation = nil
    activeAppliedRequest = try container.decodeIfPresent(
      ManualSimulationRequest.self,
      forKey: .activeAppliedRequest
    )
    status =
      try container.decodeIfPresent(
        ManualSimulationStatus.self,
        forKey: .status
      ) ?? selected.map(ManualSimulationStatus.selected) ?? .noSelection
    stopStatus =
      try container.decodeIfPresent(
        ManualSimulationStopStatus.self,
        forKey: .stopStatus
      ) ?? .idle
    pendingStopIntent = try container.decodeIfPresent(
      ManualSimulationStopIntent.self,
      forKey: .pendingStopIntent
    )
    leaseExtensionStatus =
      try container.decodeIfPresent(
        ManualSimulationLeaseExtensionStatus.self,
        forKey: .leaseExtensionStatus
      ) ?? .idle
    pendingLeaseExtension = try container.decodeIfPresent(
      ManualSimulationLeaseExtensionIntent.self,
      forKey: .pendingLeaseExtension
    )
    cleanupStatus =
      try container.decodeIfPresent(
        ManualSimulationCleanupStatus.self,
        forKey: .cleanupStatus
      ) ?? (activeAppliedRequest == nil ? .inactive : .protected)
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(selected, forKey: .selected)
    try container.encodeIfPresent(activeAppliedRequest, forKey: .activeAppliedRequest)
    try container.encode(status, forKey: .status)
    try container.encode(stopStatus, forKey: .stopStatus)
    try container.encodeIfPresent(pendingStopIntent, forKey: .pendingStopIntent)
    try container.encode(leaseExtensionStatus, forKey: .leaseExtensionStatus)
    try container.encodeIfPresent(pendingLeaseExtension, forKey: .pendingLeaseExtension)
    try container.encode(cleanupStatus, forKey: .cleanupStatus)
  }

  public mutating func select(latitude: String, longitude: String) throws {
    select(
      try SelectedLocation.parse(
        latitude: latitude,
        longitude: longitude
      )
    )
  }

  public mutating func select(_ location: SelectedLocation) {
    selected = location
    switch status {
    case .noSelection, .selected, .stopped:
      status = .selected(location)
    case .failed where activeAppliedRequest == nil:
      status = .selected(location)
    case .applying, .applied, .appliedNotVerified, .verified, .failed:
      break
    }
  }

  @discardableResult
  public mutating func beginApply(
    requestID: UUID,
    generationID: UUID? = nil,
    leaseDuration: SimulationLeaseDuration = .defaultDuration,
    at date: Date
  ) throws -> ManualSimulationRequest {
    guard pendingStopIntent == nil else {
      throw ManualSimulationSessionError.cleanupPending
    }
    if case .pending = cleanupStatus {
      throw ManualSimulationSessionError.cleanupPending
    }
    guard let selected else {
      throw ManualSimulationSessionError.noSelectedLocation
    }

    let request = ManualSimulationRequest(
      requestID: requestID,
      generationID: generationID,
      location: selected,
      requestedAt: date,
      requestedLeaseDuration: leaseDuration.timeInterval
    )
    stopStatus = .idle
    leaseExtensionStatus = .idle
    pendingLeaseExtension = nil
    cleanupStatus = .inactive
    status = .applying(request)
    return request
  }

  @discardableResult
  public mutating func acknowledgeApplied(
    requestID: UUID,
    generationID: UUID? = nil,
    leaseExpiresAt: Date? = nil
  ) -> Bool {
    guard case .applying(let request) = status else {
      return false
    }
    guard request.requestID == requestID else {
      status = .failed(request, .responseIdentityMismatch)
      return false
    }
    guard generationID == nil || request.generationID == generationID else {
      status = .failed(request, .responseIdentityMismatch)
      return false
    }

    let acknowledgedRequest = ManualSimulationRequest(
      requestID: request.requestID,
      generationID: request.generationID,
      location: request.location,
      requestedAt: request.requestedAt,
      requestedLeaseDuration: request.requestedLeaseDuration,
      leaseExpiresAt: leaseExpiresAt ?? request.leaseExpiresAt
    )
    activeAppliedRequest = acknowledgedRequest
    cleanupStatus = .protected
    status = .applied(acknowledgedRequest)
    return true
  }

  @discardableResult
  public mutating func fail(
    requestID: UUID,
    reason: ManualSimulationFailure
  ) -> Bool {
    guard let request = currentRequest else {
      return false
    }
    guard request.requestID == requestID else {
      status = .failed(request, .responseIdentityMismatch)
      return false
    }

    status = .failed(request, reason)
    return true
  }

  public mutating func record(_ observation: LocationObservation) {
    latestObservation = observation

    let request: ManualSimulationRequest
    switch status {
    case .applied(let current), .appliedNotVerified(let current, _):
      request = current
    default:
      return
    }

    switch ObservationMatcher.evaluate(
      selected: request.location,
      requestedAt: request.requestedAt,
      observation: observation
    ) {
    case .matched(let evidence):
      status = .verified(request, evidence)
    case .notAfterRequest:
      status = .appliedNotVerified(request, .notAfterRequest)
    case .timedOut(let elapsedSeconds):
      status = .appliedNotVerified(
        request,
        .timedOut(elapsedSeconds: elapsedSeconds)
      )
    case .tooFar(let distanceMeters):
      status = .appliedNotVerified(
        request,
        .tooFar(distanceMeters: distanceMeters)
      )
    }
  }

  public mutating func expire(at date: Date) {
    let request: ManualSimulationRequest
    switch status {
    case .applied(let current), .appliedNotVerified(let current, _):
      request = current
    default:
      return
    }

    let elapsedSeconds = date.timeIntervalSince(request.requestedAt)
    guard elapsedSeconds > ObservationMatcher.maximumElapsedSeconds else {
      return
    }
    status = .appliedNotVerified(
      request,
      .timedOut(elapsedSeconds: elapsedSeconds)
    )
  }

  @discardableResult
  public mutating func beginStop(
    requestID: UUID,
    at date: Date = Date()
  ) -> ManualSimulationStopIntent? {
    if let pendingStopIntent {
      stopStatus = .stopping(requestID: pendingStopIntent.requestID)
      return pendingStopIntent
    }
    let targetRequest: ManualSimulationRequest?
    if case .applying(let request) = status {
      targetRequest = request
    } else {
      targetRequest = activeAppliedRequest ?? currentRequest
    }
    guard let targetRequest else { return nil }
    let intent = ManualSimulationStopIntent(
      requestID: requestID,
      generationID: targetRequest.generationID,
      requestedAt: date
    )
    pendingStopIntent = intent
    pendingLeaseExtension = nil
    leaseExtensionStatus = .idle
    cleanupStatus = .restoreRequested(requestID: requestID)
    stopStatus = .stopping(requestID: requestID)
    return intent
  }

  @discardableResult
  public mutating func beginLeaseExtension(
    requestID: UUID,
    at date: Date = Date()
  ) -> ManualSimulationLeaseExtensionIntent? {
    guard pendingStopIntent == nil else { return nil }
    if let pendingLeaseExtension {
      leaseExtensionStatus = .extending(requestID: pendingLeaseExtension.requestID)
      return pendingLeaseExtension
    }
    guard let activeAppliedRequest else { return nil }
    let intent = ManualSimulationLeaseExtensionIntent(
      requestID: requestID,
      generationID: activeAppliedRequest.generationID,
      requestedAt: date
    )
    pendingLeaseExtension = intent
    leaseExtensionStatus = .extending(requestID: requestID)
    return intent
  }

  @discardableResult
  public mutating func acknowledgeLeaseExtension(
    requestID: UUID,
    generationID: UUID,
    leaseExpiresAt: Date
  ) -> Bool {
    guard let intent = pendingLeaseExtension else { return false }
    guard intent.requestID == requestID, intent.generationID == generationID else {
      leaseExtensionStatus = .failed(
        requestID: intent.requestID,
        .responseIdentityMismatch
      )
      return false
    }
    guard let request = activeAppliedRequest, request.generationID == generationID else {
      leaseExtensionStatus = .failed(
        requestID: intent.requestID,
        .responseIdentityMismatch
      )
      return false
    }

    let extendedRequest = request.withLeaseExpiresAt(leaseExpiresAt)
    replaceActiveRequest(with: extendedRequest)
    pendingLeaseExtension = nil
    leaseExtensionStatus = .extended(requestID: requestID)
    return true
  }

  @discardableResult
  public mutating func failLeaseExtension(
    requestID: UUID,
    reason: ManualSimulationFailure
  ) -> Bool {
    guard let intent = pendingLeaseExtension else { return false }
    guard intent.requestID == requestID else {
      leaseExtensionStatus = .failed(
        requestID: intent.requestID,
        .responseIdentityMismatch
      )
      return false
    }
    leaseExtensionStatus = .failed(requestID: requestID, reason)
    return true
  }

  @discardableResult
  public mutating func acknowledgeStopped(
    requestID: UUID,
    generationID: UUID? = nil
  ) -> Bool {
    guard let intent = pendingStopIntent else { return false }
    let expectedID = intent.requestID
    guard expectedID == requestID else {
      stopStatus = .failed(
        requestID: expectedID,
        .responseIdentityMismatch
      )
      return false
    }
    guard generationID == nil || pendingStopIntent?.generationID == generationID else {
      stopStatus = .failed(
        requestID: expectedID,
        .responseIdentityMismatch
      )
      return false
    }

    activeAppliedRequest = nil
    pendingStopIntent = nil
    pendingLeaseExtension = nil
    leaseExtensionStatus = .idle
    cleanupStatus = .cleared
    stopStatus = .stopped(requestID: requestID)
    status = .stopped
    return true
  }

  @discardableResult
  public mutating func failStop(
    requestID: UUID,
    reason: ManualSimulationFailure
  ) -> Bool {
    guard let intent = pendingStopIntent else { return false }
    let expectedID = intent.requestID
    guard expectedID == requestID else {
      stopStatus = .failed(
        requestID: expectedID,
        .responseIdentityMismatch
      )
      return false
    }

    stopStatus = .failed(requestID: requestID, reason)
    cleanupStatus = .pending(reason)
    return true
  }

  public mutating func reconcileCleanupPending(
    generationID: UUID,
    reason: ManualSimulationFailure?
  ) {
    guard let request = activeAppliedRequest ?? currentRequest,
      request.generationID == generationID
    else { return }
    cleanupStatus = .pending(reason)
  }

  @discardableResult
  public mutating func reconcileApplied(
    generationID: UUID,
    leaseExpiresAt: Date
  ) -> Bool {
    guard let request = activeAppliedRequest ?? currentRequest,
      request.generationID == generationID
    else { return false }
    let reconciled = request.withLeaseExpiresAt(leaseExpiresAt)
    replaceActiveRequest(with: reconciled)
    if pendingStopIntent == nil {
      cleanupStatus = .protected
    }
    if pendingLeaseExtension?.generationID == generationID,
      leaseExpiresAt != request.leaseExpiresAt
    {
      let requestID = pendingLeaseExtension?.requestID ?? UUID()
      pendingLeaseExtension = nil
      leaseExtensionStatus = .extended(requestID: requestID)
    }
    return true
  }

  public mutating func reconcileStopped(generationID: UUID?) {
    if let generationID,
      let knownGenerationID = (activeAppliedRequest ?? currentRequest)?.generationID,
      generationID != knownGenerationID
    {
      return
    }
    let requestID = pendingStopIntent?.requestID ?? UUID()
    activeAppliedRequest = nil
    pendingStopIntent = nil
    pendingLeaseExtension = nil
    leaseExtensionStatus = .idle
    cleanupStatus = .cleared
    stopStatus = .stopped(requestID: requestID)
    status = .stopped
  }

  private var currentRequest: ManualSimulationRequest? {
    switch status {
    case .applying(let request),
      .applied(let request),
      .appliedNotVerified(let request, _),
      .verified(let request, _),
      .failed(let request, _):
      request
    case .noSelection, .selected, .stopped:
      nil
    }
  }

  private mutating func replaceActiveRequest(with request: ManualSimulationRequest) {
    activeAppliedRequest = request
    switch status {
    case .applied:
      status = .applied(request)
    case .appliedNotVerified(_, let issue):
      status = .appliedNotVerified(request, issue)
    case .verified(_, let evidence):
      status = .verified(request, evidence)
    case .failed(_, let failure):
      status = .failed(request, failure)
    case .noSelection, .selected, .applying, .stopped:
      status = .applied(request)
    }
  }
}

private extension ManualSimulationRequest {
  func withLeaseExpiresAt(_ leaseExpiresAt: Date) -> ManualSimulationRequest {
    ManualSimulationRequest(
      requestID: requestID,
      generationID: generationID,
      location: location,
      requestedAt: requestedAt,
      requestedLeaseDuration: requestedLeaseDuration,
      leaseExpiresAt: leaseExpiresAt
    )
  }
}

public final class FileManualSimulationSessionStore: @unchecked Sendable {
  public static let fileEnvironmentKey = "PINSHIFT_APP_LIFECYCLE_FILE"

  public let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()

  public init(fileURL: URL, fileManager: FileManager = .default) {
    self.fileURL = fileURL
    self.fileManager = fileManager
  }

  public convenience init(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.init(fileURL: Self.defaultFileURL(environment: environment))
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
      .appendingPathComponent("AppLifecycle", isDirectory: true)
      .appendingPathComponent("session.json", isDirectory: false)
  }

  public func load() throws -> ManualSimulationSession? {
    try lock.withLock {
      guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
      let record = try Self.decoder().decode(
        PersistedSession.self,
        from: Data(contentsOf: fileURL)
      )
      guard record.schemaVersion == PersistedSession.currentSchemaVersion else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return record.session
    }
  }

  public func save(_ session: ManualSimulationSession) throws {
    try lock.withLock {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
      )
      let data = try Self.encoder().encode(PersistedSession(session: session))
      try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
      try fileManager.setAttributes(
        [.posixPermissions: 0o600],
        ofItemAtPath: fileURL.path
      )
    }
  }

  private struct PersistedSession: Codable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let session: ManualSimulationSession

    init(session: ManualSimulationSession) {
      schemaVersion = Self.currentSchemaVersion
      self.session = session
    }
  }

  private static func encoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .secondsSince1970
    return encoder
  }

  private static func decoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    return decoder
  }
}
