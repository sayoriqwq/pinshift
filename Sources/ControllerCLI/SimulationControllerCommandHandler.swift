import ControllerLink
import Foundation
import LocationDomain
import SimulationController
import SimulationDiagnostics

public struct SimulationControllerCommandHandler: ControllerCommandHandling {
  private let controller: SimulationController
  private let diagnostics: SimulationDiagnosticRecorder?

  public init(
    controller: SimulationController,
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) {
    self.controller = controller
    self.diagnostics = diagnostics
  }

  public func handle(_ command: ControllerCommand) async -> ControllerCommandResult {
    await diagnostics?.record(
      kind: "controller.link.command.received",
      requestID: command.requestID,
      fields: commandFields(command)
    )
    let result: ControllerCommandResult
    switch command {
    case .status(let requestID):
      result = .status(
        requestID: requestID,
        status: map(await controller.snapshot())
      )

    case .apply(let requestID, let latitude, let longitude):
      let location: SelectedLocation
      do {
        location = try SelectedLocation(latitude: latitude, longitude: longitude)
      } catch {
        result = .failed(requestID: requestID, reason: .invalidCoordinate)
        break
      }
      switch await controller.apply(location, requestID: requestID) {
      case .applied(let responseID, _, let automaticClearAt):
        result = .applied(
          requestID: responseID,
          automaticClearAt: automaticClearAt
        )
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }

    case .clear(let requestID, let targetOperationID):
      switch await controller.clear(
        requestID: requestID,
        targetOperationID: targetOperationID
      ) {
      case .cleared(let responseID):
        result = .cleared(requestID: responseID)
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }
    }
    await diagnostics?.record(
      kind: "controller.link.command.completed",
      requestID: result.requestID,
      fields: resultFields(result)
    )
    return result
  }

  private func map(_ snapshot: TemporarySimulationSnapshot) -> ControllerStatus {
    let readiness: ControllerBackendReadiness
    switch snapshot.readiness {
    case .ready:
      readiness = .ready
    case .unavailable(let reason):
      readiness = .unavailable(map(reason))
    }
    let simulation: ControllerSimulationState
    switch snapshot.simulation {
    case .idle:
      simulation = .idle
    case .active(let operationID, let location, let automaticClearAt):
      simulation = .active(
        operationID: operationID,
        latitude: location.latitude,
        longitude: location.longitude,
        automaticClearAt: automaticClearAt
      )
    case .uncertain(
      let operationID,
      let location,
      let automaticClearAt,
      let reason
    ):
      simulation = .uncertain(
        operationID: operationID,
        latitude: location?.latitude,
        longitude: location?.longitude,
        automaticClearAt: automaticClearAt,
        reason: reason.map(map)
      )
    case .clearPending(
      let operationID,
      let location,
      let automaticClearAt,
      let reason
    ):
      simulation = .clearPending(
        operationID: operationID,
        latitude: location?.latitude,
        longitude: location?.longitude,
        automaticClearAt: automaticClearAt,
        reason: reason.map(map)
      )
    }
    return ControllerStatus(readiness: readiness, simulation: simulation)
  }

  private func map(_ failure: InjectionBackendFailure) -> ControllerCommandFailure {
    switch failure {
    case .noActiveDevice:
      .noActiveDevice
    case .sessionNotReady:
      .sessionNotReady
    case .backendUnavailable:
      .backendUnavailable
    case .timedOut:
      .timedOut
    case .authenticationFailed:
      .authenticationFailed
    case .clearFailed:
      .clearFailed
    case .deviceMismatch:
      .deviceMismatch
    }
  }

  private func commandFields(_ command: ControllerCommand) -> SimulationDiagnosticFields {
    switch command {
    case .status:
      return ["command": .text("status")]
    case .apply(_, let latitude, let longitude):
      return [
        "command": .text("apply"),
        "latitude": .number(latitude),
        "longitude": .number(longitude),
      ]
    case .clear:
      return ["command": .text("clear")]
    }
  }

  private func resultFields(_ result: ControllerCommandResult) -> SimulationDiagnosticFields {
    switch result {
    case .status(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .applied(_, let automaticClearAt):
      return [
        "outcome": .text("applied"),
        "automaticClearAt": .date(automaticClearAt),
      ]
    case .cleared:
      return ["outcome": .text("cleared")]
    case .failed(_, let reason):
      return ["outcome": .text("failed"), "reason": .text(reason.rawValue)]
    }
  }
}
