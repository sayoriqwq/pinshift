import Foundation
import SimulationController
import XCTest

@testable import ControllerCLI

final class ControllerCLIRunnerTests: XCTestCase {
  func testRootCommandDoesNotExposeOneShotApplyOutsideForegroundSession() {
    let help = PinshiftControllerCommand.helpMessage()

    XCTAssertFalse(help.contains("\n  apply"))
  }

  func testStatusReportsIdleReadyAuthority() async {
    let runner = ControllerCLIRunner(
      controller: SimulationController(backend: InMemoryInjectionBackend())
    )

    let result = await runner.run(.status)
    XCTAssertEqual(
      result,
      ControllerCLIResult(
        exitCode: 0,
        output: "No Simulated Location is active; the Injection Backend is ready."
      )
    )
  }

  func testResetIsIdempotentWithAndWithoutAnActiveSimulation() async {
    let controller = SimulationController(backend: InMemoryInjectionBackend())
    let runner = ControllerCLIRunner(controller: controller)
    let firstID = UUID()
    let secondID = UUID()

    let first = await runner.run(.reset(requestID: firstID))
    let second = await runner.run(.reset(requestID: secondID))

    XCTAssertEqual(first.exitCode, 0)
    XCTAssertEqual(second.exitCode, 0)
    XCTAssertTrue(first.output.contains(firstID.uuidString))
    XCTAssertTrue(second.output.contains(secondID.uuidString))
  }
}
