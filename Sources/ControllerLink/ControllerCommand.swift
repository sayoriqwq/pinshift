import Foundation

public enum ControllerCommand: Equatable, Sendable {
  case status(requestID: UUID)
  case apply(requestID: UUID, latitude: Double, longitude: Double)
  case clear(requestID: UUID)

  public var requestID: UUID {
    switch self {
    case .status(let requestID),
      .apply(let requestID, _, _),
      .clear(let requestID):
      requestID
    }
  }
}

public enum ControllerBackendReadiness: Codable, Equatable, Sendable {
  case ready
  case unavailable(ControllerCommandFailure)
}

public enum ControllerSimulationState: Codable, Equatable, Sendable {
  case idle
  case active(
    operationID: UUID,
    latitude: Double,
    longitude: Double,
    automaticClearAt: Date
  )
  case uncertain(
    operationID: UUID,
    latitude: Double?,
    longitude: Double?,
    automaticClearAt: Date,
    reason: ControllerCommandFailure?
  )
  case clearPending(
    operationID: UUID,
    latitude: Double?,
    longitude: Double?,
    automaticClearAt: Date?,
    reason: ControllerCommandFailure?
  )
}

public struct ControllerStatus: Codable, Equatable, Sendable {
  public let readiness: ControllerBackendReadiness
  public let simulation: ControllerSimulationState

  public init(
    readiness: ControllerBackendReadiness,
    simulation: ControllerSimulationState
  ) {
    self.readiness = readiness
    self.simulation = simulation
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
}

public enum ControllerCommandResult: Equatable, Sendable {
  case status(requestID: UUID, status: ControllerStatus)
  case applied(requestID: UUID, automaticClearAt: Date)
  case cleared(requestID: UUID)
  case failed(requestID: UUID, reason: ControllerCommandFailure)

  public var requestID: UUID {
    switch self {
    case .status(let requestID, _),
      .applied(let requestID, _),
      .cleared(let requestID),
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
