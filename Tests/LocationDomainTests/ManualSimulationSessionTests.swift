import XCTest

@testable import LocationDomain

final class ManualSimulationSessionTests: XCTestCase {
  private let location = try! SelectedLocation(latitude: 31.2304, longitude: 121.4737)
  private let requestTime = Date(timeIntervalSince1970: 1_000)

  func testOnlyAppliedRequestCanBecomeVerifiedByAFreshNearbyObservation() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let requestID = UUID()
    let request = try session.beginApply(requestID: requestID, at: requestTime)

    session.record(observation(secondsAfterRequest: 2))
    XCTAssertEqual(session.status, .applying(request))

    XCTAssertTrue(session.acknowledgeApplied(requestID: requestID))
    XCTAssertEqual(session.status, .applied(request))

    session.record(observation(secondsAfterRequest: 3))
    guard case .verified(let verifiedRequest, let evidence) = session.status else {
      return XCTFail("Expected the current Applied request to become Verified")
    }
    XCTAssertEqual(verifiedRequest, request)
    XCTAssertEqual(evidence.elapsedSeconds, 3)
    XCTAssertEqual(evidence.distanceMeters, 0, accuracy: 0.001)
  }

  func testNewApplyImmediatelyInvalidatesEarlierVerification() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    _ = try session.beginApply(requestID: firstID, at: requestTime)
    _ = session.acknowledgeApplied(requestID: firstID)
    session.record(observation(secondsAfterRequest: 2))
    guard case .verified = session.status else {
      return XCTFail("Expected initial verification")
    }

    let secondID = UUID()
    let secondRequest = try session.beginApply(
      requestID: secondID,
      at: requestTime.addingTimeInterval(10)
    )

    XCTAssertEqual(session.status, .applying(secondRequest))
  }

  func testWrongAcknowledgementIdentityFailsWithoutClaimingApplied() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let requestID = UUID()
    let request = try session.beginApply(requestID: requestID, at: requestTime)

    XCTAssertFalse(session.acknowledgeApplied(requestID: UUID()))
    XCTAssertEqual(session.status, .failed(request, .responseIdentityMismatch))
  }

  func testAppliedRequestRetainsActionableDistanceAndTimeoutDiagnostics() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let requestID = UUID()
    let request = try session.beginApply(requestID: requestID, at: requestTime)
    _ = session.acknowledgeApplied(requestID: requestID)

    session.record(
      LocationObservation(
        coordinate: try SelectedLocation(latitude: 31.2304, longitude: 121.4741),
        timestamp: requestTime.addingTimeInterval(3),
        horizontalAccuracy: 5,
        isSimulatedBySoftware: true
      )
    )
    guard case .appliedNotVerified(let currentRequest, .tooFar(let meters)) = session.status else {
      return XCTFail("Expected an Applied-but-not-verified distance diagnostic")
    }
    XCTAssertEqual(currentRequest, request)
    XCTAssertGreaterThan(meters, 25)

    session.expire(at: requestTime.addingTimeInterval(15.001))
    guard
      case .appliedNotVerified(
        let timedOutRequest,
        .timedOut(let elapsedSeconds)
      ) = session.status
    else {
      return XCTFail("Expected an Applied-but-not-verified timeout diagnostic")
    }
    XCTAssertEqual(timedOutRequest, request)
    XCTAssertEqual(elapsedSeconds, 15.001, accuracy: 0.000_1)
  }

  func testStopClearsTheActiveAppliedRequestOnlyAfterMatchingAcknowledgement() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let applyID = UUID()
    let appliedRequest = try session.beginApply(requestID: applyID, at: requestTime)
    XCTAssertTrue(session.acknowledgeApplied(requestID: applyID))
    XCTAssertEqual(session.activeAppliedRequest, appliedRequest)

    let stopID = UUID()
    session.beginStop(requestID: stopID)
    XCTAssertFalse(session.acknowledgeStopped(requestID: UUID()))
    XCTAssertEqual(session.activeAppliedRequest, appliedRequest)
    guard case .failed(let failedID, .responseIdentityMismatch) = session.stopStatus else {
      return XCTFail("Expected a correlated Stop failure")
    }
    XCTAssertEqual(failedID, stopID)

    session.beginStop(requestID: stopID)
    XCTAssertTrue(session.acknowledgeStopped(requestID: stopID))
    XCTAssertNil(session.activeAppliedRequest)
    XCTAssertEqual(session.stopStatus, .stopped(requestID: stopID))
    XCTAssertEqual(session.status, .stopped)
  }

  func testFailedReplacementKeepsThePreviouslyAppliedSimulationActive() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    let firstRequest = try session.beginApply(requestID: firstID, at: requestTime)
    _ = session.acknowledgeApplied(requestID: firstID)

    try session.select(latitude: "52.5200", longitude: "13.4050")
    let secondID = UUID()
    _ = try session.beginApply(
      requestID: secondID,
      at: requestTime.addingTimeInterval(10)
    )
    _ = session.fail(
      requestID: secondID,
      reason: .requestRejected(stableCode: "backendUnavailable")
    )

    XCTAssertEqual(session.activeAppliedRequest, firstRequest)
  }

  func testSelectingReplacementKeepsAppliedRequestActiveAndStoppableUntilAcknowledged() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let applyID = UUID()
    let appliedRequest = try session.beginApply(requestID: applyID, at: requestTime)
    XCTAssertTrue(session.acknowledgeApplied(requestID: applyID))

    let replacement = try SelectedLocation(latitude: 52.5200, longitude: 13.4050)
    session.select(replacement)

    XCTAssertEqual(session.selected, replacement)
    XCTAssertEqual(session.activeAppliedRequest, appliedRequest)
    XCTAssertEqual(session.status, .applied(appliedRequest))

    let stopID = UUID()
    session.beginStop(requestID: stopID)
    XCTAssertTrue(session.acknowledgeStopped(requestID: stopID))
    XCTAssertNil(session.activeAppliedRequest)
  }

  func testSelectingDuringApplyPreservesTheInFlightRequest() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let request = try session.beginApply(requestID: UUID(), at: requestTime)

    let replacement = try SelectedLocation(latitude: 52.5200, longitude: 13.4050)
    session.select(replacement)

    XCTAssertEqual(session.selected, replacement)
    XCTAssertEqual(session.status, .applying(request))
  }

  func testStopDuringReplacementApplyTargetsTheInFlightGeneration() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let firstID = UUID()
    _ = try session.beginApply(
      requestID: firstID,
      generationID: UUID(),
      at: requestTime
    )
    XCTAssertTrue(session.acknowledgeApplied(requestID: firstID))

    try session.select(latitude: "52.5200", longitude: "13.4050")
    let replacementGenerationID = UUID()
    _ = try session.beginApply(
      requestID: UUID(),
      generationID: replacementGenerationID,
      at: requestTime.addingTimeInterval(10)
    )

    let intent = try XCTUnwrap(session.beginStop(requestID: UUID()))

    XCTAssertEqual(intent.generationID, replacementGenerationID)
  }

  func testLateAppliedAcknowledgementStillEndsAsAppliedButTimedOut() throws {
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let requestID = UUID()
    let request = try session.beginApply(requestID: requestID, at: requestTime)

    session.expire(at: requestTime.addingTimeInterval(15.001))
    XCTAssertEqual(session.status, .applying(request))
    XCTAssertTrue(session.acknowledgeApplied(requestID: requestID))
    session.expire(at: requestTime.addingTimeInterval(16))

    XCTAssertEqual(
      session.status,
      .appliedNotVerified(request, .timedOut(elapsedSeconds: 16))
    )
  }

  func testPendingStopSurvivesRelaunchAndKeepsTheSameOperationIdentity() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-app-lifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileManualSimulationSessionStore(
      fileURL: directory.appendingPathComponent("session.json")
    )
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let applyID = UUID()
    let generationID = UUID()
    _ = try session.beginApply(
      requestID: applyID,
      generationID: generationID,
      at: requestTime
    )
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: applyID,
        generationID: generationID,
        leaseExpiresAt: requestTime.addingTimeInterval(3_600)
      )
    )
    let stopID = UUID()
    let intent = session.beginStop(requestID: stopID, at: requestTime)
    try store.save(session)

    var restored = try XCTUnwrap(store.load())
    XCTAssertEqual(restored.pendingStopIntent, intent)
    let reusedIntent = restored.beginStop(requestID: UUID(), at: requestTime)
    XCTAssertEqual(reusedIntent, intent)
  }

  func testActiveGenerationSurvivesRelaunchAndRemainsStoppable() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-active-lifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileManualSimulationSessionStore(
      fileURL: directory.appendingPathComponent("session.json")
    )
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let applyID = UUID()
    let generationID = UUID()
    _ = try session.beginApply(
      requestID: applyID,
      generationID: generationID,
      at: requestTime
    )
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: applyID,
        generationID: generationID,
        leaseExpiresAt: requestTime.addingTimeInterval(3_600)
      )
    )
    try store.save(session)

    var restored = try XCTUnwrap(store.load())
    let intent = try XCTUnwrap(restored.beginStop(requestID: UUID()))

    XCTAssertEqual(restored.activeAppliedRequest?.generationID, generationID)
    XCTAssertEqual(intent.generationID, generationID)
  }

  private func observation(secondsAfterRequest: TimeInterval) -> LocationObservation {
    LocationObservation(
      coordinate: location,
      timestamp: requestTime.addingTimeInterval(secondsAfterRequest),
      horizontalAccuracy: 5,
      isSimulatedBySoftware: true
    )
  }
}
