import Darwin
import Dispatch
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

enum ControllerSessionTerminationError: Error, Equatable, LocalizedError {
  case clearFailed(InjectionBackendFailure)

  var errorDescription: String? {
    switch self {
    case .clearFailed(let reason):
      "The foreground session ended, but Clear failed (\(reason.rawValue)). Keep the iPhone reachable and run `pinshift clear`."
    }
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

  static func runSession(
    controller: SimulationController,
    stopAcceptingCommands: @escaping @Sendable () async -> Void = {},
    waitUntilStopped: @escaping @Sendable () async throws -> Void
  ) async throws {
    let waitError: (any Error)?
    do {
      try await waitUntilStopped()
      waitError = nil
    } catch {
      waitError = error
    }

    await stopAcceptingCommands()
    switch await controller.clear() {
    case .cleared:
      if let waitError { throw waitError }
    case .failed(_, let reason):
      throw ControllerSessionTerminationError.clearFailed(reason)
    }
  }

  static func runForegroundSession(
    controller: SimulationController,
    runFor duration: TimeInterval?,
    stopAcceptingCommands: @escaping @Sendable () async -> Void = {}
  ) async throws {
    if let duration {
      try await runSession(
        controller: controller,
        stopAcceptingCommands: stopAcceptingCommands
      ) {
        try await Task.sleep(for: .seconds(duration))
      }
      return
    }

    let signalWaiter = ControllerTerminationSignalWaiter()
    try await runSession(
      controller: controller,
      stopAcceptingCommands: stopAcceptingCommands
    ) {
      await signalWaiter.wait()
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

private struct ControllerTerminationSignalWaiter: Sendable {
  func wait() async {
    Darwin.signal(SIGHUP, SIG_IGN)
    Darwin.signal(SIGINT, SIG_IGN)
    Darwin.signal(SIGTERM, SIG_IGN)

    let events = AsyncStream<Void> { continuation in
      let sources = [SIGHUP, SIGINT, SIGTERM].map {
        DispatchSource.makeSignalSource(signal: $0, queue: .main)
      }
      for source in sources {
        source.setEventHandler {
          continuation.yield()
          continuation.finish()
        }
        source.resume()
      }
      continuation.onTermination = { _ in
        for source in sources {
          source.cancel()
        }
      }
    }

    for await _ in events {
      return
    }
  }
}
