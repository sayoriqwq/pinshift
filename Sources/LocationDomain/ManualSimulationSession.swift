import Foundation

public struct ManualSimulationRequest: Codable, Equatable, Sendable {
  public let requestID: UUID
  public let location: SelectedLocation
  public let requestedAt: Date
  public let automaticClearAt: Date?

  public init(
    requestID: UUID,
    location: SelectedLocation,
    requestedAt: Date,
    automaticClearAt: Date? = nil
  ) {
    self.requestID = requestID
    self.location = location
    self.requestedAt = requestedAt
    self.automaticClearAt = automaticClearAt
  }

  public func withAutomaticClearAt(_ date: Date) -> ManualSimulationRequest {
    ManualSimulationRequest(
      requestID: requestID,
      location: location,
      requestedAt: requestedAt,
      automaticClearAt: date
    )
  }
}

public struct ManualSimulationClearRequest: Equatable, Sendable {
  public let requestID: UUID
  public let requestedAt: Date

  public init(
    requestID: UUID,
    requestedAt: Date
  ) {
    self.requestID = requestID
    self.requestedAt = requestedAt
  }
}

public enum ManualSimulationSessionError: String, Codable, Error, Equatable, Sendable {
  case noSelectedLocation
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

public enum ManualSimulationStatus: Equatable, Sendable {
  case noSelection
  case selected(SelectedLocation)
  case applying(ManualSimulationRequest)
  case applied(ManualSimulationRequest)
  case appliedNotVerified(ManualSimulationRequest, AppliedVerificationIssue)
  case verified(ManualSimulationRequest, ObservationMatchEvidence)
  case failed(ManualSimulationRequest, ManualSimulationFailure)
}

public enum ManualSimulationClearStatus: Equatable, Sendable {
  case idle
  case clearing(requestID: UUID)
  case cleared(requestID: UUID)
  case unconfirmed(requestID: UUID, ManualSimulationFailure)
}

public struct ManualSimulationSession: Equatable, Sendable {
  public private(set) var selected: SelectedLocation?
  public private(set) var latestObservation: LocationObservation?
  public private(set) var activeAppliedRequest: ManualSimulationRequest?
  public private(set) var status: ManualSimulationStatus = .noSelection
  public private(set) var clearStatus: ManualSimulationClearStatus = .idle
  public private(set) var currentClearRequest: ManualSimulationClearRequest?

  public init(selected: SelectedLocation? = nil) {
    self.selected = selected
    status = selected.map(ManualSimulationStatus.selected) ?? .noSelection
  }

  public mutating func select(latitude: String, longitude: String) throws {
    select(
      try SelectedLocation.parse(latitude: latitude, longitude: longitude)
    )
  }

  public mutating func select(_ location: SelectedLocation) {
    selected = location
    switch status {
    case .noSelection, .selected:
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
    at date: Date
  ) throws -> ManualSimulationRequest {
    guard let selected else {
      throw ManualSimulationSessionError.noSelectedLocation
    }
    let request = ManualSimulationRequest(
      requestID: requestID,
      location: selected,
      requestedAt: date
    )
    currentClearRequest = nil
    clearStatus = .idle
    status = .applying(request)
    return request
  }

  @discardableResult
  public mutating func acknowledgeApplied(
    requestID: UUID,
    automaticClearAt: Date
  ) -> Bool {
    guard case .applying(let request) = status, request.requestID == requestID else {
      return false
    }
    let acknowledged = request.withAutomaticClearAt(automaticClearAt)
    activeAppliedRequest = acknowledged
    status = .applied(acknowledged)
    return true
  }

  @discardableResult
  public mutating func fail(
    requestID: UUID,
    reason: ManualSimulationFailure
  ) -> Bool {
    guard case .applying(let request) = status, request.requestID == requestID else {
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

  public mutating func expireVerification(at date: Date) {
    let request: ManualSimulationRequest
    switch status {
    case .applied(let current), .appliedNotVerified(let current, _):
      request = current
    default:
      return
    }
    let elapsedSeconds = date.timeIntervalSince(request.requestedAt)
    guard elapsedSeconds > ObservationMatcher.maximumElapsedSeconds else { return }
    status = .appliedNotVerified(
      request,
      .timedOut(elapsedSeconds: elapsedSeconds)
    )
  }

  public mutating func beginClear(
    requestID: UUID,
    at date: Date = Date()
  ) -> ManualSimulationClearRequest {
    let request = ManualSimulationClearRequest(
      requestID: requestID,
      requestedAt: date
    )
    currentClearRequest = request
    clearStatus = .clearing(requestID: requestID)
    return request
  }

  @discardableResult
  public mutating func acknowledgeCleared(requestID: UUID) -> Bool {
    guard currentClearRequest?.requestID == requestID else { return false }
    activeAppliedRequest = nil
    currentClearRequest = nil
    clearStatus = .cleared(requestID: requestID)
    status = selected.map(ManualSimulationStatus.selected) ?? .noSelection
    return true
  }

  @discardableResult
  public mutating func failClear(
    requestID: UUID,
    reason: ManualSimulationFailure
  ) -> Bool {
    guard currentClearRequest?.requestID == requestID else { return false }
    currentClearRequest = nil
    clearStatus = .unconfirmed(requestID: requestID, reason)
    return true
  }

  public mutating func replaceWithControllerSnapshot(
    _ snapshot: ManualSimulationControllerSnapshot,
    at date: Date = Date()
  ) {
    if case .applying = status {
      return
    }
    guard currentClearRequest == nil else {
      return
    }

    switch snapshot {
    case .idle:
      activeAppliedRequest = nil
      if case .cleared = clearStatus {
        // Clear feedback is deliberately transient and local. Repeated idle
        // snapshots must not make it disappear before the user can see it.
      } else {
        clearStatus = .idle
      }
      status = selected.map(ManualSimulationStatus.selected) ?? .noSelection
    case .active(let operationID, let location, let automaticClearAt):
      let existing = activeAppliedRequest
      let isSameOperation = existing?.requestID == operationID
      let request = ManualSimulationRequest(
        requestID: operationID,
        location: location,
        requestedAt: isSameOperation ? existing?.requestedAt ?? date : date,
        automaticClearAt: automaticClearAt
      )
      activeAppliedRequest = request
      status = statusPreservingLocalEvidence(for: request)
      if !isSameOperation { clearStatus = .idle }
    case .uncertain(let operationID, let location, let automaticClearAt):
      // The coordinate identifies an attempted Apply, not an execution receipt.
      // Keep A as last confirmed, and never let an observation verify unknown B.
      if let location {
        let request = ManualSimulationRequest(
          requestID: operationID,
          location: location,
          requestedAt: date,
          automaticClearAt: automaticClearAt
        )
        status = .failed(request, .controllerUnavailable)
      } else {
        status = selected.map(ManualSimulationStatus.selected) ?? .noSelection
      }
      clearStatus = .idle
    case .clearPending(let operationID, _, _):
      // This may follow a timed-out Apply or a clear with no tracked operation.
      // Its coordinate cannot manufacture an Applied Simulation after restart.
      if activeAppliedRequest == nil {
        status = selected.map(ManualSimulationStatus.selected) ?? .noSelection
      }
      if case .unconfirmed = clearStatus {
        // Preserve the request that produced the visible failure.
      } else {
        clearStatus = .unconfirmed(
          requestID: operationID,
          .requestRejected(stableCode: "clearPending")
        )
      }
    }
  }

  private func statusPreservingLocalEvidence(
    for request: ManualSimulationRequest
  ) -> ManualSimulationStatus {
    switch status {
    case .verified(let existing, let evidence)
    where existing.requestID == request.requestID:
      return .verified(request, evidence)
    case .appliedNotVerified(let existing, let issue)
    where existing.requestID == request.requestID:
      return .appliedNotVerified(request, issue)
    case .applied(let existing) where existing.requestID == request.requestID:
      return .applied(request)
    case .noSelection, .selected, .applying, .applied, .appliedNotVerified,
      .verified, .failed:
      return .applied(request)
    }
  }
}

public enum ManualSimulationControllerSnapshot: Equatable, Sendable {
  case idle
  case active(operationID: UUID, location: SelectedLocation, automaticClearAt: Date)
  case uncertain(operationID: UUID, location: SelectedLocation?, automaticClearAt: Date)
  case clearPending(operationID: UUID, location: SelectedLocation?, automaticClearAt: Date?)
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
      let data = try Data(contentsOf: fileURL)
      let current = try JSONDecoder().decode(PersistedSelection.self, from: data)
      guard current.schemaVersion == PersistedSelection.currentSchemaVersion else {
        throw CocoaError(.fileReadCorruptFile)
      }
      return ManualSimulationSession(selected: current.selected)
    }
  }

  public func save(_ session: ManualSimulationSession) throws {
    try lock.withLock {
      try writeSelection(session)
    }
  }

  private func writeSelection(_ session: ManualSimulationSession) throws {
    try fileManager.createDirectory(
      at: fileURL.deletingLastPathComponent(),
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700]
    )
    let data = try JSONEncoder().encode(PersistedSelection(selected: session.selected))
    try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUnlessOpen])
    try fileManager.setAttributes(
      [.posixPermissions: 0o600],
      ofItemAtPath: fileURL.path
    )
  }

  private struct PersistedSelection: Codable {
    static let currentSchemaVersion = 3
    let schemaVersion: Int
    let selected: SelectedLocation?

    init(selected: SelectedLocation?) {
      schemaVersion = Self.currentSchemaVersion
      self.selected = selected
    }
  }

}
