import Foundation
import LocationDomain
import SimulationController
import SimulationDiagnostics

public enum ControllerCLICommand: Equatable, Sendable {
  case status
  case apply(latitude: String, longitude: String, requestID: UUID)
  case stop(requestID: UUID)
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
    if case .reset = command {
      await diagnostics?.record(
        kind: "controller.reset.requested",
        requestID: commandRequestID(command)
      )
    }
    let result: ControllerCLIResult
    switch command {
    case .status:
      result = await status()
    case .apply(let latitude, let longitude, let requestID):
      result = await apply(latitude: latitude, longitude: longitude, requestID: requestID)
    case .stop(let requestID):
      result = await stop(requestID: requestID)
    case .reset(let requestID):
      result = await reset(requestID: requestID)
    }
    await diagnostics?.record(
      kind: "controller.cli.command.finished",
      requestID: commandRequestID(command),
      fields: [
        "exitCode": .integer(Int64(result.exitCode)),
        "outcome": .text(result.exitCode == 0 ? "success" : "failed"),
      ]
    )
    if case .reset = command {
      await diagnostics?.record(
        kind: "controller.reset.completed",
        requestID: commandRequestID(command),
        fields: [
          "outcome": .text(result.exitCode == 0 ? "success" : "failed"),
          "exitCode": .integer(Int64(result.exitCode)),
        ]
      )
    }
    return result
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
    case .stop:
      return ["command": .text("stop")]
    case .reset:
      return ["command": .text("reset")]
    }
  }

  private func commandRequestID(_ command: ControllerCLICommand) -> UUID? {
    switch command {
    case .status:
      nil
    case .apply(_, _, let requestID), .stop(let requestID), .reset(let requestID):
      requestID
    }
  }

  private func status() async -> ControllerCLIResult {
    switch await controller.status() {
    case .ready:
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "The Active Test Device and Xcode/devicectl Injection Backend are ready. Applied and Verified state is reported by the active Controller Link and Pinshift app."
      )
    case .applied(let requestID, let location):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Applied Simulation is active for request \(requestID.uuidString) at \(format(location)). Pinshift app verification is separate."
      )
    case .stopped:
      return ControllerCLIResult(exitCode: 0, output: "No Applied Simulation is active.")
    case .unavailable(let reason), .failed(_, let reason):
      return failure(reason)
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
    case .applied(let responseID, let appliedLocation):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Applied Simulation acknowledged for request \(responseID.uuidString) at \(format(appliedLocation)). Pinshift app verification is still required."
      )
    case .cleared:
      return ControllerCLIResult(
        exitCode: 1,
        output: "Injection Backend returned an unexpected clear result for an apply request."
      )
    case .failed(_, let reason):
      return failure(reason)
    }
  }

  private func stop(requestID: UUID) async -> ControllerCLIResult {
    switch await controller.stop(requestID: requestID) {
    case .cleared(let responseID):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Stopped Simulation acknowledged for request \(responseID.uuidString). A fresh physical location callback is not guaranteed."
      )
    case .applied:
      return ControllerCLIResult(
        exitCode: 1,
        output: "Injection Backend did not clear the active simulation."
      )
    case .failed(_, let reason):
      return failure(reason)
    }
  }

  private func reset(requestID: UUID) async -> ControllerCLIResult {
    switch await controller.stop(requestID: requestID) {
    case .cleared(let responseID):
      return ControllerCLIResult(
        exitCode: 0,
        output:
          "Reset completed for request \(responseID.uuidString). Repeating reset is safe; a fresh physical location callback is not guaranteed."
      )
    case .applied:
      return ControllerCLIResult(
        exitCode: 1,
        output: "Injection Backend did not clear the active simulation during reset."
      )
    case .failed(_, let reason):
      return failure(reason)
    }
  }

  private func failure(_ reason: InjectionBackendFailure) -> ControllerCLIResult {
    let message: String
    switch reason {
    case .noActiveDevice:
      message =
        "No Active Test Device is configured. Pass --device or set REMOTE_LOCATION_DEVICE."
    case .sessionNotReady:
      message =
        "The Xcode device workflow is not ready. Run `remote-location-controller doctor`, resolve the reported device check, and retry."
    case .backendUnavailable:
      message =
        "The Injection Backend is unavailable. Run `remote-location-controller doctor`, resolve the reported Xcode or device check, and retry."
    case .timedOut:
      message = "The Injection Backend timed out before acknowledging the request."
    case .authenticationFailed:
      message =
        "The controller rejected the request. Re-pair the Pinshift app with the active Controller Link and retry."
    case .clearFailed:
      message =
        "The Injection Backend could not clear the active simulation. Run reset after checking the device connection."
    case .deviceMismatch:
      message =
        "The pending cleanup belongs to a different Active Test Device. Restore that device selection before retrying."
    case .generationMismatch:
      message =
        "The Stop request targets an older simulation generation. Refresh lifecycle status before retrying."
    case .invalidLeaseDuration:
      message = "Choose a Simulation Lease of 15, 30, or 60 minutes and retry."
    case .cleanupGuardianUnavailable:
      message =
        "Cleanup Guardian protection is unavailable. Run rl-install, wait for the LaunchAgent to become healthy, and retry."
    }
    return ControllerCLIResult(exitCode: 1, output: message)
  }

  private func format(_ location: SelectedLocation) -> String {
    String(format: "%.6f, %.6f", location.latitude, location.longitude)
  }
}
