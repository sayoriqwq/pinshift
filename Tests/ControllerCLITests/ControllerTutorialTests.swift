import ArgumentParser
import XCTest

@testable import ControllerCLI

final class ControllerTutorialTests: XCTestCase {
  func testTutorialCoversTheCurrentReadOnlySetupAndSimulationWorkflow() throws {
    let output = ControllerTutorial.output

    for requiredText in [
      "open Xcode",
      "Trust",
      "Developer Mode",
      "automatic signing",
      "seven days",
      "devicectl",
      "pinshift-install",
      "pinshift-start",
      "Apply",
      "Verify",
      "15, 30, or 60 minutes",
      "active card",
      "Cleanup Guardian",
      "server-owner heartbeat",
      "Location",
      "Local Network",
    ] {
      XCTAssertTrue(output.localizedCaseInsensitiveContains(requiredText), requiredText)
    }
    XCTAssertFalse(output.localizedCaseInsensitiveContains("XCUITest"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("sudo"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("xcode-select --switch"))
  }

  func testDoctorAndTutorialAreRegisteredSubcommands() throws {
    XCTAssertTrue(
      try PinshiftControllerCommand.parseAsRoot(["doctor"])
        is PinshiftControllerCommand.Doctor
    )
    XCTAssertTrue(
      try PinshiftControllerCommand.parseAsRoot(["tutorial"])
        is PinshiftControllerCommand.Tutorial
    )
    XCTAssertTrue(
      try PinshiftControllerCommand.parseAsRoot([
        "link", "identity", "authorize-current-executable",
      ]) is PinshiftControllerCommand.Link.Identity.AuthorizeCurrentExecutable
    )
  }
}
