import Foundation
import LocationDomain
import SimulationDiagnostics
import XCTest

@testable import SimulationController

final class DevicectlInjectionBackendTests: XCTestCase {
  func testReadinessUsesTheConfiguredDeviceAndXcodeToolchain() async {
    let executor = RecordingDevicectlCommandExecutor(results: [.completed(.init(launchSucceeded: true, exitStatus: 0, duration: 0))])
    let backend = DevicectlInjectionBackend(
      device: "Active Test Device",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: executor
    )

    let readiness = await backend.readiness()

    XCTAssertEqual(readiness, .ready)
    XCTAssertEqual(
      executor.invocations,
      [
        DevicectlCommandInvocation(
          arguments: [
            "devicectl", "device", "simulate", "location", "list",
            "--device", "Active Test Device",
            "--quiet", "--timeout", "15",
          ],
          environmentOverrides: [
            "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
          ]
        )
      ]
    )
  }

  func testApplyBindsNegativeCoordinatesToTheirOptionsAndPreservesRequestIdentity() async throws {
    let executor = RecordingDevicectlCommandExecutor(results: [.completed(.init(launchSucceeded: true, exitStatus: 0, duration: 0))])
    let backend = DevicectlInjectionBackend(
      device: "Developer iPhone; do-not-run",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: executor
    )
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    let location = try SelectedLocation(latitude: -34.6037, longitude: -58.3816)

    let result = await backend.execute(.apply(requestID: requestID, location: location))

    XCTAssertEqual(result, .applied(requestID: requestID, location: location))
    XCTAssertEqual(
      executor.invocations.first?.arguments,
      [
        "devicectl", "device", "simulate", "location", "coordinate",
        "--device", "Developer iPhone; do-not-run",
        "--latitude=-34.60370000",
        "--longitude=-58.38160000",
        "--quiet", "--timeout", "15",
      ]
    )
  }

  func testClearSuccessAndFailureStayCorrelatedToTheirRequests() async {
    let successfulID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    let failedID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!
    let executor = RecordingDevicectlCommandExecutor(
      results: [.completed(.init(launchSucceeded: true, exitStatus: 0, duration: 0)), .completed(.init(launchSucceeded: true, exitStatus: 1, duration: 0))]
    )
    let backend = DevicectlInjectionBackend(
      device: "Developer iPhone",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: executor
    )

    let success = await backend.execute(.clear(requestID: successfulID))
    let failure = await backend.execute(.clear(requestID: failedID))

    XCTAssertEqual(success, .cleared(requestID: successfulID))
    XCTAssertEqual(
      failure,
      .failed(requestID: failedID, reason: .clearFailed)
    )
    XCTAssertEqual(
      executor.invocations.first?.arguments,
      [
        "devicectl", "device", "simulate", "location", "clear",
        "--device", "Developer iPhone",
        "--quiet", "--timeout", "15",
      ]
    )
  }

  func testMissingDeviceAndLaunchFailureAreStableReadinessFailures() async {
    let unusedExecutor = RecordingDevicectlCommandExecutor(results: [])
    let missingDevice = DevicectlInjectionBackend(
      device: "   ",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: unusedExecutor
    )
    let failedExecutor = RecordingDevicectlCommandExecutor(results: [.launchFailed(.init(launchSucceeded: false, exitStatus: nil, duration: 0))])
    let failedLaunch = DevicectlInjectionBackend(
      device: "Developer iPhone",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: failedExecutor
    )

    let missingReadiness = await missingDevice.readiness()
    let failedReadiness = await failedLaunch.readiness()

    XCTAssertEqual(missingReadiness, .unavailable(.noActiveDevice))
    XCTAssertTrue(unusedExecutor.invocations.isEmpty)
    XCTAssertEqual(failedReadiness, .unavailable(.backendUnavailable))
  }

  func testProductionExecutorDoesNotInheritControllerSecrets() {
    let environment = FoundationDevicectlCommandExecutor.sanitizedEnvironment(
      inherited: [
        "HOME": "/Users/developer",
        "PATH": "/usr/bin:/bin",
        "PINSHIFT_E2E_PAIRING_CODE": "123456",
        "PINSHIFT_RUNNER_CREDENTIAL": "private",
      ],
      overrides: [
        "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
      ]
    )

    XCTAssertEqual(environment["HOME"], "/Users/developer")
    XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    XCTAssertEqual(
      environment["DEVELOPER_DIR"],
      "/Applications/Xcode-beta.app/Contents/Developer"
    )
    XCTAssertNil(environment["PINSHIFT_E2E_PAIRING_CODE"])
    XCTAssertNil(environment["PINSHIFT_RUNNER_CREDENTIAL"])
  }

  func testDiagnosticsCaptureInvocationAndFailureOutputWithoutChangingClearResult() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let executor = RecordingDevicectlCommandExecutor(
      results: [
        .completed(
          DevicectlCommandExecutionDetails(
            launchSucceeded: true,
            exitStatus: 1,
            duration: 0.25,
            standardError: "device is locked; clear was rejected"
          )
        )
      ]
    )
    let backend = DevicectlInjectionBackend(
      device: "Active Test Device",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: executor,
      diagnostics: diagnostics
    )
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000302")!

    let result = await backend.execute(.clear(requestID: requestID))

    XCTAssertEqual(result, .failed(requestID: requestID, reason: .clearFailed))
    let events = await diagnostics.events()
    XCTAssertEqual(events.map(\.kind), [
      "controller.devicectl.started",
      "controller.devicectl.finished",
    ])
    XCTAssertEqual(events[1].requestID, requestID)
    XCTAssertEqual(
      events[1].fields["standardError"],
      .string("device is locked; clear was rejected")
    )
    XCTAssertEqual(
      events[0].fields["developerDirectory"],
      .string("/Applications/Xcode-beta.app/Contents/Developer")
    )
    XCTAssertEqual(
      events[0].fields["device"],
      .string("Active Test Device")
    )
    let exported = String(data: try await diagnostics.exportData(), encoding: .utf8)!
    XCTAssertFalse(exported.contains("PINSHIFT_E2E_PAIRING_CODE"))
  }

  func testDiagnosticsPreserveConfiguredDeviceSelectorInTheLocalArtifact() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let selector = "SENTINEL-UDID-00008030-001C2D3E4F5A801E"
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000303")!
    let executor = RecordingDevicectlCommandExecutor(
      results: [
        .completed(
          DevicectlCommandExecutionDetails(
            launchSucceeded: true,
            exitStatus: 1,
            duration: 0.25,
            standardOutput: "devicectl echoed " + selector + "; unrelated diagnostic text",
            standardError: "clear rejected for device " + selector + "; device is locked"
          )
        )
      ]
    )
    let backend = DevicectlInjectionBackend(
      device: selector,
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      executor: executor,
      diagnostics: diagnostics
    )

    let result = await backend.execute(.clear(requestID: requestID))

    XCTAssertEqual(result, .failed(requestID: requestID, reason: .clearFailed))
    let events = await diagnostics.events()
    XCTAssertEqual(events.count, 2)
    XCTAssertEqual(events[0].requestID, requestID)
    XCTAssertEqual(events[1].requestID, requestID)
    XCTAssertEqual(events[0].fields["device"], .string(selector))
    XCTAssertEqual(
      events[0].fields["arguments"],
      .array([
        .string("devicectl"), .string("device"), .string("simulate"),
        .string("location"), .string("clear"), .string("--device"),
        .string(selector), .string("--quiet"),
        .string("--timeout"), .string("15"),
      ])
    )
    XCTAssertEqual(
      events[1].fields["standardOutput"],
      .string("devicectl echoed " + selector + "; unrelated diagnostic text")
    )
    XCTAssertEqual(
      events[1].fields["standardError"],
      .string("clear rejected for device " + selector + "; device is locked")
    )

    let exported = String(data: try await diagnostics.exportData(), encoding: .utf8)!
    XCTAssertTrue(exported.contains(selector))
    XCTAssertTrue(exported.contains(requestID.uuidString))
    XCTAssertTrue(exported.contains("unrelated diagnostic text"))
    XCTAssertTrue(exported.contains("device is locked"))
  }

  func testProductionExecutorTimesOutWithoutWaitingForDescendantHeldPipes() {
    let executor = FoundationDevicectlCommandExecutor(
      executableURL: URL(fileURLWithPath: "/bin/sh")
    )
    let startedAt = Date()
    let result = executor.execute(
      DevicectlCommandInvocation(
        arguments: ["-c", "sleep 5 & wait"],
        environmentOverrides: [:],
        timeoutSeconds: 0.05
      )
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    guard case .timedOut = result else {
      return XCTFail("Expected the bounded executor to report timeout.")
    }
    XCTAssertLessThan(elapsed, 1.5)
  }

  func testProductionExecutorForcesATermIgnoringProcessWithoutReadingRunningStatus() {
    let executor = FoundationDevicectlCommandExecutor(
      executableURL: URL(fileURLWithPath: "/bin/sh")
    )
    let startedAt = Date()
    let result = executor.execute(
      DevicectlCommandInvocation(
        arguments: ["-c", "trap '' TERM; while :; do :; done"],
        environmentOverrides: [:],
        timeoutSeconds: 0.05
      )
    )
    let elapsed = Date().timeIntervalSince(startedAt)

    guard case .timedOut = result else {
      return XCTFail("Expected the TERM-ignoring process to time out.")
    }
    XCTAssertLessThan(elapsed, 1.5)
  }

  func testTimedOutDevicectlResultMapsToTimedOutWithoutClaimingClear() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let executor = RecordingDevicectlCommandExecutor(
      results: [
        .timedOut(
          DevicectlCommandExecutionDetails(
            launchSucceeded: true,
            exitStatus: nil,
            duration: 15,
            standardError: "device did not respond before timeout"
          )
        )
      ]
    )
    let backend = DevicectlInjectionBackend(
      device: "Active Test Device",
      executor: executor,
      diagnostics: diagnostics
    )
    let requestID = UUID()

    let result = await backend.execute(.clear(requestID: requestID))

    XCTAssertEqual(result, .failed(requestID: requestID, reason: .timedOut))
    let events = await diagnostics.events()
    XCTAssertEqual(events.last?.fields["outcome"], .string("timeout"))
  }

  func testLaunchFailureCapturesTheExecutorErrorWithoutChangingReadinessMapping() async throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let executor = RecordingDevicectlCommandExecutor(
      results: [
        .launchFailed(
          DevicectlCommandExecutionDetails(
            launchSucceeded: false,
            exitStatus: nil,
            duration: 0.01,
            standardError: "xcrun could not launch devicectl"
          )
        )
      ]
    )
    let backend = DevicectlInjectionBackend(
      device: "Active Test Device",
      executor: executor,
      diagnostics: diagnostics
    )

    let readiness = await backend.readiness()

    XCTAssertEqual(readiness, .unavailable(.backendUnavailable))
    let events = await diagnostics.events()
    XCTAssertEqual(events.last?.fields["launchResult"], .string("failed"))
    XCTAssertEqual(
      events.last?.fields["standardError"],
      .string("xcrun could not launch devicectl")
    )
  }

  func testDiagnosticWriteFailureDoesNotChangeBackendOutcome() async throws {
    let recorder = SimulationDiagnosticRecorder(
      side: .macController,
      fileURL: URL(fileURLWithPath: "/dev/null/diagnostics.jsonl")
    )
    let executor = RecordingDevicectlCommandExecutor(results: [.completed(.init(launchSucceeded: true, exitStatus: 0, duration: 0))])
    let backend = DevicectlInjectionBackend(
      device: "Active Test Device",
      executor: executor,
      diagnostics: recorder
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let requestID = UUID()

    let result = await backend.execute(
      .apply(requestID: requestID, location: location)
    )

    XCTAssertEqual(result, .applied(requestID: requestID, location: location))
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-controller-diagnostics-\(UUID().uuidString)")
    try! FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    return directory
  }
}

private final class RecordingDevicectlCommandExecutor:
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
