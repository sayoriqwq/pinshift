import Foundation
import LocationDomain
import SimulationController
import SimulationDiagnostics

public enum ControllerCLICommand: Equatable, Sendable {
  case status
  case apply(latitude: String, longitude: String, requestID: UUID)
  case clear(requestID: UUID)
  case reset(requestID: UUID)
}

public struct ControllerCLIResult: Equatable, Sendable {
  public let exitCode: Int32
  public let output: String

  public init(exitCode: Int32, output: String) {
    self.exitCode = exitCode
    self.output = output
  }
}

public struct ControllerCLIRunner: Sendable {
  private let controller: SimulationController
  private let diagnostics: SimulationDiagnosticRecorder?

  public init(
    controller: SimulationController,
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) {
    self.controller = controller
    self.diagnostics = diagnostics
  }

  public func run(_ command: ControllerCLICommand) async -> ControllerCLIResult {
    await diagnostics?.record(
      kind: "controller.cli.command.started",
      requestID: commandRequestID(command),
      fields: commandFields(command)
    )
    let result: ControllerCLIResult
    switch command {
    case .status:
      result = await status()
    case .apply(let latitude, let longitude, let requestID):
      result = await apply(latitude: latitude, longitude: longitude, requestID: requestID)
    case .clear(let requestID), .reset(let requestID):
      result = await clear(requestID: requestID)
    }
    await diagnostics?.record(
      kind: "controller.cli.command.finished",
      requestID: commandRequestID(command),
      fields: [
        "exitCode": .integer(Int64(result.exitCode)),
        "outcome": .text(result.exitCode == 0 ? "success" : "failed"),
      ]
    )
    return result
  }

  private func status() async -> ControllerCLIResult {
    let snapshot = await controller.snapshot()
    switch snapshot.simulation {
    case .idle:
      switch snapshot.readiness {
      case .ready:
        return ControllerCLIResult(
          exitCode: 0,
          output: "No Simulated Location is active; the Injection Backend is ready."
        )
      case .unavailable(let reason):
        return failure(reason)
      }
    case .active(let operationID, let location, let automaticClearAt):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Temporary Simulated Location \(operationID.uuidString) is active at "
          + "\(format(location)) and will clear automatically at "
          + "\(automaticClearAt.formatted(.iso8601))."
      )
    case .uncertain(let operationID, _, let automaticClearAt, let reason),
      .clearPending(let operationID, _, let automaticClearAt, let reason):
      let suffix = reason.map { " Last result: \($0.rawValue)." } ?? ""
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Temporary Simulated Location \(operationID.uuidString) is pending automatic "
          + "clear at or after \(automaticClearAt.formatted(.iso8601)).\(suffix)"
      )
    }
  }

  private func apply(
    latitude: String,
    longitude: String,
    requestID: UUID
  ) async -> ControllerCLIResult {
    let location: SelectedLocation
    do {
      location = try SelectedLocation.parse(latitude: latitude, longitude: longitude)
    } catch let error as LocalizedError {
      return ControllerCLIResult(
        exitCode: 2,
        output: error.errorDescription ?? "The coordinate is invalid."
      )
    } catch {
      return ControllerCLIResult(exitCode: 2, output: "The coordinate is invalid.")
    }

    switch await controller.apply(location, requestID: requestID) {
    case .applied(let responseID, let appliedLocation, let automaticClearAt):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Temporary Simulated Location acknowledged for request "
          + "\(responseID.uuidString) at \(format(appliedLocation)); automatic clear is "
          + "armed for \(automaticClearAt.formatted(.iso8601))."
      )
    case .failed(_, let reason):
      return failure(reason)
    }
  }

  private func clear(requestID: UUID) async -> ControllerCLIResult {
    switch await controller.clear(requestID: requestID) {
    case .cleared(let responseID):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Simulated Location cleared for request \(responseID.uuidString). A fresh "
          + "physical location callback is not guaranteed immediately."
      )
    case .failed(_, let reason):
      return failure(reason)
    }
  }

  private func failure(_ reason: InjectionBackendFailure) -> ControllerCLIResult {
    let message: String
    switch reason {
    case .noActiveDevice:
      message = "No Active Test Device is configured. Pass --device or set PINSHIFT_DEVICE."
    case .sessionNotReady:
      message = "The Xcode device workflow is not ready. Run pinshift-controller doctor."
    case .backendUnavailable:
      message = "The Injection Backend is unavailable. Run pinshift-controller doctor."
    case .timedOut:
      message = "The Injection Backend timed out before acknowledging the request."
    case .authenticationFailed:
      message = "The controller rejected the request. Re-pair and retry."
    case .clearFailed:
      message = "The Injection Backend could not clear the Simulated Location."
    case .deviceMismatch:
      message = "The retained automatic clear belongs to another Active Test Device."
    }
    return ControllerCLIResult(exitCode: 1, output: message)
  }

  private func commandFields(_ command: ControllerCLICommand) -> SimulationDiagnosticFields {
    switch command {
    case .status:
      return ["command": .text("status")]
    case .apply(let latitude, let longitude, _):
      return [
        "command": .text("apply"),
        "latitude": .text(latitude),
        "longitude": .text(longitude),
      ]
    case .clear:
      return ["command": .text("clear")]
    case .reset:
      return ["command": .text("reset")]
    }
  }

  private func commandRequestID(_ command: ControllerCLICommand) -> UUID? {
    switch command {
    case .status:
      nil
    case .apply(_, _, let requestID), .clear(let requestID), .reset(let requestID):
      requestID
    }
  }

  private func format(_ location: SelectedLocation) -> String {
    String(format: "%.6f, %.6f", location.latitude, location.longitude)
  }
}
