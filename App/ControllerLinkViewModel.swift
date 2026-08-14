import Foundation
import SwiftUI

enum LocalNetworkPermissionState: Equatable {
  case notYetConfirmed
  case allowed
  case denied
}

@MainActor
final class ControllerLinkViewModel: ObservableObject {
  @Published private(set) var state: ControllerLinkState = .notDiscovered
  @Published private(set) var controllerStatus: ControllerStatus?
  @Published private(set) var localNetworkPermission: LocalNetworkPermissionState =
    .notYetConfirmed
  @Published var pairingCode = ""

  private let discovery: any ControllerDiscovering
  private let link: TrustedControllerLink
  private let diagnostics: SimulationDiagnosticPipeline?
  private var discoveryTask: Task<Void, Never>?
  private var reconnectTask: Task<Void, Never>?
  private var discoveryRetryPolicy = ControllerDiscoveryRetryPolicy()
  private var hasPairingCandidate = false

  #if DEBUG
    private static let e2eFixtureIdentity = try! ControllerIdentity(
      fingerprint: Data(repeating: 0, count: 32)
    )

    private var usesE2EFixture: Bool {
      ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"
      ] == "1"
    }

    private var usesE2EClearFailureFixture: Bool {
      ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_CONTROLLER_LINK_FAILURE_FIXTURE"
      ] == "failed-clear"
    }

    private var e2eApplyDelayMilliseconds: Int {
      guard
        let value = ProcessInfo.processInfo.environment[
          "PINSHIFT_E2E_APPLY_DELAY_MILLISECONDS"
        ],
        let milliseconds = Int(value),
        milliseconds > 0
      else {
        return 0
      }
      return milliseconds
    }
  #endif

  init(
    discovery: any ControllerDiscovering = BonjourControllerDiscovery(),
    link: TrustedControllerLink = TrustedControllerLink(
      trust: ControllerTrust(store: KeychainControllerTrustStore()),
      authorizationStore: KeychainControllerAuthorizationStore(),
      transport: NetworkControllerLinkTransport()
    ),
    diagnostics: SimulationDiagnosticPipeline? = nil
  ) {
    self.discovery = discovery
    self.link = link
    self.diagnostics = diagnostics
  }

  func start() {
    guard discoveryTask == nil else { return }
    record(kind: "app.controller-link.started")
    #if DEBUG
      if usesE2EFixture {
        localNetworkPermission = .allowed
        state = .connected(Self.e2eFixtureIdentity)
        controllerStatus = ControllerStatus(readiness: .ready, simulation: .idle)
        record(kind: "app.controller-link.connected", fields: ["source": .text("fixture")])
        return
      }
    #endif
    discoveryTask = Task { [weak self] in
      guard let self else { return }
      #if DEBUG
        if ProcessInfo.processInfo.environment[
          "PINSHIFT_E2E_RESET_CONTROLLER_TRUST"
        ] == "1" {
          state = await link.forgetController()
          controllerStatus = nil
        }
      #endif
      for await event in discovery.events() {
        guard !Task.isCancelled else { return }
        await handle(event)
      }
    }
  }

  func retry() {
    record(kind: "app.controller-link.discovery-retry")
    discovery.stop()
    discoveryTask?.cancel()
    discoveryTask = nil
    cancelScheduledReconnect()
    discoveryRetryPolicy.reset()
    hasPairingCandidate = false
    pairingCode = ""
    controllerStatus = nil
    localNetworkPermission = .notYetConfirmed
    state = .notDiscovered
    start()
  }

  func pair() {
    guard hasPairingCandidate else { return }
    let code = pairingCode
    record(kind: "app.controller-link.pairing-submitted")
    Task { [weak self] in
      guard let self else { return }
      state = await link.pair(code: code)
      record(kind: "app.controller-link.pairing-result", fields: stateFields(state))
      if case .connected = state {
        pairingCode = ""
        hasPairingCandidate = false
        state = await link.refresh()
        controllerStatus = await link.currentStatus()
        record(kind: "app.controller-link.connected", fields: stateFields(state))
      }
    }
  }

  var canPair: Bool {
    hasPairingCandidate && pairingCode.count == 6 && pairingCode.allSatisfy(\.isNumber)
  }

  /// Historical simulation state and backend readiness never gate a new Apply.
  var canApply: Bool {
    if case .connected = state { return true }
    return false
  }

  var canClear: Bool {
    if case .connected = state { return true }
    return false
  }

  func apply(_ request: ManualSimulationRequest) async -> ControllerLinkResponse {
    record(
      kind: "app.controller-link.apply-started",
      requestID: request.requestID,
      fields: [
        "latitude": .number(request.location.latitude),
        "longitude": .number(request.location.longitude),
      ]
    )
    #if DEBUG
      if usesE2EFixture {
        if e2eApplyDelayMilliseconds > 0 {
          try? await Task.sleep(for: .milliseconds(e2eApplyDelayMilliseconds))
        }
        let automaticClearAt = Date().addingTimeInterval(900)
        controllerStatus = ControllerStatus(
          readiness: .ready,
          simulation: .active(
            operationID: request.requestID,
            latitude: request.location.latitude,
            longitude: request.location.longitude,
            automaticClearAt: automaticClearAt
          )
        )
        let response = ControllerLinkResponse.applied(
          requestID: request.requestID,
          automaticClearAt: automaticClearAt
        )
        record(
          kind: "app.controller-link.apply-response",
          requestID: request.requestID,
          fields: responseFields(response).merging(["source": .text("fixture")]) { _, new in new }
        )
        return response
      }
    #endif
    let response = await link.apply(
      requestID: request.requestID,
      latitude: request.location.latitude,
      longitude: request.location.longitude
    )
    state = await link.currentState()
    controllerStatus = await link.currentStatus()
    record(
      kind: "app.controller-link.apply-response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  func clear(_ request: ManualSimulationClearRequest) async -> ControllerLinkResponse {
    record(kind: "app.controller-link.clear-started", requestID: request.requestID)
    #if DEBUG
      if usesE2EFixture {
        if usesE2EClearFailureFixture {
          let existing = controllerStatus?.simulation
          let fallbackDeadline = Date().addingTimeInterval(900)
          switch existing {
          case .active(let operationID, let latitude, let longitude, let deadline):
            controllerStatus = ControllerStatus(
              readiness: .unavailable(.clearFailed),
              simulation: .clearPending(
                operationID: operationID,
                latitude: latitude,
                longitude: longitude,
                automaticClearAt: deadline,
                reason: .clearFailed
              )
            )
          default:
            controllerStatus = ControllerStatus(
              readiness: .unavailable(.clearFailed),
              simulation: .clearPending(
                operationID: request.requestID,
                latitude: nil,
                longitude: nil,
                automaticClearAt: fallbackDeadline,
                reason: .clearFailed
              )
            )
          }
          let response = ControllerLinkResponse.failed(
            requestID: request.requestID,
            reason: .clearFailed
          )
          record(
            kind: "app.controller-link.clear-response",
            requestID: request.requestID,
            fields: responseFields(response).merging(["source": .text("fixture")]) {
              _, new in new
            }
          )
          return response
        }
        controllerStatus = ControllerStatus(readiness: .ready, simulation: .idle)
        let response = ControllerLinkResponse.cleared(requestID: request.requestID)
        record(
          kind: "app.controller-link.clear-response",
          requestID: request.requestID,
          fields: responseFields(response).merging(["source": .text("fixture")]) { _, new in new }
        )
        return response
      }
    #endif
    let response = await link.clear(
      requestID: request.requestID,
      targetOperationID: request.targetOperationID
    )
    state = await link.currentState()
    controllerStatus = await link.currentStatus()
    record(
      kind: "app.controller-link.clear-response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  func reconcileStatus() async -> ControllerStatus? {
    #if DEBUG
      if usesE2EFixture { return controllerStatus }
    #endif
    state = await link.refresh()
    controllerStatus = await link.currentStatus()
    if let controllerStatus {
      record(
        kind: "app.controller-link.status-reconciled",
        fields: ["simulation": .text(String(describing: controllerStatus.simulation))]
      )
    }
    return controllerStatus
  }

  func refreshStatus() {
    Task { [weak self] in
      guard let self else { return }
      state = await link.refresh()
      controllerStatus = await link.currentStatus()
      record(kind: "app.controller-link.status-refreshed", fields: stateFields(state))
    }
  }

  private func handle(_ event: ControllerDiscoveryEvent) async {
    record(kind: "app.controller-link.discovery-event", fields: eventFields(event))
    switch event {
    case .localNetworkReady:
      localNetworkPermission = .allowed
    case .notFound:
      cancelScheduledReconnect()
      discoveryRetryPolicy.serviceBecameAbsent()
      if case .connected = state {
        state = await link.disconnected()
        controllerStatus = nil
        record(kind: "app.controller-link.disconnected")
      } else {
        state = .notDiscovered
      }
    case .found(let service):
      localNetworkPermission = .allowed
      await attemptConnection(to: service)
    case .localNetworkDenied:
      cancelScheduledReconnect()
      localNetworkPermission = .denied
      discoveryRetryPolicy.stopRetrying()
      state = await link.localNetworkPermissionDenied()
      controllerStatus = nil
      record(kind: "app.controller-link.local-network-denied")
    case .failed:
      cancelScheduledReconnect()
      discoveryRetryPolicy.stopRetrying()
      state = .unavailable(.transportUnavailable)
      controllerStatus = nil
      record(kind: "app.controller-link.connection-failed")
    }
  }

  private func attemptConnection(to service: ControllerService) async {
    guard discoveryRetryPolicy.beginConnectionAttemptIfAllowed() else { return }
    let connectionState = await link.connect(to: service)
    guard !Task.isCancelled else { return }
    state = connectionState
    controllerStatus = await link.currentStatus()
    record(kind: "app.controller-link.connection-result", fields: stateFields(state))

    switch state {
    case .awaitingPairing:
      reconnectTask = nil
      discoveryRetryPolicy.connectionAttemptSettled()
      hasPairingCandidate = true
    case .connected:
      reconnectTask = nil
      discoveryRetryPolicy.connectionAttemptSettled()
    case .unavailable(.transportUnavailable):
      scheduleReconnect(to: service)
    case .notDiscovered, .unavailable, .localNetworkDenied:
      reconnectTask = nil
      discoveryRetryPolicy.stopRetrying()
    }
  }

  private func scheduleReconnect(to service: ControllerService) {
    let scheduledRetry = discoveryRetryPolicy.scheduleRetryAfterConnectionFailure()
    reconnectTask?.cancel()
    reconnectTask = Task { [weak self] in
      do {
        try await Task.sleep(for: .seconds(scheduledRetry.delay))
      } catch {
        return
      }
      guard let self, !Task.isCancelled else { return }
      guard discoveryRetryPolicy.retryDelayElapsed(scheduledRetry) else { return }
      await attemptConnection(to: service)
    }
  }

  private func cancelScheduledReconnect() {
    reconnectTask?.cancel()
    reconnectTask = nil
  }

  private func record(
    kind: String,
    requestID: UUID? = nil,
    fields: SimulationDiagnosticFields = [:]
  ) {
    guard let diagnostics else { return }
    diagnostics.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func eventFields(_ event: ControllerDiscoveryEvent) -> SimulationDiagnosticFields {
    switch event {
    case .localNetworkReady:
      return ["event": .text("local-network-ready")]
    case .notFound:
      return ["event": .text("not-found")]
    case .found:
      return ["event": .text("found")]
    case .localNetworkDenied:
      return ["event": .text("local-network-denied")]
    case .failed(let failure):
      return ["event": .text("failed"), "reason": .text(String(describing: failure))]
    }
  }

  private func stateFields(_ state: ControllerLinkState) -> SimulationDiagnosticFields {
    var fields: SimulationDiagnosticFields
    switch state {
    case .notDiscovered:
      fields = ["state": .text("not-discovered")]
    case .awaitingPairing:
      fields = ["state": .text("pairing-required")]
    case .connected:
      fields = ["state": .text("connected")]
    case .unavailable(let failure):
      fields = ["state": .text("unavailable"), "reason": .text(String(describing: failure))]
    case .localNetworkDenied:
      fields = ["state": .text("local-network-denied")]
    }
    if let readiness = controllerStatus?.readiness {
      switch readiness {
      case .ready:
        fields["backendReadiness"] = .text("ready")
      case .unavailable(let reason):
        fields["backendReadiness"] = .text("unavailable")
        fields["backendReadinessReason"] = .text(reason.rawValue)
      }
    } else {
      fields["backendReadiness"] = .null
    }
    return fields
  }

  private func responseFields(_ response: ControllerLinkResponse) -> SimulationDiagnosticFields {
    switch response {
    case .status(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .paired:
      return ["outcome": .text("paired")]
    case .applied(_, let automaticClearAt):
      return [
        "outcome": .text("applied"),
        "automaticClearAt": .date(automaticClearAt),
      ]
    case .cleared:
      return ["outcome": .text("cleared")]
    case .failed(_, let reason):
      return ["outcome": .text("failed"), "reason": .text(reason.rawValue)]
    case .rejected(_, let reason):
      return ["outcome": .text("rejected"), "reason": .text(reason.rawValue)]
    }
  }
}
