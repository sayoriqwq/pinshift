import Foundation
import XCTest

@testable import LocationDomain

final class ManualSimulationSessionTests: XCTestCase {
  private let startedAt = Date(timeIntervalSince1970: 1_000)
  private let deadline = Date(timeIntervalSince1970: 1_900)

  func testUnconfirmedSnapshotsNeverManufactureAppliedOrVerifiedSimulation() throws {
    let location = try SelectedLocation(latitude: 35.676212345678, longitude: 139.650312345678)
    let operationID = UUID()
    for snapshot in [
      ManualSimulationControllerSnapshot.uncertain(
        operationID: operationID, location: location, automaticClearAt: deadline),
      .clearPending(operationID: operationID, location: location, automaticClearAt: deadline),
    ] {
      var session = ManualSimulationSession()
      session.select(location)
      session.replaceWithControllerSnapshot(snapshot, at: startedAt)
      session.record(
        LocationObservation(
          coordinate: location, timestamp: startedAt.addingTimeInterval(1), horizontalAccuracy: 5,
          isSimulatedBySoftware: true))
      XCTAssertNil(session.activeAppliedRequest)
      if case .verified = session.status {
        XCTFail("An observation cannot replace a missing Apply receipt")
      }
      let next = try session.beginApply(requestID: UUID(), at: startedAt.addingTimeInterval(2))
      XCTAssertEqual(next.location, location, "Uncertainty must not block new Apply")
    }
  }

  func testUncertainReplacementKeepsOnlyLastConfirmedAAndCannotVerifyB() throws {
    var session = ManualSimulationSession()
    let a = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let b = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)
    session.select(a)
    let first = try session.beginApply(requestID: UUID(), at: startedAt)
    XCTAssertTrue(
      session.acknowledgeApplied(requestID: first.requestID, automaticClearAt: deadline))
    session.select(b)
    let second = try session.beginApply(requestID: UUID(), at: startedAt.addingTimeInterval(1))
    XCTAssertTrue(session.fail(requestID: second.requestID, reason: .controllerUnavailable))
    session.replaceWithControllerSnapshot(
      .uncertain(operationID: second.requestID, location: b, automaticClearAt: deadline),
      at: startedAt.addingTimeInterval(2))
    session.record(
      LocationObservation(
        coordinate: b, timestamp: startedAt.addingTimeInterval(3), horizontalAccuracy: 5,
        isSimulatedBySoftware: true))
    XCTAssertEqual(session.activeAppliedRequest?.requestID, first.requestID)
    XCTAssertEqual(session.selected, b)
    guard case .failed(let unconfirmed, _) = session.status else {
      return XCTFail("B is still unconfirmed")
    }
    XCTAssertEqual(unconfirmed.requestID, second.requestID)
    session.replaceWithControllerSnapshot(
      .clearPending(operationID: second.requestID, location: b, automaticClearAt: deadline),
      at: startedAt.addingTimeInterval(4))
    XCTAssertEqual(session.activeAppliedRequest?.requestID, first.requestID)
    guard case .unconfirmed = session.clearStatus else {
      return XCTFail("Clear remains unconfirmed")
    }
    session.replaceWithControllerSnapshot(
      .active(operationID: second.requestID, location: b, automaticClearAt: deadline),
      at: startedAt.addingTimeInterval(5))
    XCTAssertEqual(session.activeAppliedRequest?.location, b)
    session.record(
      LocationObservation(
        coordinate: b, timestamp: startedAt.addingTimeInterval(3), horizontalAccuracy: 5,
        isSimulatedBySoftware: true))
    guard case .appliedNotVerified(_, .notAfterRequest) = session.status else {
      return XCTFail("The old sample cannot verify a newly confirmed operation")
    }
    session.record(
      LocationObservation(
        coordinate: b, timestamp: startedAt.addingTimeInterval(6), horizontalAccuracy: 5,
        isSimulatedBySoftware: true))
    guard case .verified = session.status else {
      return XCTFail("A fresh sample can verify acknowledged B")
    }
  }

  func testDefaultStoreUsesTheAppSelectionFile() {
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

}
