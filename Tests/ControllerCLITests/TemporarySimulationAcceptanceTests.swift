import ControllerLink
import Foundation
import LocationDomain
import SimulationController
import XCTest

@testable import ControllerCLI

final class TemporarySimulationAcceptanceTests: XCTestCase {
  func testApplyIsTemporaryAcrossTheAppControllerLinkAndSimulationController() async throws {
    let startedAt = Date(timeIntervalSince1970: 20_000)
    let clock = TemporarySimulationTestClock(now: startedAt)
    let store = InMemoryTemporarySimulationStore()
    let backend = TemporarySimulationRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      stateStore: store,
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let identity = try ControllerIdentity(
      fingerprint: Data(repeating: 0x41, count: 32)
    )
    let authorization = try ControllerAuthorization(
      bytes: Data(repeating: 0x42, count: 32)
    )
    let session = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: startedAt.addingTimeInterval(300)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      commandHandler: SimulationControllerCommandHandler(controller: controller),
      now: { clock.now }
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(
        store: InMemoryControllerTrustStore(identity: identity)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: TemporarySimulationInMemoryTransport(
        identity: identity,
        session: session
      )
    )

    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .connected(identity))

    var app = ManualSimulationSession()
    try app.select(latitude: "31.2304", longitude: "121.4737")
    let request = try app.beginApply(requestID: UUID(), at: startedAt)
    let response = await link.apply(
      requestID: request.requestID,
      latitude: request.location.latitude,
      longitude: request.location.longitude
    )

    guard case .applied(let responseID, let automaticClearAt) = response else {
      return XCTFail("Apply should return the fixed automatic-clear time")
    }
    XCTAssertEqual(responseID, request.requestID)
    XCTAssertEqual(automaticClearAt, startedAt.addingTimeInterval(900))
    XCTAssertTrue(
      app.acknowledgeApplied(
        requestID: responseID,
        automaticClearAt: automaticClearAt
      )
    )

    clock.advance(by: 901)
    await controller.reconcile()

    let finalLocation = await backend.appliedLocation
    let finalSnapshot = await controller.snapshot()
    XCTAssertNil(finalLocation)
    XCTAssertEqual(finalSnapshot.simulation, .idle)
  }
}

private final class TemporarySimulationTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(now: Date) {
    value = now
  }

  var now: Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock {
      value = value.addingTimeInterval(interval)
    }
  }
}

private actor TemporarySimulationRecordingBackend: InjectionBackend {
  private(set) var appliedLocation: SelectedLocation?

  func readiness() -> InjectionBackendReadiness {
    .ready
  }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      appliedLocation = location
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      appliedLocation = nil
      return .cleared(requestID: requestID)
    }
  }
}

private actor TemporarySimulationInMemoryTransport: ControllerLinkTransport {
  private let identity: ControllerIdentity
  private let session: ControllerServerSession

  init(identity: ControllerIdentity, session: ControllerServerSession) {
    self.identity = identity
    self.session = session
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) async throws -> ControllerTransportReply {
    ControllerTransportReply(
      presentedIdentity: identity,
      response: await session.process(request)
    )
  }
}
