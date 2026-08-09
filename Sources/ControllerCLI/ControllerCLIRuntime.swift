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

public enum ControllerServeLifecycleError: Error, Equatable, Sendable {
  case cleanupFailed
}

public enum ControllerCLIRuntime {
  public static let deviceEnvironmentKey = "REMOTE_LOCATION_DEVICE"
  public static let developerDirectoryEnvironmentKey =
    "REMOTE_LOCATION_DEVELOPER_DIR"
  public static let defaultDeveloperDirectory =
    "/Applications/Xcode-beta.app/Contents/Developer"
  public static let e2ePairingCodeEnvironmentKey =
    "REMOTE_LOCATION_E2E_PAIRING_CODE"
  public static let defaultSimulationLeaseDuration: TimeInterval =
    SimulationLeasePolicy.defaultDuration

  public static func makeRunner(
    device: String? = nil,
    developerDirectory: String? = nil,
    leaseDuration: TimeInterval = defaultSimulationLeaseDuration,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) -> ControllerCLIRunner {
    let recorder = diagnostics ?? makeDiagnostics(environment: environment)
    return ControllerCLIRunner(
      controller: makeController(
        device: device,
        developerDirectory: developerDirectory,
        leaseDuration: leaseDuration,
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
    leaseDuration: TimeInterval = defaultSimulationLeaseDuration,
    serverOwnerID: UUID? = nil,
    serverHeartbeatStore: (any SimulationServerHeartbeatStoring)? = nil,
    cleanupGuardianHealthStore: (any SimulationCleanupGuardianHealthStoring)? = nil,
    requiresHealthyCleanupGuardian: Bool = true,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) -> SimulationController {
    let configuration = resolveConfiguration(
      device: device,
      developerDirectory: developerDirectory,
      environment: environment
    )

    let diagnostics = diagnostics ?? makeDiagnostics(environment: environment)
    return SimulationController(
      backend: DevicectlInjectionBackend(
        device: configuration.device ?? "",
        developerDirectory: configuration.developerDirectory,
        executor: executor,
        diagnostics: diagnostics
      ),
      diagnostics: diagnostics,
      lifecycleStore: FileSimulationLifecycleStore(
        fileURL: FileSimulationLifecycleStore.defaultFileURL(environment: environment)
      ),
      activeDeviceIdentifier: configuration.device ?? "",
      leaseDuration: leaseDuration,
      serverOwnerID: serverOwnerID,
      serverHeartbeatStore: serverHeartbeatStore
        ?? FileSimulationServerHeartbeatStore(
          fileURL: FileSimulationServerHeartbeatStore.defaultFileURL(
            environment: environment
          )
        ),
      cleanupGuardianHealthStore: cleanupGuardianHealthStore
        ?? FileSimulationCleanupGuardianHealthStore(
          fileURL: FileSimulationCleanupGuardianHealthStore.defaultFileURL(
            environment: environment
          )
        ),
      requiresHealthyCleanupGuardian: requiresHealthyCleanupGuardian,
      recoversLegacySimulation: true
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

  public static func makeCleanupGuardian(
    device: String? = nil,
    developerDirectory: String? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    executor: any DevicectlCommandExecuting = FoundationDevicectlCommandExecutor(),
    diagnostics: SimulationDiagnosticRecorder? = nil,
    pollInterval: TimeInterval = 1
  ) -> SimulationCleanupGuardian {
    let configuration = resolveConfiguration(
      device: device,
      developerDirectory: developerDirectory,
      environment: environment
    )
    let recorder = diagnostics ?? makeDiagnostics(environment: environment)
    return SimulationCleanupGuardian(
      backend: DevicectlInjectionBackend(
        device: configuration.device ?? "",
        developerDirectory: configuration.developerDirectory,
        executor: executor,
        diagnostics: recorder
      ),
      diagnostics: recorder,
      lifecycleStore: FileSimulationLifecycleStore(
        fileURL: FileSimulationLifecycleStore.defaultFileURL(environment: environment)
      ),
      activeDeviceIdentifier: configuration.device ?? "",
      serverHeartbeatStore: FileSimulationServerHeartbeatStore(
        fileURL: FileSimulationServerHeartbeatStore.defaultFileURL(
          environment: environment
        )
      ),
      healthStore: FileSimulationCleanupGuardianHealthStore(
        fileURL: FileSimulationCleanupGuardianHealthStore.defaultFileURL(
          environment: environment
        )
      ),
      pollInterval: pollInterval
    )
  }

  public static func makeServerHeartbeatEmitter(
    ownerID: UUID,
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> SimulationServerHeartbeatEmitter {
    SimulationServerHeartbeatEmitter(
      ownerID: ownerID,
      store: FileSimulationServerHeartbeatStore(
        fileURL: FileSimulationServerHeartbeatStore.defaultFileURL(
          environment: environment
        )
      )
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

  static func runServeLifecycle(
    seconds: Double,
    controller: SimulationController,
    serverHeartbeat: SimulationServerHeartbeatEmitter? = nil,
    sleep: @Sendable (Double) async throws -> Void = { duration in
      try await Task.sleep(for: .seconds(duration))
    },
    diagnostics: SimulationDiagnosticRecorder? = nil,
    report: @Sendable (ControllerCLIResult) async -> Void
  ) async throws {
    try await serverHeartbeat?.recordNow()
    let heartbeatTask = serverHeartbeat.map { heartbeat in
      Task {
        try? await heartbeat.run()
      }
    }
    defer { heartbeatTask?.cancel() }
    if let diagnostics {
      await diagnostics.record(kind: "controller.lifecycle.serve-started")
    }
    do {
      try await sleep(seconds)
    } catch {
      _ = await reportServeCleanup(
        using: controller,
        diagnostics: diagnostics,
        interrupted: true,
        report: report
      )
      throw error
    }
    let cleanupResult = await reportServeCleanup(
      using: controller,
      diagnostics: diagnostics,
      interrupted: false,
      report: report
    )
    guard cleanupResult.exitCode == 0 else {
      throw ControllerServeLifecycleError.cleanupFailed
    }
  }

  private static func reportServeCleanup(
    using controller: SimulationController,
    diagnostics: SimulationDiagnosticRecorder?,
    interrupted: Bool,
    report: @Sendable (ControllerCLIResult) async -> Void
  ) async -> ControllerCLIResult {
    await diagnostics?.record(
      kind: interrupted
        ? "controller.lifecycle.interrupted-shutdown-cleanup-started"
        : "controller.lifecycle.shutdown-cleanup-started"
    )
    let result = await ControllerCLIRunner(
      controller: controller,
      diagnostics: diagnostics
    ).run(
      .reset(requestID: UUID())
    )
    await report(result)
    await diagnostics?.record(
      kind: interrupted
        ? "controller.lifecycle.interrupted-shutdown-cleanup-finished"
        : "controller.lifecycle.shutdown-cleanup-finished",
      fields: [
        "exitCode": .integer(Int64(result.exitCode)),
        "outcome": .text(result.exitCode == 0 ? "success" : "failed"),
      ]
    )
    return result
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
