import Foundation
import XCTest

@testable import LocationDomain

final class ManualSimulationSessionTests: XCTestCase {
  private let startedAt = Date(timeIntervalSince1970: 1_000)
  private let deadline = Date(timeIntervalSince1970: 1_900)

  func testDefaultStoreMigratesTheExistingAppFileInPlace() {
    let url = FileManualSimulationSessionStore.defaultFileURL(environment: [:])

    XCTAssertTrue(url.path.hasSuffix("/Pinshift/AppLifecycle/session.json"))
  }

  func testOnlyTheLatestApplyCanBecomeAppliedAndVerified() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    _ = try session.beginApply(requestID: firstID, at: startedAt)

    try session.select(latitude: "31.2200", longitude: "121.4800")
    let secondID = UUID()
    let second = try session.beginApply(
      requestID: secondID,
      at: startedAt.addingTimeInterval(1)
    )

    XCTAssertFalse(
      session.acknowledgeApplied(
        requestID: firstID,
        automaticClearAt: deadline
      )
    )
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: secondID,
        automaticClearAt: deadline.addingTimeInterval(1)
      )
    )
    session.record(
      LocationObservation(
        coordinate: second.location,
        timestamp: startedAt.addingTimeInterval(2),
        horizontalAccuracy: 5,
        isSimulatedBySoftware: true
      )
    )
    guard case .verified(let request, _) = session.status else {
      return XCTFail("The latest Applied request should be verifiable")
    }
    XCTAssertEqual(request.requestID, secondID)
  }

  func testSelectionAndReplacementApplyRemainAvailableAfterUnconfirmedClear() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    _ = try session.beginApply(requestID: firstID, at: startedAt)
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: firstID,
        automaticClearAt: deadline
      )
    )

    let clear = session.beginClear(requestID: UUID(), at: startedAt)
    XCTAssertTrue(
      session.failClear(requestID: clear.requestID, reason: .controllerUnavailable)
    )

    let replacement = try SelectedLocation(latitude: 35.6812, longitude: 139.7671)
    session.select(replacement)
    let replacementRequest = try session.beginApply(
      requestID: UUID(),
      at: startedAt.addingTimeInterval(2)
    )
    XCTAssertEqual(replacementRequest.location, replacement)
  }

  func testSelectingWhileApplyIsInFlightPreservesItsReplyAndPreparesReplacement() throws {
    var session = ManualSimulationSession()
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let replacement = try SelectedLocation(latitude: 35.6812, longitude: 139.7671)
    session.select(first)
    let firstID = UUID()
    _ = try session.beginApply(requestID: firstID, at: startedAt)

    session.select(replacement)

    XCTAssertEqual(session.selected, replacement)
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: firstID,
        automaticClearAt: deadline
      )
    )
    XCTAssertEqual(session.activeAppliedRequest?.location, first)

    let replacementRequest = try session.beginApply(
      requestID: UUID(),
      at: startedAt.addingTimeInterval(1)
    )
    XCTAssertEqual(replacementRequest.location, replacement)
  }

  func testLateClearResponseCannotEraseANewerApply() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    _ = try session.beginApply(requestID: firstID, at: startedAt)
    _ = session.acknowledgeApplied(requestID: firstID, automaticClearAt: deadline)
    let clear = session.beginClear(requestID: UUID(), at: startedAt)

    try session.select(latitude: "35.6812", longitude: "139.7671")
    let replacementID = UUID()
    _ = try session.beginApply(
      requestID: replacementID,
      at: startedAt.addingTimeInterval(1)
    )
    _ = session.acknowledgeApplied(
      requestID: replacementID,
      automaticClearAt: deadline.addingTimeInterval(1)
    )

    XCTAssertFalse(session.acknowledgeCleared(requestID: clear.requestID))
    XCTAssertEqual(session.activeAppliedRequest?.requestID, replacementID)
  }

  func testControllerSnapshotReplacesLocalDisplayState() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let requestID = UUID()
    let controllerLocation = try SelectedLocation(latitude: 35.6812, longitude: 139.7671)

    session.replaceWithControllerSnapshot(
      .active(
        operationID: requestID,
        location: controllerLocation,
        automaticClearAt: deadline
      ),
      at: startedAt
    )
    XCTAssertEqual(session.activeAppliedRequest?.requestID, requestID)
    XCTAssertEqual(session.activeAppliedRequest?.location, controllerLocation)

    session.replaceWithControllerSnapshot(.idle)
    XCTAssertNil(session.activeAppliedRequest)
    XCTAssertEqual(session.selected, try SelectedLocation(latitude: 31.2304, longitude: 121.4737))
  }

  func testSameOperationSnapshotPreservesLocalVerificationEvidence() throws {
    var session = ManualSimulationSession()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    session.select(location)
    let requestID = UUID()
    _ = try session.beginApply(requestID: requestID, at: startedAt)
    _ = session.acknowledgeApplied(requestID: requestID, automaticClearAt: deadline)
    session.record(
      LocationObservation(
        coordinate: location,
        timestamp: startedAt.addingTimeInterval(1),
        horizontalAccuracy: 5,
        isSimulatedBySoftware: true
      )
    )

    session.replaceWithControllerSnapshot(
      .active(
        operationID: requestID,
        location: location,
        automaticClearAt: deadline
      ),
      at: startedAt.addingTimeInterval(2)
    )

    guard case .verified(let request, _) = session.status else {
      return XCTFail("Polling the same Mac operation must not erase local evidence.")
    }
    XCTAssertEqual(request.requestID, requestID)
  }

  func testIdleSnapshotKeepsAcknowledgedClearFeedbackTransiently() throws {
    var session = ManualSimulationSession()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    session.select(location)
    let applyID = UUID()
    _ = try session.beginApply(requestID: applyID, at: startedAt)
    _ = session.acknowledgeApplied(requestID: applyID, automaticClearAt: deadline)
    let clear = session.beginClear(requestID: UUID(), at: startedAt)
    _ = session.acknowledgeCleared(requestID: clear.requestID)

    session.replaceWithControllerSnapshot(.idle)

    XCTAssertNil(session.activeAppliedRequest)
    XCTAssertEqual(session.clearStatus, .cleared(requestID: clear.requestID))
  }

  func testSuccessfulClearSeparatesInactiveSimulationFromHistoricalObservation() throws {
    var session = ManualSimulationSession()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let observation = LocationObservation(
      coordinate: location,
      timestamp: startedAt.addingTimeInterval(1),
      horizontalAccuracy: 5,
      isSimulatedBySoftware: true
    )
    session.select(location)
    let applyID = UUID()
    _ = try session.beginApply(requestID: applyID, at: startedAt)
    _ = session.acknowledgeApplied(requestID: applyID, automaticClearAt: deadline)
    session.record(observation)
    let clear = session.beginClear(requestID: UUID(), at: startedAt.addingTimeInterval(2))

    XCTAssertTrue(session.acknowledgeCleared(requestID: clear.requestID))

    XCTAssertNil(session.activeAppliedRequest)
    XCTAssertEqual(session.latestObservation, observation)
    XCTAssertEqual(session.clearStatus, .cleared(requestID: clear.requestID))
    XCTAssertEqual(session.status, .selected(location))
  }

  func testControllerPollingCannotCancelAnExplicitActionInFlight() throws {
    var session = ManualSimulationSession()
    let previous = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let replacement = try SelectedLocation(latitude: 35.6812, longitude: 139.7671)
    session.select(previous)
    let previousID = UUID()
    _ = try session.beginApply(requestID: previousID, at: startedAt)
    _ = session.acknowledgeApplied(requestID: previousID, automaticClearAt: deadline)

    session.select(replacement)
    let replacementID = UUID()
    _ = try session.beginApply(
      requestID: replacementID,
      at: startedAt.addingTimeInterval(1)
    )
    session.replaceWithControllerSnapshot(
      .active(
        operationID: previousID,
        location: previous,
        automaticClearAt: deadline
      )
    )
    guard case .applying(let applying) = session.status else {
      return XCTFail("A status poll must not cancel an explicit Apply in flight.")
    }
    XCTAssertEqual(applying.requestID, replacementID)

    _ = session.acknowledgeApplied(
      requestID: replacementID,
      automaticClearAt: deadline.addingTimeInterval(1)
    )
    let clear = session.beginClear(requestID: UUID(), at: startedAt.addingTimeInterval(2))
    session.replaceWithControllerSnapshot(
      .active(
        operationID: replacementID,
        location: replacement,
        automaticClearAt: deadline.addingTimeInterval(1)
      )
    )
    XCTAssertEqual(session.currentClearRequest, clear)
    XCTAssertEqual(session.clearStatus, .clearing(requestID: clear.requestID))
  }

  func testLegacyPendingStopIsDiscardedWhileSelectionSurvivesRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-app-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("session.json")
    let legacy = """
      {
        "schemaVersion": 1,
        "session": {
          "selected": {"latitude":31.2304,"longitude":121.4737},
          "pendingStopIntent": {
            "requestID":"00000000-0000-0000-0000-000000000001",
            "generationID":"00000000-0000-0000-0000-000000000002",
            "requestedAt":1000
          },
          "cleanupStatus":{"restoreRequested":{"requestID":"00000000-0000-0000-0000-000000000001"}}
        }
      }
      """
    try Data(legacy.utf8).write(to: file)

    let restored = try XCTUnwrap(FileManualSimulationSessionStore(fileURL: file).load())
    XCTAssertEqual(
      restored.selected,
      try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    )
    XCTAssertNil(restored.activeAppliedRequest)
    XCTAssertEqual(restored.clearStatus, .idle)
    let migrated = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    )
    XCTAssertEqual(migrated["schemaVersion"] as? Int, 2)
    XCTAssertNil(migrated["session"])
  }
}
