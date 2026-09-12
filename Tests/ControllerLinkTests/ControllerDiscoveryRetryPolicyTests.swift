import XCTest

@testable import ControllerLink

final class ControllerDiscoveryRetryPolicyTests: XCTestCase {
  func testServiceReturningAfterDisappearanceStartsANewConnectionAttempt() {
    var policy = ControllerDiscoveryRetryPolicy()

    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    XCTAssertFalse(policy.beginConnectionAttemptIfAllowed())

    policy.serviceBecameAbsent()

    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
  }

  func testExplicitRetryReenablesConnectionAfterTerminalDiscoveryFailure() {
    var policy = ControllerDiscoveryRetryPolicy()
    policy.stopRetrying()

    XCTAssertFalse(policy.beginConnectionAttemptIfAllowed())

    policy.reset()

    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
  }

  func testFailedConnectionRetriesWhileServiceRemainsPresentWithBoundedBackoff() {
    var policy = ControllerDiscoveryRetryPolicy()

    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    var retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 1)
    XCTAssertFalse(policy.beginConnectionAttemptIfAllowed())

    XCTAssertTrue(policy.retryDelayElapsed(retry))
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 2)

    XCTAssertTrue(policy.retryDelayElapsed(retry))
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 4)

    XCTAssertTrue(policy.retryDelayElapsed(retry))
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 8)

    XCTAssertTrue(policy.retryDelayElapsed(retry))
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    XCTAssertEqual(policy.scheduleRetryAfterConnectionFailure().delay, 8)
  }

  func testServiceDisappearanceResetsBackoff() {
    var policy = ControllerDiscoveryRetryPolicy()
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    var retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 1)
    XCTAssertTrue(policy.retryDelayElapsed(retry))
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    retry = policy.scheduleRetryAfterConnectionFailure()
    XCTAssertEqual(retry.delay, 2)

    policy.serviceBecameAbsent()

    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    XCTAssertEqual(policy.scheduleRetryAfterConnectionFailure().delay, 1)
  }

  func testStoppingRetriesInvalidatesAnAlreadyScheduledRetry() {
    var policy = ControllerDiscoveryRetryPolicy()
    XCTAssertTrue(policy.beginConnectionAttemptIfAllowed())
    let retry = policy.scheduleRetryAfterConnectionFailure()

    policy.stopRetrying()

    XCTAssertFalse(policy.retryDelayElapsed(retry))
    XCTAssertFalse(policy.beginConnectionAttemptIfAllowed())
  }
}
