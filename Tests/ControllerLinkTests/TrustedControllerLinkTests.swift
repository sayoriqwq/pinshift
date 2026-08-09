import XCTest

@testable import ControllerLink

final class TrustedControllerLinkTests: XCTestCase {
  func testPairsOnceThenReusesThePinnedControllerIdentity() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x19, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x31, count: 32))
    let store = InMemoryControllerTrustStore()
    let authorizationStore = InMemoryControllerAuthorizationStore()
    let trust = ControllerTrust(store: store)
    let firstTransport = PairingTransport(identity: identity, authorization: authorization)
    let service = ControllerService(name: "controller")
    let firstLink = TrustedControllerLink(
      trust: trust,
      authorizationStore: authorizationStore,
      transport: firstTransport
    )

    let awaitingPairing = await firstLink.connect(to: service)
    XCTAssertEqual(awaitingPairing, .awaitingPairing(identity))
    let paired = await firstLink.pair(code: "123456")
    XCTAssertEqual(paired, .connected(identity))
    let storedIdentity = await store.load()
    XCTAssertEqual(storedIdentity, identity)
    let storedAuthorization = await authorizationStore.load()
    XCTAssertEqual(storedAuthorization, authorization)

    let reconnectTransport = TrustedStatusTransport(
      identity: identity,
      authorization: authorization
    )
    let reconnect = TrustedControllerLink(
      trust: trust,
      authorizationStore: authorizationStore,
      transport: reconnectTransport
    )
    let reconnected = await reconnect.connect(to: service)
    XCTAssertEqual(reconnected, .connected(identity))
    let expectedIdentity = await reconnectTransport.lastExpectedIdentity()
    XCTAssertEqual(expectedIdentity, identity)
  }

  func testMismatchedResponseIdentityNeverBecomesTrusted() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x27, count: 32))
    let store = InMemoryControllerTrustStore()
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: store),
      authorizationStore: InMemoryControllerAuthorizationStore(),
      transport: MismatchedResponseTransport(identity: identity)
    )

    _ = await link.connect(to: ControllerService(name: "controller"))
    let pairingResult = await link.pair(code: "123456")
    XCTAssertEqual(pairingResult, .unavailable(.transportUnavailable))
    let storedIdentity = await store.load()
    XCTAssertNil(storedIdentity)
  }

  func testConnectedLinkSendsAuthorizedCorrelatedApplyAndStop() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x71, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x72, count: 32))
    let transport = AuthorizedCommandTransport(
      identity: identity,
      authorization: authorization
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    let connected = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connected, .connected(identity))
    let readiness = await link.currentBackendReadiness()
    XCTAssertEqual(readiness, .ready)

    let applyID = UUID()
    let applied = await link.apply(
      requestID: applyID,
      latitude: 31.2304,
      longitude: 121.4737
    )
    XCTAssertEqual(
      applied,
      .appliedLifecycle(
        requestID: applyID,
        generationID: applyID,
        leaseExpiresAt: Date(timeIntervalSince1970: 3_600)
      )
    )
    let stopID = UUID()
    let stopped = await link.stop(requestID: stopID)
    XCTAssertEqual(
      stopped,
      .stoppedLifecycle(requestID: stopID, generationID: nil)
    )
  }

  func testApplyAndStopRefreshTheTrustedLinkAfterTransientDiscoveryLoss() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x75, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x76, count: 32))
    let transport = AuthorizedCommandTransport(
      identity: identity,
      authorization: authorization
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )

    let connected = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connected, .connected(identity))
    _ = await link.disconnected()

    let requestID = UUID()
    let response = await link.apply(
      requestID: requestID,
      latitude: 31.2304,
      longitude: 121.4737
    )

    XCTAssertEqual(
      response,
      .appliedLifecycle(
        requestID: requestID,
        generationID: requestID,
        leaseExpiresAt: Date(timeIntervalSince1970: 3_600)
      )
    )
    let refreshedState = await link.currentState()
    XCTAssertEqual(refreshedState, .connected(identity))

    _ = await link.disconnected()
    let stopID = UUID()
    let stopResponse = await link.stop(requestID: stopID)

    XCTAssertEqual(
      stopResponse,
      .stoppedLifecycle(requestID: stopID, generationID: nil)
    )
    let stopRefreshedState = await link.currentState()
    XCTAssertEqual(stopRefreshedState, .connected(identity))
  }

  func testLegacyControllerCannotReceiveAnUnprotectedApply() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x77, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x78, count: 32))
    let transport = LegacyControllerTransport(
      identity: identity,
      authorization: authorization
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(
        store: InMemoryControllerTrustStore(identity: identity)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .connected(identity))

    let requestID = UUID()
    let response = await link.apply(
      requestID: requestID,
      latitude: 31.2304,
      longitude: 121.4737,
      requestedLeaseDuration: 900
    )
    let applyCount = await transport.applyCount()

    XCTAssertEqual(
      response,
      .failed(requestID: requestID, reason: .controllerUpgradeRequired)
    )
    XCTAssertEqual(applyCount, 0)
  }

  func testUnavailableBackendPreventsApplyWithoutSendingACommand() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x73, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x74, count: 32))
    let transport = UnavailableBackendTransport(
      identity: identity,
      authorization: authorization
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    let state = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(state, .connected(identity))

    let requestID = UUID()
    let response = await link.apply(
      requestID: requestID,
      latitude: 31.2304,
      longitude: 121.4737
    )

    XCTAssertEqual(
      response,
      .failed(requestID: requestID, reason: .sessionNotReady)
    )
    let applyCount = await transport.applyCount()
    XCTAssertEqual(applyCount, 0)
  }
}

private actor LegacyControllerTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization
  private var sentApplyCount = 0

  init(identity: ControllerIdentity, authorization: ControllerAuthorization) {
    self.identity = identity
    self.authorization = authorization
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) -> ControllerTransportReply {
    XCTAssertEqual(expectedIdentity, identity)
    let response: ControllerLinkResponse
    switch request {
    case .lifecycleStatus(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .status(requestID: requestID, readiness: .ready)
    case .apply, .applyLifecycle:
      sentApplyCount += 1
      response = .rejected(requestID: request.requestID, reason: .invalidRequest)
    case .status(let requestID, _):
      response = .status(requestID: requestID, readiness: .ready)
    case .pair, .extendLifecycle, .stop, .stopLifecycle:
      response = .rejected(requestID: request.requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(
      presentedIdentity: identity,
      response: response
    )
  }

  func applyCount() -> Int {
    sentApplyCount
  }
}

private actor PairingTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization

  init(identity: ControllerIdentity, authorization: ControllerAuthorization) {
    self.identity = identity
    self.authorization = authorization
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) throws -> ControllerTransportReply {
    switch request {
    case .status(let requestID, let presentedAuthorization):
      XCTAssertNil(presentedAuthorization)
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: requestID, reason: .pairingRequired)
      )
    case .lifecycleStatus(let requestID, _):
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: requestID, reason: .invalidRequest)
      )
    case .pair(let requestID, let code):
      XCTAssertEqual(code, "123456")
      XCTAssertEqual(expectedIdentity, identity)
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .paired(requestID: requestID, authorization: authorization)
      )
    case .apply, .applyLifecycle, .extendLifecycle, .stop, .stopLifecycle:
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: request.requestID, reason: .invalidRequest)
      )
    }
  }
}

private actor TrustedStatusTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization
  private var expectedIdentity: ControllerIdentity?

  init(identity: ControllerIdentity, authorization: ControllerAuthorization) {
    self.identity = identity
    self.authorization = authorization
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) throws -> ControllerTransportReply {
    self.expectedIdentity = expectedIdentity
    guard case .lifecycleStatus(let requestID, let presentedAuthorization) = request else {
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: request.requestID, reason: .invalidRequest)
      )
    }
    XCTAssertEqual(presentedAuthorization, authorization)
    return ControllerTransportReply(
      presentedIdentity: identity,
      response: .lifecycleStatus(
        requestID: requestID,
        status: ControllerLifecycleStatus(
          readiness: .ready,
          simulation: .noActive
        )
      )
    )
  }

  func lastExpectedIdentity() -> ControllerIdentity? {
    expectedIdentity
  }
}

private actor MismatchedResponseTransport: ControllerLinkTransport {
  let identity: ControllerIdentity

  init(identity: ControllerIdentity) {
    self.identity = identity
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) throws -> ControllerTransportReply {
    switch request {
    case .status(let requestID, _):
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: requestID, reason: .pairingRequired)
      )
    case .pair:
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .paired(
          requestID: UUID(),
          authorization: try ControllerAuthorization(bytes: Data(repeating: 0x55, count: 32))
        )
      )
    case .lifecycleStatus(let requestID, _):
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: requestID, reason: .invalidRequest)
      )
    case .apply, .applyLifecycle, .extendLifecycle, .stop, .stopLifecycle:
      return ControllerTransportReply(
        presentedIdentity: identity,
        response: .rejected(requestID: request.requestID, reason: .invalidRequest)
      )
    }
  }
}

private actor AuthorizedCommandTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization

  init(identity: ControllerIdentity, authorization: ControllerAuthorization) {
    self.identity = identity
    self.authorization = authorization
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) throws -> ControllerTransportReply {
    XCTAssertEqual(expectedIdentity, identity)
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .status(requestID: requestID, readiness: .ready)
    case .lifecycleStatus(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .lifecycleStatus(
        requestID: requestID,
        status: ControllerLifecycleStatus(
          readiness: .ready,
          simulation: .noActive
        )
      )
    case .apply(let requestID, let presentedAuthorization, let latitude, let longitude):
      XCTAssertEqual(presentedAuthorization, authorization)
      XCTAssertEqual(latitude, 31.2304)
      XCTAssertEqual(longitude, 121.4737)
      response = .applied(requestID: requestID)
    case .applyLifecycle(
      let requestID,
      let generationID,
      let presentedAuthorization,
      let latitude,
      let longitude,
      let requestedLeaseDuration
    ):
      XCTAssertEqual(presentedAuthorization, authorization)
      XCTAssertEqual(latitude, 31.2304)
      XCTAssertEqual(longitude, 121.4737)
      XCTAssertEqual(requestedLeaseDuration, 900)
      response = .appliedLifecycle(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: Date(timeIntervalSince1970: 3_600)
      )
    case .extendLifecycle(
      let requestID,
      let generationID,
      let presentedAuthorization,
      let extensionDuration
    ):
      XCTAssertEqual(presentedAuthorization, authorization)
      XCTAssertEqual(extensionDuration, 900)
      response = .extendedLifecycle(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: Date(timeIntervalSince1970: 4_500)
      )
    case .stop(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .stopped(requestID: requestID)
    case .stopLifecycle(let requestID, let generationID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .stoppedLifecycle(
        requestID: requestID,
        generationID: generationID
      )
    case .pair(let requestID, _):
      response = .rejected(requestID: requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }
}

private actor UnavailableBackendTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization
  private var sentApplyCount = 0

  init(identity: ControllerIdentity, authorization: ControllerAuthorization) {
    self.identity = identity
    self.authorization = authorization
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) -> ControllerTransportReply {
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .status(
        requestID: requestID,
        readiness: .unavailable(.sessionNotReady)
      )
    case .lifecycleStatus(let requestID, let presentedAuthorization):
      XCTAssertEqual(presentedAuthorization, authorization)
      response = .lifecycleStatus(
        requestID: requestID,
        status: ControllerLifecycleStatus(
          readiness: .unavailable(.sessionNotReady),
          simulation: .noActive
        )
      )
    case .apply(let requestID, _, _, _):
      sentApplyCount += 1
      response = .applied(requestID: requestID)
    case .applyLifecycle(let requestID, _, _, _, _, _):
      sentApplyCount += 1
      response = .applied(requestID: requestID)
    case .pair(let requestID, _), .extendLifecycle(let requestID, _, _, _),
      .stop(let requestID, _),
      .stopLifecycle(let requestID, _, _):
      response = .rejected(requestID: requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }

  func applyCount() -> Int {
    sentApplyCount
  }
}
