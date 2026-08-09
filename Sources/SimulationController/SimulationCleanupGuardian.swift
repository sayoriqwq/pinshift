import Foundation
import SimulationDiagnostics

public actor SimulationCleanupGuardian {
  private let backend: any InjectionBackend
  private let diagnostics: SimulationDiagnosticRecorder?
  private let lifecycleStore: any SimulationLifecycleStoring
  private let activeDeviceIdentifier: String
  private let serverHeartbeatStore: any SimulationServerHeartbeatStoring
  private let serverHeartbeatLossGrace: TimeInterval
  private let healthStore: any SimulationCleanupGuardianHealthStoring
  private let guardianID: UUID
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let pollInterval: TimeInterval

  public init(
    backend: any InjectionBackend,
    diagnostics: SimulationDiagnosticRecorder? = nil,
    lifecycleStore: any SimulationLifecycleStoring,
    activeDeviceIdentifier: String,
    serverHeartbeatStore: any SimulationServerHeartbeatStoring =
      InMemorySimulationServerHeartbeatStore(),
    serverHeartbeatLossGrace: TimeInterval = 30,
    healthStore: any SimulationCleanupGuardianHealthStoring =
      InMemorySimulationCleanupGuardianHealthStore(),
    guardianID: UUID = UUID(),
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    pollInterval: TimeInterval = 1
  ) {
    self.backend = backend
    self.diagnostics = diagnostics
    self.lifecycleStore = lifecycleStore
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.serverHeartbeatStore = serverHeartbeatStore
    self.serverHeartbeatLossGrace = max(1, serverHeartbeatLossGrace)
    self.healthStore = healthStore
    self.guardianID = guardianID
    self.now = now
    self.sleep = sleep
    self.pollInterval = max(0.1, pollInterval)
  }

  @discardableResult
  public func reconcileNow() async -> SimulationControllerStatus {
    do {
      try await healthStore.save(
        SimulationCleanupGuardianHealth(
          guardianID: guardianID,
          activeDeviceIdentifier: activeDeviceIdentifier,
          recordedAt: now()
        )
      )
    } catch {
      await diagnostics?.record(
        kind: "controller.lifecycle.cleanup-guardian-health-write-failed",
        fields: ["error": .text(String(describing: error))]
      )
    }
    let controller = SimulationController(
      backend: backend,
      diagnostics: diagnostics,
      lifecycleStore: lifecycleStore,
      activeDeviceIdentifier: activeDeviceIdentifier,
      serverHeartbeatStore: serverHeartbeatStore,
      serverHeartbeatLossGrace: serverHeartbeatLossGrace,
      now: now,
      sleep: sleep,
      startupBehavior: .honorPersistedLease,
      automaticallySchedulesMaintenance: false
    )
    return await controller.reconcileLifecycle()
  }

  public func run() async throws {
    while !Task.isCancelled {
      _ = await reconcileNow()
      try await sleep(pollInterval)
    }
  }
}
