import Foundation
import SimulationController
import SimulationDiagnostics

public struct ControllerRuntimeConfiguration: Equatable, Sendable {
  public let device: String?
  public let developerDirectory: String

  public init(device: String?, developerDirectory: String) {
    self.device = device
    self.developerDirectory = developerDirectory
  }
}

public enum ControllerCLIRuntime {
  public static let deviceEnvironmentKey = "PINSHIFT_DEVICE"
  public static let developerDirectoryEnvironmentKey = "PINSHIFT_DEVELOPER_DIR"
  public static let defaultDeveloperDirectory =
    "/Applications/Xcode-beta.app/Contents/Developer"
  public static let e2ePairingCodeEnvironmentKey = "PINSHIFT_E2E_PAIRING_CODE"

  public static func makeRunner(
    device: String? = nil,
    developerDirectory: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) -> ControllerCLIRunner {
    let recorder = diagnostics ?? makeDiagnostics(environment: environment)
    return ControllerCLIRunner(
      controller: makeController(
        device: device,
        developerDirectory: developerDirectory,
        environment: environment,
        executor: executor,
        diagnostics: recorder
      ),
      diagnostics: recorder
    )
  }

  public static func makeController(
    device: String? = nil,
    developerDirectory: String? = nil,
    automaticClearInterval: TimeInterval = TemporarySimulationPolicy.automaticClearInterval,
    stateStore: (any TemporarySimulationStoring)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    automaticallySchedulesMaintenance: Bool = true
  ) -> SimulationController {
    let configuration = resolveConfiguration(
      device: device,
      developerDirectory: developerDirectory,
      environment: environment
    )
    let recorder = diagnostics ?? makeDiagnostics(environment: environment)
    return SimulationController(
      backend: DevicectlInjectionBackend(
        device: configuration.device ?? "",
        developerDirectory: configuration.developerDirectory,
        executor: executor,
        diagnostics: recorder
      ),
      diagnostics: recorder,
      stateStore: stateStore
        ?? FileTemporarySimulationStore(
          fileURL: FileTemporarySimulationStore.defaultFileURL(
            environment: environment
          )
        ),
      activeDeviceIdentifier: configuration.device ?? "",
      automaticClearInterval: automaticClearInterval,
      now: now,
      sleep: sleep,
      automaticallySchedulesMaintenance: automaticallySchedulesMaintenance
    )
  }

  public static func makeDiagnostics(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SimulationDiagnosticRecorder {
    SimulationDiagnosticRecorder(
      side: .macController,
      directory: SimulationDiagnosticRecorder.defaultDirectory(environment: environment)
    )
  }

  public static func resolveConfiguration(
    device: String? = nil,
    developerDirectory: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> ControllerRuntimeConfiguration {
    ControllerRuntimeConfiguration(
      device: nonempty(device) ?? nonempty(environment[deviceEnvironmentKey]),
      developerDirectory: nonempty(developerDirectory)
        ?? nonempty(environment[developerDirectoryEnvironmentKey])
        ?? defaultDeveloperDirectory
    )
  }

  static func runAuthority(
    controller: SimulationController,
    pollInterval: TimeInterval = 60,
    runFor duration: TimeInterval? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    }
  ) async throws {
    let startedAt = now()
    while !Task.isCancelled {
      _ = await controller.reconcile()
      if let duration, now().timeIntervalSince(startedAt) >= duration {
        return
      }
      try await sleep(pollInterval)
    }
  }

  private static func nonempty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
      !trimmed.isEmpty
    else {
      return nil
    }
    return trimmed
  }
}
