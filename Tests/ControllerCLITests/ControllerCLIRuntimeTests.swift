import ControllerLink
import Foundation
import SimulationController
import SimulationDiagnostics
import XCTest

@testable import ControllerCLI

final class ControllerCLIRuntimeTests: XCTestCase {
  func testServeLifecycleNormalCompletionResetsOnceAndReportsResult() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-serve-events-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let backend = ServeLifecycleRecordingBackend()
    let controller = SimulationController(backend: backend)
    let reports = ServeLifecycleReports()

    try await ControllerCLIRuntime.runServeLifecycle(
      seconds: 60,
      controller: controller,
      sleep: { _ in },
      diagnostics: diagnostics,
      report: { result in await reports.append(result) }
    )

    let clearCount = await backend.clearCount
    XCTAssertEqual(clearCount, 1)
    let reportedResults = await reports.values
    XCTAssertEqual(reportedResults.count, 1)
    XCTAssertEqual(reportedResults[0].exitCode, 0)
    XCTAssertTrue(reportedResults[0].output.hasPrefix("Reset completed for request "))
    let events = await diagnostics.events()
    XCTAssertTrue(events.contains { $0.kind == "controller.lifecycle.serve-started" })
    XCTAssertTrue(events.contains { $0.kind == "controller.lifecycle.shutdown-cleanup-started" })
    XCTAssertTrue(events.contains { $0.kind == "controller.lifecycle.shutdown-cleanup-finished" })
  }

  func testServeLifecycleInterruptedCleanupIsRecordedAndStillResetsOnce() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-serve-events-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let backend = ServeLifecycleRecordingBackend()
    let controller = SimulationController(backend: backend)
    let reports = ServeLifecycleReports()

    do {
      try await ControllerCLIRuntime.runServeLifecycle(
        seconds: 60,
        controller: controller,
        sleep: { _ in throw ServeLifecycleInterruption.cancelled },
        diagnostics: diagnostics,
        report: { result in await reports.append(result) }
      )
      XCTFail("Expected the interrupted lifecycle to rethrow")
    } catch is ServeLifecycleInterruption {
      // The cleanup result is reported before the interruption is rethrown.
    }

    let clearCount = await backend.clearCount
    let reportedValues = await reports.values
    XCTAssertEqual(clearCount, 1)
    XCTAssertEqual(reportedValues.count, 1)
    let events = await diagnostics.events()
    XCTAssertTrue(
      events.contains { $0.kind == "controller.lifecycle.interrupted-shutdown-cleanup-started" }
    )
    XCTAssertTrue(
      events.contains { $0.kind == "controller.lifecycle.interrupted-shutdown-cleanup-finished" }
    )
    XCTAssertTrue(events.contains { $0.kind == "controller.reset.requested" })
  }

  func testServeLifecycleReportsCleanupFailureThroughExitSemantics() async {
    let backend = ServeLifecycleFailingClearBackend()
    let controller = SimulationController(backend: backend)
    let reports = ServeLifecycleReports()

    do {
      try await ControllerCLIRuntime.runServeLifecycle(
        seconds: 60,
        controller: controller,
        sleep: { _ in },
        report: { result in await reports.append(result) }
      )
      XCTFail("Expected failed expiry cleanup to make the serve command fail")
    } catch let error as ControllerServeLifecycleError {
      XCTAssertEqual(error, .cleanupFailed)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }

    let reportedValues = await reports.values
    XCTAssertEqual(reportedValues.count, 1)
    XCTAssertEqual(reportedValues[0].exitCode, 1)
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
    XCTAssertEqual(
      defaults.developerDirectory,
      ControllerCLIRuntime.defaultDeveloperDirectory
    )
  }

  func testDefaultSimulationLeaseIsIndependentFromServerDuration() {
    XCTAssertEqual(ControllerCLIRuntime.defaultSimulationLeaseDuration, 900)
  }

  func testBuildsTheProductionControllerFromDevicectlConfiguration() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let executor = RuntimeRecordingDevicectlExecutor(
      results: [.exited(0), .exited(0), .exited(0), .exited(0)]
    )
    let environment = [
      "PINSHIFT_DEVICE": "Active Test Device",
      "PINSHIFT_DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer",
      FileSimulationLifecycleStore.fileEnvironmentKey:
        directory.appendingPathComponent("lifecycle.json").path,
    ]
    let guardianHealthStore = InMemorySimulationCleanupGuardianHealthStore(
      health: SimulationCleanupGuardianHealth(
        guardianID: UUID(),
        activeDeviceIdentifier: "Active Test Device",
        recordedAt: Date()
      )
    )
    let controller = ControllerCLIRuntime.makeController(
      cleanupGuardianHealthStore: guardianHealthStore,
      environment: environment,
      executor: executor
    )
    let handler = SimulationControllerCommandHandler(controller: controller)

    let status = await handler.handle(.status(requestID: UUID()))
    let applyID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!
    let applied = await handler.handle(
      .apply(requestID: applyID, latitude: 31.2304, longitude: 121.4737)
    )
    let stopID = UUID(uuidString: "00000000-0000-0000-0000-000000000202")!
    let stopped = await handler.handle(.stop(requestID: stopID))

    XCTAssertEqual(status, .ready(requestID: status.requestID))
    XCTAssertEqual(applied, .applied(requestID: applyID))
    XCTAssertEqual(stopped, .stopped(requestID: stopID))
    XCTAssertEqual(executor.invocations.count, 4)
    XCTAssertTrue(
      executor.invocations.allSatisfy {
        $0.environmentOverrides["DEVELOPER_DIR"]
          == "/Applications/Xcode-beta.app/Contents/Developer"
      }
    )
  }

  func testMissingDeviceConfigurationReportsNoActiveDeviceWithoutSpawningAProcess() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-runtime-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let executor = RuntimeRecordingDevicectlExecutor(results: [])
    let runner = ControllerCLIRuntime.makeRunner(
      environment: [
        FileSimulationLifecycleStore.fileEnvironmentKey:
          directory.appendingPathComponent("lifecycle.json").path
      ],
      executor: executor
    )

    let result = await runner.run(.status)

    XCTAssertEqual(
      result,
      ControllerCLIResult(
        exitCode: 1,
        output: "No Active Test Device is configured. Pass --device or set PINSHIFT_DEVICE."
      )
    )
    XCTAssertTrue(executor.invocations.isEmpty)
  }
}

private actor ServeLifecycleRecordingBackend: InjectionBackend {
  private(set) var clearCount = 0

  func readiness() -> InjectionBackendReadiness {
    .ready
  }

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

private actor ServeLifecycleFailingClearBackend: InjectionBackend {
  func readiness() -> InjectionBackendReadiness {
    .ready
  }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      return .failed(requestID: requestID, reason: .clearFailed)
    }
  }
}

private actor ServeLifecycleReports {
  private(set) var values: [ControllerCLIResult] = []

  func append(_ result: ControllerCLIResult) {
    values.append(result)
  }
}

private enum ServeLifecycleInterruption: Error {
  case cancelled
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
