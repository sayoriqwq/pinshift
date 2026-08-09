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
    await record(
      kind: "controller.link.command.received",
      requestID: command.requestID,
      fields: commandFields(command)
    )
    let result: ControllerCommandResult
    switch command {
    case .status(let requestID):
      switch await controller.status() {
      case .ready, .applied, .stopped:
        result = .ready(requestID: requestID)
      case .unavailable(let reason), .failed(_, let reason):
        result = .failed(requestID: requestID, reason: map(reason))
      }

    case .lifecycleStatus(let requestID):
      result = .lifecycleStatus(
        requestID: requestID,
        status: await map(await controller.lifecycleSnapshot())
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
      case .applied(let responseID, _):
        result = .applied(requestID: responseID)
      case .cleared(let responseID):
        result = .failed(requestID: responseID, reason: .backendUnavailable)
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }

    case .applyLifecycle(
      let requestID,
      let generationID,
      let latitude,
      let longitude,
      let requestedLeaseDuration
    ):
      let location: SelectedLocation
      do {
        location = try SelectedLocation(latitude: latitude, longitude: longitude)
      } catch {
        result = .failed(requestID: requestID, reason: .invalidCoordinate)
        break
      }

      switch await controller.apply(
        location,
        requestID: requestID,
        generationID: generationID,
        requestedLeaseDuration: requestedLeaseDuration
      ) {
      case .applied(let responseID, _):
        let snapshot = await controller.lifecycleSnapshot()
        if case .applied(let responseGenerationID, let leaseExpiresAt) = snapshot.state {
          result = .appliedLifecycle(
            requestID: responseID,
            generationID: responseGenerationID,
            leaseExpiresAt: leaseExpiresAt
          )
        } else {
          result = .failed(requestID: responseID, reason: .backendUnavailable)
        }
      case .cleared(let responseID):
        result = .failed(requestID: responseID, reason: .backendUnavailable)
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }

    case .extendLifecycle(
      let requestID,
      let generationID,
      let extensionDuration
    ):
      switch await controller.extendLease(
        requestID: requestID,
        generationID: generationID,
        extensionDuration: extensionDuration
      ) {
      case .extended(let responseID, let responseGenerationID, let leaseExpiresAt):
        result = .extendedLifecycle(
          requestID: responseID,
          generationID: responseGenerationID,
          leaseExpiresAt: leaseExpiresAt
        )
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }

    case .stop(let requestID):
      switch await controller.stop(requestID: requestID) {
      case .cleared(let responseID):
        result = .stopped(requestID: responseID)
      case .applied(let responseID, _):
        result = .failed(requestID: responseID, reason: .clearFailed)
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }

    case .stopLifecycle(let requestID, let generationID):
      switch await controller.stop(
        requestID: requestID,
        generationID: generationID
      ) {
      case .cleared(let responseID):
        result = .stoppedLifecycle(
          requestID: responseID,
          generationID: generationID
        )
      case .applied(let responseID, _):
        result = .failed(requestID: responseID, reason: .clearFailed)
      case .failed(let responseID, let reason):
        result = .failed(requestID: responseID, reason: map(reason))
      }
    }
    await record(
      kind: "controller.link.command.completed",
      requestID: result.requestID,
      fields: resultFields(result)
    )
    return result
  }

  private func record(
    kind: String,
    requestID: UUID,
    fields: SimulationDiagnosticFields
  ) async {
    guard let diagnostics else { return }
    await diagnostics.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func commandFields(_ command: ControllerCommand) -> SimulationDiagnosticFields {
    switch command {
    case .status:
      return ["command": .text("status")]
    case .lifecycleStatus:
      return ["command": .text("lifecycle-status")]
    case .apply(_, let latitude, let longitude):
      return [
        "command": .text("apply"),
        "latitude": .number(latitude),
        "longitude": .number(longitude),
      ]
    case .applyLifecycle(
      _,
      let generationID,
      let latitude,
      let longitude,
      let requestedLeaseDuration
    ):
      return [
        "command": .text("apply"),
        "generationID": .text(generationID.uuidString),
        "latitude": .number(latitude),
        "longitude": .number(longitude),
        "requestedLeaseDuration": .number(requestedLeaseDuration),
      ]
    case .extendLifecycle(_, let generationID, let extensionDuration):
      return [
        "command": .text("extend-lease"),
        "generationID": .text(generationID.uuidString),
        "extensionDuration": .number(extensionDuration),
      ]
    case .stop:
      return ["command": .text("stop")]
    case .stopLifecycle(_, let generationID):
      var fields: SimulationDiagnosticFields = ["command": .text("stop")]
      if let generationID {
        fields["generationID"] = .text(generationID.uuidString)
      }
      return fields
    }
  }

  private func resultFields(_ result: ControllerCommandResult) -> SimulationDiagnosticFields {
    switch result {
    case .ready:
      return ["outcome": .text("ready")]
    case .lifecycleStatus(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .applied:
      return ["outcome": .text("applied")]
    case .appliedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("applied"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .extendedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("extended"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .stopped:
      return ["outcome": .text("stopped")]
    case .stoppedLifecycle(_, let generationID):
      var fields: SimulationDiagnosticFields = ["outcome": .text("stopped")]
      if let generationID {
        fields["generationID"] = .text(generationID.uuidString)
      }
      return fields
    case .failed(_, let reason):
      return [
        "outcome": .text("failed"),
        "reason": .text(reason.rawValue),
      ]
    }
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
    case .generationMismatch:
      .generationMismatch
    case .invalidLeaseDuration:
      .invalidLeaseDuration
    case .cleanupGuardianUnavailable:
      .cleanupGuardianUnavailable
    }
  }

  private func map(
    _ snapshot: SimulationLifecycleSnapshot
  ) async -> ControllerLifecycleStatus {
    let readiness: ControllerBackendReadiness
    switch snapshot.readiness {
    case .ready:
      readiness = .ready
    case .unavailable(let reason):
      readiness = .unavailable(map(reason))
    }
    let simulation: ControllerSimulationLifecycleState
    switch snapshot.state {
    case .noActive:
      simulation = .noActive
    case .applyUncertain(let generationID):
      simulation = .applyUncertain(generationID: generationID)
    case .applied(let generationID, let leaseExpiresAt):
      simulation = .applied(
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
    case .cleanupPending(let generationID, let requestID, let reason):
      simulation = .cleanupPending(
        generationID: generationID,
        requestID: requestID,
        reason: reason.map(map)
      )
    case .stopped(let generationID):
      simulation = .stopped(generationID: generationID)
    case .deviceMismatch(let generationID):
      simulation = .deviceMismatch(generationID: generationID)
    }
    let cleanupReadiness: ControllerCleanupReadiness
    switch snapshot.cleanupReadiness {
    case .ready:
      cleanupReadiness = .ready
    case .unavailable(let reason):
      cleanupReadiness = .unavailable(map(reason))
    }
    return ControllerLifecycleStatus(
      readiness: readiness,
      cleanupReadiness: cleanupReadiness,
      simulation: simulation
    )
  }
}
