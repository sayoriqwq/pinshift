import ControllerLink
import Foundation
import SimulationController
import XCTest

@testable import ControllerCLI

final class SimulationControllerCommandHandlerTests: XCTestCase {
  func testMapsStatusApplyAndClearToTheSimulationController() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let controller = SimulationController(
      backend: InMemoryInjectionBackend(),
      now: { now },
      automaticallySchedulesMaintenance: false
    )
    let handler = SimulationControllerCommandHandler(controller: controller)
    let statusID = UUID()
    let status = await handler.handle(.status(requestID: statusID))
    XCTAssertEqual(
      status,
      .status(
        requestID: statusID,
        status: ControllerStatus(readiness: .ready, simulation: .idle)
      )
    )

    let applyID = UUID()
    let applied = await handler.handle(
      .apply(requestID: applyID, latitude: 31.2304, longitude: 121.4737)
    )
    XCTAssertEqual(
      applied,
      .applied(
        requestID: applyID,
        automaticClearAt: now.addingTimeInterval(180)
      )
    )

    let clearID = UUID()
    let cleared = await handler.handle(
      .clear(requestID: clearID)
    )
    XCTAssertEqual(
      cleared,
      .cleared(requestID: clearID)
    )
  }

  func testRejectsInvalidCoordinatesBeforeCallingTheInjectionBackend() async {
    let backend = CountingBackend()
    let controller = SimulationController(backend: backend)
    let handler = SimulationControllerCommandHandler(controller: controller)
    let requestID = UUID()

    let result = await handler.handle(
      .apply(requestID: requestID, latitude: 91, longitude: 0)
    )
    XCTAssertEqual(
      result,
      .failed(requestID: requestID, reason: .invalidCoordinate)
    )
    let executeCount = await backend.executeCount
    XCTAssertEqual(executeCount, 0)
  }
}

private actor CountingBackend: InjectionBackend {
  private(set) var executeCount = 0

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    executeCount += 1
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      return .cleared(requestID: requestID)
    }
  }
}
