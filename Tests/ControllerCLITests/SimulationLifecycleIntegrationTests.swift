import ControllerLink
import Foundation
import LocationDomain
import SimulationController
import SimulationDiagnostics
import XCTest

@testable import ControllerCLI

final class SimulationLifecycleIntegrationTests: XCTestCase {
  func testControllerRestartClearsAppliedSimulationBeforeReportingReady() async {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-lifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let lifecycleFile = directory.appendingPathComponent("lifecycle.json")
    let environment = [
      ControllerCLIRuntime.deviceEnvironmentKey: "Active Test Device",
      ControllerCLIRuntime.developerDirectoryEnvironmentKey:
        "/Applications/Xcode-beta.app/Contents/Developer",
      "REMOTE_LOCATION_LIFECYCLE_FILE": lifecycleFile.path,
    ]
    let executor = LifecycleRecordingDevicectlExecutor()
    let guardianHealthStore = InMemorySimulationCleanupGuardianHealthStore(
      health: SimulationCleanupGuardianHealth(
        guardianID: UUID(),
        activeDeviceIdentifier: "Active Test Device",
        recordedAt: Date()
      )
    )

    let firstController = ControllerCLIRuntime.makeController(
      cleanupGuardianHealthStore: guardianHealthStore,
      environment: environment,
      executor: executor
    )
    let firstHandler = SimulationControllerCommandHandler(controller: firstController)
    let baselineResetID = UUID()
    let baselineReset = await firstHandler.handle(.stop(requestID: baselineResetID))
    XCTAssertEqual(
      baselineReset,
      .stopped(requestID: baselineResetID)
    )
    let applyID = UUID()
    let applied = await firstHandler.handle(
      .apply(
        requestID: applyID,
        latitude: 31.2304,
        longitude: 121.4737
      )
    )
    XCTAssertEqual(
      applied,
      .applied(requestID: applyID)
    )
    XCTAssertEqual(executor.clearCount, 1)

    let restartedController = ControllerCLIRuntime.makeController(
      cleanupGuardianHealthStore: guardianHealthStore,
      environment: environment,
      executor: executor
    )
    let restartedHandler = SimulationControllerCommandHandler(
      controller: restartedController
    )
    let statusID = UUID()
    let restartedStatus = await restartedHandler.handle(.status(requestID: statusID))
    XCTAssertEqual(
      restartedStatus,
      .ready(requestID: statusID)
    )

    XCTAssertEqual(executor.clearCount, 2)
  }

  func testLeaseExpiryClearsWithoutAnotherUserAction() async throws {
    let start = Date(timeIntervalSince1970: 10_000)
    let clock = LifecycleTestClock(now: start)
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      leaseDuration: 3_600,
      now: { clock.now }
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let applied = await controller.apply(
      location,
      requestID: UUID(),
      generationID: UUID()
    )
    guard case .applied = applied else {
      return XCTFail("Expected the Simulation Lease to begin after Apply")
    }

    clock.advance(by: 3_601)
    await controller.reconcileLifecycle()

    let clearCount = await backend.clearCount
    let persistedActive = await store.load()?.active
    let status = await controller.status()
    XCTAssertEqual(clearCount, 1)
    XCTAssertNil(persistedActive)
    XCTAssertEqual(status, .stopped)
  }

  func testDefaultApplyStartsFifteenMinuteAuthoritativeLeaseAcrossAppAndController() async throws {
    let start = Date(timeIntervalSince1970: 12_000)
    let clock = LifecycleTestClock(now: start)
    let controllerStore = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: controllerStore,
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x31, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x32, count: 32))
    let serverSession = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: start.addingTimeInterval(300)
      ),
      authorizationStore: InMemoryControllerAuthorizationStore(
        authorization: authorization
      ),
      commandHandler: SimulationControllerCommandHandler(controller: controller),
      now: { clock.now }
    )
    let transport = RestartableControllerTransport(
      identity: identity,
      session: serverSession
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

    var appSession = ManualSimulationSession()
    try appSession.select(latitude: "31.2304", longitude: "121.4737")
    let applyRequest = try appSession.beginApply(requestID: UUID(), at: start)
    XCTAssertEqual(applyRequest.requestedLeaseDuration, 900)

    let response = await link.apply(
      requestID: applyRequest.requestID,
      generationID: applyRequest.generationID,
      latitude: applyRequest.location.latitude,
      longitude: applyRequest.location.longitude,
      requestedLeaseDuration: applyRequest.requestedLeaseDuration
    )
    guard
      case .appliedLifecycle(
        let responseID,
        let generationID,
        let leaseExpiresAt
      ) = response
    else {
      return XCTFail("Expected a protected lifecycle Apply acknowledgement")
    }
    XCTAssertEqual(leaseExpiresAt, start.addingTimeInterval(900))
    XCTAssertTrue(
      appSession.acknowledgeApplied(
        requestID: responseID,
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
    )
    XCTAssertEqual(appSession.activeAppliedRequest?.leaseExpiresAt, leaseExpiresAt)
    let persistedLeaseExpiresAt = await controllerStore.load()?.active?.leaseExpiresAt
    XCTAssertEqual(persistedLeaseExpiresAt, leaseExpiresAt)
  }

  func testMissingCleanupGuardianBlocksApplyBeforeAnyCoordinateMutation() async throws {
    let start = Date(timeIntervalSince1970: 12_500)
    let clock = LifecycleTestClock(now: start)
    let guardianHealthStore = InMemorySimulationCleanupGuardianHealthStore()
    let lifecycleStore = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: lifecycleStore,
      activeDeviceIdentifier: "Active Test Device",
      cleanupGuardianHealthStore: guardianHealthStore,
      requiresHealthyCleanupGuardian: true,
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x35, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x36, count: 32))
    let serverSession = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: start.addingTimeInterval(300)
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
      transport: RestartableControllerTransport(
        identity: identity,
        session: serverSession
      )
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
    let applyCount = await backend.applyCount
    let obligation = await lifecycleStore.load()?.active

    XCTAssertEqual(
      response,
      .failed(requestID: requestID, reason: .cleanupGuardianUnavailable)
    )
    XCTAssertEqual(applyCount, 0)
    XCTAssertNil(obligation)
  }

  func testAcknowledgedLeaseExtensionKeepsTheGenerationAndNeverReappliesCoordinates() async throws {
    let start = Date(timeIntervalSince1970: 13_000)
    let clock = LifecycleTestClock(now: start)
    let controllerStore = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: controllerStore,
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x33, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x34, count: 32))
    let serverSession = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: start.addingTimeInterval(300)
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
      transport: RestartableControllerTransport(
        identity: identity,
        session: serverSession
      )
    )
    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .connected(identity))

    var appSession = ManualSimulationSession()
    try appSession.select(latitude: "31.2304", longitude: "121.4737")
    let applyRequest = try appSession.beginApply(
      requestID: UUID(),
      leaseDuration: .thirtyMinutes,
      at: start
    )
    let applyResponse = await link.apply(
      requestID: applyRequest.requestID,
      generationID: applyRequest.generationID,
      latitude: applyRequest.location.latitude,
      longitude: applyRequest.location.longitude,
      requestedLeaseDuration: applyRequest.requestedLeaseDuration
    )
    guard
      case .appliedLifecycle(
        let applyResponseID,
        let generationID,
        let originalExpiry
      ) = applyResponse
    else {
      return XCTFail("Expected the initial lifecycle Apply acknowledgement")
    }
    XCTAssertEqual(originalExpiry, start.addingTimeInterval(1_800))
    XCTAssertTrue(
      appSession.acknowledgeApplied(
        requestID: applyResponseID,
        generationID: generationID,
        leaseExpiresAt: originalExpiry
      )
    )

    let extensionRequestID = UUID()
    let extensionIntent = try XCTUnwrap(
      appSession.beginLeaseExtension(requestID: extensionRequestID, at: start)
    )
    let firstExtensionResponse = await link.extendLease(
      requestID: extensionIntent.requestID,
      generationID: extensionIntent.generationID,
      extensionDuration: extensionIntent.extensionDuration
    )
    guard
      case .extendedLifecycle(
        let responseID,
        let extendedGenerationID,
        let extendedExpiry
      ) = firstExtensionResponse
    else {
      return XCTFail("Expected an acknowledged lease extension")
    }
    XCTAssertEqual(responseID, extensionRequestID)
    XCTAssertEqual(extendedGenerationID, generationID)
    XCTAssertEqual(extendedExpiry, start.addingTimeInterval(2_700))
    XCTAssertTrue(
      appSession.acknowledgeLeaseExtension(
        requestID: responseID,
        generationID: extendedGenerationID,
        leaseExpiresAt: extendedExpiry
      )
    )

    let retriedResponse = await link.extendLease(
      requestID: extensionIntent.requestID,
      generationID: extensionIntent.generationID,
      extensionDuration: extensionIntent.extensionDuration
    )
    let applyCount = await backend.applyCount
    XCTAssertEqual(retriedResponse, firstExtensionResponse)
    XCTAssertEqual(appSession.activeAppliedRequest?.generationID, generationID)
    XCTAssertEqual(appSession.activeAppliedRequest?.leaseExpiresAt, extendedExpiry)
    XCTAssertNil(appSession.pendingLeaseExtension)
    XCTAssertEqual(applyCount, 1)
  }

  func testSixtyMinuteChoiceAndExtensionNearCapUseAuthoritativeDeadline() async throws {
    let start = Date(timeIntervalSince1970: 14_000)
    let clock = LifecycleTestClock(now: start)
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let generationID = UUID()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let applyResult = await controller.apply(
      location,
      requestID: UUID(),
      generationID: generationID,
      requestedLeaseDuration: SimulationLeaseDuration.sixtyMinutes.timeInterval
    )
    guard case .applied = applyResult else {
      return XCTFail("Expected the 60-minute choice to Apply")
    }
    let initialExpiry = await store.load()?.active?.leaseExpiresAt
    XCTAssertEqual(initialExpiry, start.addingTimeInterval(3_600))

    clock.advance(by: 300)
    let extensionID = UUID()
    let extensionResult = await controller.extendLease(
      requestID: extensionID,
      generationID: generationID
    )
    let cappedExpiry = clock.now.addingTimeInterval(3_600)

    XCTAssertEqual(
      extensionResult,
      .extended(
        requestID: extensionID,
        generationID: generationID,
        leaseExpiresAt: cappedExpiry
      )
    )
    let persistedCappedExpiry = await store.load()?.active?.leaseExpiresAt
    let applyCount = await backend.applyCount
    XCTAssertEqual(persistedCappedExpiry, cappedExpiry)
    XCTAssertEqual(applyCount, 1)
  }

  func testPendingLeaseExtensionSurvivesLearningAppRelaunch() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-extension-session-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = FileManualSimulationSessionStore(
      fileURL: directory.appendingPathComponent("app-session.json")
    )
    let start = Date(timeIntervalSince1970: 14_500)
    var session = ManualSimulationSession()
    try session.select(latitude: "31.2304", longitude: "121.4737")
    let apply = try session.beginApply(requestID: UUID(), at: start)
    XCTAssertTrue(
      session.acknowledgeApplied(
        requestID: apply.requestID,
        generationID: apply.generationID,
        leaseExpiresAt: start.addingTimeInterval(900)
      )
    )
    let extensionIntent = try XCTUnwrap(
      session.beginLeaseExtension(requestID: UUID(), at: start.addingTimeInterval(30))
    )

    try store.save(session)
    let relaunched = try XCTUnwrap(store.load())

    XCTAssertEqual(relaunched.pendingLeaseExtension, extensionIntent)
    XCTAssertEqual(relaunched.activeAppliedRequest, session.activeAppliedRequest)
    XCTAssertEqual(relaunched.cleanupStatus, .protected)
  }

  func testIndependentCleanupGuardianClearsAfterServerOwnerDisappears() async throws {
    let start = Date(timeIntervalSince1970: 15_000)
    let clock = LifecycleTestClock(now: start)
    let serverOwnerID = UUID()
    let heartbeatStore = InMemorySimulationServerHeartbeatStore(
      heartbeat: SimulationServerHeartbeat(
        ownerID: serverOwnerID,
        recordedAt: start
      )
    )
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let sleepRecorder = LifecycleSleepRecorder()
    var serverController: SimulationController? = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      leaseDuration: 3_600,
      serverOwnerID: serverOwnerID,
      serverHeartbeatStore: heartbeatStore,
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let guardian = SimulationCleanupGuardian(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      serverHeartbeatStore: heartbeatStore,
      now: { clock.now },
      sleep: { seconds in
        await sleepRecorder.record(seconds)
        throw CancellationError()
      }
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    _ = await serverController?.apply(
      location,
      requestID: UUID(),
      generationID: UUID()
    )
    serverController = nil

    _ = await guardian.reconcileNow()
    let earlyClearCount = await backend.clearCount
    let scheduledSleeps = await sleepRecorder.durations
    XCTAssertEqual(earlyClearCount, 0)
    XCTAssertTrue(scheduledSleeps.isEmpty)

    clock.advance(by: 29)

    _ = await guardian.reconcileNow()
    let beforeGraceClearCount = await backend.clearCount
    XCTAssertEqual(beforeGraceClearCount, 0)

    clock.advance(by: 2)

    _ = await guardian.reconcileNow()

    let clearCount = await backend.clearCount
    let persistedActive = await store.load()?.active
    XCTAssertEqual(clearCount, 1)
    XCTAssertNil(persistedActive)
  }

  func testTransientIOSDisconnectDoesNotClearWhileServerHeartbeatRemainsHealthy() async throws {
    let start = Date(timeIntervalSince1970: 16_000)
    let clock = LifecycleTestClock(now: start)
    let ownerID = UUID()
    let heartbeatStore = InMemorySimulationServerHeartbeatStore(
      heartbeat: SimulationServerHeartbeat(ownerID: ownerID, recordedAt: start)
    )
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      serverOwnerID: ownerID,
      serverHeartbeatStore: heartbeatStore,
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let guardian = SimulationCleanupGuardian(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      serverHeartbeatStore: heartbeatStore,
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x37, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x38, count: 32))
    let serverSession = ControllerServerSession(
      identity: identity,
      pairingAuthority: try PairingCodeAuthority(
        code: "123456",
        identity: identity,
        expiresAt: start.addingTimeInterval(300)
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
      transport: RestartableControllerTransport(
        identity: identity,
        session: serverSession
      )
    )
    let connection = await link.connect(to: ControllerService(name: "controller"))
    XCTAssertEqual(connection, .connected(identity))
    let applyID = UUID()
    guard
      case .appliedLifecycle = await link.apply(
        requestID: applyID,
        generationID: UUID(),
        latitude: 31.2304,
        longitude: 121.4737,
        requestedLeaseDuration: 900
      )
    else {
      return XCTFail("Expected a protected 15-minute Apply")
    }

    _ = await link.disconnected()
    clock.advance(by: 31)
    await heartbeatStore.save(
      SimulationServerHeartbeat(ownerID: ownerID, recordedAt: clock.now)
    )
    _ = await guardian.reconcileNow()
    let clearCountAfterDisconnect = await backend.clearCount
    XCTAssertEqual(clearCountAfterDisconnect, 0)

    clock.advance(by: 868)
    await heartbeatStore.save(
      SimulationServerHeartbeat(ownerID: ownerID, recordedAt: clock.now)
    )
    _ = await guardian.reconcileNow()
    let clearCountBeforeLease = await backend.clearCount
    XCTAssertEqual(clearCountBeforeLease, 0)

    clock.advance(by: 2)
    _ = await guardian.reconcileNow()
    let finalClearCount = await backend.clearCount
    let finalObligation = await store.load()?.active
    XCTAssertEqual(finalClearCount, 1)
    XCTAssertNil(finalObligation)
  }

  func testLostStopResponseRetriesTheSameOperationWithoutASecondClear() async throws {
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device"
    )
    _ = await controller.apply(
      location,
      requestID: UUID(),
      generationID: UUID()
    )
    let stopID = UUID()
    let firstResult = await controller.stop(requestID: stopID)
    XCTAssertEqual(firstResult, .cleared(requestID: stopID))

    let restartedController = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device"
    )
    let retriedResult = await restartedController.stop(requestID: stopID)
    let clearCount = await backend.clearCount

    XCTAssertEqual(retriedResult, .cleared(requestID: stopID))
    XCTAssertEqual(clearCount, 1)
  }

  func testLostApplyAcknowledgementIsClearedFromTheDurablePreApplyObligation() async throws {
    let backingStore = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let failingStore = FailingSaveLifecycleStore(
      backingStore: backingStore,
      failingSaveNumbers: [2]
    )
    let backend = LifecycleRecordingBackend()
    let firstController = SimulationController(
      backend: backend,
      lifecycleStore: failingStore,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    let applyID = UUID()
    let generationID = UUID()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let uncertainApply = await firstController.apply(
      location,
      requestID: applyID,
      generationID: generationID
    )
    let durableBeforeRestart = await backingStore.load()?.active
    let applyCountBeforeRestart = await backend.applyCount
    let clearCountBeforeRestart = await backend.clearCount

    XCTAssertEqual(
      uncertainApply,
      .failed(requestID: applyID, reason: .backendUnavailable)
    )
    XCTAssertEqual(durableBeforeRestart?.phase, .applyUncertain)
    XCTAssertEqual(durableBeforeRestart?.generationID, generationID)
    XCTAssertEqual(applyCountBeforeRestart, 1)
    XCTAssertEqual(clearCountBeforeRestart, 0)

    let restartedController = SimulationController(
      backend: backend,
      lifecycleStore: backingStore,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    _ = await restartedController.reconcileLifecycle()
    let durableAfterRestart = await backingStore.load()?.active
    let clearCountAfterRestart = await backend.clearCount

    XCTAssertEqual(clearCountAfterRestart, 1)
    XCTAssertNil(durableAfterRestart)
  }

  func testUnavailableDeviceKeepsCleanupPendingUntilBoundedRetrySucceeds() async throws {
    let start = Date(timeIntervalSince1970: 20_000)
    let clock = LifecycleTestClock(now: start)
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend(clearFailures: [.clearFailed])
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID(), generationID: UUID())

    let stopID = UUID()
    let failedStop = await controller.stop(requestID: stopID)
    XCTAssertEqual(failedStop, .failed(requestID: stopID, reason: .clearFailed))
    let pending = await store.load()?.active
    XCTAssertEqual(pending?.phase, .cleanupPending)
    XCTAssertEqual(pending?.retryAttempt, 1)
    XCTAssertEqual(pending?.nextRetryAt, start.addingTimeInterval(2))

    await controller.reconcileLifecycle()
    let earlyClearCount = await backend.clearCount
    XCTAssertEqual(earlyClearCount, 1)

    clock.advance(by: 2)
    await controller.reconcileLifecycle()
    let finalClearCount = await backend.clearCount
    let remainingObligation = await store.load()?.active
    XCTAssertEqual(finalClearCount, 2)
    XCTAssertNil(remainingObligation)
  }

  func testFailedShutdownClearExitsNonzeroAndRecoversOnNextControllerStart() async throws {
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend(clearFailures: [.clearFailed])
    let firstController = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    _ = await firstController.apply(
      try SelectedLocation(latitude: 31.2304, longitude: 121.4737),
      requestID: UUID(),
      generationID: UUID()
    )

    do {
      try await ControllerCLIRuntime.runServeLifecycle(
        seconds: 0,
        controller: firstController,
        sleep: { _ in },
        report: { _ in }
      )
      XCTFail("Expected the failed foreground cleanup to fail the serve lifecycle")
    } catch let error as ControllerServeLifecycleError {
      XCTAssertEqual(error, .cleanupFailed)
    }
    let pendingAfterShutdown = await store.load()?.active
    let firstClearCount = await backend.clearCount
    XCTAssertEqual(pendingAfterShutdown?.phase, .cleanupPending)
    XCTAssertEqual(firstClearCount, 1)

    let restartedController = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    _ = await restartedController.reconcileLifecycle()
    let remainingAfterRestart = await store.load()?.active
    let finalClearCount = await backend.clearCount

    XCTAssertNil(remainingAfterRestart)
    XCTAssertEqual(finalClearCount, 2)
  }

  func testServeLifecyclePublishesItsDurableOwnerHeartbeatBeforeAcceptingWork() async throws {
    let start = Date(timeIntervalSince1970: 25_000)
    let ownerID = UUID()
    let heartbeatStore = InMemorySimulationServerHeartbeatStore()
    let heartbeat = SimulationServerHeartbeatEmitter(
      ownerID: ownerID,
      store: heartbeatStore,
      now: { start },
      sleep: { _ in throw CancellationError() }
    )
    let controller = SimulationController(
      backend: LifecycleRecordingBackend(),
      lifecycleStore: InMemorySimulationLifecycleStore(
        journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
      ),
      activeDeviceIdentifier: "Active Test Device",
      serverOwnerID: ownerID,
      serverHeartbeatStore: heartbeatStore,
      sleep: { _ in throw CancellationError() }
    )

    try await ControllerCLIRuntime.runServeLifecycle(
      seconds: 0,
      controller: controller,
      serverHeartbeat: heartbeat,
      sleep: { _ in },
      report: { _ in }
    )

    let persistedHeartbeat = await heartbeatStore.load()
    XCTAssertEqual(
      persistedHeartbeat,
      SimulationServerHeartbeat(ownerID: ownerID, recordedAt: start)
    )
  }

  func testLifecycleDiagnosticsObserveObligationLeaseRetryAndClearAcknowledgement() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-lifecycle-diagnostics-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let diagnostics = SimulationDiagnosticRecorder(
      side: .macController,
      directory: directory
    )
    let start = Date(timeIntervalSince1970: 40_000)
    let clock = LifecycleTestClock(now: start)
    let backend = LifecycleRecordingBackend(clearFailures: [.clearFailed])
    let controller = SimulationController(
      backend: backend,
      diagnostics: diagnostics,
      lifecycleStore: InMemorySimulationLifecycleStore(
        journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
      ),
      activeDeviceIdentifier: "Active Test Device",
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    _ = await controller.apply(
      try SelectedLocation(latitude: 31.2304, longitude: 121.4737),
      requestID: UUID(),
      generationID: UUID()
    )
    _ = await controller.stop(requestID: UUID())
    clock.advance(by: 2)
    _ = await controller.reconcileLifecycle()

    let events = await diagnostics.events()
    let eventKinds = Set(events.map(\.kind))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.apply-obligation-persisted"))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.lease-started"))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.cleanup-intent-persisted"))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.cleanup-retry-scheduled"))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.cleanup-retry-started"))
    XCTAssertTrue(eventKinds.contains("controller.lifecycle.clear-acknowledged"))
  }

  func testLongerServerDurationCannotExtendTheOneHourMaximumLease() async throws {
    let start = Date(timeIntervalSince1970: 30_000)
    let clock = LifecycleTestClock(now: start)
    let controller = SimulationController(
      backend: LifecycleRecordingBackend(),
      lifecycleStore: InMemorySimulationLifecycleStore(
        journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
      ),
      activeDeviceIdentifier: "Active Test Device",
      leaseDuration: 7_200,
      now: { clock.now },
      sleep: { _ in throw CancellationError() }
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    _ = await controller.apply(location, requestID: UUID(), generationID: UUID())

    let snapshot = await controller.lifecycleSnapshot()
    guard case .applied(_, let leaseExpiresAt) = snapshot.state else {
      return XCTFail("Expected an Applied Simulation Lease")
    }
    XCTAssertEqual(leaseExpiresAt, start.addingTimeInterval(3_600))
  }

  func testOfflineStopSurvivesAppRelaunchAndClearsWhenControllerReturns() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("pinshift-link-lifecycle-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let appStore = FileManualSimulationSessionStore(
      fileURL: directory.appendingPathComponent("app-session.json")
    )
    let controllerStore = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: controllerStore,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x41, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x42, count: 32))
    let serverAuthorization = InMemoryControllerAuthorizationStore(
      authorization: authorization
    )
    let pairingAuthority = try PairingCodeAuthority(
      code: "123456",
      identity: identity,
      expiresAt: Date().addingTimeInterval(300)
    )
    let serverSession = ControllerServerSession(
      identity: identity,
      pairingAuthority: pairingAuthority,
      authorizationStore: serverAuthorization,
      commandHandler: SimulationControllerCommandHandler(controller: controller)
    )
    let transport = RestartableControllerTransport(
      identity: identity,
      session: serverSession
    )
    let trustStore = InMemoryControllerTrustStore(identity: identity)
    let clientAuthorization = InMemoryControllerAuthorizationStore(
      authorization: authorization
    )
    let service = ControllerService(name: "controller")
    let firstLink = TrustedControllerLink(
      trust: ControllerTrust(store: trustStore),
      authorizationStore: clientAuthorization,
      transport: transport
    )
    let firstConnection = await firstLink.connect(to: service)
    XCTAssertEqual(firstConnection, .connected(identity))

    var appSession = ManualSimulationSession()
    try appSession.select(latitude: "31.2304", longitude: "121.4737")
    let applyID = UUID()
    let generationID = UUID()
    let applyRequest = try appSession.beginApply(
      requestID: applyID,
      generationID: generationID,
      at: Date()
    )
    let applyResponse = await firstLink.apply(
      requestID: applyID,
      generationID: generationID,
      latitude: applyRequest.location.latitude,
      longitude: applyRequest.location.longitude
    )
    guard
      case .appliedLifecycle(
        let responseID,
        let responseGenerationID,
        let leaseExpiresAt
      ) = applyResponse
    else {
      return XCTFail("Expected lifecycle-aware Apply acknowledgement")
    }
    XCTAssertTrue(
      appSession.acknowledgeApplied(
        requestID: responseID,
        generationID: responseGenerationID,
        leaseExpiresAt: leaseExpiresAt
      )
    )

    let stopIntent = try XCTUnwrap(
      appSession.beginStop(requestID: UUID(), at: Date())
    )
    try appStore.save(appSession)
    await transport.setSession(nil)
    _ = await firstLink.disconnected()
    let offlineResponse = await firstLink.stop(
      requestID: stopIntent.requestID,
      generationID: stopIntent.generationID
    )
    XCTAssertEqual(
      offlineResponse,
      .failed(requestID: stopIntent.requestID, reason: .controllerUnavailable)
    )
    _ = appSession.failStop(
      requestID: stopIntent.requestID,
      reason: .controllerUnavailable
    )
    try appStore.save(appSession)

    var relaunchedSession = try XCTUnwrap(appStore.load())
    XCTAssertEqual(relaunchedSession.pendingStopIntent, stopIntent)
    await transport.setSession(serverSession)
    let relaunchedLink = TrustedControllerLink(
      trust: ControllerTrust(store: trustStore),
      authorizationStore: clientAuthorization,
      transport: transport
    )
    let relaunchedConnection = await relaunchedLink.connect(to: service)
    XCTAssertEqual(relaunchedConnection, .connected(identity))
    let retriedStop = await relaunchedLink.stop(
      requestID: stopIntent.requestID,
      generationID: stopIntent.generationID
    )
    guard case .stoppedLifecycle(let stopResponseID, let stoppedGenerationID) = retriedStop else {
      return XCTFail("Expected the original pending Stop to clear after reconnect")
    }
    XCTAssertTrue(
      relaunchedSession.acknowledgeStopped(
        requestID: stopResponseID,
        generationID: stoppedGenerationID
      )
    )
    try appStore.save(relaunchedSession)

    let clearCount = await backend.clearCount
    let remainingControllerObligation = await controllerStore.load()?.active
    XCTAssertEqual(clearCount, 1)
    XCTAssertNil(try XCTUnwrap(appStore.load()).pendingStopIntent)
    XCTAssertNil(remainingControllerObligation)
  }

  func testReplacementGenerationRejectsLateStopForTheOlderSimulation() async throws {
    let backend = LifecycleRecordingBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: InMemorySimulationLifecycleStore(
        journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
      ),
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    let firstLocation = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let replacement = try SelectedLocation(latitude: 52.5200, longitude: 13.4050)
    let firstGenerationID = UUID()
    let secondGenerationID = UUID()
    _ = await controller.apply(
      firstLocation,
      requestID: UUID(),
      generationID: firstGenerationID
    )
    let replacementResult = await controller.apply(
      replacement,
      requestID: UUID(),
      generationID: secondGenerationID
    )
    guard case .applied = replacementResult else {
      return XCTFail("Expected a normal replacement Apply to create a new generation")
    }

    let oldStopID = UUID()
    let oldStop = await controller.stop(
      requestID: oldStopID,
      generationID: firstGenerationID
    )
    XCTAssertEqual(
      oldStop,
      .failed(requestID: oldStopID, reason: .generationMismatch)
    )
    let applyCount = await backend.applyCount
    let clearCountBeforeCurrentStop = await backend.clearCount
    XCTAssertEqual(applyCount, 2)
    XCTAssertEqual(clearCountBeforeCurrentStop, 0)

    let currentStopID = UUID()
    let currentStop = await controller.stop(
      requestID: currentStopID,
      generationID: secondGenerationID
    )
    let finalClearCount = await backend.clearCount
    XCTAssertEqual(currentStop, .cleared(requestID: currentStopID))
    XCTAssertEqual(finalClearCount, 1)
  }

  func testStopDuringInFlightApplyWaitsThenClearsTheAppliedGeneration() async throws {
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(legacyCleanupCompleted: true)
    )
    let backend = SuspendedApplyLifecycleBackend()
    let controller = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() }
    )
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let generationID = UUID()
    let applyTask = Task {
      await controller.apply(
        location,
        requestID: UUID(),
        generationID: generationID
      )
    }

    await backend.waitUntilApplyStarted()
    let stopID = UUID()
    let pendingStop = await controller.stop(
      requestID: stopID,
      generationID: generationID
    )

    XCTAssertEqual(
      pendingStop,
      .failed(requestID: stopID, reason: .clearFailed)
    )
    let pendingCommandOrder = await backend.commandOrder
    let pendingRecord = await store.load()?.active
    XCTAssertEqual(pendingCommandOrder, ["apply-started"])
    XCTAssertEqual(pendingRecord?.phase, .cleanupPending)

    await backend.finishApply()
    guard case .applied = await applyTask.value else {
      return XCTFail("Expected the in-flight Apply acknowledgement")
    }
    let retriedStop = await controller.stop(
      requestID: stopID,
      generationID: generationID
    )
    let finalCommandOrder = await backend.commandOrder
    let finalRecord = await store.load()?.active

    XCTAssertEqual(retriedStop, .cleared(requestID: stopID))
    XCTAssertEqual(
      finalCommandOrder,
      ["apply-started", "apply-finished", "clear"]
    )
    XCTAssertNil(finalRecord)
  }

  func testPersistedDeviceMismatchNeverClearsOrReplacesTheWrongDevice() async throws {
    let originalLocation = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)
    let generationID = UUID()
    let originalRecord = SimulationLifecycleRecord(
      activeDeviceIdentifier: "Original Test Device",
      generationID: generationID,
      applyRequestID: UUID(),
      location: originalLocation,
      leaseExpiresAt: Date().addingTimeInterval(3_600),
      phase: .applied
    )
    let store = InMemorySimulationLifecycleStore(
      journal: SimulationLifecycleJournal(
        legacyCleanupCompleted: true,
        active: originalRecord
      )
    )
    let wrongDeviceBackend = LifecycleRecordingBackend()
    let wrongDeviceController = SimulationController(
      backend: wrongDeviceBackend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Different Test Device",
      sleep: { _ in throw CancellationError() }
    )

    _ = await wrongDeviceController.reconcileLifecycle()
    let replacementID = UUID()
    let replacementResult = await wrongDeviceController.apply(
      try SelectedLocation(latitude: 52.5200, longitude: 13.4050),
      requestID: replacementID,
      generationID: UUID()
    )
    let wrongDeviceClearCount = await wrongDeviceBackend.clearCount
    let wrongDeviceApplyCount = await wrongDeviceBackend.applyCount
    let retainedRecord = await store.load()?.active

    XCTAssertEqual(wrongDeviceClearCount, 0)
    XCTAssertEqual(wrongDeviceApplyCount, 0)
    XCTAssertEqual(
      replacementResult,
      .failed(requestID: replacementID, reason: .deviceMismatch)
    )
    XCTAssertEqual(retainedRecord, originalRecord)

    let originalDeviceBackend = LifecycleRecordingBackend()
    let originalDeviceController = SimulationController(
      backend: originalDeviceBackend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Original Test Device",
      sleep: { _ in throw CancellationError() }
    )
    _ = await originalDeviceController.reconcileLifecycle()
    let originalDeviceClearCount = await originalDeviceBackend.clearCount
    let remainingRecord = await store.load()?.active

    XCTAssertEqual(originalDeviceClearCount, 1)
    XCTAssertNil(remainingRecord)
  }

  func testLegacyCleanupCreatedWithoutADeviceBindsToTheFirstConfiguredDevice() async {
    let store = InMemorySimulationLifecycleStore()
    let unconfiguredController = SimulationController(
      backend: UnavailableInjectionBackend(reason: .noActiveDevice),
      lifecycleStore: store,
      activeDeviceIdentifier: "",
      sleep: { _ in throw CancellationError() },
      recoversLegacySimulation: true
    )
    _ = await unconfiguredController.reconcileLifecycle()
    let unboundObligation = await store.load()?.active
    XCTAssertEqual(unboundObligation?.activeDeviceIdentifier, "")
    XCTAssertNil(unboundObligation?.location)

    let backend = LifecycleRecordingBackend()
    let configuredController = SimulationController(
      backend: backend,
      lifecycleStore: store,
      activeDeviceIdentifier: "Active Test Device",
      sleep: { _ in throw CancellationError() },
      recoversLegacySimulation: true
    )
    _ = await configuredController.reconcileLifecycle()

    let clearCount = await backend.clearCount
    let remainingObligation = await store.load()?.active
    XCTAssertEqual(clearCount, 1)
    XCTAssertNil(remainingObligation)
  }

  func testOptInProductionHeartbeatSmokeAppliesAndExtendsPhysicalDevice() async throws {
    guard ProcessInfo.processInfo.environment["REMOTE_LOCATION_PHYSICAL_SMOKE"] == "1"
    else {
      throw XCTSkip("Explicit physical-device smoke opt-in is required.")
    }

    let heartbeatStore = FileSimulationServerHeartbeatStore(
      fileURL: FileSimulationServerHeartbeatStore.defaultFileURL()
    )
    let guardianHealthStore = FileSimulationCleanupGuardianHealthStore(
      fileURL: FileSimulationCleanupGuardianHealthStore.defaultFileURL()
    )
    let persistedHeartbeat = try await heartbeatStore.load()
    let persistedGuardianHealth = try await guardianHealthStore.load()
    let heartbeat = try XCTUnwrap(persistedHeartbeat)
    let guardianHealth = try XCTUnwrap(persistedGuardianHealth)
    let controller = ControllerCLIRuntime.makeController(
      device: guardianHealth.activeDeviceIdentifier,
      serverOwnerID: heartbeat.ownerID
    )
    let generationID = UUID()
    let location = try SelectedLocation(latitude: 31.2304, longitude: 121.4737)

    let applied = await controller.apply(
      location,
      requestID: UUID(),
      generationID: generationID,
      requestedLeaseDuration: SimulationLeaseDuration.fifteenMinutes.timeInterval
    )
    guard case .applied = applied else {
      return XCTFail("The production devicectl backend did not acknowledge Apply")
    }
    let appliedSnapshot = await controller.lifecycleSnapshot()
    guard case .applied(let appliedGenerationID, let originalExpiry) = appliedSnapshot.state
    else {
      return XCTFail("The production lifecycle did not retain the Applied Simulation")
    }
    XCTAssertEqual(appliedGenerationID, generationID)

    let extensionID = UUID()
    let extensionResult = await controller.extendLease(
      requestID: extensionID,
      generationID: generationID
    )
    XCTAssertEqual(
      extensionResult,
      .extended(
        requestID: extensionID,
        generationID: generationID,
        leaseExpiresAt: originalExpiry.addingTimeInterval(900)
      )
    )
  }
}

private enum RestartableControllerTransportError: Error {
  case unavailable
}

private actor RestartableControllerTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  private var session: ControllerServerSession?

  init(identity: ControllerIdentity, session: ControllerServerSession?) {
    self.identity = identity
    self.session = session
  }

  func setSession(_ session: ControllerServerSession?) {
    self.session = session
  }

  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) async throws -> ControllerTransportReply {
    guard expectedIdentity == identity, let session else {
      throw RestartableControllerTransportError.unavailable
    }
    return ControllerTransportReply(
      presentedIdentity: identity,
      response: await session.process(request)
    )
  }
}

private final class LifecycleTestClock: @unchecked Sendable {
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

private actor LifecycleSleepRecorder {
  private(set) var durations: [TimeInterval] = []

  func record(_ duration: TimeInterval) {
    durations.append(duration)
  }
}

private actor LifecycleRecordingBackend: InjectionBackend {
  private(set) var applyCount = 0
  private(set) var clearCount = 0
  private var clearFailures: [InjectionBackendFailure]

  init(clearFailures: [InjectionBackendFailure] = []) {
    self.clearFailures = clearFailures
  }

  func readiness() -> InjectionBackendReadiness {
    .ready
  }

  func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      applyCount += 1
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      clearCount += 1
      if !clearFailures.isEmpty {
        return .failed(requestID: requestID, reason: clearFailures.removeFirst())
      }
      return .cleared(requestID: requestID)
    }
  }
}

private actor SuspendedApplyLifecycleBackend: InjectionBackend {
  private(set) var commandOrder: [String] = []
  private var applyStarted = false
  private var startWaiters: [CheckedContinuation<Void, Never>] = []
  private var applyContinuation: CheckedContinuation<Void, Never>?

  func readiness() -> InjectionBackendReadiness {
    .ready
  }

  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult {
    switch command {
    case .apply(let requestID, let location):
      commandOrder.append("apply-started")
      applyStarted = true
      for waiter in startWaiters {
        waiter.resume()
      }
      startWaiters.removeAll()
      await withCheckedContinuation { continuation in
        applyContinuation = continuation
      }
      commandOrder.append("apply-finished")
      return .applied(requestID: requestID, location: location)
    case .clear(let requestID):
      commandOrder.append("clear")
      return .cleared(requestID: requestID)
    }
  }

  func waitUntilApplyStarted() async {
    guard !applyStarted else { return }
    await withCheckedContinuation { continuation in
      startWaiters.append(continuation)
    }
  }

  func finishApply() {
    applyContinuation?.resume()
    applyContinuation = nil
  }
}

private actor FailingSaveLifecycleStore: SimulationLifecycleStoring {
  private let backingStore: InMemorySimulationLifecycleStore
  private let failingSaveNumbers: Set<Int>
  private var saveCount = 0

  init(
    backingStore: InMemorySimulationLifecycleStore,
    failingSaveNumbers: Set<Int>
  ) {
    self.backingStore = backingStore
    self.failingSaveNumbers = failingSaveNumbers
  }

  func load() async throws -> SimulationLifecycleJournal? {
    await backingStore.load()
  }

  func save(_ journal: SimulationLifecycleJournal) async throws {
    saveCount += 1
    guard !failingSaveNumbers.contains(saveCount) else {
      throw CocoaError(.fileWriteUnknown)
    }
    await backingStore.save(journal)
  }
}

private final class LifecycleRecordingDevicectlExecutor:
  DevicectlCommandExecuting, @unchecked Sendable
{
  private let lock = NSLock()
  private var recordedInvocations: [DevicectlCommandInvocation] = []

  var clearCount: Int {
    lock.withLock {
      recordedInvocations.filter { invocation in
        invocation.arguments.prefix(5)
          == ["devicectl", "device", "simulate", "location", "clear"]
      }.count
    }
  }

  func execute(
    _ invocation: DevicectlCommandInvocation
  ) -> DevicectlCommandExecutionResult {
    lock.withLock {
      recordedInvocations.append(invocation)
    }
    return .exited(0)
  }
}
