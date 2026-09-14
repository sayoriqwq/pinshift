@testable import ControllerCLI
import ControllerLink
import Foundation
import Testing
import SimulationController

@Test func renewalReturnsImmediatelyDeduplicatesAndRetainsConfirmedExpiry() async throws {
  let gate = RenewalGate()
  let expiry = Date(timeIntervalSince1970: 4_100_000_000)
  let service = AppRenewalService { report in
    await gate.enter()
    await report(.signing, nil)
    await gate.wait()
    await report(.verifying, nil)
    await report(.installing, nil)
    await report(.installed, expiry)
  }
  let id = UUID()
  #expect(await service.start(requestID: id).phase == .checking)
  #expect(await service.start(requestID: UUID()).operationID == id)
  #expect(await service.snapshot().installedExpiresAt == nil)
  await gate.release()
  for _ in 0..<100 where await service.snapshot().phase != .installed {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await service.snapshot().phase == .installed)
  #expect(await service.snapshot().installedExpiresAt == expiry)
  #expect(await service.start(requestID: id).phase == .installed)
  #expect(await gate.count == 1)
}

@Test func processSuccessWithoutInstallationEvidenceFails() async throws {
  let service = AppRenewalService { report in
    await report(.verifying, nil)
  }
  _ = await service.start(requestID: UUID())
  for _ in 0..<100 where await service.snapshot().phase != .failed {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await service.snapshot().failure == .verificationFailed)
  #expect(await service.snapshot().installedExpiresAt == nil)
}

@Test func installationFailureIsDistinctAndNeverInventsExpiry() async throws {
  struct InstallError: Error {}
  let service = AppRenewalService { report in
    await report(.installing, nil)
    throw InstallError()
  }
  _ = await service.start(requestID: UUID())
  for _ in 0..<100 where await service.snapshot().phase != .failed {
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await service.snapshot().failure == .installationUnconfirmed)
  #expect(await service.snapshot().installedExpiresAt == nil)
}

private actor RenewalGate {
  var count = 0
  private var released = false
  private var continuation: CheckedContinuation<Void, Never>?
  func enter() { count += 1 }
  func wait() async {
    if released { return }
    await withCheckedContinuation { continuation = $0 }
  }
  func release() {
    released = true
    continuation?.resume()
    continuation = nil
  }
}

@Test func renewalDoesNotBlockStatusApplyOrDeadlineClear() async throws {
  let gate = RenewalGate()
  let service = AppRenewalService { report in
    await gate.wait()
    await report(.installed, Date().addingTimeInterval(86400))
  }
  let deadline = RenewalGate()
  let controller = SimulationController(backend: InMemoryInjectionBackend(),
    sleep: { _ in await deadline.wait() })
  let handler = SimulationControllerCommandHandler(controller: controller, renewal: service)
  let id = UUID()
  guard case .renewal = await handler.handle(.renewApp(requestID: id)) else {
    Issue.record("Renewal was not accepted")
    return
  }
  guard case .status(_, let status) = await handler.handle(.status(requestID: UUID())) else {
    Issue.record("Status blocked")
    return
  }
  #expect(status.renewal?.operationID == id)
  let applyID = UUID()
  guard case .applied = await handler.handle(.apply(requestID: applyID, latitude: 1, longitude: 2)) else {
    Issue.record("Apply blocked")
    return
  }
  await deadline.release()
  for _ in 0..<100 {
    if case .idle = await controller.snapshot().simulation { break }
    try await Task.sleep(for: .milliseconds(5))
  }
  #expect(await controller.snapshot().simulation == .idle)
  #expect(await service.snapshot().phase.isRunning)
  guard case .cleared = await handler.handle(.clear(requestID: UUID())) else {
    Issue.record("Clear blocked")
    return
  }
  await gate.release()
}

@Test func executorUsesOnlyFixedArgumentsAndConfiguredDeviceAndSanitizesFailures() async throws {
  let root = FileManager.default.temporaryDirectory.appending(path: "renewal-executor-\(UUID())")
  defer { try? FileManager.default.removeItem(at: root) }
  try FileManager.default.createDirectory(at: root.appending(path: "bin"), withIntermediateDirectories: true)
  let script = root.appending(path: "bin/pinshift-resign-app")
  try """
  #!/bin/sh
  test "$#" = 2 && test "$1" = --force && test "$2" = --no-launch || exit 2
  test "$PINSHIFT_DEVICE" = fixture-device || exit 3
  test "$PINSHIFT_DEVELOPER_DIR" = /fixture/developer || exit 4
  printf '%s' '{"phase":"installing","expiry":null}' > "$PINSHIFT_RENEWAL_PROGRESS"
  echo 'authorization = do-not-transmit'
  exit 1
  """.write(to: script, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
  let executor = AppRenewalExecutor(repository: root,
    configuration: ControllerRuntimeConfiguration(device: "fixture-device", developerDirectory: "/fixture/developer"),
    environment: ["PATH": "/usr/bin:/bin", "PINSHIFT_DEVICE": "wrong-device"])
  let service = AppRenewalService(execute: executor.execute)
  _ = await service.start(requestID: UUID())
  for _ in 0..<100 where await service.snapshot().phase != .failed {
    try await Task.sleep(for: .milliseconds(10))
  }
  let snapshot = await service.snapshot()
  #expect(snapshot.failure == .installationUnconfirmed)
  #expect(snapshot.detail?.contains("do-not-transmit") == false)
  #expect(snapshot.installedExpiresAt == nil)
}


@Test func normalShutdownClearsBeforeDrainingRenewalAndRejectsLateRequests() async throws {
  let work = RenewalGate()
  let drainStarted = RenewalGate()
  let returned = RenewalGate()
  let service = AppRenewalService { report in
    await work.wait()
    await report(.installed, Date().addingTimeInterval(86400))
  }
  let controller = SimulationController(backend: InMemoryInjectionBackend(),
    automaticallySchedulesMaintenance: false)
  let handler = SimulationControllerCommandHandler(controller: controller, renewal: service)
  _ = await handler.handle(.apply(requestID: UUID(), latitude: 1, longitude: 2))
  _ = await service.start(requestID: UUID())
  let shutdown = Task {
    try await ControllerCLIRuntime.runSession(controller: controller,
      stopAcceptingCommands: { await service.stopAcceptingRequests() },
      finishAcceptedWork: {
        await service.finishAcceptedWork(onWaiting: { await drainStarted.release() })
      },
      waitUntilStopped: {})
    await returned.enter()
  }
  await drainStarted.wait()
  #expect(await controller.snapshot().simulation == .idle)
  #expect(await returned.count == 0)
  #expect(await service.snapshot().phase.isRunning)
  #expect(await service.start(requestID: UUID()).phase == .failed)
  await work.release()
  try await shutdown.value
  #expect(await returned.count == 1)
  #expect(await service.snapshot().phase == .installed)
}
