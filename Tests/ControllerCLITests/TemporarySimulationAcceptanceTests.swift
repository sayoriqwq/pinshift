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
    let link = try makeLink(controller: controller, clock: clock)

    let connection = await link.connect(to: ControllerService(name: "controller"))
    guard case .connected = connection else { return XCTFail("Trusted link must connect") }

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

  func testQueuedExpiredCleanupRetryCannotClearTheReplacementApply() async throws {
    let startedAt = Date(timeIntervalSince1970: 20_000)
    let clock = TemporarySimulationTestClock(now: startedAt)
    let sleeper = TemporarySimulationControlledSleeper()
    let backend = TemporarySimulationRecordingBackend(failures: 1)
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      sleep: { seconds in try await sleeper.sleep(for: seconds) }
    )
    let link = try makeLink(controller: controller, clock: clock)
    _ = await link.connect(to: ControllerService(name: "controller"))
    var app = ManualSimulationSession()
    try app.select(latitude: "31.2304", longitude: "121.4737")
    let first = try app.beginApply(requestID: UUID(), at: clock.now)
    guard
      case .applied(let id, let deadline) = await link.apply(
        requestID: first.requestID,
        latitude: first.location.latitude,
        longitude: first.location.longitude
      )
    else { return XCTFail("The initial Apply must be acknowledged") }
    XCTAssertTrue(app.acknowledgeApplied(requestID: id, automaticClearAt: deadline))
    let originalDelay = await sleeper.waitUntilScheduled()
    XCTAssertEqual(originalDelay, 180)

    // Simulate resuming the Mac after the original deadline, with the phone unreachable.
    clock.advance(by: 600)
    await sleeper.resume()
    let retryDelay = await sleeper.waitUntilScheduled()
    XCTAssertEqual(retryDelay, 1)
    _ = await link.refresh()
    guard case .clearPending = await link.currentStatus()?.simulation else {
      return XCTFail("The expired obligation must survive the failed real Clear")
    }

    try app.select(latitude: "35.6762", longitude: "139.6503")
    let replacement = try app.beginApply(requestID: UUID(), at: clock.now)
    await backend.holdNextApply()
    let replacementTask = Task {
      await link.apply(
        requestID: replacement.requestID,
        latitude: replacement.location.latitude,
        longitude: replacement.location.longitude
      )
    }
    await backend.waitUntilApplyHeld()
    // Wake the obsolete retry while Apply owns the backend. It must recheck ownership
    // after waiting for that Apply, not just when the timer wakes up.
    await sleeper.resume()
    for _ in 0..<100 { await Task.yield() }
    await backend.releaseApply()
    guard case .applied(let replacementID, let replacementDeadline) = await replacementTask.value
    else {
      return XCTFail("Historical failed cleanup must not block replacement Apply")
    }
    XCTAssertEqual(replacementID, replacement.requestID)
    XCTAssertEqual(replacementDeadline, clock.now.addingTimeInterval(180))
    let newDelay = await sleeper.waitUntilScheduled()
    XCTAssertEqual(newDelay, 180)
    _ = await link.refresh()
    let status = await link.currentStatus()
    XCTAssertEqual(
      status?.simulation,
      .active(
        operationID: replacement.requestID,
        latitude: replacement.location.latitude,
        longitude: replacement.location.longitude,
        automaticClearAt: replacementDeadline
      )
    )
    let commands = await backend.commands
    guard commands.count == 3, case .clear(let clearID) = commands[1] else {
      return XCTFail("Expected Apply, failed expiry Clear, replacement Apply; got \(commands)")
    }
    XCTAssertEqual(
      commands,
      [
        .apply(requestID: first.requestID, location: first.location),
        .clear(requestID: clearID),
        .apply(requestID: replacement.requestID, location: replacement.location),
      ])
    let finalLocation = await backend.appliedLocation
    XCTAssertEqual(finalLocation, replacement.location)
    await controller.stopMaintenance()
    await sleeper.resume()
  }

  func testSupersededApplyRemainsRejectedAfterMoreThanEightLaterApplies() async throws {
    let clock = TemporarySimulationTestClock(now: Date(timeIntervalSince1970: 20_000))
    let backend = TemporarySimulationRecordingBackend()
    let controller = SimulationController(
      backend: backend, now: { clock.now }, automaticallySchedulesMaintenance: false
    )
    let link = try makeLink(controller: controller, clock: clock)
    _ = await link.connect(to: ControllerService(name: "controller"))
    var app = ManualSimulationSession()
    var requests: [ManualSimulationRequest] = []
    for index in 0..<10 {
      app.select(try SelectedLocation(latitude: Double(index), longitude: 121))
      let request = try app.beginApply(requestID: UUID(), at: clock.now)
      requests.append(request)
      guard
        case .applied(let id, let deadline) = await link.apply(
          requestID: request.requestID,
          latitude: request.location.latitude, longitude: request.location.longitude
        )
      else { return XCTFail("Each new Apply must succeed") }
      XCTAssertTrue(app.acknowledgeApplied(requestID: id, automaticClearAt: deadline))
      clock.advance(by: 1)
    }
    let first = try XCTUnwrap(requests.first)
    let active = try XCTUnwrap(app.activeAppliedRequest)
    let stale = await link.apply(
      requestID: first.requestID,
      latitude: first.location.latitude, longitude: first.location.longitude
    )
    XCTAssertEqual(stale, .failed(requestID: first.requestID, reason: .timedOut))
    clock.advance(by: 30)
    let currentRetry = await link.apply(
      requestID: active.requestID,
      latitude: active.location.latitude, longitude: active.location.longitude
    )
    XCTAssertEqual(
      currentRetry,
      .applied(
        requestID: active.requestID, automaticClearAt: try XCTUnwrap(active.automaticClearAt))
    )
    _ = await link.refresh()
    let snapshot = await link.currentStatus()
    XCTAssertEqual(
      snapshot?.simulation,
      .active(
        operationID: active.requestID, latitude: active.location.latitude,
        longitude: active.location.longitude,
        automaticClearAt: try XCTUnwrap(active.automaticClearAt)
      ))
    let commands = await backend.commands
    XCTAssertEqual(commands.count, 10, "Neither old nor current retries may replay backend Apply")
  }

  func testSupersededAcceptedFailedApplyCannotReplayButPreAcceptanceFailureCanRetry() async throws {
    let clock = TemporarySimulationTestClock(now: Date(timeIntervalSince1970: 20_000))
    let backend = TemporarySimulationRecordingBackend()
    let controller = SimulationController(
      backend: backend, now: { clock.now }, automaticallySchedulesMaintenance: false
    )
    let link = try makeLink(controller: controller, clock: clock)
    _ = await link.connect(to: ControllerService(name: "controller"))
    var app = ManualSimulationSession(selected: try SelectedLocation(latitude: 31, longitude: 121))
    let attempted = try app.beginApply(requestID: UUID(), at: clock.now)
    await backend.setReadiness(.unavailable(.sessionNotReady))
    let notAccepted = await link.apply(
      requestID: attempted.requestID,
      latitude: attempted.location.latitude, longitude: attempted.location.longitude
    )
    XCTAssertEqual(notAccepted, .failed(requestID: attempted.requestID, reason: .sessionNotReady))
    let beforeAcceptance = await backend.commands
    XCTAssertTrue(beforeAcceptance.isEmpty)

    await backend.setReadiness(.ready)
    await backend.failNextApply()
    let acceptedFailure = await link.apply(
      requestID: attempted.requestID,
      latitude: attempted.location.latitude, longitude: attempted.location.longitude
    )
    XCTAssertEqual(acceptedFailure, .failed(requestID: attempted.requestID, reason: .timedOut))
    XCTAssertTrue(app.fail(requestID: attempted.requestID, reason: .controllerUnavailable))
    app.select(try SelectedLocation(latitude: 35, longitude: 139))
    clock.advance(by: 1)
    let replacement = try app.beginApply(requestID: UUID(), at: clock.now)
    guard
      case .applied(let id, let deadline) = await link.apply(
        requestID: replacement.requestID,
        latitude: replacement.location.latitude, longitude: replacement.location.longitude
      )
    else { return XCTFail("Replacement must succeed after accepted Apply failure") }
    XCTAssertTrue(app.acknowledgeApplied(requestID: id, automaticClearAt: deadline))

    clock.advance(by: 30)
    let stale = await link.apply(
      requestID: attempted.requestID,
      latitude: attempted.location.latitude, longitude: attempted.location.longitude
    )
    XCTAssertEqual(stale, .failed(requestID: attempted.requestID, reason: .timedOut))
    _ = await link.refresh()
    let snapshot = await link.currentStatus()
    XCTAssertEqual(
      snapshot?.simulation,
      .active(
        operationID: replacement.requestID, latitude: replacement.location.latitude,
        longitude: replacement.location.longitude, automaticClearAt: deadline
      ))
    let commands = await backend.commands
    XCTAssertEqual(
      commands,
      [
        .apply(requestID: attempted.requestID, location: attempted.location),
        .apply(requestID: replacement.requestID, location: replacement.location),
      ])
  }

  private func makeLink(
    controller: SimulationController,
    clock: TemporarySimulationTestClock
  ) throws -> TrustedControllerLink {
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
        expiresAt: clock.now.addingTimeInterval(300)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      commandHandler: SimulationControllerCommandHandler(controller: controller),
      now: { clock.now }
    )
    return TrustedControllerLink(
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
  private(set) var commands: [InjectionBackendCommand] = []
  private var currentReadiness: InjectionBackendReadiness = .ready
  private var failsNextApply = false
  private var holdsNextApply = false
  private var applyHeld = false
  private var applyWaiters: [CheckedContinuation<Void, Never>] = []
  private var heldApply: CheckedContinuation<Void, Never>?
  private var failures: Int
  init(failures: Int = 0) { self.failures = failures }
  private var didClear = false
  private var clearWaiters: [CheckedContinuation<Void, Never>] = []

  func readiness() -> InjectionBackendReadiness { currentReadiness }

  func setReadiness(_ readiness: InjectionBackendReadiness) { currentReadiness = readiness }
  func failNextApply() { failsNextApply = true }

  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    commands.append(command)
    switch command {
    case .apply(let requestID, let location):
      if failsNextApply {
        failsNextApply = false
        return .failed(requestID: requestID, reason: .timedOut)
      }
      if holdsNextApply {
        holdsNextApply = false
        applyHeld = true
        let waiters = applyWaiters
        applyWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { heldApply = $0 }
      }
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

  func holdNextApply() { holdsNextApply = true }

  func waitUntilApplyHeld() async {
    if applyHeld { return }
    await withCheckedContinuation { applyWaiters.append($0) }
  }

  func releaseApply() {
    heldApply?.resume()
    heldApply = nil
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
