import XCTest

@testable import ControllerCLI

final class ControllerDoctorProbeTests: XCTestCase {
  func testProductionProbeUsesOnlyReadOnlyAllowlistedCommandsAndRedactsRawOutput() {
    let executor = RecordingDoctorCommandExecutor(
      results: [
        .exited(status: 0, output: "/Library/Developer/CommandLineTools\n"),
        .exited(status: 0, output: "Xcode 27.0 beta 4\nBuild version PrivateBuild\n"),
        .exited(status: 0, output: ""),
        .exited(status: 0, output: "Private Device Selector and Private Device Identifier\n"),
        .exited(
          status: 0,
          output:
            "1) Private Certificate Hash Apple Development: Private Account\n1 valid identities found\n"
        ),
      ]
    )
    let configuration = ControllerDoctorConfiguration(
      device: "Private Device Selector",
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      identityLabel: "Private Controller Identity"
    )
    let probe = FoundationControllerDoctorProbe(
      executor: executor,
      controllerIdentityIsReady: { _ in true }
    )

    let report = ControllerDoctor.evaluate(
      probe.snapshot(configuration: configuration),
      configuration: configuration
    )

    XCTAssertEqual(executor.invocations.count, 5)
    XCTAssertEqual(
      executor.invocations.map(\.executable),
      [
        "/usr/bin/xcode-select",
        "/usr/bin/xcrun",
        "/usr/bin/xcrun",
        "/usr/bin/xcrun",
        "/usr/bin/security",
      ]
    )
    XCTAssertTrue(
      executor.invocations.allSatisfy { invocation in
        let joined = invocation.arguments.joined(separator: " ").lowercased()
        return !joined.contains(" coordinate")
          && !joined.contains(" clear")
          && !joined.contains(" reset")
          && !joined.contains("sudo")
          && !joined.contains("xcode-select --switch")
      }
    )
    XCTAssertTrue(
      executor.invocations
        .filter { $0.executable == "/usr/bin/xcrun" }
        .allSatisfy {
          $0.environmentOverrides["DEVELOPER_DIR"]
            == "/Applications/Xcode-beta.app/Contents/Developer"
        }
    )
    XCTAssertFalse(report.output.contains("Private Device Selector"))
    XCTAssertFalse(report.output.contains("Private Device Identifier"))
    XCTAssertFalse(report.output.contains("Private Certificate Hash"))
    XCTAssertFalse(report.output.contains("Private Account"))
    XCTAssertFalse(report.output.contains("Private Controller Identity"))
  }

  func testNoConfiguredDeviceSkipsDevicectlProbe() {
    let executor = RecordingDoctorCommandExecutor(
      results: [
        .exited(status: 0, output: "/Applications/Xcode-beta.app/Contents/Developer\n"),
        .exited(status: 0, output: "Xcode 27.0 beta 4\n"),
        .exited(status: 0, output: ""),
        .exited(status: 0, output: "1 valid identities found\n"),
      ]
    )
    let configuration = ControllerDoctorConfiguration(
      device: nil,
      developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
      identityLabel: "Pinshift Controller"
    )
    let probe = FoundationControllerDoctorProbe(
      executor: executor,
      controllerIdentityIsReady: { _ in false }
    )

    let snapshot = probe.snapshot(configuration: configuration)

    XCTAssertEqual(snapshot.deviceState, .notConfigured)
    XCTAssertFalse(
      executor.invocations.contains { $0.arguments.contains("devicectl") }
    )
  }

  func testDeviceFailuresDistinguishDeveloperModeAndDeveloperDiskImage() {
    XCTAssertEqual(
      FoundationControllerDoctorProbe.classifyDeviceResult(
        .exited(status: 1, output: "Developer Mode is disabled")
      ),
      .developerModeDisabled
    )
    XCTAssertEqual(
      FoundationControllerDoctorProbe.classifyDeviceResult(
        .exited(status: 1, output: "Could not mount the developer disk image")
      ),
      .developerDiskImageIncompatible
    )
  }

  func testCommandExecutorEnvironmentDropsControllerSecrets() {
    let environment = FoundationControllerDoctorCommandExecutor.sanitizedEnvironment(
      inherited: [
        "HOME": "/Users/developer",
        "PATH": "/usr/bin:/bin",
        "PINSHIFT_DEVICE": "private-device",
        "PINSHIFT_E2E_PAIRING_CODE": "123456",
        "PINSHIFT_RUNNER_CREDENTIAL": "private-credential",
      ],
      overrides: [
        "DEVELOPER_DIR": "/Applications/Xcode-beta.app/Contents/Developer"
      ]
    )

    XCTAssertEqual(environment["HOME"], "/Users/developer")
    XCTAssertEqual(environment["PATH"], "/usr/bin:/bin")
    XCTAssertNil(environment["PINSHIFT_DEVICE"])
    XCTAssertNil(environment["PINSHIFT_E2E_PAIRING_CODE"])
    XCTAssertNil(environment["PINSHIFT_RUNNER_CREDENTIAL"])
  }
}

private final class RecordingDoctorCommandExecutor:
  ControllerDoctorCommandExecuting, @unchecked Sendable
{
  private let lock = NSLock()
  private var pendingResults: [ControllerDoctorCommandResult]
  private var recordedInvocations: [ControllerDoctorCommandInvocation] = []

  init(results: [ControllerDoctorCommandResult]) {
    pendingResults = results
  }

  var invocations: [ControllerDoctorCommandInvocation] {
    lock.withLock { recordedInvocations }
  }

  func execute(_ invocation: ControllerDoctorCommandInvocation) -> ControllerDoctorCommandResult {
    lock.withLock {
      recordedInvocations.append(invocation)
      return pendingResults.removeFirst()
    }
  }
}
