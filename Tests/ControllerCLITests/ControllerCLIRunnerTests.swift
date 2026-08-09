import SimulationController
import XCTest

@testable import ControllerCLI

final class ControllerCLIRunnerTests: XCTestCase {
  func testStatusUsesTheCurrentDevicectlWorkflowAndDoesNotInventPersistentState() async {
    let runner = ControllerCLIRunner(
      controller: SimulationController(backend: InMemoryInjectionBackend())
    )

    let result = await runner.run(.status)

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      result.output,
      "The Active Test Device and Xcode/devicectl Injection Backend are ready. Applied and Verified state is reported by the active Controller Link and Pinshift app."
    )
    XCTAssertFalse(result.output.localizedCaseInsensitiveContains("test session"))
  }

  func testApplyReportsBackendAcknowledgementWithoutClaimingVerification() async {
    let controller = SimulationController(backend: InMemoryInjectionBackend())
    let runner = ControllerCLIRunner(controller: controller)
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let result = await runner.run(
      .apply(
        latitude: "31.2304",
        longitude: "121.4737",
        requestID: requestID
      )
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertEqual(
      result.output,
      "Applied Simulation acknowledged for request 00000000-0000-0000-0000-000000000002 at 31.230400, 121.473700. Pinshift app verification is still required."
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
