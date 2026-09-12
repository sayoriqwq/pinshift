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
      "Forced exit: Clear is unconfirmed (\(reason.rawValue)). Keep the iPhone reachable and run `pinshift clear`."
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
    retrySleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      // Normal task cancellation must not abandon the exit-time cleanup responsibility.
      try await Task { try await Task.sleep(for: .seconds(seconds)) }.value
    },
    cleanupFailed: @escaping @Sendable (InjectionBackendFailure) async throws -> Void = { reason in
      print("Clear is unconfirmed (\(reason.rawValue)). Keep the iPhone reachable; retrying. Press Ctrl-C again to force exit without confirmed cleanup.")
    },
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
    await controller.beginShutdown()
    var delay: TimeInterval = 1
    while true {
      switch await controller.clear() {
      case .cleared:
        if let waitError { throw waitError }
        return
      case .failed(_, let reason):
        try await cleanupFailed(reason)
        try await retrySleep(delay)
        delay = min(delay * 2, 30)
      }
    }
  }

  static func runForegroundSession(
    controller: SimulationController,
    runFor duration: TimeInterval?,
    stopAcceptingCommands: @escaping @Sendable () async -> Void = {},
    signalHandlersReady: @Sendable () -> Void = {}
  ) async throws {
    let signalWaiter = ControllerTerminationSignalWaiter()
    defer { signalWaiter.cancel() }
    signalHandlersReady()
    try await runSession(
      controller: controller,
      stopAcceptingCommands: stopAcceptingCommands
    ) {
      if let duration {
        await withTaskGroup(of: Void.self) { group in
          group.addTask { try? await Task.sleep(for: .seconds(duration)) }
          group.addTask { await signalWaiter.wait() }
          await group.next()
          group.cancelAll()
        }
      } else {
        await signalWaiter.wait()
      }
      signalWaiter.armForceExit()
    }
  }

  static func prepareSession(controller: SimulationController) async {
    if case .failed(_, let reason) = await controller.clear() {
      print("Startup Clear is unconfirmed (\(reason.rawValue)); the foreground session will retry. New Apply remains available.")
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

private final class ControllerTerminationSignalWaiter: @unchecked Sendable {
  private let lock = NSLock()
  private var forceExitArmed = false
  private let events: AsyncStream<Void>
  private let continuation: AsyncStream<Void>.Continuation
  private var sources: [DispatchSourceSignal] = []

  init() {
    let stream = AsyncStream<Void>.makeStream()
    events = stream.stream
    continuation = stream.continuation
    for number in [SIGHUP, SIGINT, SIGTERM] {
      Darwin.signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        let force = self.lock.withLock {
          let wasArmed = self.forceExitArmed
          self.forceExitArmed = true
          return wasArmed
        }
        if force {
          let message = "Forced exit: cleanup is unconfirmed. Keep the iPhone reachable and restart pinshift to clear residual simulation.\n"
          FileHandle.standardError.write(Data(message.utf8))
          Darwin.exit(1)
        }
        self.continuation.yield()
      }
      sources.append(source)
      source.resume()
    }
  }

  func armForceExit() { lock.withLock { forceExitArmed = true } }

  func wait() async {
    for await _ in events { return }
  }

  func cancel() {
    for source in sources { source.cancel() }
    continuation.finish()
  }
}
