import Foundation
import SimulationDiagnostics
import XCTest

@testable import ControllerLink

final class ControllerServerSessionTests: XCTestCase {
  func testCorrectCodePairsAndAuthorizedStatusUsesTheThreeOperationHandler() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x41, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x42, count: 32))
    let store = InMemoryControllerAuthorizationStore()
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
      now: { Date(timeIntervalSince1970: 100) },
      makeAuthorization: { authorization }
    )

    let unpairedID = UUID()
    let unpaired = await session.process(
      .status(requestID: unpairedID, authorization: nil)
    )
    XCTAssertEqual(
      unpaired,
      .rejected(requestID: unpairedID, reason: .pairingRequired)
    )
    let pairID = UUID()
    let paired = await session.process(.pair(requestID: pairID, code: "123456"))
    XCTAssertEqual(
      paired,
      .paired(requestID: pairID, authorization: authorization)
    )
    let statusID = UUID()
    let status = await session.process(
      .status(requestID: statusID, authorization: authorization)
    )
    XCTAssertEqual(
      status,
      .status(
        requestID: statusID,
        status: ControllerStatus(readiness: .ready, simulation: .idle)
      )
    )
  }

  func testAuthorizedApplyAndClearReachHandlerButInvalidInputDoesNot() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x51, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x52, count: 32))
    let invalidAuthorization = try ControllerAuthorization(bytes: Data(repeating: 0x53, count: 32))
    let handler = RecordingControllerCommandHandler()
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: Date(timeIntervalSince1970: 200)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      commandHandler: handler
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
    let invalidCoordinateID = UUID()
    let invalidCoordinate = await session.process(
      .apply(
        requestID: invalidCoordinateID,
        authorization: authorization,
        latitude: 91,
        longitude: 0
      )
    )
    XCTAssertEqual(
      invalidCoordinate,
      .failed(requestID: invalidCoordinateID, reason: .invalidCoordinate)
    )

    let applyID = UUID()
    let applied = await session.process(
      .apply(
        requestID: applyID,
        authorization: authorization,
        latitude: 31.2304,
        longitude: 121.4737
      )
    )
    XCTAssertEqual(
      applied,
      .applied(
        requestID: applyID,
        automaticClearAt: Date(timeIntervalSince1970: 1_000)
      )
    )
    let clearID = UUID()
    let cleared = await session.process(
      .clear(
        requestID: clearID,
        authorization: authorization
      )
    )
    XCTAssertEqual(
      cleared,
      .cleared(requestID: clearID)
    )
    let commands = await handler.commands
    XCTAssertEqual(
      commands,
      [
        .apply(requestID: applyID, latitude: 31.2304, longitude: 121.4737),
        .clear(requestID: clearID),
      ]
    )
  }

  func testRenewalRequiresExistingAuthorizationAndDoesNotAcceptDeviceOrCommandArguments() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x51, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x52, count: 32))
    let invalid = try ControllerAuthorization(bytes: Data(repeating: 0x53, count: 32))
    let handler = RecordingControllerCommandHandler()
    let session = ControllerServerSession(identity: identity,
      pairingAuthority: try PairingCodeAuthority(code: "123456", identity: identity,
        expiresAt: Date().addingTimeInterval(60)),
      authorizationStore: InMemoryControllerAuthorizationStore(authorization: authorization),
      commandHandler: handler)
    let id = UUID()
    let rejected = await session.process(.renewApp(requestID: id, authorization: invalid))
    XCTAssertEqual(rejected, .rejected(requestID: id, reason: .authorizationFailed))
    let commandsBefore = await handler.commands
    XCTAssertTrue(commandsBefore.isEmpty)
    let response = await session.process(.renewApp(requestID: id, authorization: authorization))
    guard case .renewal(let returnedID, _) = response else { return XCTFail("Expected renewal") }
    XCTAssertEqual(returnedID, id)
    let commands = await handler.commands
    XCTAssertEqual(commands, [.renewApp(requestID: id)])
    let request = ControllerLinkRequest.renewApp(requestID: id, authorization: authorization)
    let encoded = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    XCTAssertFalse(encoded.contains("device"))
    XCTAssertFalse(encoded.contains("path"))
  }

  func testPairingAndAuthorizationValuesNeverEnterDiagnostics() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-link-events-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x61, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x62, count: 32))
    let diagnostics = SimulationDiagnosticRecorder(side: .macController, directory: directory)
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

    _ = await session.process(.pair(requestID: UUID(), code: "123456"))
    let exported = String(data: try await diagnostics.exportData(), encoding: .utf8)!
    XCTAssertFalse(exported.contains("123456"))
    XCTAssertFalse(exported.contains("authorization"))
    XCTAssertFalse(exported.contains("62626262"))
  }
}

private actor RecordingControllerCommandHandler: ControllerCommandHandling {
  private(set) var commands: [ControllerCommand] = []

  func handle(_ command: ControllerCommand) -> ControllerCommandResult {
    commands.append(command)
    switch command {
    case .status(let requestID):
      return .status(
        requestID: requestID,
        status: ControllerStatus(readiness: .ready, simulation: .idle)
      )
    case .apply(let requestID, _, _):
      return .applied(
        requestID: requestID,
        automaticClearAt: Date(timeIntervalSince1970: 1_000)
      )
    case .renewApp(let requestID):
      return .renewal(requestID: requestID, status: AppRenewalStatus(phase: .checking))
    case .clear(let requestID):
      return .cleared(requestID: requestID)
    }
  }
}
