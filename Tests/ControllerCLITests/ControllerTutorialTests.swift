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
      "temporary for 15 minutes",
      "active card",
      "latest Apply replaces",
      "Historical state never blocks",
      "first reachable opportunity",
      "Location",
      "Local Network",
    ] {
      XCTAssertTrue(output.localizedCaseInsensitiveContains(requiredText), requiredText)
    }
    XCTAssertFalse(output.localizedCaseInsensitiveContains("XCUITest"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("sudo"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("xcode-select --switch"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("Cleanup Guardian"))
    XCTAssertFalse(output.localizedCaseInsensitiveContains("Simulation Lease"))
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
      try PinshiftControllerCommand.parseAsRoot(["clear"])
        is PinshiftControllerCommand.Clear
    )
    XCTAssertTrue(
      try PinshiftControllerCommand.parseAsRoot([
        "link", "identity", "authorize-current-executable",
      ]) is PinshiftControllerCommand.Link.Identity.AuthorizeCurrentExecutable
    )
  }
}
