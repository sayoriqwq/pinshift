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

public enum TemporarySimulationPolicy {
  public static let automaticClearInterval: TimeInterval = 900
}

public enum TemporarySimulationSnapshotState: Equatable, Sendable {
  case idle
  case active(
    operationID: UUID,
    location: SelectedLocation,
    automaticClearAt: Date
  )
  case uncertain(
    operationID: UUID,
    location: SelectedLocation?,
    automaticClearAt: Date,
    reason: InjectionBackendFailure?
  )
  case clearPending(
    operationID: UUID,
    location: SelectedLocation?,
    automaticClearAt: Date,
    reason: InjectionBackendFailure?
  )
}

public struct TemporarySimulationSnapshot: Equatable, Sendable {
  public let readiness: InjectionBackendReadiness
  public let simulation: TemporarySimulationSnapshotState

  public init(
    readiness: InjectionBackendReadiness,
    simulation: TemporarySimulationSnapshotState
  ) {
    self.readiness = readiness
    self.simulation = simulation
  }
}

public enum TemporarySimulationApplyResult: Equatable, Sendable {
  case applied(
    requestID: UUID,
    location: SelectedLocation,
    automaticClearAt: Date
  )
  case failed(requestID: UUID, reason: InjectionBackendFailure)
}

public enum TemporarySimulationClearResult: Equatable, Sendable {
  case cleared(requestID: UUID)
  case failed(requestID: UUID, reason: InjectionBackendFailure)
}

public actor SimulationController {
  private let backend: any InjectionBackend
  private let diagnostics: SimulationDiagnosticRecorder?
  private let stateStore: any TemporarySimulationStoring
  private let activeDeviceIdentifier: String
  private let automaticClearInterval: TimeInterval
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private let automaticallySchedulesMaintenance: Bool

  private var state = TemporarySimulationState()
  private var didLoadState = false
  private var operationInFlight = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []
  private var maintenanceTask: Task<Void, Never>?

  public init(
    backend: any InjectionBackend,
    diagnostics: SimulationDiagnosticRecorder? = nil,
    stateStore: any TemporarySimulationStoring = InMemoryTemporarySimulationStore(),
    activeDeviceIdentifier: String = "in-memory-active-device",
    automaticClearInterval: TimeInterval = TemporarySimulationPolicy.automaticClearInterval,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    automaticallySchedulesMaintenance: Bool = true
  ) {
    self.backend = backend
    self.diagnostics = diagnostics
    self.stateStore = stateStore
    self.activeDeviceIdentifier = activeDeviceIdentifier
    self.automaticClearInterval = automaticClearInterval
    self.now = now
    self.sleep = sleep
    self.automaticallySchedulesMaintenance = automaticallySchedulesMaintenance
  }

  public func snapshot() async -> TemporarySimulationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    guard await loadStateIfNeeded() else {
      return TemporarySimulationSnapshot(
        readiness: .unavailable(.backendUnavailable),
        simulation: snapshotState()
      )
    }
    let readiness = await backend.readiness()
    return TemporarySimulationSnapshot(
      readiness: readiness,
      simulation: snapshotState()
    )
  }

  public func apply(
    _ location: SelectedLocation,
    requestID: UUID = UUID()
  ) async -> TemporarySimulationApplyResult {
    await acquireOperation()
    defer { releaseOperation() }
    await record(
      kind: "controller.apply.started",
      requestID: requestID,
      fields: coordinateFields(location)
    )
    guard await loadStateIfNeeded() else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }

    if let receipt = state.recentApplyReceipts.last(where: {
      $0.operationID == requestID
    }) {
      guard receipt.location == location else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      return .applied(
        requestID: requestID,
        location: receipt.location,
        automaticClearAt: receipt.automaticClearAt
      )
    }

    if let current = state.current, current.operationID == requestID {
      guard current.location == location else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      if current.phase == .active {
        return .applied(
          requestID: requestID,
          location: location,
          automaticClearAt: current.automaticClearAt
        )
      }
      guard now() < current.automaticClearAt else {
        return .failed(requestID: requestID, reason: .timedOut)
      }
    } else {
      switch await backend.readiness() {
      case .ready:
        break
      case .unavailable(let reason):
        return .failed(requestID: requestID, reason: reason)
      }
    }

    let automaticClearAt: Date
    if let current = state.current, current.operationID == requestID {
      automaticClearAt = current.automaticClearAt
    } else {
      automaticClearAt = now().addingTimeInterval(automaticClearInterval)
      var replacement = state
      replacement.current = TemporarySimulationRecord(
        activeDeviceIdentifier: activeDeviceIdentifier,
        operationID: requestID,
        location: location,
        automaticClearAt: automaticClearAt,
        phase: .armed
      )
      guard await persist(replacement) else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      await record(
        kind: "controller.temporary-simulation.armed",
        requestID: requestID,
        fields: ["automaticClearAt": .date(automaticClearAt)]
      )
    }

    let backendResult = await backend.execute(
      .apply(requestID: requestID, location: location)
    )
    switch backendResult {
    case .applied(let responseID, let appliedLocation)
      where responseID == requestID && appliedLocation == location:
      var acknowledged = state
      if var current = acknowledged.current, current.operationID == requestID {
        current.phase = .active
        current.retryAttempt = 0
        current.nextClearAttemptAt = nil
        current.lastClearFailure = nil
        acknowledged.current = current
      }
      appendReceipt(
        TemporaryApplyReceipt(
          operationID: requestID,
          location: location,
          automaticClearAt: automaticClearAt
        ),
        to: &acknowledged
      )
      _ = await persist(acknowledged)
      scheduleMaintenance()
      await record(
        kind: "controller.temporary-simulation.applied",
        requestID: requestID,
        fields: ["automaticClearAt": .date(automaticClearAt)]
      )
      return .applied(
        requestID: requestID,
        location: location,
        automaticClearAt: automaticClearAt
      )

    case .failed(let responseID, let reason) where responseID == requestID:
      await retainUncertainApplyFailure(requestID: requestID, reason: reason)
      scheduleMaintenance()
      return .failed(requestID: requestID, reason: reason)

    case .applied(let responseID, _), .cleared(let responseID),
      .failed(let responseID, _):
      await retainUncertainApplyFailure(
        requestID: requestID,
        reason: .backendUnavailable
      )
      scheduleMaintenance()
      return .failed(requestID: responseID, reason: .backendUnavailable)
    }
  }

  public func clear(
    requestID: UUID = UUID(),
    targetOperationID: UUID? = nil
  ) async -> TemporarySimulationClearResult {
    await acquireOperation()
    defer { releaseOperation() }
    await record(kind: "controller.clear.started", requestID: requestID)
    guard await loadStateIfNeeded() else {
      return .failed(requestID: requestID, reason: .backendUnavailable)
    }

    if let targetOperationID, state.current?.operationID != targetOperationID {
      await record(
        kind: "controller.clear.stale-target-ignored",
        requestID: requestID,
        fields: ["targetOperationID": .text(targetOperationID.uuidString)]
      )
      return .cleared(requestID: requestID)
    }

    let resolvedTargetOperationID = state.current?.operationID
    if var current = state.current {
      current.phase = .clearPending
      current.lastClearFailure = nil
      current.nextClearAttemptAt = current.automaticClearAt
      var pending = state
      pending.current = current
      guard await persist(pending) else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
    }

    let result = await backend.execute(.clear(requestID: requestID))
    return await finishClear(
      result,
      requestID: requestID,
      targetOperationID: resolvedTargetOperationID,
      automatic: false
    )
  }

  @discardableResult
  public func reconcile() async -> TemporarySimulationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    guard await loadStateIfNeeded() else {
      return TemporarySimulationSnapshot(
        readiness: .unavailable(.backendUnavailable),
        simulation: snapshotState()
      )
    }
    guard let current = state.current else {
      maintenanceTask?.cancel()
      maintenanceTask = nil
      return TemporarySimulationSnapshot(
        readiness: await backend.readiness(),
        simulation: .idle
      )
    }
    guard current.activeDeviceIdentifier == activeDeviceIdentifier else {
      // A different configured device cannot satisfy this retained obligation.
      // Keep it visible and retry slowly without creating an immediate task loop.
      scheduleMaintenance(after: 60)
      return TemporarySimulationSnapshot(
        readiness: .unavailable(.deviceMismatch),
        simulation: snapshotState()
      )
    }

    let dueAt = max(
      current.automaticClearAt,
      current.nextClearAttemptAt ?? current.automaticClearAt
    )
    guard now() >= dueAt else {
      scheduleMaintenance()
      return TemporarySimulationSnapshot(
        readiness: await backend.readiness(),
        simulation: snapshotState()
      )
    }

    var pending = current
    pending.phase = .clearPending
    pending.nextClearAttemptAt = nil
    var pendingState = state
    pendingState.current = pending
    guard await persist(pendingState) else {
      scheduleMaintenance(after: 1)
      return TemporarySimulationSnapshot(
        readiness: .unavailable(.backendUnavailable),
        simulation: snapshotState()
      )
    }

    let requestID = UUID()
    let result = await backend.execute(.clear(requestID: requestID))
    _ = await finishClear(
      result,
      requestID: requestID,
      targetOperationID: current.operationID,
      automatic: true
    )
    return TemporarySimulationSnapshot(
      readiness: await backend.readiness(),
      simulation: snapshotState()
    )
  }

  private func loadStateIfNeeded() async -> Bool {
    guard !didLoadState else { return true }
    do {
      state = try await stateStore.load() ?? TemporarySimulationState()
      if var current = state.current, current.activeDeviceIdentifier.isEmpty {
        current.activeDeviceIdentifier = activeDeviceIdentifier
        var migrated = state
        migrated.current = current
        guard await persist(migrated) else { return false }
      } else {
        // Re-save once so a decoded legacy schema is atomically replaced by schema 2.
        guard await persist(state) else { return false }
      }
      didLoadState = true
      scheduleMaintenance()
      return true
    } catch {
      await record(
        kind: "controller.temporary-simulation.state-load-failed",
        fields: ["error": .text(String(describing: error))]
      )
      return false
    }
  }

  private func persist(_ replacement: TemporarySimulationState) async -> Bool {
    do {
      try await stateStore.save(replacement)
      state = replacement
      return true
    } catch {
      await record(
        kind: "controller.temporary-simulation.state-save-failed",
        fields: ["error": .text(String(describing: error))]
      )
      return false
    }
  }

  private func finishClear(
    _ result: InjectionBackendResult,
    requestID: UUID,
    targetOperationID: UUID?,
    automatic: Bool
  ) async -> TemporarySimulationClearResult {
    switch result {
    case .cleared(let responseID) where responseID == requestID:
      var cleared = state
      if targetOperationID == nil || cleared.current?.operationID == targetOperationID {
        cleared.current = nil
      }
      let persisted = await persist(cleared)
      if persisted {
        maintenanceTask?.cancel()
        maintenanceTask = nil
      } else {
        scheduleMaintenance(after: 1)
      }
      await record(
        kind: automatic
          ? "controller.temporary-simulation.automatic-clear-succeeded"
          : "controller.temporary-simulation.clear-succeeded",
        requestID: requestID
      )
      return .cleared(requestID: responseID)

    case .failed(let responseID, let reason) where responseID == requestID:
      await retainClearFailure(
        requestID: requestID,
        targetOperationID: targetOperationID,
        reason: reason
      )
      return .failed(requestID: responseID, reason: reason)

    case .applied(let responseID, _), .cleared(let responseID),
      .failed(let responseID, _):
      await retainClearFailure(
        requestID: requestID,
        targetOperationID: targetOperationID,
        reason: .clearFailed
      )
      return .failed(requestID: responseID, reason: .clearFailed)
    }
  }

  private func retainUncertainApplyFailure(
    requestID: UUID,
    reason: InjectionBackendFailure
  ) async {
    guard var current = state.current, current.operationID == requestID else { return }
    current.phase = .armed
    current.lastClearFailure = reason
    var uncertain = state
    uncertain.current = current
    _ = await persist(uncertain)
  }

  private func retainClearFailure(
    requestID: UUID,
    targetOperationID: UUID?,
    reason: InjectionBackendFailure
  ) async {
    guard var current = state.current,
      targetOperationID == nil || current.operationID == targetOperationID
    else { return }
    current.phase = .clearPending
    current.retryAttempt += 1
    let retryDelay = min(pow(2, Double(current.retryAttempt)), 60)
    current.nextClearAttemptAt = max(
      current.automaticClearAt,
      now().addingTimeInterval(retryDelay)
    )
    current.lastClearFailure = reason
    var pending = state
    pending.current = current
    _ = await persist(pending)
    scheduleMaintenance()
    await record(
      kind: "controller.temporary-simulation.clear-retry-scheduled",
      requestID: requestID,
      fields: [
        "automaticClearAt": .date(current.automaticClearAt),
        "nextClearAttemptAt": .date(current.nextClearAttemptAt ?? current.automaticClearAt),
        "reason": .text(reason.rawValue),
      ]
    )
  }

  private func snapshotState() -> TemporarySimulationSnapshotState {
    guard let current = state.current else { return .idle }
    if current.activeDeviceIdentifier != activeDeviceIdentifier {
      return .uncertain(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt,
        reason: .deviceMismatch
      )
    }
    switch current.phase {
    case .active:
      guard let location = current.location else {
        return .uncertain(
          operationID: current.operationID,
          location: nil,
          automaticClearAt: current.automaticClearAt,
          reason: current.lastClearFailure
        )
      }
      return .active(
        operationID: current.operationID,
        location: location,
        automaticClearAt: current.automaticClearAt
      )
    case .armed:
      return .uncertain(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt,
        reason: current.lastClearFailure
      )
    case .clearPending:
      return .clearPending(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt,
        reason: current.lastClearFailure
      )
    }
  }

  private func appendReceipt(
    _ receipt: TemporaryApplyReceipt,
    to state: inout TemporarySimulationState
  ) {
    state.recentApplyReceipts.removeAll { $0.operationID == receipt.operationID }
    state.recentApplyReceipts.append(receipt)
    if state.recentApplyReceipts.count > 8 {
      state.recentApplyReceipts.removeFirst(state.recentApplyReceipts.count - 8)
    }
  }

  private func scheduleMaintenance(after explicitDelay: TimeInterval? = nil) {
    maintenanceTask?.cancel()
    guard automaticallySchedulesMaintenance, didLoadState, let current = state.current else {
      maintenanceTask = nil
      return
    }
    let dueAt = max(
      current.automaticClearAt,
      current.nextClearAttemptAt ?? current.automaticClearAt
    )
    let delay = explicitDelay ?? max(0, dueAt.timeIntervalSince(now()))
    let sleep = self.sleep
    maintenanceTask = Task { [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.reconcile()
    }
  }

  private func acquireOperation() async {
    if !operationInFlight {
      operationInFlight = true
      return
    }
    await withCheckedContinuation { continuation in
      operationWaiters.append(continuation)
    }
  }

  private func releaseOperation() {
    if operationWaiters.isEmpty {
      operationInFlight = false
    } else {
      operationWaiters.removeFirst().resume()
    }
  }

  private func record(
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) async {
    await diagnostics?.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func coordinateFields(_ location: SelectedLocation) -> SimulationDiagnosticFields {
    [
      "latitude": .number(location.latitude),
      "longitude": .number(location.longitude),
    ]
  }
}

public actor InMemoryInjectionBackend: InjectionBackend {
  private var currentReadiness: InjectionBackendReadiness
  public private(set) var appliedLocation: SelectedLocation?

  public init(readiness: InjectionBackendReadiness = .ready) {
    currentReadiness = readiness
  }

  public func readiness() -> InjectionBackendReadiness {
    currentReadiness
  }

  public func setReadiness(_ readiness: InjectionBackendReadiness) {
    currentReadiness = readiness
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
