import Foundation
import SimulationDiagnostics
import XCTest

@testable import ControllerLink

final class ControllerServerSessionTests: XCTestCase {
  func testCorrectCodePairsWhenServerPersistsAuthorizationInKeychain() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x35, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x53, count: 32))
    let store = KeychainControllerAuthorizationStore(
      service: "dev.sayori.pinshift.tests.\(UUID().uuidString)",
      account: ControllerAuthorization.pairedAppKeychainAccount
    )
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: Date(timeIntervalSince1970: 200)
      ),
      authorizationStore: store,
      now: { Date(timeIntervalSince1970: 100) },
      makeAuthorization: { authorization }
    )

    let requestID = UUID()
    let response = await session.process(.pair(requestID: requestID, code: "123456"))
    try? await store.remove()

    XCTAssertEqual(response, .paired(requestID: requestID, authorization: authorization))
  }

  func testRejectsUnpairedStatusThenPersistsOnePairingAuthorization() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x42, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x24, count: 32))
    let store = InMemoryControllerAuthorizationStore()
    let authority = try PairingCodeAuthority(
      code: "123456",
      identity: identity,
      expiresAt: Date(timeIntervalSince1970: 200)
    )
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: authority,
      authorizationStore: store,
      now: { Date(timeIntervalSince1970: 100) },
      makeAuthorization: { authorization }
    )

    let statusID = UUID()
    let unpairedStatus = await session.process(
      .status(requestID: statusID, authorization: nil)
    )
    XCTAssertEqual(unpairedStatus, .rejected(requestID: statusID, reason: .pairingRequired))
    let pairID = UUID()
    let paired = await session.process(.pair(requestID: pairID, code: "123456"))
    XCTAssertEqual(paired, .paired(requestID: pairID, authorization: authorization))
    let trustedStatusID = UUID()
    let trustedStatus = await session.process(
      .status(requestID: trustedStatusID, authorization: authorization)
    )
    XCTAssertEqual(
      trustedStatus,
      .status(
        requestID: trustedStatusID,
        readiness: .unavailable(.backendUnavailable)
      )
    )

    let restarted = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "654321",
        identity: identity,
        expiresAt: Date(timeIntervalSince1970: 300)
      ),
      authorizationStore: store,
      now: { Date(timeIntervalSince1970: 100) },
      makeAuthorization: { authorization }
    )
    let restartStatusID = UUID()
    let restartedStatus = await restarted.process(
      .status(requestID: restartStatusID, authorization: authorization)
    )
    XCTAssertEqual(
      restartedStatus,
      .status(
        requestID: restartStatusID,
        readiness: .unavailable(.backendUnavailable)
      )
    )
  }

  func testAuthorizedApplyAndStopReachHandlerButInvalidAuthorizationDoesNot() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x61, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x62, count: 32))
    let invalidAuthorization = try ControllerAuthorization(bytes: Data(repeating: 0x63, count: 32))
    let store = InMemoryControllerAuthorizationStore(authorization: authorization)
    let handler = RecordingControllerCommandHandler()
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: Date(timeIntervalSince1970: 200)
      ),
      authorizationStore: store,
      commandHandler: handler,
      now: { Date(timeIntervalSince1970: 100) }
    )

    let rejectedID = UUID()
    let rejected = await session.process(
      .apply(
        requestID: rejectedID,
        authorization: invalidAuthorization,
        latitude: 31.2304,
        longitude: 121.4737
      )
    )
    XCTAssertEqual(
      rejected,
      .rejected(requestID: rejectedID, reason: .authorizationFailed)
    )
    let commandsAfterRejection = await handler.recordedCommands()
    XCTAssertEqual(commandsAfterRejection, [])

    let applyID = UUID()
    let applied = await session.process(
      .apply(
        requestID: applyID,
        authorization: authorization,
        latitude: 31.2304,
        longitude: 121.4737
      )
    )
    XCTAssertEqual(applied, .applied(requestID: applyID))

    let stopID = UUID()
    let stopped = await session.process(
      .stop(requestID: stopID, authorization: authorization)
    )
    XCTAssertEqual(stopped, .stopped(requestID: stopID))
    let recordedCommands = await handler.recordedCommands()
    XCTAssertEqual(
      recordedCommands,
      [
        .apply(requestID: applyID, latitude: 31.2304, longitude: 121.4737),
        .stop(requestID: stopID),
      ]
    )
  }

  func testPairingAndAuthorizationValuesNeverEnterTheControllerRecord() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-link-events-(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x71, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x72, count: 32))
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: Date(timeIntervalSince1970: 200)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(),
      now: { Date(timeIntervalSince1970: 100) },
      makeAuthorization: { authorization },
      diagnostics: diagnostics
    )

    let response = await session.process(
      .pair(requestID: UUID(), code: "123456")
    )
    XCTAssertEqual(response, .paired(requestID: response.requestID, authorization: authorization))

    let exported = String(data: try await diagnostics.exportData(), encoding: .utf8)!
    XCTAssertFalse(exported.contains("123456"))
    XCTAssertFalse(exported.contains("authorization"))
    XCTAssertFalse(exported.contains("72727272"))
  }
}

private actor RecordingControllerCommandHandler: ControllerCommandHandling {
  private var commands: [ControllerCommand] = []

  func handle(_ command: ControllerCommand) -> ControllerCommandResult {
    commands.append(command)
    switch command {
    case .status(let requestID):
      return .ready(requestID: requestID)
    case .lifecycleStatus(let requestID):
      return .lifecycleStatus(
        requestID: requestID,
        status: ControllerLifecycleStatus(
          readiness: .ready,
          simulation: .noActive
        )
      )
    case .apply(let requestID, _, _):
      return .applied(requestID: requestID)
    case .applyLifecycle(let requestID, let generationID, _, _, _):
      return .appliedLifecycle(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: Date(timeIntervalSince1970: 3_600)
      )
    case .extendLifecycle(let requestID, let generationID, _):
      return .extendedLifecycle(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: Date(timeIntervalSince1970: 4_500)
      )
    case .stop(let requestID):
      return .stopped(requestID: requestID)
    case .stopLifecycle(let requestID, let generationID):
      return .stoppedLifecycle(
        requestID: requestID,
        generationID: generationID
      )
    }
  }

  func recordedCommands() -> [ControllerCommand] {
    commands
  }
}
