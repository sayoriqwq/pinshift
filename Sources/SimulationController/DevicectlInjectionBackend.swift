import Darwin
import Foundation
import LocationDomain
import SimulationDiagnostics

public struct DevicectlCommandInvocation: Equatable, Sendable {
  public let arguments: [String]
  public let environmentOverrides: [String: String]
  public let timeoutSeconds: TimeInterval

  public init(
    arguments: [String],
    environmentOverrides: [String: String],
    timeoutSeconds: TimeInterval = 15
  ) {
    self.arguments = arguments
    self.environmentOverrides = environmentOverrides
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct DevicectlCommandExecutionDetails: Equatable, Sendable {
  public let launchSucceeded: Bool
  public let exitStatus: Int32?
  public let duration: TimeInterval
  public let standardOutput: String
  public let standardError: String

  public init(
    launchSucceeded: Bool,
    exitStatus: Int32?,
    duration: TimeInterval,
    standardOutput: String = "",
    standardError: String = ""
  ) {
    self.launchSucceeded = launchSucceeded
    self.exitStatus = exitStatus
    self.duration = duration
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

public enum DevicectlCommandExecutionResult: Equatable, Sendable {
  case completed(DevicectlCommandExecutionDetails)
  case timedOut(DevicectlCommandExecutionDetails)
  case launchFailed(DevicectlCommandExecutionDetails)
}

public protocol DevicectlCommandExecuting: Sendable {
  func execute(
    _ invocation: DevicectlCommandInvocation
  ) -> DevicectlCommandExecutionResult
}

public struct FoundationDevicectlCommandExecutor: DevicectlCommandExecuting {
  private static let inheritedEnvironmentKeys = [
    "HOME", "TMPDIR", "USER", "LOGNAME", "PATH", "LANG", "LC_ALL", "LC_CTYPE",
  ]

  private let executableURL: URL

  public init() {
    self.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
  }

  init(executableURL: URL) {
    self.executableURL = executableURL
  }

  static func sanitizedEnvironment(
    inherited: [String: String],
    overrides: [String: String]
  ) -> [String: String] {
    var environment: [String: String] = [:]
    for key in inheritedEnvironmentKeys {
      if let value = inherited[key] {
        environment[key] = value
      }
    }
    environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin"
    for (key, value) in overrides {
      environment[key] = value
    }
    return environment
  }

  public func execute(
    _ invocation: DevicectlCommandInvocation
  ) -> DevicectlCommandExecutionResult {
    let startedAt = Date()
    let process = Process()
    process.executableURL = executableURL
    process.arguments = invocation.arguments

    process.environment = Self.sanitizedEnvironment(
      inherited: ProcessInfo.processInfo.environment,
      overrides: invocation.environmentOverrides
    )

    let standardOutput = Pipe()
    let standardError = Pipe()
    process.standardOutput = standardOutput
    process.standardError = standardError

    do {
      try process.run()
    } catch {
      return .launchFailed(
        DevicectlCommandExecutionDetails(
          launchSucceeded: false,
          exitStatus: nil,
          duration: Date().timeIntervalSince(startedAt),
          standardError: String(describing: error)
        )
      )
    }

    let outputData = LockedData()
    let errorData = LockedData()
    let readers = DispatchGroup()
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      outputData.replace(standardOutput.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }
    readers.enter()
    DispatchQueue.global(qos: .utility).async {
      errorData.replace(standardError.fileHandleForReading.readDataToEndOfFile())
      readers.leave()
    }

    let waiter = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in waiter.signal() }

    let timeout = max(0.001, invocation.timeoutSeconds)
    let timedOut = waiter.wait(timeout: .now() + timeout) == .timedOut
    if timedOut {
      process.terminate()
      if waiter.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
        kill(process.processIdentifier, SIGKILL)
        _ = waiter.wait(timeout: .now() + 0.2)
      }
    }
    // A subprocess may leave a descendant holding either inherited pipe open.
    // Drain only for a bounded interval, then close our read ends so this call
    // returns its timeout result instead of waiting for that descendant.
    if readers.wait(timeout: .now() + 0.2) == .timedOut {
      try? standardOutput.fileHandleForReading.close()
      try? standardError.fileHandleForReading.close()
      _ = readers.wait(timeout: .now() + 0.2)
    }

    let details = DevicectlCommandExecutionDetails(
      launchSucceeded: true,
      exitStatus: process.isRunning ? nil : process.terminationStatus,
      duration: Date().timeIntervalSince(startedAt),
      standardOutput: String(
        data: outputData.value(),
        encoding: .utf8
      ) ?? "",
      standardError: String(
        data: errorData.value(),
        encoding: .utf8
      ) ?? ""
    )
    return timedOut ? .timedOut(details) : .completed(details)
  }
}

public actor DevicectlInjectionBackend: InjectionBackend {
  private static let timeoutSeconds = "15"

  private let device: String
  private let developerDirectory: String
  private let executor: any DevicectlCommandExecuting
  private let diagnostics: SimulationDiagnosticRecorder?

  public init(
    device: String,
    developerDirectory: String = "/Applications/Xcode-beta.app/Contents/Developer",
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) {
    self.device = device.trimmingCharacters(in: .whitespacesAndNewlines)
    self.developerDirectory = developerDirectory
    self.executor = executor
    self.diagnostics = diagnostics
  }

  public func readiness() async -> InjectionBackendReadiness {
    guard !device.isEmpty else {
      return .unavailable(.noActiveDevice)
    }

    let result = await run(
      [
        "devicectl", "device", "simulate", "location", "list",
        "--device", device,
        "--quiet", "--timeout", Self.timeoutSeconds,
      ],
      commandKind: "readiness"
    )
    switch result {
    case .completed(let details) where details.exitStatus == 0:
      return .ready
    case .timedOut:
      return .unavailable(.timedOut)
    case .completed, .launchFailed:
      return .unavailable(.backendUnavailable)
    }
  }

  public func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    guard !device.isEmpty else {
      return .failed(requestID: command.requestID, reason: .noActiveDevice)
    }

    switch command {
    case .apply(let requestID, let location):
      let result = await run(
        [
          "devicectl", "device", "simulate", "location", "coordinate",
          "--device", device,
          "--latitude=\(format(location.latitude))",
          "--longitude=\(format(location.longitude))",
          "--quiet", "--timeout", Self.timeoutSeconds,
        ],
        commandKind: "apply",
        requestID: requestID
      )
      guard isSuccessful(result) else {
        if isTimedOut(result) {
          return .failed(requestID: requestID, reason: .timedOut)
        }
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      return .applied(requestID: requestID, location: location)

    case .clear(let requestID):
      let result = await run(
        [
          "devicectl", "device", "simulate", "location", "clear",
          "--device", device,
          "--quiet", "--timeout", Self.timeoutSeconds,
        ],
        commandKind: "clear",
        requestID: requestID
      )
      guard isSuccessful(result) else {
        if isTimedOut(result) {
          return .failed(requestID: requestID, reason: .timedOut)
        }
        return .failed(requestID: requestID, reason: .clearFailed)
      }
      return .cleared(requestID: requestID)
    }
  }

  private func run(
    _ arguments: [String],
    commandKind: String,
    requestID: UUID? = nil
  ) async -> DevicectlCommandExecutionResult {
    let invocation = DevicectlCommandInvocation(
      arguments: arguments,
      environmentOverrides: ["DEVELOPER_DIR": developerDirectory],
      timeoutSeconds: Double(Self.timeoutSeconds) ?? 15
    )
    await record(
      kind: "controller.devicectl.started",
      requestID: requestID,
      fields: invocationFields(invocation, commandKind: commandKind)
    )
    let result = executor.execute(invocation)
    let duration: TimeInterval
    switch result {
    case .completed(let details), .timedOut(let details), .launchFailed(let details):
      duration = details.duration
    }
    await record(
      kind: "controller.devicectl.finished",
      requestID: requestID,
      fields: resultFields(
        result,
        commandKind: commandKind,
        duration: duration
      )
    )
    return result
  }

  private func record(
    kind: String,
    requestID: UUID?,
    fields: SimulationDiagnosticFields
  ) async {
    guard let diagnostics else { return }
    await diagnostics.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func invocationFields(
    _ invocation: DevicectlCommandInvocation,
    commandKind: String
  ) -> SimulationDiagnosticFields {
    [
      "commandKind": .text(commandKind),
      "arguments": .array(invocation.arguments.map(SimulationDiagnosticValue.text)),
      "developerDirectory": .text(
        invocation.environmentOverrides["DEVELOPER_DIR"] ?? developerDirectory
      ),
      // The local artifact is intended to correlate an invocation to the
      // configured Active Test Device. It is never printed by the controller.
      "device": .text(device),
      "timeoutSeconds": .number(invocation.timeoutSeconds),
    ]
  }

  private func resultFields(
    _ result: DevicectlCommandExecutionResult,
    commandKind: String,
    duration: TimeInterval
  ) -> SimulationDiagnosticFields {
    var fields: SimulationDiagnosticFields = [
      "commandKind": .text(commandKind),
      "durationSeconds": .number(duration),
    ]
    switch result {
    case .completed(let details):
      fields["launchResult"] = .text(details.launchSucceeded ? "launched" : "failed")
      if let status = details.exitStatus {
        fields["exitStatus"] = .integer(Int64(status))
      }
      fields["outcome"] = .text(details.exitStatus == 0 ? "success" : "nonzero-exit")
      addFailureOutput(from: details, to: &fields)
    case .timedOut(let details):
      fields["launchResult"] = .text(details.launchSucceeded ? "launched" : "failed")
      if let status = details.exitStatus {
        fields["exitStatus"] = .integer(Int64(status))
      }
      fields["outcome"] = .text("timeout")
      addFailureOutput(from: details, to: &fields)
    case .launchFailed(let details):
      fields["launchResult"] = .text("failed")
      fields["outcome"] = .text("launch-failed")
      addFailureOutput(from: details, to: &fields)
    }
    return fields
  }

  private func addFailureOutput(
    from details: DevicectlCommandExecutionDetails,
    to fields: inout SimulationDiagnosticFields
  ) {
    if !details.standardOutput.isEmpty {
      fields["standardOutput"] = .text(details.standardOutput)
    }
    if !details.standardError.isEmpty {
      fields["standardError"] = .text(details.standardError)
    }
  }

  private func isSuccessful(_ result: DevicectlCommandExecutionResult) -> Bool {
    switch result {
    case .completed(let details): details.exitStatus == 0
    case .timedOut, .launchFailed: false
    }
  }

  private func isTimedOut(_ result: DevicectlCommandExecutionResult) -> Bool {
    if case .timedOut = result { return true }
    return false
  }

  private func format(_ coordinate: Double) -> String {
    String(
      format: "%.8f",
      locale: Locale(identifier: "en_US_POSIX"),
      coordinate
    )
  }
}

extension InjectionBackendCommand {
  fileprivate var requestID: UUID {
    switch self {
    case .apply(let requestID, _), .clear(let requestID):
      requestID
    }
  }
}

private final class LockedData: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func replace(_ data: Data) {
    lock.lock()
    self.data = data
    lock.unlock()
  }

  func value() -> Data {
    lock.lock()
    defer { lock.unlock() }
    return data
  }
}
