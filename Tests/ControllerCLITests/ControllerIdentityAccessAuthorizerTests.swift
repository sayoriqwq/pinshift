import ControllerLink
import XCTest

@testable import ControllerCLI

final class ControllerIdentityAccessAuthorizerTests: XCTestCase {
  func testAuthorizationPreservesTheExistingControllerIdentity() throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x31, count: 32))
    let manager = RecordingControllerIdentityAccessManager(
      fingerprints: [identity, identity]
    )

    let result = try ControllerIdentityAccessAuthorizer(manager: manager).authorize(
      label: "Pinshift Controller"
    )

    XCTAssertEqual(result, identity)
    XCTAssertEqual(manager.authorizedLabels, ["Pinshift Controller"])
  }

  func testAuthorizationRejectsAnyIdentityReplacement() throws {
    let original = try ControllerIdentity(fingerprint: Data(repeating: 0x41, count: 32))
    let replacement = try ControllerIdentity(fingerprint: Data(repeating: 0x42, count: 32))
    let manager = RecordingControllerIdentityAccessManager(
      fingerprints: [original, replacement]
    )

    XCTAssertThrowsError(
      try ControllerIdentityAccessAuthorizer(manager: manager).authorize(
        label: "Pinshift Controller"
      )
    ) { error in
      XCTAssertEqual(error as? ControllerIdentityAccessAuthorizationError, .identityChanged)
    }
  }

  func testAuthorizationStopsWhenTheKeychainRejectsMigration() throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x51, count: 32))
    let manager = RecordingControllerIdentityAccessManager(
      fingerprints: [identity],
      authorizationError: TestAuthorizationError.denied
    )

    XCTAssertThrowsError(
      try ControllerIdentityAccessAuthorizer(manager: manager).authorize(
        label: "Pinshift Controller"
      )
    ) { error in
      XCTAssertEqual(error as? TestAuthorizationError, .denied)
    }
    XCTAssertEqual(manager.fingerprintReadCount, 1)
  }

  func testAuthorizationPassesTheOriginalIdentityToTheTransactionalManager() throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x61, count: 32))
    let manager = RecordingControllerIdentityAccessManager(fingerprints: [identity, identity])

    _ = try ControllerIdentityAccessAuthorizer(manager: manager).authorize(
      label: "Pinshift Controller"
    )

    XCTAssertEqual(manager.preservedIdentities, [identity])
  }

  func testTransactionalManagerRollsBackACLWhenPostMutationVerificationFails() throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x71, count: 32))
    let manager = TransactionalFakeAccessManager(identity: identity, failAfterMutation: true)

    XCTAssertThrowsError(
      try ControllerIdentityAccessAuthorizer(manager: manager).authorize(
        label: "Pinshift Controller"
      )
    )

    XCTAssertEqual(manager.trustedApplications, ["existing-controller"])
    XCTAssertEqual(manager.rollbackCount, 1)
  }
}

private final class TransactionalFakeAccessManager:
  ControllerIdentityAccessManaging, @unchecked Sendable
{
  let identity: ControllerIdentity
  let failAfterMutation: Bool
  private(set) var trustedApplications = ["existing-controller"]
  private(set) var rollbackCount = 0

  init(identity: ControllerIdentity, failAfterMutation: Bool) {
    self.identity = identity
    self.failAfterMutation = failAfterMutation
  }

  func fingerprint(label: String) throws -> ControllerIdentity { identity }

  func authorizeCurrentApplication(
    label: String,
    preserving identity: ControllerIdentity
  ) throws {
    let snapshot = trustedApplications
    trustedApplications.append("current-controller")
    if failAfterMutation {
      trustedApplications = snapshot
      rollbackCount += 1
      throw ControllerIdentityAccessAuthorizationError.signatureVerificationFailed
    }
  }
}

private enum TestAuthorizationError: Error, Equatable {
  case denied
}

private final class RecordingControllerIdentityAccessManager:
  ControllerIdentityAccessManaging, @unchecked Sendable
{
  private var fingerprints: [ControllerIdentity]
  private let authorizationError: (any Error)?
  private(set) var authorizedLabels: [String] = []
  private(set) var preservedIdentities: [ControllerIdentity] = []
  private(set) var fingerprintReadCount = 0

  init(
    fingerprints: [ControllerIdentity],
    authorizationError: (any Error)? = nil
  ) {
    self.fingerprints = fingerprints
    self.authorizationError = authorizationError
  }

  func fingerprint(label: String) throws -> ControllerIdentity {
    fingerprintReadCount += 1
    return fingerprints.removeFirst()
  }

  func authorizeCurrentApplication(
    label: String,
    preserving identity: ControllerIdentity
  ) throws {
    authorizedLabels.append(label)
    preservedIdentities.append(identity)
    if let authorizationError {
      throw authorizationError
    }
  }
}
