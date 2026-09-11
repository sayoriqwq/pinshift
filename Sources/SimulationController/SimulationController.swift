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
  public static let automaticClearInterval: TimeInterval = 180
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
    automaticClearAt: Date?,
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
  private enum Phase {
    case uncertain
    case active
    case clearPending
  }

  private struct CurrentSimulation {
    let operationID: UUID
    let location: SelectedLocation
    let automaticClearAt: Date
    var phase: Phase
    var lastFailure: InjectionBackendFailure?
  }

  private struct ApplyReceipt {
    let operationID: UUID
    let location: SelectedLocation
    let automaticClearAt: Date
  }

  private struct UntrackedClearFailure {
    let requestID: UUID
    let reason: InjectionBackendFailure
  }

  private let backend: any InjectionBackend
  private let diagnostics: SimulationDiagnosticRecorder?
  private let now: @Sendable () -> Date
  private let sleep: @Sendable (TimeInterval) async throws -> Void
  private var automaticallySchedulesMaintenance: Bool

  private var current: CurrentSimulation?
  private var untrackedClearFailure: UntrackedClearFailure?
  private var recentApplyReceipts: [ApplyReceipt] = []
  private var acceptsApply = true
  private var operationInFlight = false
  private var operationWaiters: [CheckedContinuation<Void, Never>] = []
  private var automaticClearTask: Task<Void, Never>?
  private var maintenanceGeneration = UUID()
  private var recoveryDelay: TimeInterval = 1

  public init(
    backend: any InjectionBackend,
    diagnostics: SimulationDiagnosticRecorder? = nil,
    now: @escaping @Sendable () -> Date = Date.init,
    sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
      try await Task.sleep(for: .seconds(seconds))
    },
    automaticallySchedulesMaintenance: Bool = true
  ) {
    self.backend = backend
    self.diagnostics = diagnostics
    self.now = now
    self.sleep = sleep
    self.automaticallySchedulesMaintenance = automaticallySchedulesMaintenance
  }

  public func snapshot() async -> TemporarySimulationSnapshot {
    await acquireOperation()
    defer { releaseOperation() }
    return TemporarySimulationSnapshot(
      readiness: await backend.readiness(),
      simulation: snapshotState()
    )
  }

  public func apply(
    _ location: SelectedLocation,
    requestID: UUID = UUID()
  ) async -> TemporarySimulationApplyResult {
    await acquireOperation()
    defer { releaseOperation() }
    guard acceptsApply else {
      return .failed(requestID: requestID, reason: .sessionNotReady)
    }
    await record(
      kind: "controller.apply.started",
      requestID: requestID,
      fields: coordinateFields(location)
    )

    if let receipt = recentApplyReceipts.last(where: { $0.operationID == requestID }) {
      guard receipt.location == location else {
        return .failed(requestID: requestID, reason: .backendUnavailable)
      }
      guard current?.operationID == requestID else {
        return .failed(requestID: requestID, reason: .timedOut)
      }
      return .applied(
        requestID: requestID,
        location: receipt.location,
        automaticClearAt: receipt.automaticClearAt
      )
    }

    if let current, current.operationID == requestID {
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
    if let current, current.operationID == requestID {
      automaticClearAt = current.automaticClearAt
    } else {
      automaticClearAt = now().addingTimeInterval(
        TemporarySimulationPolicy.automaticClearInterval
      )
      current = CurrentSimulation(
        operationID: requestID,
        location: location,
        automaticClearAt: automaticClearAt,
        phase: .uncertain,
        lastFailure: nil
      )
      untrackedClearFailure = nil
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
      if var current, current.operationID == requestID {
        current.phase = .active
        current.lastFailure = nil
        self.current = current
      }
      appendReceipt(
        ApplyReceipt(
          operationID: requestID,
          location: location,
          automaticClearAt: automaticClearAt
        )
      )
      scheduleAutomaticClear()
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
      retainUncertainApplyFailure(requestID: requestID, reason: reason)
      scheduleAutomaticClear()
      return .failed(requestID: requestID, reason: reason)

    case .applied(let responseID, _), .cleared(let responseID),
      .failed(let responseID, _):
      retainUncertainApplyFailure(
        requestID: requestID,
        reason: .backendUnavailable
      )
      scheduleAutomaticClear()
      return .failed(requestID: responseID, reason: .backendUnavailable)
    }
  }

  public func clear(requestID: UUID = UUID()) async -> TemporarySimulationClearResult {
    await acquireOperation()
    defer { releaseOperation() }
    await record(kind: "controller.clear.started", requestID: requestID)
    if var current {
      current.phase = .clearPending
      current.lastFailure = nil
      self.current = current
    }

    return await finishClear(
      await backend.execute(.clear(requestID: requestID)),
      requestID: requestID,
      automatic: false
    )
  }

  public func beginShutdown() async {
    await acquireOperation()
    defer { releaseOperation() }
    acceptsApply = false
    stopMaintenance()
  }

  public func stopMaintenance() {
    automaticallySchedulesMaintenance = false
    maintenanceGeneration = UUID()
    automaticClearTask?.cancel()
    automaticClearTask = nil
  }

  private func automaticallyClear(generation: UUID) async {
    await acquireOperation()
    defer { releaseOperation() }
    guard generation == maintenanceGeneration, !Task.isCancelled else { return }
    if var current {
      current.phase = .clearPending
      current.lastFailure = nil
      self.current = current
    }

    let requestID = UUID()
    _ = await finishClear(
      await backend.execute(.clear(requestID: requestID)),
      requestID: requestID,
      automatic: true
    )
  }

  private func finishClear(
    _ result: InjectionBackendResult,
    requestID: UUID,
    automatic: Bool
  ) async -> TemporarySimulationClearResult {
    switch result {
    case .cleared(let responseID) where responseID == requestID:
      current = nil
      untrackedClearFailure = nil
      maintenanceGeneration = UUID()
      recoveryDelay = 1
      automaticClearTask?.cancel()
      automaticClearTask = nil
      await record(
        kind: automatic
          ? "controller.temporary-simulation.automatic-clear-succeeded"
          : "controller.temporary-simulation.clear-succeeded",
        requestID: requestID
      )
      return .cleared(requestID: responseID)

    case .failed(let responseID, let reason) where responseID == requestID:
      await retainClearFailure(requestID: requestID, reason: reason, automatic: automatic)
      return .failed(requestID: responseID, reason: reason)

    case .applied(let responseID, _), .cleared(let responseID),
      .failed(let responseID, _):
      await retainClearFailure(
        requestID: requestID,
        reason: .clearFailed,
        automatic: automatic
      )
      return .failed(requestID: responseID, reason: .clearFailed)
    }
  }

  private func retainUncertainApplyFailure(
    requestID: UUID,
    reason: InjectionBackendFailure
  ) {
    guard var current, current.operationID == requestID else { return }
    current.phase = .uncertain
    current.lastFailure = reason
    self.current = current
  }

  private func retainClearFailure(
    requestID: UUID,
    reason: InjectionBackendFailure,
    automatic: Bool
  ) async {
    defer { scheduleAutomaticClear() }
    guard var current else {
      untrackedClearFailure = UntrackedClearFailure(
        requestID: requestID,
        reason: reason
      )
      await record(
        kind: automatic
          ? "controller.temporary-simulation.automatic-clear-failed"
          : "controller.temporary-simulation.clear-failed",
        requestID: requestID,
        fields: ["reason": .text(reason.rawValue)]
      )
      return
    }
    current.phase = .clearPending
    current.lastFailure = reason
    self.current = current
    await record(
      kind: automatic
        ? "controller.temporary-simulation.automatic-clear-failed"
        : "controller.temporary-simulation.clear-failed",
      requestID: requestID,
      fields: [
        "automaticClearAt": .date(current.automaticClearAt),
        "reason": .text(reason.rawValue),
      ]
    )
  }

  private func snapshotState() -> TemporarySimulationSnapshotState {
    guard let current else {
      if let untrackedClearFailure {
        return .clearPending(
          operationID: untrackedClearFailure.requestID,
          location: nil,
          automaticClearAt: nil,
          reason: untrackedClearFailure.reason
        )
      }
      return .idle
    }
    switch current.phase {
    case .active:
      return .active(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt
      )
    case .uncertain:
      return .uncertain(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt,
        reason: current.lastFailure
      )
    case .clearPending:
      return .clearPending(
        operationID: current.operationID,
        location: current.location,
        automaticClearAt: current.automaticClearAt,
        reason: current.lastFailure
      )
    }
  }

  private func appendReceipt(_ receipt: ApplyReceipt) {
    recentApplyReceipts.removeAll { $0.operationID == receipt.operationID }
    recentApplyReceipts.append(receipt)
    if recentApplyReceipts.count > 8 {
      recentApplyReceipts.removeFirst(recentApplyReceipts.count - 8)
    }
  }

  private func scheduleAutomaticClear() {
    automaticClearTask?.cancel()
    maintenanceGeneration = UUID()
    guard automaticallySchedulesMaintenance else {
      automaticClearTask = nil
      return
    }
    let delay: TimeInterval
    if current?.phase == .clearPending || untrackedClearFailure != nil {
      delay = recoveryDelay
      recoveryDelay = min(recoveryDelay * 2, 30)
    } else if let current {
      recoveryDelay = 1
      delay = max(0, current.automaticClearAt.timeIntervalSince(now()))
    } else {
      automaticClearTask = nil
      return
    }
    let generation = maintenanceGeneration
    let sleep = self.sleep
    automaticClearTask = Task { [weak self] in
      do {
        try await sleep(delay)
      } catch {
        return
      }
      guard !Task.isCancelled else { return }
      await self?.automaticallyClear(generation: generation)
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
