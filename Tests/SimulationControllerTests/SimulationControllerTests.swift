import Foundation
import LocationDomain
import SimulationDiagnostics
import XCTest

@testable import SimulationController

final class SimulationControllerTests: XCTestCase {
  func testApplyArmsFixedAutomaticClearAndReportsActiveSnapshot() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let backend = InMemoryInjectionBackend()
    let controller = SimulationController(
      backend: backend,
      now: { now },
      automaticallySchedulesMaintenance: false
    )
    let requestID = UUID()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let applyResult = await controller.apply(location, requestID: requestID)
    let snapshot = await controller.snapshot()
    XCTAssertEqual(
      applyResult,
      .applied(
        requestID: requestID,
        location: location,
        automaticClearAt: now.addingTimeInterval(180)
      )
    )
    XCTAssertEqual(
      snapshot.simulation,
      .active(
        operationID: requestID,
        location: location,
        automaticClearAt: now.addingTimeInterval(180)
      )
    )
  }

  func testFailedManualClearCanBeRetriedWithoutDurableCleanupState() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let backend = FailingThenSucceedingClearBackend()
    let controller = SimulationController(
      backend: backend,
      now: { now },
      automaticallySchedulesMaintenance: false
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID())
    let clearID = UUID()

    let clearResult = await controller.clear(requestID: clearID)
    XCTAssertEqual(
      clearResult,
      .failed(requestID: clearID, reason: .clearFailed)
    )
    let failedSnapshot = await controller.snapshot()
    guard
      case .clearPending(_, _, let automaticClearAt, .clearFailed) =
        failedSnapshot.simulation
    else {
      return XCTFail("A failed Clear Now must remain visible for manual retry")
    }
    XCTAssertEqual(automaticClearAt, now.addingTimeInterval(180))

    let retryID = UUID()
    let retryResult = await controller.clear(requestID: retryID)
    XCTAssertEqual(
      retryResult,
      .cleared(requestID: retryID)
    )
    let finalSnapshot = await controller.snapshot()
    XCTAssertEqual(finalSnapshot.simulation, .idle)
  }

  func testClearExecutesBackendWhenTheSessionHasNoTrackedOperation() async {
    let backend = CountingSuccessBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let clearID = UUID()

    let result = await controller.clear(requestID: clearID)

    XCTAssertEqual(result, .cleared(requestID: clearID))
    let clearCount = await backend.clearCount
    XCTAssertEqual(clearCount, 1)
  }

  func testFailedClearWithoutATrackedOperationRemainsVisibleUntilManualRetry() async {
    let backend = FailingThenSucceedingClearBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let clearID = UUID()

    let failed = await controller.clear(requestID: clearID)

    XCTAssertEqual(failed, .failed(requestID: clearID, reason: .clearFailed))
    guard
      case .clearPending(let operationID, nil, _, .clearFailed) =
        await controller.snapshot().simulation
    else {
      return XCTFail("An untracked Clear failure must not be reported as idle")
    }
    XCTAssertEqual(operationID, clearID)

    let retryID = UUID()
    let retried = await controller.clear(requestID: retryID)
    let finalSnapshot = await controller.snapshot()
    XCTAssertEqual(retried, .cleared(requestID: retryID))
    XCTAssertEqual(finalSnapshot.simulation, .idle)
  }

  func testSameApplyRetryKeepsItsDeadlineAndNewApplyGetsAFreshOne() async throws {
    let clock = ControllerTestClock(now: Date(timeIntervalSince1970: 1_000))
    let backend = CountingSuccessBackend()
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let firstID = UUID()
    let secondID = UUID()
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let second = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)

    let original = await controller.apply(first, requestID: firstID)
    clock.advance(by: 100)
    let retry = await controller.apply(first, requestID: firstID)
    let replacement = await controller.apply(second, requestID: secondID)

    XCTAssertEqual(
      original,
      .applied(
        requestID: firstID,
        location: first,
        automaticClearAt: Date(timeIntervalSince1970: 1_180)
      )
    )
    XCTAssertEqual(retry, original)
    XCTAssertEqual(
      replacement,
      .applied(
        requestID: secondID,
        location: second,
        automaticClearAt: Date(timeIntervalSince1970: 1_280)
      )
    )
    let applyCount = await backend.applyCount
    XCTAssertEqual(applyCount, 2)
  }

  func testClearedApplyRequestCannotBeAcknowledgedAgainAsActive() async throws {
    let backend = CountingSuccessBackend()
    let controller = SimulationController(
      backend: backend,
      automaticallySchedulesMaintenance: false
    )
    let requestID = UUID()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: requestID)
    _ = await controller.clear()

    let replay = await controller.apply(location, requestID: requestID)

    XCTAssertEqual(replay, .failed(requestID: requestID, reason: .timedOut))
    let applyCount = await backend.applyCount
    XCTAssertEqual(applyCount, 1)
  }

  func testAutomaticClearAlreadyInFlightFinishesBeforeReplacementApply() async throws {
    let clock = ControllerTestClock(now: Date(timeIntervalSince1970: 1_000))
    let backend = BlockingClearBackend()
    let sleeper = ControlledSleeper()
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      sleep: { seconds in try await sleeper.sleep(for: seconds) }
    )
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let second = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)
    _ = await controller.apply(first, requestID: UUID())
    let scheduledInterval = await sleeper.waitUntilScheduled()
    XCTAssertEqual(scheduledInterval, 180)

    await sleeper.resume()
    await backend.waitUntilClearStarted()
    let replacementID = UUID()
    let replacementApply = Task {
      await controller.apply(second, requestID: replacementID)
    }
    await Task.yield()
    await backend.releaseClear()
    _ = await replacementApply.value

    let finalLocation = await backend.appliedLocation
    let finalSnapshot = await controller.snapshot()
    XCTAssertEqual(finalLocation, second)
    guard case .active(let operationID, let location, _) = finalSnapshot.simulation else {
      return XCTFail("The replacement must own the final state")
    }
    XCTAssertEqual(operationID, replacementID)
    XCTAssertEqual(location, second)
  }
}

private actor ControlledSleeper {
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
    sleepContinuation?.resume()
    sleepContinuation = nil
  }
}

private final class ControllerTestClock: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Date

  init(now: Date) {
    value = now
  }

  var now: Date {
    lock.withLock { value }
  }

  func advance(by interval: TimeInterval) {
    lock.withLock { value = value.addingTimeInterval(interval) }
  }
}

private actor CountingSuccessBackend: InjectionBackend {
  private(set) var applyCount = 0
  private(set) var clearCount = 0
  private(set) var appliedLocation: SelectedLocation?

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      applyCount += 1
      appliedLocation = location
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearCount += 1
      appliedLocation = nil
      return .cleared(requestID: requestID)
    }
  }
}

private actor BlockingClearBackend: InjectionBackend {
  private(set) var appliedLocation: SelectedLocation?
  private var clearStarted = false
  private var clearStartedWaiters: [CheckedContinuation<Void, Never>] = []
  private var clearContinuation: CheckedContinuation<Void, Never>?

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      appliedLocation = location
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearStarted = true
      let waiters = clearStartedWaiters
      clearStartedWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      await withCheckedContinuation { continuation in
        clearContinuation = continuation
      }
      appliedLocation = nil
      return .cleared(requestID: requestID)
    }
  }

  func waitUntilClearStarted() async {
    if clearStarted { return }
    await withCheckedContinuation { continuation in
      clearStartedWaiters.append(continuation)
    }
  }

  func releaseClear() {
    clearContinuation?.resume()
    clearContinuation = nil
  }
}

private actor FailingThenSucceedingClearBackend: InjectionBackend {
  private var clearCount = 0

  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearCount += 1
      if clearCount == 1 {
        return .failed(requestID: requestID, reason: .clearFailed)
      }
      return .cleared(requestID: requestID)
    }
  }
}
