import ControllerLink
import Foundation
import SimulationController
import XCTest

@testable import ControllerCLI

final class ControllerCLIRuntimeTests: XCTestCase {
  func testBackgroundAuthorityUsesMinuteFallbackPollingByDefault() async throws {
    let controller = SimulationController(
      backend: RuntimeCountingBackend(),
      automaticallySchedulesMaintenance: false
    )
    let clock = RuntimeTestClock(now: Date(timeIntervalSince1970: 1_000))
    let intervals = RuntimeIntervalRecorder()

    try await ControllerCLIRuntime.runAuthority(
      controller: controller,
      runFor: 60,
      now: { clock.now },
      sleep: { seconds in
        intervals.record(seconds)
        clock.advance(by: seconds)
      }
    )

    XCTAssertEqual(intervals.values, [60])
  }

  func testBackgroundAuthorityPollsTheSameControllerWithoutClearingOnShutdown() async throws {
    let backend = RuntimeCountingBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let clock = RuntimeTestClock(now: Date(timeIntervalSince1970: 1_000))
    let sleeps = RuntimeCounter()

    try await ControllerCLIRuntime.runAuthority(
      controller: controller,
      pollInterval: 1,
      runFor: 1,
      now: { clock.now },
      sleep: { _ in
        sleeps.increment()
        clock.advance(by: 1)
      }
    )

    let clearCount = await backend.clearCount
    XCTAssertEqual(sleeps.value, 1)
    XCTAssertEqual(clearCount, 0)
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
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let executor = RuntimeRecordingDevicectlExecutor(
      results: [.exited(0), .exited(0), .exited(0)]
    )
    let environment = [
      "PINSHIFT_DEVICE": "Active Test Device",
      "PINSHIFT_DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
      FileTemporarySimulationStore.fileEnvironmentKey:
        directory.appendingPathComponent("state.json").path,
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
      .clear(requestID: clearID, targetOperationID: nil)
    )

    XCTAssertEqual(
      applied,
      .applied(
        requestID: applyID,
        automaticClearAt: now.addingTimeInterval(900)
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

private final class RuntimeIntervalRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var intervals: [TimeInterval] = []

  var values: [TimeInterval] { lock.withLock { intervals } }
  func record(_ interval: TimeInterval) {
    lock.withLock { intervals.append(interval) }
  }
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
