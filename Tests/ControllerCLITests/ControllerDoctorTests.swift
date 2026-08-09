import XCTest

@testable import ControllerCLI

final class ControllerDoctorTests: XCTestCase {
  private let configuration = ControllerDoctorConfiguration(
    device: "Private Device Selector",
    developerDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
    identityLabel: "Pinshift Controller"
  )

  func testHealthyFixturePassesWithoutExposingPrivateProbeData() {
    let report = ControllerDoctor.evaluate(
      snapshot(
        activeDeveloperDirectory: "/Applications/Xcode-beta.app/Contents/Developer",
        deviceState: .available,
        signingReady: true,
        controllerIdentityReady: true
      ),
      configuration: configuration
    )

    XCTAssertEqual(report.exitCode, 0)
    XCTAssertTrue(report.check(.fullXcode)?.status == .pass)
    XCTAssertTrue(report.check(.activeDevice)?.status == .pass)
    XCTAssertTrue(report.check(.developerMode)?.status == .pass)
    XCTAssertTrue(report.check(.developerDiskImage)?.status == .pass)
    XCTAssertFalse(report.output.contains("Private Device Selector"))
    XCTAssertTrue(report.output.contains("No settings were changed."))
  }

  func testCommandLineToolsMismatchIsActionableButDoesNotChangeGlobalSelection() {
    let report = ControllerDoctor.evaluate(
      snapshot(
        activeDeveloperDirectory: "/Library/Developer/CommandLineTools",
        deviceState: .available
      ),
      configuration: configuration
    )

    let check = report.check(.developerDirectory)
    XCTAssertEqual(check?.status, .warning)
    XCTAssertTrue(check?.summary.contains("Command Line Tools") == true)
    XCTAssertTrue(check?.recovery.contains("does not change the global selection") == true)
  }

  func testFirstLaunchFixtureFailsWithAnExplicitRecoveryStep() {
    let report = ControllerDoctor.evaluate(
      snapshot(firstLaunchReady: false, deviceState: .available),
      configuration: configuration
    )

    XCTAssertEqual(report.exitCode, 1)
    XCTAssertEqual(report.check(.firstLaunch)?.status, .fail)
    XCTAssertTrue(report.check(.firstLaunch)?.recovery.contains("open Xcode") == true)
  }

  func testMissingAndUnavailableDeviceFixturesAreDistinct() {
    let missingConfiguration = ControllerDoctorConfiguration(
      device: nil,
      developerDirectory: configuration.developerDirectory,
      identityLabel: configuration.identityLabel
    )
    let missing = ControllerDoctor.evaluate(
      snapshot(deviceState: .notConfigured),
      configuration: missingConfiguration
    )
    let unavailable = ControllerDoctor.evaluate(
      snapshot(deviceState: .unavailable),
      configuration: configuration
    )

    XCTAssertEqual(missing.check(.activeDevice)?.status, .fail)
    XCTAssertTrue(missing.check(.activeDevice)?.recovery.contains("--device") == true)
    XCTAssertEqual(unavailable.check(.activeDevice)?.status, .fail)
    XCTAssertTrue(unavailable.check(.activeDevice)?.recovery.contains("reconnect") == true)
  }

  func testDeveloperModeAndDDIFixturesProduceDifferentRecovery() {
    let developerMode = ControllerDoctor.evaluate(
      snapshot(deviceState: .developerModeDisabled),
      configuration: configuration
    )
    let ddi = ControllerDoctor.evaluate(
      snapshot(deviceState: .developerDiskImageIncompatible),
      configuration: configuration
    )

    XCTAssertEqual(developerMode.check(.developerMode)?.status, .fail)
    XCTAssertTrue(developerMode.check(.developerMode)?.recovery.contains("Developer Mode") == true)
    XCTAssertEqual(ddi.check(.developerDiskImage)?.status, .fail)
    XCTAssertTrue(ddi.check(.developerDiskImage)?.recovery.contains("Xcode") == true)
  }

  func testSigningAndControllerIdentityFixturesAreActionable() {
    let report = ControllerDoctor.evaluate(
      snapshot(
        deviceState: .available,
        signingReady: false,
        controllerIdentityReady: false
      ),
      configuration: configuration
    )

    XCTAssertEqual(report.check(.signing)?.status, .fail)
    XCTAssertTrue(report.check(.signing)?.recovery.contains("Signing & Capabilities") == true)
    XCTAssertEqual(report.check(.controllerIdentity)?.status, .fail)
    XCTAssertTrue(
      report.check(.controllerIdentity)?.recovery.contains("link identity create") == true)
  }

  private func snapshot(
    activeDeveloperDirectory: String? = "/Applications/Xcode-beta.app/Contents/Developer",
    xcodeVersion: String? = "Xcode 27.0 beta 4",
    firstLaunchReady: Bool = true,
    deviceState: ControllerDoctorDeviceState,
    signingReady: Bool = true,
    controllerIdentityReady: Bool = true
  ) -> ControllerDoctorSnapshot {
    ControllerDoctorSnapshot(
      activeDeveloperDirectory: activeDeveloperDirectory,
      xcodeVersion: xcodeVersion,
      firstLaunchReady: firstLaunchReady,
      deviceState: deviceState,
      signingReady: signingReady,
      controllerIdentityReady: controllerIdentityReady
    )
  }
}

extension ControllerDoctorReport {
  fileprivate func check(_ id: ControllerDoctorCheckID) -> ControllerDoctorCheck? {
    checks.first { $0.id == id }
  }
}
