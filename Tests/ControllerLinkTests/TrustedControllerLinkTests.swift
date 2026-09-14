import Foundation
import XCTest

@testable import ControllerLink

final class TrustedControllerLinkTests: XCTestCase {
  func testPairsOnceThenReusesThePinnedControllerIdentity() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x11, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x12, count: 32))
    let trustStore = InMemoryControllerTrustStore()
    let authorizationStore = InMemoryControllerAuthorizationStore()
    let transport = PairingControllerTransport(
      identity: identity,
      authorization: authorization
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: trustStore),
      authorizationStore: authorizationStore,
      transport: transport
    )

    let discovered = await link.connect(to: ControllerService(name: "controller"))
    let paired = await link.pair(code: "123456")
    let storedIdentity = await trustStore.load()
    let storedAuthorization = await authorizationStore.load()
    let refreshed = await link.refresh()
    XCTAssertEqual(discovered, .awaitingPairing(identity))
    XCTAssertEqual(paired, .connected(identity))
    XCTAssertEqual(storedIdentity, identity)
    XCTAssertEqual(storedAuthorization, authorization)
    XCTAssertEqual(refreshed, .connected(identity))
  }

  func testMismatchedResponseIdentityNeverBecomesTrusted() async throws {
    let trusted = try ControllerIdentity(fingerprint: Data(repeating: 0x21, count: 32))
    let presented = try ControllerIdentity(fingerprint: Data(repeating: 0x22, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x23, count: 32))
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: trusted)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: FixedIdentityControllerTransport(identity: presented)
    )

    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .unavailable(.tlsIdentityMismatch))
  }

  func testConnectedLinkAlwaysSubmitsReplacementApplyDespiteHistoricalStatus() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x31, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x32, count: 32))
    let deadline = Date(timeIntervalSince1970: 10_900)
    let transport = RecordingControllerTransport(
      identity: identity,
      authorization: authorization,
      initialStatus: ControllerStatus(
        readiness: .unavailable(.clearFailed),
        simulation: .clearPending(
          operationID: UUID(),
          latitude: 1,
          longitude: 2,
          automaticClearAt: Date(timeIntervalSince1970: 9_000),
          reason: .clearFailed
        )
      ),
      applyDeadline: deadline
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .connected(identity))

    let applyID = UUID()
    let applied = await link.apply(
      requestID: applyID,
      latitude: 31.2304,
      longitude: 121.4737
    )
    XCTAssertEqual(
      applied,
      .applied(requestID: applyID, automaticClearAt: deadline)
    )
    let applyCount = await transport.applyCount
    XCTAssertEqual(applyCount, 1)

    let clearID = UUID()
    let cleared = await link.clear(requestID: clearID)
    XCTAssertEqual(
      cleared,
      .cleared(requestID: clearID)
    )
    let clearCount = await transport.clearCount
    XCTAssertEqual(clearCount, 1)
  }

  func testSuccessfulClearAlwaysMakesCachedStatusIdle() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x41, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x42, count: 32))
    let deadline = Date(timeIntervalSince1970: 20_900)
    let transport = RecordingControllerTransport(
      identity: identity,
      authorization: authorization,
      initialStatus: ControllerStatus(readiness: .ready, simulation: .idle),
      applyDeadline: deadline
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    _ = await link.connect(to: ControllerService(name: "controller"))

    let newerOperationID = UUID()
    _ = await link.apply(
      requestID: newerOperationID,
      latitude: 31.2304,
      longitude: 121.4737
    )
    let clearResponse = await link.clear(requestID: UUID())

    guard case .cleared = clearResponse else {
      return XCTFail("The controller should acknowledge a real Clear.")
    }
    let status = await link.currentStatus()
    XCTAssertEqual(
      status,
      ControllerStatus(
        readiness: .ready,
        simulation: .idle
      )
    )
  }

  func testClearReconnectsBeforeSubmittingTheRealRequest() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x45, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x46, count: 32))
    let transport = RecordingControllerTransport(
      identity: identity,
      authorization: authorization,
      initialStatus: ControllerStatus(readiness: .ready, simulation: .idle),
      applyDeadline: Date(timeIntervalSince1970: 1_180)
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    _ = await link.connect(to: ControllerService(name: "controller"))
    _ = await link.disconnected()

    let clearID = UUID()
    let response = await link.clear(requestID: clearID)

    XCTAssertEqual(response, .cleared(requestID: clearID))
    let statusCount = await transport.statusCount
    let clearCount = await transport.clearCount
    XCTAssertEqual(statusCount, 2)
    XCTAssertEqual(clearCount, 1)
  }

  func testStatusPollStartedBeforeApplyCannotOverwriteTheNewApply() async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x51, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x52, count: 32))
    let olderOperationID = UUID()
    let newerOperationID = UUID()
    let oldDeadline = Date(timeIntervalSince1970: 30_900)
    let newDeadline = Date(timeIntervalSince1970: 31_900)
    let transport = BlockingRefreshControllerTransport(
      identity: identity,
      authorization: authorization,
      status: ControllerStatus(
        readiness: .ready,
        simulation: .active(
          operationID: olderOperationID,
          latitude: 1,
          longitude: 2,
          automaticClearAt: oldDeadline
        )
      ),
      applyDeadline: newDeadline
    )
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      transport: transport
    )
    _ = await link.connect(to: ControllerService(name: "controller"))

    let refresh = Task { await link.refresh() }
    await transport.waitUntilRefreshIsBlocked()
    _ = await link.apply(
      requestID: newerOperationID,
      latitude: 31.2304,
      longitude: 121.4737
    )
    await transport.releaseRefresh()
    _ = await refresh.value

    let currentStatus = await link.currentStatus()
    XCTAssertEqual(
      currentStatus,
      ControllerStatus(
        readiness: .ready,
        simulation: .active(
          operationID: newerOperationID,
          latitude: 31.2304,
          longitude: 121.4737,
          automaticClearAt: newDeadline
        )
      )
    )
  }
}

private actor PairingControllerTransport: ControllerLinkTransport {
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
  ) -> ControllerTransportReply {
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, nil):
      response = .rejected(requestID: requestID, reason: .pairingRequired)
    case .status(let requestID, let presented?):
      XCTAssertEqual(presented, authorization)
      response = .status(
        requestID: requestID,
        status: ControllerStatus(readiness: .ready, simulation: .idle)
      )
    case .pair(let requestID, let code):
      XCTAssertEqual(code, "123456")
      response = .paired(requestID: requestID, authorization: authorization)
    case .apply(let requestID, _, _, _), .clear(let requestID, _), .renewApp(let requestID, _):
      response = .rejected(requestID: requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }
}

private actor FixedIdentityControllerTransport: ControllerLinkTransport {
  let identity: ControllerIdentity

  init(identity: ControllerIdentity) {
    self.identity = identity
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) -> ControllerTransportReply {
    ControllerTransportReply(
      presentedIdentity: identity,
      response: .status(
        requestID: request.requestID,
        status: ControllerStatus(readiness: .ready, simulation: .idle)
      )
    )
  }
}

private actor RecordingControllerTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization
  let initialStatus: ControllerStatus
  let applyDeadline: Date
  private(set) var statusCount = 0
  private(set) var applyCount = 0
  private(set) var clearCount = 0

  init(
    identity: ControllerIdentity,
    authorization: ControllerAuthorization,
    initialStatus: ControllerStatus,
    applyDeadline: Date
  ) {
    self.identity = identity
    self.authorization = authorization
    self.initialStatus = initialStatus
    self.applyDeadline = applyDeadline
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) -> ControllerTransportReply {
    XCTAssertEqual(expectedIdentity, identity)
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, let presented):
      XCTAssertEqual(presented, authorization)
      statusCount += 1
      response = .status(requestID: requestID, status: initialStatus)
    case .apply(let requestID, let presented, let latitude, let longitude):
      XCTAssertEqual(presented, authorization)
      XCTAssertEqual(latitude, 31.2304)
      XCTAssertEqual(longitude, 121.4737)
      applyCount += 1
      response = .applied(requestID: requestID, automaticClearAt: applyDeadline)
    case .clear(let requestID, let presented):
      XCTAssertEqual(presented, authorization)
      clearCount += 1
      response = .cleared(requestID: requestID)
    case .pair(let requestID, _), .renewApp(let requestID, _):
      response = .rejected(requestID: requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }
}

private actor BlockingRefreshControllerTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  let authorization: ControllerAuthorization
  let status: ControllerStatus
  let applyDeadline: Date
  private var statusRequestCount = 0
  private var blockedRefresh: CheckedContinuation<Void, Never>?
  private var refreshStartedWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    identity: ControllerIdentity,
    authorization: ControllerAuthorization,
    status: ControllerStatus,
    applyDeadline: Date
  ) {
    self.identity = identity
    self.authorization = authorization
    self.status = status
    self.applyDeadline = applyDeadline
  }

  func waitUntilRefreshIsBlocked() async {
    if blockedRefresh != nil { return }
    await withCheckedContinuation { continuation in
      refreshStartedWaiters.append(continuation)
    }
  }

  func releaseRefresh() {
    blockedRefresh?.resume()
    blockedRefresh = nil
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) async -> ControllerTransportReply {
    XCTAssertEqual(expectedIdentity, identity)
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, let presented):
      XCTAssertEqual(presented, authorization)
      statusRequestCount += 1
      if statusRequestCount == 2 {
        await withCheckedContinuation { continuation in
          blockedRefresh = continuation
          let waiters = refreshStartedWaiters
          refreshStartedWaiters.removeAll()
          for waiter in waiters {
            waiter.resume()
          }
        }
      }
      response = .status(requestID: requestID, status: status)
    case .apply(let requestID, let presented, _, _):
      XCTAssertEqual(presented, authorization)
      response = .applied(requestID: requestID, automaticClearAt: applyDeadline)
    case .pair(let requestID, _), .clear(let requestID, _), .renewApp(let requestID, _):
      response = .rejected(requestID: requestID, reason: .invalidRequest)
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }
}
