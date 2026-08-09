import Foundation
import LocationDomain
import SimulationDiagnostics
import XCTest

@testable import SimulationController

final class SimulationControllerTests: XCTestCase {
  func testReadyBackendAppliesCoordinateAndReportsAppliedState() async throws {
    let backend = InMemoryInjectionBackend(readiness: .ready)
    let controller = SimulationController(backend: backend)
    let requestID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let result = await controller.apply(location, requestID: requestID)

    XCTAssertEqual(result, .applied(requestID: requestID, location: location))
    let status = await controller.status()
    XCTAssertEqual(status, .applied(requestID: requestID, location: location))
  }

  func testFailedStopIsRecordedWithoutClaimingStoppedSimulation() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-controller-events-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let controller = SimulationController(
      backend: FailingClearBackend(),
      diagnostics: diagnostics
    )
    let applyID = UUID(uuidString: "00000000-0000-0000-0000-000000000304")!
    let stopID = UUID(uuidString: "00000000-0000-0000-0000-000000000305")!
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let applyResult = await controller.apply(location, requestID: applyID)
    let stopResult = await controller.stop(requestID: stopID)
    let status = await controller.status()
    XCTAssertEqual(
      applyResult,
      .applied(requestID: applyID, location: location)
    )
    XCTAssertEqual(
      stopResult,
      .failed(requestID: stopID, reason: .clearFailed)
    )
    XCTAssertEqual(status, .failed(requestID: stopID, reason: .clearFailed))

    let events = await diagnostics.events()
    XCTAssertTrue(
      events.contains {
        $0.kind == "controller.stop.backend-response"
          && $0.requestID == stopID
          && $0.fields["outcome"] == .string("failed")
      }
    )
    XCTAssertFalse(
      events.contains {
        $0.kind == "controller.stop.backend-response"
          && $0.fields["outcome"] == .string("cleared")
      }
    )
  }
}

private actor FailingClearBackend: InjectionBackend {
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
