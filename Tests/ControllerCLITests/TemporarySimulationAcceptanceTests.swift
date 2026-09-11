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
    let sleeper = TemporarySimulationControlledSleeper()
    let backend = TemporarySimulationRecordingBackend(failures: 2)
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      sleep: { seconds in try await sleeper.sleep(for: seconds) }
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
    XCTAssertEqual(automaticClearAt, startedAt.addingTimeInterval(180))
    XCTAssertTrue(
      app.acknowledgeApplied(
        requestID: responseID,
        automaticClearAt: automaticClearAt
      )
    )

    clock.advance(by: 181)
    let scheduledInterval = await sleeper.waitUntilScheduled()
    XCTAssertEqual(scheduledInterval, 180)
    await sleeper.resume()
    let firstRetry = await sleeper.waitUntilScheduled()
    XCTAssertEqual(firstRetry, 1)
    _ = await link.refresh()
    guard case .clearPending = await link.currentStatus()?.simulation else {
      return XCTFail("Failed deadline cleanup must remain pending")
    }
    await sleeper.resume()
    let secondRetry = await sleeper.waitUntilScheduled()
    XCTAssertEqual(secondRetry, 2)
    await sleeper.resume()
    await backend.waitUntilClearExecuted()

    let finalLocation = await backend.appliedLocation
    let finalSnapshot = await controller.snapshot()
    XCTAssertNil(finalLocation)
    XCTAssertEqual(finalSnapshot.simulation, .idle)
    _ = await link.refresh()
    let reconnectedStatus = await link.currentStatus()
    XCTAssertEqual(reconnectedStatus?.simulation, .idle)
  }
}

private actor TemporarySimulationControlledSleeper {
  private var requestedInterval: TimeInterval?
  private var requestWaiters: [CheckedContinuation<TimeInterval, Never>] = []
  private var sleepContinuation: CheckedContinuation<Void, Error>?

  func sleep(for interval: TimeInterval) async throws {
    requestedInterval = interval
    let waiters = requestWaiters
    requestWaiters.removeAll()
    for waiter in waiters {
      waiter.resume(returning: interval)
    }
    try await withCheckedThrowingContinuation { continuation in
      sleepContinuation = continuation
    }
  }

  func waitUntilScheduled() async -> TimeInterval {
    if let requestedInterval { return requestedInterval }
    return await withCheckedContinuation { continuation in
      requestWaiters.append(continuation)
    }
  }

  func resume() {
    requestedInterval = nil
    sleepContinuation?.resume()
    sleepContinuation = nil
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
  private var failures: Int
  init(failures: Int = 0) { self.failures = failures }
  private var didClear = false
  private var clearWaiters: [CheckedContinuation<Void, Never>] = []

  func readiness() -> InjectionBackendReadiness {
    .ready
  }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      appliedLocation = location
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      if failures > 0 {
        failures -= 1
        return .failed(requestID: requestID, reason: .sessionNotReady)
      }
      appliedLocation = nil
      didClear = true
      let waiters = clearWaiters
      clearWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      return .cleared(requestID: requestID)
    }
  }

  func waitUntilClearExecuted() async {
    if didClear { return }
    await withCheckedContinuation { continuation in
      clearWaiters.append(continuation)
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
