import Foundation

public enum ControllerCommand: Equatable, Sendable {
  case status(requestID: UUID)
  case lifecycleStatus(requestID: UUID)
  case apply(requestID: UUID, latitude: Double, longitude: Double)
  case applyLifecycle(
    requestID: UUID,
    generationID: UUID,
    latitude: Double,
    longitude: Double,
    requestedLeaseDuration: TimeInterval
  )
  case extendLifecycle(
    requestID: UUID,
    generationID: UUID,
    extensionDuration: TimeInterval
  )
  case stop(requestID: UUID)
  case stopLifecycle(requestID: UUID, generationID: UUID?)

  public var requestID: UUID {
    switch self {
    case .status(let requestID),
      .lifecycleStatus(let requestID),
      .apply(let requestID, _, _),
      .applyLifecycle(let requestID, _, _, _, _),
      .extendLifecycle(let requestID, _, _),
      .stop(let requestID),
      .stopLifecycle(let requestID, _):
      requestID
    }
  }
}

public enum ControllerBackendReadiness: Codable, Equatable, Sendable {
  case ready
  case unavailable(ControllerCommandFailure)
}

public enum ControllerCleanupReadiness: Codable, Equatable, Sendable {
  case ready
  case unavailable(ControllerCommandFailure)
  case unsupportedController
}

public enum ControllerSimulationLifecycleState: Codable, Equatable, Sendable {
  case noActive
  case applyUncertain(generationID: UUID)
  case applied(generationID: UUID, leaseExpiresAt: Date)
  case cleanupPending(
    generationID: UUID,
    requestID: UUID,
    reason: ControllerCommandFailure?
  )
  case stopped(generationID: UUID?)
  case deviceMismatch(generationID: UUID)
}

public struct ControllerLifecycleStatus: Codable, Equatable, Sendable {
  public let readiness: ControllerBackendReadiness
  public let cleanupReadiness: ControllerCleanupReadiness
  public let simulation: ControllerSimulationLifecycleState

  public init(
    readiness: ControllerBackendReadiness,
    cleanupReadiness: ControllerCleanupReadiness = .ready,
    simulation: ControllerSimulationLifecycleState
  ) {
    self.readiness = readiness
    self.cleanupReadiness = cleanupReadiness
    self.simulation = simulation
  }

  private enum CodingKeys: String, CodingKey {
    case readiness
    case cleanupReadiness
    case simulation
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    readiness = try container.decode(ControllerBackendReadiness.self, forKey: .readiness)
    cleanupReadiness =
      try container.decodeIfPresent(
        ControllerCleanupReadiness.self,
        forKey: .cleanupReadiness
      ) ?? .unsupportedController
    simulation = try container.decode(
      ControllerSimulationLifecycleState.self,
      forKey: .simulation
    )
  }
}

public enum ControllerCommandFailure: String, Codable, Error, Equatable, Sendable {
  case invalidCoordinate
  case noActiveDevice
  case sessionNotReady
  case backendUnavailable
  case timedOut
  case authenticationFailed
  case clearFailed
  case controllerUnavailable
  case responseIdentityMismatch
  case deviceMismatch
  case generationMismatch
  case invalidLeaseDuration
  case cleanupGuardianUnavailable
  case controllerUpgradeRequired
}

public enum ControllerCommandResult: Equatable, Sendable {
  case ready(requestID: UUID)
  case lifecycleStatus(requestID: UUID, status: ControllerLifecycleStatus)
  case applied(requestID: UUID)
  case appliedLifecycle(requestID: UUID, generationID: UUID, leaseExpiresAt: Date)
  case extendedLifecycle(requestID: UUID, generationID: UUID, leaseExpiresAt: Date)
  case stopped(requestID: UUID)
  case stoppedLifecycle(requestID: UUID, generationID: UUID?)
  case failed(requestID: UUID, reason: ControllerCommandFailure)

  public var requestID: UUID {
    switch self {
    case .ready(let requestID),
      .lifecycleStatus(let requestID, _),
      .applied(let requestID),
      .appliedLifecycle(let requestID, _, _),
      .extendedLifecycle(let requestID, _, _),
      .stopped(let requestID),
      .stoppedLifecycle(let requestID, _),
      .failed(let requestID, _):
      requestID
    }
  }
}

public protocol ControllerCommandHandling: Sendable {
  func handle(_ command: ControllerCommand) async -> ControllerCommandResult
}

public struct UnavailableControllerCommandHandler: ControllerCommandHandling {
  public init() {}

  public func handle(_ command: ControllerCommand) -> ControllerCommandResult {
    .failed(requestID: command.requestID, reason: .backendUnavailable)
  }
}
