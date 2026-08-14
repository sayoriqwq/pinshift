import Foundation
import LocationDomain
import SimulationDiagnostics
import XCTest

@testable import SimulationController

final class SimulationControllerTests: XCTestCase {
  func testDefaultStorePathMigratesTheExistingAuthorityFileInPlace() {
    let url = FileTemporarySimulationStore.defaultFileURL(environment: [:])

    XCTAssertTrue(
      url.path.hasSuffix("/Pinshift/SimulationLifecycle/lifecycle.json"),
      "The new authority must discover and replace the old durable journal"
    )
  }

  func testLegacyAuthorityStateBecomesAnImmediateNonBlockingClear() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-controller-migration-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("lifecycle.json")
    let operationID = UUID()
    let legacy = """
      {
        "schemaVersion": 1,
        "legacyCleanupCompleted": true,
        "active": {
          "activeDeviceIdentifier": "device",
          "generationID": "\(operationID.uuidString)",
          "location": {"latitude":31.2304,"longitude":121.4737},
          "leaseExpiresAt": "2099-01-01T00:00:00Z",
          "phase": "applied",
          "retryAttempt": 0
        }
      }
      """
    try Data(legacy.utf8).write(to: file)

    let migrated = try await FileTemporarySimulationStore(fileURL: file).load()

    XCTAssertEqual(migrated?.current?.operationID, operationID)
    XCTAssertEqual(migrated?.current?.phase, .clearPending)
    XCTAssertEqual(migrated?.current?.automaticClearAt, .distantPast)
  }

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
        automaticClearAt: now.addingTimeInterval(900)
      )
    )
    XCTAssertEqual(
      snapshot.simulation,
      .active(
        operationID: requestID,
        location: location,
        automaticClearAt: now.addingTimeInterval(900)
      )
    )
  }

  func testFailedClearRetainsAutomaticClearResponsibility() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let store = InMemoryTemporarySimulationStore()
    let controller = SimulationController(
      backend: FailingClearBackend(),
      stateStore: store,
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
    guard case .clearPending(_, _, let automaticClearAt, .clearFailed) =
      await controller.snapshot().simulation
    else {
      return XCTFail("A failed Clear Now must retain automatic clear")
    }
    XCTAssertEqual(automaticClearAt, now.addingTimeInterval(900))
    let retained = await store.load()?.current
    XCTAssertNotNil(retained)
  }

  func testClearTargetingOlderOperationCannotClearNewerApply() async throws {
    let now = Date(timeIntervalSince1970: 1_000)
    let backend = InMemoryInjectionBackend()
    let controller = SimulationController(
      backend: backend,
      now: { now },
      automaticallySchedulesMaintenance: false
    )
    let firstOperationID = UUID()
    let secondOperationID = UUID()
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let second = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)

    _ = await controller.apply(first, requestID: firstOperationID)
    _ = await controller.apply(second, requestID: secondOperationID)

    let clearResult = await controller.clear(
      requestID: UUID(),
      targetOperationID: firstOperationID
    )

    guard case .cleared = clearResult else {
      return XCTFail("A stale Clear should be acknowledged as a no-op")
    }
    let appliedLocation = await backend.appliedLocation
    let snapshot = await controller.snapshot()
    XCTAssertEqual(appliedLocation, second)
    XCTAssertEqual(
      snapshot.simulation,
      .active(
        operationID: secondOperationID,
        location: second,
        automaticClearAt: now.addingTimeInterval(900)
      )
    )
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
        automaticClearAt: Date(timeIntervalSince1970: 1_900)
      )
    )
    XCTAssertEqual(retry, original)
    XCTAssertEqual(
      replacement,
      .applied(
        requestID: secondID,
        location: second,
        automaticClearAt: Date(timeIntervalSince1970: 2_000)
      )
    )
    let applyCount = await backend.applyCount
    XCTAssertEqual(applyCount, 2)
  }

  func testRestartKeepsTheOriginalDeadlineAndClearsWhenAlreadyDue() async throws {
    let clock = ControllerTestClock(now: Date(timeIntervalSince1970: 1_000))
    let store = InMemoryTemporarySimulationStore()
    let backend = CountingSuccessBackend()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let operationID = UUID()
    let firstAuthority = SimulationController(
      backend: backend,
      stateStore: store,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    _ = await firstAuthority.apply(location, requestID: operationID)

    clock.advance(by: 899)
    let restartedBeforeDeadline = SimulationController(
      backend: backend,
      stateStore: store,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let beforeDeadline = await restartedBeforeDeadline.snapshot()
    XCTAssertEqual(
      beforeDeadline.simulation,
      .active(
        operationID: operationID,
        location: location,
        automaticClearAt: Date(timeIntervalSince1970: 1_900)
      )
    )

    clock.advance(by: 2)
    let restartedAfterDeadline = SimulationController(
      backend: backend,
      stateStore: store,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let afterDeadline = await restartedAfterDeadline.reconcile()
    XCTAssertEqual(afterDeadline.simulation, .idle)
    let clearCount = await backend.clearCount
    XCTAssertEqual(clearCount, 1)
  }

  func testExpiredUnreachableLocationCanBeReplacedAsSoonAsBackendReturns() async throws {
    let clock = ControllerTestClock(now: Date(timeIntervalSince1970: 1_000))
    let backend = InMemoryInjectionBackend()
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let second = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)
    _ = await controller.apply(first, requestID: UUID())

    clock.advance(by: 901)
    await backend.setReadiness(.unavailable(.backendUnavailable))
    let unreachable = await controller.reconcile()
    guard case .clearPending = unreachable.simulation else {
      return XCTFail("The due clear must remain retryable while unreachable")
    }

    await backend.setReadiness(.ready)
    let replacementID = UUID()
    let replacement = await controller.apply(second, requestID: replacementID)
    XCTAssertEqual(
      replacement,
      .applied(
        requestID: replacementID,
        location: second,
        automaticClearAt: clock.now.addingTimeInterval(900)
      )
    )
    let finalLocation = await backend.appliedLocation
    XCTAssertEqual(finalLocation, second)
  }

  func testAutomaticClearAlreadyInFlightFinishesBeforeReplacementApply() async throws {
    let clock = ControllerTestClock(now: Date(timeIntervalSince1970: 1_000))
    let backend = BlockingClearBackend()
    let controller = SimulationController(
      backend: backend,
      now: { clock.now },
      automaticallySchedulesMaintenance: false
    )
    let first = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let second = try SelectedLocation(latitude: 35.6762, longitude: 139.6503)
    _ = await controller.apply(first, requestID: UUID())
    clock.advance(by: 901)

    let automaticClear = Task { await controller.reconcile() }
    await backend.waitUntilClearStarted()
    let replacementID = UUID()
    let replacementApply = Task {
      await controller.apply(second, requestID: replacementID)
    }
    await Task.yield()
    await backend.releaseClear()
    _ = await automaticClear.value
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
      waiters.forEach { $0.resume() }
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

private actor FailingClearBackend: InjectionBackend {
  func readiness() -> InjectionBackendReadiness { .ready }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      return .failed(requestID: requestID, reason: .clearFailed)
    }
  }
}
