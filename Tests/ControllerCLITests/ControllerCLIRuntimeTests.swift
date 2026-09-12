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

  func testSecondProcessCannotClearAndProcessExitReleasesSessionOwnership() async throws {
    let marker = "PINSHIFT_TEST_LOCK_DIRECTORY"
    if let directoryPath = ProcessInfo.processInfo.environment[marker] {
      let directory = URL(fileURLWithPath: directoryPath, isDirectory: true)
      let ownership: ControllerSessionLock
      do { ownership = try ControllerSessionLock.acquire(directory: directory) }
      catch {
        // A second session must fail before preparing/clearing the device.
        Darwin.exit(23)
      }
      let controller = SimulationController(
        backend: RuntimeFileRecordingBackend(file: directory.appending(path: "clears")),
        automaticallySchedulesMaintenance: false
      )
      await ControllerCLIRuntime.prepareSession(controller: controller)
      withExtendedLifetime(ownership) {
        // Bypass Swift deinit and explicit release, as a forced process exit would.
        Darwin.exit(0)
      }
    }

    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let ownership = try ControllerSessionLock.acquire(directory: directory)
    defer { ownership.release() }
    let eventFile = directory.appending(path: "clears")
    let controller = SimulationController(
      backend: RuntimeFileRecordingBackend(file: eventFile), automaticallySchedulesMaintenance: false
    )
    await ControllerCLIRuntime.prepareSession(controller: controller)

    for expectedExit in [Int32(23), Int32(0)] {
      let child = Process()
      child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
      child.arguments = [
        "-XCTest",
        "ControllerCLITests.ControllerCLIRuntimeTests/testSecondProcessCannotClearAndProcessExitReleasesSessionOwnership",
        Bundle(for: ControllerCLIRuntimeTests.self).bundlePath,
      ]
      child.environment = ProcessInfo.processInfo.environment.merging([marker: directory.path]) { _, new in new }
      child.standardOutput = FileHandle.nullDevice
      child.standardError = FileHandle.nullDevice
      try child.run()
      for _ in 0..<250 where child.isRunning {
        try await Task.sleep(for: .milliseconds(20))
      }
      guard !child.isRunning else {
        kill(child.processIdentifier, SIGKILL)
        return XCTFail("Session ownership child must finish promptly")
      }
      XCTAssertEqual(child.terminationStatus, expectedExit)
      XCTAssertEqual(try String(contentsOf: eventFile, encoding: .utf8),
        expectedExit == 23 ? "clear\n" : "clear\nclear\n")
      ownership.release()
    }
    // The lock file remains, but the exited child cannot leave a stale ownership lock.
    let recovered = try ControllerSessionLock.acquire(directory: directory)
    recovered.release()
  }

  func testLateApplyIsRejectedWhileShutdownClearIsInFlight() async throws {
    let backend = RuntimeHeldClearBackend()
    let controller = SimulationController(backend: backend, automaticallySchedulesMaintenance: false)
    let location = try SelectedLocation(latitude: 31, longitude: 121)
    _ = await controller.apply(location)
    let shutdown = Task {
      try await ControllerCLIRuntime.runSession(controller: controller, waitUntilStopped: {})
    }
    await backend.waitUntilClearHeld()
    // Represents an already accepted connection whose handler reaches Apply after listener.stop().
    let handler = SimulationControllerCommandHandler(controller: controller)
    let lateID = UUID()
    let late = Task {
      await handler.handle(.apply(requestID: lateID, latitude: 35, longitude: 139))
    }
    for _ in 0..<100 { await Task.yield() }
    await backend.releaseClear()
    try await shutdown.value
    let result = await late.value
    XCTAssertEqual(result, .failed(requestID: lateID, reason: .sessionNotReady))
    let locationAfterExit = await backend.location
    XCTAssertNil(locationAfterExit)
    let commands = await backend.names
    XCTAssertEqual(commands, ["apply", "clear"])
  }

  func testSecondSignalForcesExitWithUnconfirmedCleanupWarning() async throws {
    let marker = "PINSHIFT_TEST_FORCE_EXIT_CHILD"
    if ProcessInfo.processInfo.environment[marker] == "1" {
      let controller = SimulationController(
        backend: RuntimeFailingClearBackend(), automaticallySchedulesMaintenance: false
      )
      try await ControllerCLIRuntime.runForegroundSession(
        controller: controller, runFor: nil,
        stopAcceptingCommands: {
          FileHandle.standardOutput.write(Data("PINSHIFT_EXIT_CLEANUP_STARTED\n".utf8))
        },
        signalHandlersReady: {
          FileHandle.standardOutput.write(Data("PINSHIFT_SIGNAL_HANDLERS_READY\n".utf8))
        }
      )
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
    // Bound both readiness waits even if the child never reaches either handshake.
    let timeout = Task {
      try await Task.sleep(for: .seconds(30))
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    defer {
      timeout.cancel()
      if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    var handlersReady = false
    var lines = output.fileHandleForReading.bytes.lines.makeAsyncIterator()
    while let line = try await lines.next() {
      if line == "PINSHIFT_SIGNAL_HANDLERS_READY" {
        handlersReady = true
        break
      }
    }
    guard handlersReady else {
      return XCTFail("Child exited before its signal handlers were ready")
    }
    kill(process.processIdentifier, SIGINT)
    var cleanupStarted = false
    while let line = try await lines.next() {
      if line == "PINSHIFT_EXIT_CLEANUP_STARTED" {
        cleanupStarted = true
        break
      }
    }
    XCTAssertTrue(cleanupStarted, "First signal must reach shutdown cleanup")
    XCTAssertTrue(process.isRunning, "A failed normal exit must remain in the foreground")
    kill(process.processIdentifier, SIGINT)
    for _ in 0..<100 where process.isRunning {
      try await Task.sleep(for: .milliseconds(20))
    }
    guard !process.isRunning else {
      kill(process.processIdentifier, SIGKILL)
      return XCTFail("Explicit force exit must finish without waiting for cleanup")
    }
    var text = ""
    while let line = try await lines.next() { text += line + "\n" }
    XCTAssertEqual(process.terminationStatus, 1, text)
    XCTAssertTrue(text.contains("Forced exit: cleanup is unconfirmed"), text)
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

private struct RuntimeFileRecordingBackend: InjectionBackend {
  let file: URL
  func readiness() -> InjectionBackendReadiness { .ready }
  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    switch command {
    case .apply(let id, let location): return .applied(requestID: id, location: location)
    case .clear(let id):
      do {
        let previous = (try? Data(contentsOf: file)) ?? Data()
        try (previous + Data("clear\n".utf8)).write(to: file)
        return .cleared(requestID: id)
      } catch { return .failed(requestID: id, reason: .clearFailed) }
    }
  }
}

private actor RuntimeHeldClearBackend: InjectionBackend {
  private(set) var location: SelectedLocation?
  private(set) var names: [String] = []
  private var clearHeld = false
  private var waiters: [CheckedContinuation<Void, Never>] = []
  private var continuation: CheckedContinuation<Void, Never>?
  func readiness() -> InjectionBackendReadiness { .ready }
  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    switch command {
    case .apply(let id, let selected):
      names.append("apply")
      location = selected
      return .applied(requestID: id, location: selected)
    case .clear(let id):
      names.append("clear")
      clearHeld = true
      for waiter in waiters { waiter.resume() }
      waiters.removeAll()
      await withCheckedContinuation { continuation = $0 }
      location = nil
      return .cleared(requestID: id)
    }
  }
  func waitUntilClearHeld() async {
    if clearHeld { return }
    await withCheckedContinuation { waiters.append($0) }
  }
  func releaseClear() { continuation?.resume(); continuation = nil }
}
