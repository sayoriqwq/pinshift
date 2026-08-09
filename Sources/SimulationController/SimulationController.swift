import Foundation
import LocationDomain
import SimulationDiagnostics

public enum InjectionBackendFailure: String, Codable, Error, Equatable, Sendable {
  case noActiveDevice
  case sessionNotReady
  case backendUnavailable
  case timedOut
  case authenticationFailed
  case clearFailed
  case deviceMismatch
  case generationMismatch
  case invalidLeaseDuration
  case cleanupGuardianUnavailable
}

public enum SimulationLeasePolicy {
  public static let defaultDuration: TimeInterval = 900
  public static let extensionDuration: TimeInterval = 900
  public static let supportedDurations: Set<TimeInterval> = [900, 1_800, 3_600]
  public static let maximumDuration: TimeInterval = 3_600

  public static func accepts(_ duration: TimeInterval) -> Bool {
    duration.isFinite && supportedDurations.contains(duration)
  }
}

public enum SimulationLeaseExtensionResult: Equatable, Sendable {
  case extended(requestID: UUID, generationID: UUID, leaseExpiresAt: Date)
  case failed(requestID: UUID, reason: InjectionBackendFailure)
}

public enum InjectionBackendReadiness: Equatable, Sendable {
  case ready
  case unavailable(InjectionBackendFailure)
}

public enum InjectionBackendCommand: Equatable, Sendable {
  case apply(requestID: UUID, location: SelectedLocation)
  case clear(requestID: UUID)
}

public enum InjectionBackendResult: Equatable, Sendable {
  case applied(requestID: UUID, location: SelectedLocation)
  case cleared(requestID: UUID)
  case failed(requestID: UUID, reason: InjectionBackendFailure)
}

public protocol InjectionBackend: Sendable {
  func readiness() async -> InjectionBackendReadiness
  func execute(_ command: InjectionBackendCommand) async -> InjectionBackendResult
}

public enum SimulationControllerStatus: Equatable, Sendable {
  case unavailable(InjectionBackendFailure)
  case ready
  case applied(requestID: UUID, location: SelectedLocation)
  case stopped
  case failed(requestID: UUID, reason: InjectionBackendFailure)
}

public enum SimulationLifecycleState: Equatable, Sendable {
  case noActive
  case applyUncertain(generationID: UUID)
  case applied(generationID: UUID, leaseExpiresAt: Date)
  case cleanupPending(
    generationID: UUID,
    requestID: UUID,
    reason: InjectionBackendFailure?
  )
  case stopped(generationID: UUID?)
  case deviceMismatch(generationID: UUID)
}

public enum SimulationCleanupReadiness: Equatable, Sendable {
  case ready
  case unavailable(InjectionBackendFailure)
}

public struct SimulationLifecycleSnapshot: Equatable, Sendable {
  public let readiness: InjectionBackendReadiness
  public let cleanupReadiness: SimulationCleanupReadiness
  public let state: SimulationLifecycleState

  public init(
    readiness: InjectionBackendReadiness,
    cleanupReadiness: SimulationCleanupReadiness = .ready,
    state: SimulationLifecycleState
  ) {
    self.readiness = readiness
    self.cleanupReadiness = cleanupReadiness
    self.state = state
  }
}

public enum SimulationControllerStartupBehavior: Equatable, Sendable {
  case recoverPersistedObligationImmediately
  case honorPersistedLease
}

public actor SimulationController {
  private let backend: any InjectionBackend
  private let diagnostics: SimulationDiagnosticRecorder?
  private let lifecycleStore: any SimulationLifecycleStoring
  private let activeDeviceIdentifier: String
  private let leaseDuration: TimeInterval
  private let serverOwnerID: UUID?
  private let serverHeartbeatStore: any SimulationServerHeartbeatStoring
  private let serverHeartbeatLossGrace: TimeInterval
  private let cleanupGuardianHealthStore: any SimulationCleanupGuardianHealthStoring
  private let requiresHealthyCleanupGuardian: Bool
  private let cleanupGuardianMaximumAge: TimeInterval
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let recoversLegacySimulation: Bool
  private let startupBehavior: SimulationControllerStartupBehavior
  private let automaticallySchedulesMaintenance: Bool
  private var currentStatus: SimulationControllerStatus = .unavailable(.sessionNotReady)
  private var lifecycleJournal: SimulationLifecycleJournal?
  private var didStart = false
  private var maintenanceTask: Task<Void, Never>?
  private var backendOperationInFlight = false
  private var backendOperationGenerationID: UUID?
  private var deferredCleanupRequest: (requestID: UUID, generationID: UUID)?

  public init(
    backend: any InjectionBackend,
    diagnostics: SimulationDiagnosticRecorder? = nil,
    lifecycleStore: any SimulationLifecycleStoring = InMemorySimulationLifecycleStore(),
    activeDeviceIdentifier: String = "in-memory-active-device",
    leaseDuration: TimeInterval = SimulationLeasePolicy.defaultDuration,
    serverOwnerID: UUID? = nil,
    serverHeartbeatStore: any SimulationServerHeartbeatStoring =
      InMemorySimulationServerHeartbeatStore(),
    serverHeartbeatLossGrace: TimeInterval = 30,
    cleanupGuardianHealthStore: any SimulationCleanupGuardianHealthStoring =
      InMemorySimulationCleanupGuardianHealthStore(),
    requiresHealthyCleanupGuardian: Bool = false,
    cleanupGuardianMaximumAge: TimeInterval = 10,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    recoversLegacySimulation: Bool = false,
    startupBehavior: SimulationControllerStartupBehavior =
      .recoverPersistedObligationImmediately,
    automaticallySchedulesMaintenance: Bool = true
  ) {
    self.backend = backend
    self.diagnostics = diagnostics
    self.lifecycleStore = lifecycleStore
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.leaseDuration = min(max(1, leaseDuration), SimulationLeasePolicy.maximumDuration)
    self.serverOwnerID = serverOwnerID
    self.serverHeartbeatStore = serverHeartbeatStore
    self.serverHeartbeatLossGrace = max(1, serverHeartbeatLossGrace)
    self.cleanupGuardianHealthStore = cleanupGuardianHealthStore
    self.requiresHealthyCleanupGuardian = requiresHealthyCleanupGuardian
    self.cleanupGuardianMaximumAge = max(1, cleanupGuardianMaximumAge)
    self.now = now
    self.sleep = sleep
    self.recoversLegacySimulation = recoversLegacySimulation
    self.startupBehavior = startupBehavior
    self.automaticallySchedulesMaintenance = automaticallySchedulesMaintenance
  }

  public func status() async -> SimulationControllerStatus {
    await record(kind: "controller.status.requested")
    guard await startIfNeeded(recoverLegacySimulation: true) else {
      await record(
        kind: "controller.status.result",
        fields: statusFields(currentStatus)
      )
      return currentStatus
    }
    if case .unavailable(.sessionNotReady) = currentStatus {
      switch await backend.readiness() {
      case .ready:
        currentStatus = .ready
      case .unavailable(let reason):
        currentStatus = .unavailable(reason)
      }
    }
    await record(
      kind: "controller.status.result",
      fields: statusFields(currentStatus)
    )
    return currentStatus
  }

  public func apply(
    _ location: SelectedLocation,
    requestID: UUID = UUID(),
    generationID: UUID? = nil,
    requestedLeaseDuration: TimeInterval? = nil
  ) async -> InjectionBackendResult {
    await record(
      kind: "controller.apply.started",
      requestID: requestID,
      fields: coordinateFields(location)
    )
    guard await startIfNeeded(recoverLegacySimulation: true) else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }
    let resolvedLeaseDuration: TimeInterval
    if let requestedLeaseDuration {
      guard SimulationLeasePolicy.accepts(requestedLeaseDuration) else {
        return .failed(requestID: requestID, reason: .invalidLeaseDuration)
      }
      resolvedLeaseDuration = requestedLeaseDuration
    } else {
      resolvedLeaseDuration = leaseDuration
    }
    if let completion = lifecycleJournal?.completions.last(where: {
      $0.requestID == requestID
    }) {
      guard completion.outcome == .applied,
        generationID == nil || completion.generationID == generationID,
        let appliedLocation = completion.location
      else {
        return .failed(requestID: requestID, reason: .generationMismatch)
      }
      return .applied(requestID: requestID, location: appliedLocation)
    }
    guard case .ready = await currentCleanupReadiness() else {
      let result = InjectionBackendResult.failed(
        requestID: requestID,
        reason: .cleanupGuardianUnavailable
      )
      await record(
        kind: "controller.lifecycle.cleanup-protection-unavailable",
        requestID: requestID
      )
      return result
    }
    if let active = lifecycleJournal?.active {
      guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
        return .failed(requestID: requestID, reason: .deviceMismatch)
      }
      guard active.phase == .applied else {
        return .failed(requestID: requestID, reason: .clearFailed)
      }
    }
    guard !backendOperationInFlight else {
      return .failed(requestID: requestID, reason: .clearFailed)
    }

    let resolvedGenerationID = generationID ?? requestID
    backendOperationInFlight = true
    backendOperationGenerationID = resolvedGenerationID
    switch await backend.readiness() {
    case .unavailable(let reason):
      deferredCleanupRequest = nil
      releaseBackendOperation()
      currentStatus = .failed(requestID: requestID, reason: reason)
      let result = InjectionBackendResult.failed(requestID: requestID, reason: reason)
      await recordResult(result, kind: "controller.apply.backend-response")
      return result
    case .ready:
      break
    }

    let obligationCreatedAt = now()
    var journal = lifecycleJournal ?? SimulationLifecycleJournal()
    journal.active = SimulationLifecycleRecord(
      activeDeviceIdentifier: activeDeviceIdentifier,
      generationID: resolvedGenerationID,
      applyRequestID: requestID,
      location: location,
      leaseExpiresAt: obligationCreatedAt.addingTimeInterval(resolvedLeaseDuration),
      serverOwnerID: serverOwnerID,
      serverOwnerHeartbeatRequiredSince: serverOwnerID == nil ? nil : obligationCreatedAt,
      phase: .applyUncertain
    )
    guard await persist(journal) else {
      deferredCleanupRequest = nil
      releaseBackendOperation()
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }
    await record(
      kind: "controller.lifecycle.apply-obligation-persisted",
      requestID: requestID,
      fields: [
        "generationID": .text(resolvedGenerationID.uuidString),
        "leaseExpiresAt": .date(journal.active?.leaseExpiresAt ?? now()),
      ]
    )

    if let deferredCleanupRequest,
      deferredCleanupRequest.generationID == resolvedGenerationID,
      var active = lifecycleJournal?.active
    {
      active.phase = .cleanupPending
      active.cleanupRequestID = deferredCleanupRequest.requestID
      journal = lifecycleJournal ?? journal
      journal.active = active
      guard await persist(journal) else {
        self.deferredCleanupRequest = nil
        releaseBackendOperation()
        scheduleMaintenance()
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
    }

    let result = await backend.execute(.apply(requestID: requestID, location: location))
    var shouldReconcile = false
    switch result {
    case .applied(let responseID, let appliedLocation):
      guard var journal = lifecycleJournal,
        var active = journal.active,
        active.generationID == resolvedGenerationID
      else {
        deferredCleanupRequest = nil
        releaseBackendOperation()
        currentStatus = .failed(requestID: responseID, reason: .backendUnavailable)
        return .failed(requestID: responseID, reason: .backendUnavailable)
      }
      if active.phase == .cleanupPending
        || deferredCleanupRequest?.generationID == resolvedGenerationID
      {
        active.phase = .cleanupPending
        active.cleanupRequestID =
          active.cleanupRequestID ?? deferredCleanupRequest?.requestID ?? UUID()
        shouldReconcile = true
      } else {
        active.phase = .applied
      }
      journal.active = active
      appendCompletion(
        to: &journal,
        completion:
          SimulationLifecycleCompletion(
            requestID: responseID,
            outcome: .applied,
            generationID: active.generationID,
            location: appliedLocation,
            leaseExpiresAt: active.leaseExpiresAt
          )
      )
      guard await persist(journal) else {
        deferredCleanupRequest = nil
        releaseBackendOperation()
        currentStatus = .failed(requestID: responseID, reason: .backendUnavailable)
        scheduleMaintenance()
        return .failed(requestID: responseID, reason: .backendUnavailable)
      }
      currentStatus = .applied(requestID: responseID, location: appliedLocation)
      await record(
        kind: "controller.lifecycle.lease-started",
        requestID: responseID,
        fields: [
          "generationID": .text(active.generationID.uuidString),
          "leaseExpiresAt": .date(active.leaseExpiresAt),
        ]
      )
    case .cleared(let responseID):
      shouldReconcile = await markApplyUncertainForCleanup(
        generationID: resolvedGenerationID,
        preferredRequestID: deferredCleanupRequest?.requestID
      )
      currentStatus = .failed(requestID: responseID, reason: .backendUnavailable)
    case .failed(let responseID, let reason):
      shouldReconcile = await markApplyUncertainForCleanup(
        generationID: resolvedGenerationID,
        preferredRequestID: deferredCleanupRequest?.requestID
      )
      currentStatus = .failed(requestID: responseID, reason: reason)
    }
    deferredCleanupRequest = nil
    releaseBackendOperation()
    if shouldReconcile {
      _ = await reconcileLifecycle()
    } else {
      scheduleMaintenance()
    }
    await recordResult(result, kind: "controller.apply.backend-response")
    return result
  }

  public func extendLease(
    requestID: UUID,
    generationID: UUID,
    extensionDuration: TimeInterval = SimulationLeasePolicy.extensionDuration
  ) async -> SimulationLeaseExtensionResult {
    await record(
      kind: "controller.lifecycle.lease-extension-started",
      requestID: requestID,
      fields: [
        "generationID": .text(generationID.uuidString),
        "extensionDuration": .number(extensionDuration),
      ]
    )
    guard await startIfNeeded(recoverLegacySimulation: false) else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }
    guard extensionDuration == SimulationLeasePolicy.extensionDuration else {
      return .failed(requestID: requestID, reason: .invalidLeaseDuration)
    }
    if let completion = lifecycleJournal?.completions.last(where: {
      $0.requestID == requestID
    }) {
      guard completion.outcome == .leaseExtended,
        completion.generationID == generationID,
        let leaseExpiresAt = completion.leaseExpiresAt
      else {
        return .failed(requestID: requestID, reason: .generationMismatch)
      }
      return .extended(
        requestID: requestID,
        generationID: generationID,
        leaseExpiresAt: leaseExpiresAt
      )
    }
    guard !backendOperationInFlight,
      var journal = lifecycleJournal,
      var active = journal.active
    else {
      return .failed(requestID: requestID, reason: .clearFailed)
    }
    guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
      return .failed(requestID: requestID, reason: .deviceMismatch)
    }
    guard active.generationID == generationID else {
      return .failed(requestID: requestID, reason: .generationMismatch)
    }
    guard active.phase == .applied, now() < active.leaseExpiresAt else {
      _ = await reconcileLifecycle()
      return .failed(requestID: requestID, reason: .clearFailed)
    }

    let acknowledgedAt = now()
    active.leaseExpiresAt = min(
      active.leaseExpiresAt.addingTimeInterval(extensionDuration),
      acknowledgedAt.addingTimeInterval(SimulationLeasePolicy.maximumDuration)
    )
    journal.active = active
    appendCompletion(
      to: &journal,
      completion: SimulationLifecycleCompletion(
        requestID: requestID,
        outcome: .leaseExtended,
        generationID: generationID,
        leaseExpiresAt: active.leaseExpiresAt
      )
    )
    guard await persist(journal) else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }
    scheduleMaintenance()
    await record(
      kind: "controller.lifecycle.lease-extension-acknowledged",
      requestID: requestID,
      fields: [
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(active.leaseExpiresAt),
      ]
    )
    return .extended(
      requestID: requestID,
      generationID: generationID,
      leaseExpiresAt: active.leaseExpiresAt
    )
  }

  @discardableResult
  public func reconcileLifecycle() async -> SimulationControllerStatus {
    guard await startIfNeeded(recoverLegacySimulation: true) else {
      return currentStatus
    }
    guard var active = lifecycleJournal?.active else {
      maintenanceTask?.cancel()
      maintenanceTask = nil
      return currentStatus
    }
    await record(
      kind: "controller.lifecycle.reconciliation-started",
      requestID: active.cleanupRequestID ?? active.applyRequestID,
      fields: [
        "generationID": .text(active.generationID.uuidString),
        "phase": .text(active.phase.rawValue),
      ]
    )
    guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
      currentStatus = .failed(
        requestID: active.cleanupRequestID ?? active.applyRequestID,
        reason: .deviceMismatch
      )
      return currentStatus
    }
    guard !backendOperationInFlight else {
      return currentStatus
    }

    switch active.phase {
    case .applied:
      let leaseExpired = now() >= active.leaseExpiresAt
      let serverHeartbeatExpired = await isServerHeartbeatExpired(for: active)
      guard leaseExpired || serverHeartbeatExpired else {
        scheduleMaintenance()
        return currentStatus
      }
      active.phase = .cleanupPending
      active.cleanupRequestID = active.cleanupRequestID ?? UUID()
      active.retryAttempt = 0
      active.nextRetryAt = nil
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = active
      guard await persist(journal) else {
        return currentStatus
      }
      await record(
        kind: serverHeartbeatExpired
          ? "controller.lifecycle.server-heartbeat-lost"
          : "controller.lifecycle.lease-expired",
        requestID: active.cleanupRequestID,
        fields: [
          "generationID": .text(active.generationID.uuidString),
          "leaseExpiresAt": .date(active.leaseExpiresAt),
        ]
      )
    case .applyUncertain:
      if startupBehavior == .honorPersistedLease,
        now() < active.leaseExpiresAt
      {
        scheduleMaintenance()
        return currentStatus
      }
      active.phase = .cleanupPending
      active.cleanupRequestID = active.cleanupRequestID ?? UUID()
      active.nextRetryAt = nil
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = active
      guard await persist(journal) else {
        return currentStatus
      }
    case .cleanupPending:
      if let nextRetryAt = active.nextRetryAt, now() < nextRetryAt {
        scheduleMaintenance()
        return currentStatus
      }
    }

    let cleanupID = lifecycleJournal?.active?.cleanupRequestID ?? UUID()
    return await performPendingCleanup(requestID: cleanupID)
  }

  public func stop(
    requestID: UUID = UUID(),
    generationID: UUID? = nil
  ) async -> InjectionBackendResult {
    await record(kind: "controller.stop.started", requestID: requestID)
    guard await startIfNeeded(recoverLegacySimulation: false) else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }
    if let completion = lifecycleJournal?.completions.last(where: {
      $0.requestID == requestID
    }) {
      guard completion.outcome == .stopped,
        generationID == nil || completion.generationID == generationID
      else {
        return .failed(requestID: requestID, reason: .generationMismatch)
      }
      return .cleared(requestID: requestID)
    }

    if backendOperationInFlight {
      guard let operationGenerationID = backendOperationGenerationID else {
        return .failed(requestID: requestID, reason: .clearFailed)
      }
      if let generationID, generationID != operationGenerationID {
        return .failed(requestID: requestID, reason: .generationMismatch)
      }
      if let active = lifecycleJournal?.active,
        active.generationID == operationGenerationID
      {
        guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
          return .failed(requestID: requestID, reason: .deviceMismatch)
        }
        var pending = active
        pending.phase = .cleanupPending
        pending.cleanupRequestID = pending.cleanupRequestID ?? requestID
        pending.nextRetryAt = nil
        var journal = lifecycleJournal ?? SimulationLifecycleJournal()
        journal.active = pending
        guard await persist(journal) else {
          return .failed(requestID: requestID, reason: .backendUnavailable)
        }
        await recordCleanupIntent(pending, requestID: requestID)
      }
      deferredCleanupRequest = (
        requestID: requestID,
        generationID: operationGenerationID
      )
      return .failed(requestID: requestID, reason: .clearFailed)
    }

    var targetGenerationID: UUID?
    if var active = lifecycleJournal?.active {
      if let generationID, generationID != active.generationID {
        currentStatus = .failed(requestID: requestID, reason: .generationMismatch)
        return .failed(requestID: requestID, reason: .generationMismatch)
      }
      guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
        currentStatus = .failed(requestID: requestID, reason: .deviceMismatch)
        return .failed(requestID: requestID, reason: .deviceMismatch)
      }
      targetGenerationID = active.generationID
      active.phase = .cleanupPending
      active.cleanupRequestID = requestID
      active.nextRetryAt = nil
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = active
      guard await persist(journal) else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      await recordCleanupIntent(active, requestID: requestID)
    } else {
      let obligationGenerationID = generationID ?? requestID
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = SimulationLifecycleRecord(
        activeDeviceIdentifier: activeDeviceIdentifier,
        generationID: obligationGenerationID,
        applyRequestID: generationID == nil ? obligationGenerationID : requestID,
        location: nil,
        leaseExpiresAt: now(),
        phase: .cleanupPending,
        cleanupRequestID: requestID
      )
      guard await persist(journal) else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      if let active = journal.active {
        await recordCleanupIntent(active, requestID: requestID)
      }
      targetGenerationID = generationID
    }

    backendOperationInFlight = true
    backendOperationGenerationID = targetGenerationID
    let result = await backend.execute(.clear(requestID: requestID))
    releaseBackendOperation()
    let returnedResult = await finishCleanup(
      result,
      requestID: requestID,
      generationID: targetGenerationID
    )
    await recordResult(result, kind: "controller.stop.backend-response")
    return returnedResult
  }

  public func lifecycleSnapshot() async -> SimulationLifecycleSnapshot {
    let status = await status()
    let cleanupReadiness = await currentCleanupReadiness()
    if let active = lifecycleJournal?.active {
      if active.activeDeviceIdentifier != activeDeviceIdentifier {
        return SimulationLifecycleSnapshot(
          readiness: .unavailable(.deviceMismatch),
          cleanupReadiness: cleanupReadiness,
          state: .deviceMismatch(generationID: active.generationID)
        )
      }
      switch active.phase {
      case .applyUncertain:
        return SimulationLifecycleSnapshot(
          readiness: .unavailable(.clearFailed),
          cleanupReadiness: cleanupReadiness,
          state: .applyUncertain(generationID: active.generationID)
        )
      case .applied:
        return SimulationLifecycleSnapshot(
          readiness: .ready,
          cleanupReadiness: cleanupReadiness,
          state: .applied(
            generationID: active.generationID,
            leaseExpiresAt: active.leaseExpiresAt
          )
        )
      case .cleanupPending:
        return SimulationLifecycleSnapshot(
          readiness: .unavailable(active.lastFailure ?? .clearFailed),
          cleanupReadiness: cleanupReadiness,
          state: .cleanupPending(
            generationID: active.generationID,
            requestID: active.cleanupRequestID ?? active.applyRequestID,
            reason: active.lastFailure
          )
        )
      }
    }

    let readiness = await backend.readiness()
    let state: SimulationLifecycleState
    if case .stopped = status {
      state = .stopped(generationID: lifecycleJournal?.lastStoppedGenerationID)
    } else {
      state = .noActive
    }
    return SimulationLifecycleSnapshot(
      readiness: readiness,
      cleanupReadiness: cleanupReadiness,
      state: state
    )
  }

  private func startIfNeeded(recoverLegacySimulation: Bool) async -> Bool {
    if didStart { return true }

    do {
      lifecycleJournal = try await lifecycleStore.load() ?? SimulationLifecycleJournal()
    } catch {
      currentStatus = .unavailable(.backendUnavailable)
      await record(
        kind: "controller.lifecycle.journal-load-failed",
        fields: ["error": .text(String(describing: error))]
      )
      return false
    }
    didStart = true

    if var active = lifecycleJournal?.active {
      if active.activeDeviceIdentifier.isEmpty,
        active.location == nil,
        !activeDeviceIdentifier.isEmpty
      {
        active.activeDeviceIdentifier = activeDeviceIdentifier
        var journal = lifecycleJournal ?? SimulationLifecycleJournal()
        journal.active = active
        guard await persist(journal) else {
          didStart = false
          return false
        }
      }
      guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
        currentStatus = .failed(
          requestID: active.cleanupRequestID ?? active.applyRequestID,
          reason: .deviceMismatch
        )
        await record(
          kind: "controller.lifecycle.device-mismatch",
          requestID: active.cleanupRequestID ?? active.applyRequestID
        )
        return true
      }
      if startupBehavior == .honorPersistedLease {
        switch active.phase {
        case .applied:
          if let location = active.location {
            currentStatus = .applied(
              requestID: active.applyRequestID,
              location: location
            )
          }
        case .applyUncertain, .cleanupPending:
          currentStatus = .failed(
            requestID: active.cleanupRequestID ?? active.applyRequestID,
            reason: active.lastFailure ?? .clearFailed
          )
        }
        scheduleMaintenance()
        return true
      }
      let cleanupID = active.cleanupRequestID ?? UUID()
      active.phase = .cleanupPending
      active.cleanupRequestID = cleanupID
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = active
      guard await persist(journal) else {
        didStart = false
        return false
      }
      _ = await performPendingCleanup(requestID: cleanupID)
    } else if recoverLegacySimulation && recoversLegacySimulation
      && lifecycleJournal?.legacyCleanupCompleted == false
    {
      let cleanupID = UUID()
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      journal.active = SimulationLifecycleRecord(
        activeDeviceIdentifier: activeDeviceIdentifier,
        generationID: cleanupID,
        applyRequestID: cleanupID,
        location: nil,
        leaseExpiresAt: now(),
        phase: .cleanupPending,
        cleanupRequestID: cleanupID
      )
      guard await persist(journal) else {
        didStart = false
        return false
      }
      _ = await performPendingCleanup(requestID: cleanupID)
    }

    return true
  }

  private func persist(_ journal: SimulationLifecycleJournal) async -> Bool {
    do {
      try await lifecycleStore.save(journal)
      lifecycleJournal = journal
      return true
    } catch {
      currentStatus = .unavailable(.backendUnavailable)
      await record(
        kind: "controller.lifecycle.journal-save-failed",
        fields: ["error": .text(String(describing: error))]
      )
      return false
    }
  }

  private func performPendingCleanup(requestID: UUID) async -> SimulationControllerStatus {
    guard let active = lifecycleJournal?.active else { return currentStatus }
    guard active.activeDeviceIdentifier == activeDeviceIdentifier else {
      currentStatus = .failed(requestID: requestID, reason: .deviceMismatch)
      return currentStatus
    }
    guard !backendOperationInFlight else { return currentStatus }

    backendOperationInFlight = true
    backendOperationGenerationID = active.generationID
    if active.retryAttempt > 0 {
      await record(
        kind: "controller.lifecycle.cleanup-retry-started",
        requestID: requestID,
        fields: [
          "generationID": .text(active.generationID.uuidString),
          "retryAttempt": .integer(Int64(active.retryAttempt)),
        ]
      )
    }
    let result = await backend.execute(.clear(requestID: requestID))
    releaseBackendOperation()
    _ = await finishCleanup(
      result,
      requestID: requestID,
      generationID: active.location == nil && active.applyRequestID == active.generationID
        ? nil : active.generationID
    )
    return currentStatus
  }

  private func finishCleanup(
    _ result: InjectionBackendResult,
    requestID: UUID,
    generationID: UUID?
  ) async -> InjectionBackendResult {
    switch result {
    case .cleared:
      var journal = lifecycleJournal ?? SimulationLifecycleJournal()
      appendCompletion(
        to: &journal,
        completion: SimulationLifecycleCompletion(
          requestID: requestID,
          outcome: .stopped,
          generationID: generationID
        )
      )
      journal.lastStoppedGenerationID = generationID
      journal.active = nil
      journal.legacyCleanupCompleted = true
      guard await persist(journal) else {
        if var retained = lifecycleJournal?.active {
          retained.phase = .cleanupPending
          retained.retryAttempt += 1
          retained.nextRetryAt = now().addingTimeInterval(
            min(pow(2, Double(retained.retryAttempt)), 60)
          )
          retained.lastFailure = .backendUnavailable
          lifecycleJournal?.active = retained
        }
        currentStatus = .failed(requestID: requestID, reason: .backendUnavailable)
        scheduleMaintenance()
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      maintenanceTask?.cancel()
      maintenanceTask = nil
      currentStatus = .stopped
      var fields: SimulationDiagnosticFields = [:]
      if let generationID {
        fields["generationID"] = .text(generationID.uuidString)
      }
      await record(
        kind: "controller.lifecycle.clear-acknowledged",
        requestID: requestID,
        fields: fields
      )
      return .cleared(requestID: requestID)
    case .applied:
      return await retainCleanupFailure(
        requestID: requestID,
        reason: .clearFailed
      )
    case .failed(_, let reason):
      return await retainCleanupFailure(
        requestID: requestID,
        reason: reason
      )
    }
  }

  private func retainCleanupFailure(
    requestID: UUID,
    reason: InjectionBackendFailure
  ) async -> InjectionBackendResult {
    guard var active = lifecycleJournal?.active else {
      currentStatus = .failed(requestID: requestID, reason: reason)
      return .failed(requestID: requestID, reason: reason)
    }
    active.phase = .cleanupPending
    active.cleanupRequestID = requestID
    active.retryAttempt += 1
    active.nextRetryAt = now().addingTimeInterval(
      min(pow(2, Double(active.retryAttempt)), 60)
    )
    active.lastFailure = reason
    var journal = lifecycleJournal ?? SimulationLifecycleJournal()
    journal.active = active
    let persisted = await persist(journal)
    if !persisted {
      lifecycleJournal = journal
    }
    let reportedReason: InjectionBackendFailure = persisted ? reason : .backendUnavailable
    currentStatus = .failed(requestID: requestID, reason: reportedReason)
    await record(
      kind: "controller.lifecycle.cleanup-retry-scheduled",
      requestID: requestID,
      fields: [
        "generationID": .text(active.generationID.uuidString),
        "retryAttempt": .integer(Int64(active.retryAttempt)),
        "nextRetryAt": .date(active.nextRetryAt ?? now()),
        "reason": .text(reportedReason.rawValue),
      ]
    )
    scheduleMaintenance()
    return .failed(requestID: requestID, reason: reportedReason)
  }

  private func markApplyUncertainForCleanup(
    generationID: UUID,
    preferredRequestID: UUID?
  ) async -> Bool {
    guard var active = lifecycleJournal?.active,
      active.generationID == generationID
    else { return false }
    active.phase = .cleanupPending
    active.cleanupRequestID = active.cleanupRequestID ?? preferredRequestID ?? UUID()
    active.nextRetryAt = nil
    var journal = lifecycleJournal ?? SimulationLifecycleJournal()
    journal.active = active
    return await persist(journal)
  }

  private func releaseBackendOperation() {
    backendOperationInFlight = false
    backendOperationGenerationID = nil
  }

  private func recordCleanupIntent(
    _ active: SimulationLifecycleRecord,
    requestID: UUID
  ) async {
    await record(
      kind: "controller.lifecycle.cleanup-intent-persisted",
      requestID: requestID,
      fields: ["generationID": .text(active.generationID.uuidString)]
    )
  }

  private func isServerHeartbeatExpired(
    for active: SimulationLifecycleRecord
  ) async -> Bool {
    guard let ownerID = active.serverOwnerID,
      let requiredSince = active.serverOwnerHeartbeatRequiredSince
    else { return false }

    let lastMatchingHeartbeat: Date?
    do {
      let heartbeat = try await serverHeartbeatStore.load()
      lastMatchingHeartbeat = heartbeat?.ownerID == ownerID ? heartbeat?.recordedAt : nil
    } catch {
      lastMatchingHeartbeat = nil
    }
    let lastSeenAt = max(requiredSince, lastMatchingHeartbeat ?? requiredSince)
    return now().timeIntervalSince(lastSeenAt) >= serverHeartbeatLossGrace
  }

  private func currentCleanupReadiness() async -> SimulationCleanupReadiness {
    guard requiresHealthyCleanupGuardian else { return .ready }
    do {
      guard let health = try await cleanupGuardianHealthStore.load(),
        health.activeDeviceIdentifier == activeDeviceIdentifier
      else {
        return .unavailable(.cleanupGuardianUnavailable)
      }
      let age = now().timeIntervalSince(health.recordedAt)
      guard age >= -cleanupGuardianMaximumAge, age <= cleanupGuardianMaximumAge else {
        return .unavailable(.cleanupGuardianUnavailable)
      }
      return .ready
    } catch {
      return .unavailable(.cleanupGuardianUnavailable)
    }
  }

  private func scheduleMaintenance() {
    maintenanceTask?.cancel()
    guard automaticallySchedulesMaintenance,
      didStart,
      let active = lifecycleJournal?.active
    else {
      maintenanceTask = nil
      return
    }
    let wakeAt: Date
    switch active.phase {
    case .applied:
      if active.serverOwnerID == nil {
        wakeAt = active.leaseExpiresAt
      } else {
        wakeAt = min(active.leaseExpiresAt, now().addingTimeInterval(1))
      }
    case .applyUncertain:
      wakeAt = now()
    case .cleanupPending:
      wakeAt = active.nextRetryAt ?? now()
    }
    let delay = max(0, wakeAt.timeIntervalSince(now()))
    let sleep = self.sleep
    maintenanceTask = Task { [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.reconcileLifecycle()
    }
  }

  private func appendCompletion(
    to journal: inout SimulationLifecycleJournal,
    completion: SimulationLifecycleCompletion
  ) {
    journal.completions.removeAll { $0.requestID == completion.requestID }
    journal.completions.append(completion)
    if journal.completions.count > 64 {
      journal.completions.removeFirst(journal.completions.count - 64)
    }
  }

  private func record(
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) async {
    guard let diagnostics else { return }
    await diagnostics.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func recordResult(
    _ result: InjectionBackendResult,
    kind: String
  ) async {
    var fields: SimulationDiagnosticFields = [:]
    switch result {
    case .applied(_, let location):
      fields["outcome"] = .text("applied")
      fields.merge(coordinateFields(location)) { _, new in new }
    case .cleared:
      fields["outcome"] = .text("cleared")
    case .failed(_, let reason):
      fields["outcome"] = .text("failed")
      fields["reason"] = .text(String(describing: reason))
    }
    await record(kind: kind, requestID: result.requestID, fields: fields)
  }

  private func coordinateFields(_ location: SelectedLocation) -> SimulationDiagnosticFields {
    [
      "latitude": .number(location.latitude),
      "longitude": .number(location.longitude),
    ]
  }

  private func statusFields(_ status: SimulationControllerStatus) -> SimulationDiagnosticFields {
    switch status {
    case .unavailable(let reason):
      return [
        "state": .text("unavailable"),
        "reason": .text(String(describing: reason)),
      ]
    case .ready:
      return ["state": .text("ready")]
    case .applied(_, let location):
      var fields = ["state": SimulationDiagnosticValue.text("applied")]
      fields.merge(coordinateFields(location)) { _, new in new }
      return fields
    case .stopped:
      return ["state": .text("stopped")]
    case .failed(_, let reason):
      return [
        "state": .text("failed"),
        "reason": .text(String(describing: reason)),
      ]
    }
  }
}

extension InjectionBackendResult {
  fileprivate var requestID: UUID {
    switch self {
    case .applied(let requestID, _), .cleared(let requestID), .failed(let requestID, _):
      requestID
    }
  }
}

public actor InMemoryInjectionBackend: InjectionBackend {
  private var currentReadiness: InjectionBackendReadiness
  private var appliedLocation: SelectedLocation?

  public init(readiness: InjectionBackendReadiness = .ready) {
    currentReadiness = readiness
  }

  public func readiness() -> InjectionBackendReadiness {
    currentReadiness
  }

  public func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    switch currentReadiness {
    case .unavailable(let reason):
      return .failed(requestID: command.requestID, reason: reason)
    case .ready:
      break
    }

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

public struct UnavailableInjectionBackend: InjectionBackend {
  private let reason: InjectionBackendFailure

  public init(reason: InjectionBackendFailure) {
    self.reason = reason
  }

  public func readiness() -> InjectionBackendReadiness {
    .unavailable(reason)
  }

  public func execute(_ command: InjectionBackendCommand) -> InjectionBackendResult {
    .failed(requestID: command.requestID, reason: reason)
  }
}

extension InjectionBackendCommand {
  fileprivate var requestID: UUID {
    switch self {
    case .apply(let requestID, _), .clear(let requestID):
      requestID
    }
  }
}
