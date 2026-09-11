import Darwin
import ControllerLink
import Foundation
import LocationDomain
import SimulationController
import XCTest

@testable import ControllerCLI

final class ControllerCLIRuntimeTests: XCTestCase {
  func testForegroundSessionWaitsOnceThenClearsBeforeReturning() async throws {
    let backend = RuntimeCountingBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let waits = RuntimeCounter()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID())

    try await ControllerCLIRuntime.runSession(
      controller: controller,
      waitUntilStopped: {
        waits.increment()
      }
    )

    XCTAssertEqual(waits.value, 1)
    let clearCount = await backend.clearCount
    XCTAssertEqual(clearCount, 1)
    let snapshot = await controller.snapshot()
    XCTAssertEqual(snapshot.simulation, .idle)
  }

  func testForegroundSessionReportsARealClearFailure() async throws {
    let backend = RuntimeFailingClearBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID())

    do {
      try await ControllerCLIRuntime.runSession(
        controller: controller,
        cleanupFailed: { reason in
          throw ControllerSessionTerminationError.clearFailed(reason)
        },
        waitUntilStopped: {}
      )
      XCTFail("Explicit forced exit must report unconfirmed cleanup")
    } catch {
      XCTAssertEqual(
        error as? ControllerSessionTerminationError,
        .clearFailed(.clearFailed)
      )
    }

    let clearCount = await backend.clearCount
    XCTAssertEqual(clearCount, 1)
    guard case .clearPending = await controller.snapshot().simulation else {
      return XCTFail("A failed exit-time Clear must remain visible")
    }
  }

  func testForegroundSessionStopsAcceptingCommandsBeforeFinalClear() async throws {
    let events = RuntimeEventRecorder()
    let controller = SimulationController(
      backend: RuntimeOrderingBackend(events: events),
      automaticallySchedulesMaintenance: false
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID())

    try await ControllerCLIRuntime.runSession(
      controller: controller,
      stopAcceptingCommands: {
        await events.append("server-stopped")
      },
      waitUntilStopped: {}
    )

    let recordedEvents = await events.values
    XCTAssertEqual(recordedEvents, ["apply", "server-stopped", "clear"])
  }

  func testSecondSignalForcesExitWithUnconfirmedCleanupWarning() async throws {
    let marker = "PINSHIFT_TEST_FORCE_EXIT_CHILD"
    if ProcessInfo.processInfo.environment[marker] == "1" {
      let controller = SimulationController(
        backend: RuntimeFailingClearBackend(), automaticallySchedulesMaintenance: false
      )
      try await ControllerCLIRuntime.runForegroundSession(controller: controller, runFor: nil)
      return XCTFail("Unacknowledged cleanup must keep the child process alive")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = [
      "-XCTest",
      "ControllerCLITests.ControllerCLIRuntimeTests/testSecondSignalForcesExitWithUnconfirmedCleanupWarning",
      Bundle(for: ControllerCLIRuntimeTests.self).bundlePath,
    ]
    process.environment = ProcessInfo.processInfo.environment.merging([marker: "1"]) { _, new in new }
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    defer { if process.isRunning { process.terminate() } }

    try await Task.sleep(for: .seconds(1))
    kill(process.processIdentifier, SIGINT)
    try await Task.sleep(for: .milliseconds(100))
    XCTAssertTrue(process.isRunning, "A failed normal exit must remain in the foreground")
    kill(process.processIdentifier, SIGINT)
    for _ in 0..<100 where process.isRunning {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !process.isRunning else {
      kill(process.processIdentifier, SIGKILL)
      return XCTFail("Explicit force exit must finish without waiting for cleanup")
    }
    let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    XCTAssertEqual(process.terminationStatus, 1)
    XCTAssertTrue(text.contains("Forced exit: cleanup is unconfirmed"))
  }

  func testNormalExitRetriesUntilAcknowledgedWithBoundedBackoff() async throws {
    let backend = RuntimeRecoveringBackend(failures: 8)
    let controller = SimulationController(backend: backend, automaticallySchedulesMaintenance: false)
    let delays = RuntimeEventRecorder()
    try await ControllerCLIRuntime.runSession(
      controller: controller,
      retrySleep: { seconds in await delays.append(String(Int(seconds))) },
      cleanupFailed: { _ in },
      waitUntilStopped: {}
    )
    let values = await delays.values
    XCTAssertEqual(values, ["1", "2", "4", "8", "16", "30", "30", "30"])
    let snapshot = await controller.snapshot()
    XCTAssertEqual(snapshot.simulation, .idle)
  }

  func testStartupReallyClearsWithoutLocalRecordAndFailureDoesNotBlockApply() async throws {
    let backend = RuntimeRecoveringBackend(failures: 1)
    let controller = SimulationController(backend: backend, automaticallySchedulesMaintenance: false)
    await ControllerCLIRuntime.prepareSession(controller: controller)
    guard case .clearPending = await controller.snapshot().simulation else {
      return XCTFail("Startup failure must remain visible")
    }
    let location = try SelectedLocation(latitude: 31, longitude: 121)
    guard case .applied = await controller.apply(location) else {
      return XCTFail("Startup failure must not block a new Apply")
    }
    let count = await backend.clearCount
    XCTAssertEqual(count, 1)
  }

  func testResolvesExplicitValuesBeforeEnvironmentAndDefaults() {
    let explicit = ControllerCLIRuntime.resolveConfiguration(
      device: " Explicit Device ",
      developerDirectory: " /Explicit/Xcode.app/Contents/Developer ",
      environment: [
        "PINSHIFT_DEVICE": "Environment Device",
        "PINSHIFT_DEVELOPER_DIR": "/Environment/Xcode.app/Contents/Developer",
      ]
    )
    let environment = ControllerCLIRuntime.resolveConfiguration(
      environment: [
        "PINSHIFT_DEVICE": " Environment Device ",
        "PINSHIFT_DEVELOPER_DIR": " /Environment/Xcode.app/Contents/Developer ",
      ]
    )
    let defaults = ControllerCLIRuntime.resolveConfiguration(environment: [:])

    XCTAssertEqual(explicit.device, "Explicit Device")
    XCTAssertEqual(explicit.developerDirectory, "/Explicit/Xcode.app/Contents/Developer")
    XCTAssertEqual(environment.device, "Environment Device")
    XCTAssertEqual(
      environment.developerDirectory,
      "/Environment/Xcode.app/Contents/Developer"
    )
    XCTAssertNil(defaults.device)
    XCTAssertEqual(defaults.developerDirectory, ControllerCLIRuntime.defaultDeveloperDirectory)
  }

  func testBuildsProductionControllerFromDevicectlConfiguration() async {
    let executor = RuntimeRecordingDevicectlExecutor(
      results: [.exited(0), .exited(0), .exited(0)]
    )
    let environment = [
      "PINSHIFT_DEVICE": "Active Test Device",
      "PINSHIFT_DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
    ]
    let now = Date(timeIntervalSince1970: 1_000)
    let controller = ControllerCLIRuntime.makeController(
      environment: environment,
      executor: executor,
      now: { now },
      automaticallySchedulesMaintenance: false
    )
    let handler = SimulationControllerCommandHandler(controller: controller)
    let applyID = UUID()
    let applied = await handler.handle(
      .apply(requestID: applyID, latitude: 31.2304, longitude: 121.4737)
    )
    let clearID = UUID()
    let cleared = await handler.handle(
      .clear(requestID: clearID)
    )

    XCTAssertEqual(
      applied,
      .applied(
        requestID: applyID,
        automaticClearAt: now.addingTimeInterval(180)
      )
    )
    XCTAssertEqual(cleared, .cleared(requestID: clearID))
    XCTAssertEqual(executor.invocations.count, 3)
    XCTAssertTrue(
      executor.invocations.allSatisfy {
        $0.environmentOverrides["DEVELOPER_DIR"]
          == "/Applications/Xcode-beta.app/Contents/Developer"
      }
    )
  }

  func testMissingDeviceConfigurationReportsNoActiveDeviceWithoutSpawningAProcess() async {
    let executor = RuntimeRecordingDevicectlExecutor(results: [])
    let runner = ControllerCLIRuntime.makeRunner(environment: [:], executor: executor)

    let result = await runner.run(.status)

    XCTAssertEqual(result.exitCode, 1)
    XCTAssertTrue(result.output.contains("No Active Test Device"))
    XCTAssertTrue(executor.invocations.isEmpty)
  }
}

private actor RuntimeCountingBackend: InjectionBackend {
  private(set) var clearCount = 0

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearCount += 1
      return .cleared(requestID: requestID)
    }
  }
}

private actor RuntimeFailingClearBackend: InjectionBackend {
  private(set) var clearCount = 0

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearCount += 1
      return .failed(requestID: requestID, reason: .clearFailed)
    }
  }
}

private actor RuntimeEventRecorder {
  private var recordedValues: [String] = []

  var values: [String] { recordedValues }

  func append(_ value: String) {
    recordedValues.append(value)
  }
}

private struct RuntimeOrderingBackend: InjectionBackend {
  let events: RuntimeEventRecorder

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      await events.append("apply")
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      await events.append("clear")
      return .cleared(requestID: requestID)
    }
  }
}

private final class RuntimeTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(now: Date) { value = now }
  var now: Date { lock.withLock { value } }
  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

private final class RuntimeCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var count = 0

  var value: Int { lock.withLock { count } }
  func increment() { lock.withLock { count += 1 } }
}

private final class RuntimeRecordingDevicectlExecutor:
  DevicectlCommandExecuting, @unchecked Sendable
{
  private let lock = NSLock()
  private var pendingResults: [DevicectlCommandExecutionResult]
  private var recordedInvocations: [DevicectlCommandInvocation] = []

  init(results: [DevicectlCommandExecutionResult]) {
    pendingResults = results
  }

  var invocations: [DevicectlCommandInvocation] {
    lock.withLock { recordedInvocations }
  }

  func execute(
    _ invocation: DevicectlCommandInvocation
  ) -> DevicectlCommandExecutionResult {
    lock.withLock {
      recordedInvocations.append(invocation)
      return pendingResults.removeFirst()
    }
  }
}

private actor RuntimeRecoveringBackend: InjectionBackend {
  private var failures: Int
  private(set) var clearCount = 0
  init(failures: Int) { self.failures = failures }
  func readiness() -> InjectionBackendReadiness { .ready }
  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let id, let location): return .applied(requestID: id, location: location)
    case .clear(let id):
      clearCount += 1
      if failures > 0 {
        failures -= 1
        return .failed(requestID: id, reason: .clearFailed)
      }
      return .cleared(requestID: id)
    }
  }
}
