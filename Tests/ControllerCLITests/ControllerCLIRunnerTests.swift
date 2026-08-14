import Foundation
import SimulationController
import XCTest

@testable import ControllerCLI

final class ControllerCLIRunnerTests: XCTestCase {
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

  func testApplyReportsAutomaticClearWithoutClaimingVerification() async {
    let now = Date(timeIntervalSince1970: 1_000)
    let runner = ControllerCLIRunner(
      controller: SimulationController(
        backend: InMemoryInjectionBackend(),
        now: { now },
        automaticallySchedulesMaintenance: false
      )
    )
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    let result = await runner.run(
      .apply(
        latitude: "31.2304",
        longitude: "121.4737",
        requestID: requestID
      )
    )

    XCTAssertEqual(result.exitCode, 0)
    XCTAssertTrue(result.output.contains(requestID.uuidString))
    XCTAssertTrue(result.output.contains("automatic clear is armed"))
    XCTAssertFalse(result.output.localizedCaseInsensitiveContains("verified"))
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
