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
  @Published private(set) var backendReadiness: ControllerBackendReadiness?
  @Published private(set) var lifecycleStatus: ControllerLifecycleStatus?
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
  private var stopDeliveryRequestIDs: Set<UUID> = []
  private var extensionDeliveryRequestIDs: Set<UUID> = []

  #if DEBUG
    private static let e2eFixtureIdentity = try! ControllerIdentity(
      fingerprint: Data(repeating: 0, count: 32)
    )

    private var usesE2EFixture: Bool {
      ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"
      ] == "1"
    }

    private var usesE2EStopFailureFixture: Bool {
      ProcessInfo.processInfo.environment[
        "PINSHIFT_E2E_CONTROLLER_LINK_FAILURE_FIXTURE"
      ] == "failed-stop"
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
    record(kind: "app.controller-link.lifecycle-started")
    #if DEBUG
      if usesE2EFixture {
        localNetworkPermission = .allowed
        state = .connected(Self.e2eFixtureIdentity)
        backendReadiness = .ready
        lifecycleStatus = ControllerLifecycleStatus(
          readiness: .ready,
          simulation: .noActive
        )
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
          backendReadiness = nil
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
    backendReadiness = nil
    lifecycleStatus = nil
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
        backendReadiness = await link.currentBackendReadiness()
        lifecycleStatus = await link.currentLifecycleStatus()
        record(kind: "app.controller-link.connected", fields: stateFields(state))
      }
    }
  }

  var canPair: Bool {
    hasPairingCandidate && pairingCode.count == 6 && pairingCode.allSatisfy(\.isNumber)
  }

  var canApply: Bool {
    guard case .connected = state, backendReadiness == .ready,
      lifecycleStatus?.cleanupReadiness == .ready
    else {
      return false
    }
    return true
  }

  var cleanupProtectionMessage: String? {
    switch lifecycleStatus?.cleanupReadiness {
    case .ready:
      return nil
    case .unavailable(.cleanupGuardianUnavailable):
      return
        "Cleanup Guardian protection is unavailable. Run pinshift-install on the Mac, "
        + "then retry."
    case .unavailable:
      return
        "Automatic cleanup protection is unavailable. Resolve the Mac "
        + "controller check and retry."
    case .unsupportedController:
      return
        "This Mac controller is too old for protected time-bounded sessions. "
        + "Update it with pinshift-install."
    case nil:
      return "Waiting for the Mac to confirm automatic-cleanup protection."
    }
  }

  var canSendStop: Bool {
    if case .connected = state {
      return true
    }
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
        let leaseExpiresAt = Date().addingTimeInterval(request.requestedLeaseDuration)
        lifecycleStatus = ControllerLifecycleStatus(
          readiness: .ready,
          cleanupReadiness: .ready,
          simulation: .applied(
            generationID: request.generationID,
            leaseExpiresAt: leaseExpiresAt
          )
        )
        record(
          kind: "app.controller-link.apply-response",
          requestID: request.requestID,
          fields: ["outcome": .text("applied"), "source": .text("fixture")]
        )
        return .appliedLifecycle(
          requestID: request.requestID,
          generationID: request.generationID,
          leaseExpiresAt: leaseExpiresAt
        )
      }
    #endif
    let response = await link.apply(
      requestID: request.requestID,
      generationID: request.generationID,
      latitude: request.location.latitude,
      longitude: request.location.longitude,
      requestedLeaseDuration: request.requestedLeaseDuration
    )
    state = await link.currentState()
    backendReadiness = await link.currentBackendReadiness()
    lifecycleStatus = await link.currentLifecycleStatus()
    record(
      kind: "app.controller-link.apply-response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  func deliverLeaseExtension(
    _ intent: ManualSimulationLeaseExtensionIntent
  ) async -> ControllerLinkResponse? {
    guard extensionDeliveryRequestIDs.insert(intent.requestID).inserted else {
      return nil
    }
    defer { extensionDeliveryRequestIDs.remove(intent.requestID) }
    #if DEBUG
      if usesE2EFixture {
        let currentExpiry: Date
        if case .applied(_, let leaseExpiresAt) = lifecycleStatus?.simulation {
          currentExpiry = leaseExpiresAt
        } else {
          currentExpiry = Date()
        }
        let extendedExpiry = min(
          currentExpiry.addingTimeInterval(intent.extensionDuration),
          Date().addingTimeInterval(3_600)
        )
        lifecycleStatus = ControllerLifecycleStatus(
          readiness: .ready,
          cleanupReadiness: .ready,
          simulation: .applied(
            generationID: intent.generationID,
            leaseExpiresAt: extendedExpiry
          )
        )
        return .extendedLifecycle(
          requestID: intent.requestID,
          generationID: intent.generationID,
          leaseExpiresAt: extendedExpiry
        )
      }
    #endif
    let response = await link.extendLease(
      requestID: intent.requestID,
      generationID: intent.generationID,
      extensionDuration: intent.extensionDuration
    )
    state = await link.currentState()
    backendReadiness = await link.currentBackendReadiness()
    lifecycleStatus = await link.currentLifecycleStatus()
    record(
      kind: "app.controller-link.lease-extension-response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  func deliverStop(
    _ intent: ManualSimulationStopIntent
  ) async -> ControllerLinkResponse? {
    guard stopDeliveryRequestIDs.insert(intent.requestID).inserted else {
      return nil
    }
    defer { stopDeliveryRequestIDs.remove(intent.requestID) }
    let requestID = intent.requestID
    record(
      kind: "app.controller-link.stop-started",
      requestID: requestID,
      fields: ["generationID": .text(intent.generationID.uuidString)]
    )
    #if DEBUG
      if usesE2EFixture {
        if usesE2EStopFailureFixture {
          state = .unavailable(.transportUnavailable)
          backendReadiness = nil
          record(
            kind: "app.controller-link.unavailable",
            fields: [
              "state": .text("unavailable"),
              "reason": .text("transport-unavailable"),
              "source": .text("fixture"),
            ]
          )
          record(
            kind: "app.controller-link.connection-failed",
            fields: ["source": .text("fixture")]
          )
          let response = ControllerLinkResponse.failed(
            requestID: requestID,
            reason: .clearFailed
          )
          lifecycleStatus = ControllerLifecycleStatus(
            readiness: .unavailable(.clearFailed),
            cleanupReadiness: .ready,
            simulation: .cleanupPending(
              generationID: intent.generationID,
              requestID: requestID,
              reason: .clearFailed
            )
          )
          record(
            kind: "app.controller-link.stop-response",
            requestID: requestID,
            fields: responseFields(response)
          )
          return response
        }
        lifecycleStatus = ControllerLifecycleStatus(
          readiness: .ready,
          cleanupReadiness: .ready,
          simulation: .stopped(generationID: intent.generationID)
        )
        record(
          kind: "app.controller-link.stop-response",
          requestID: requestID,
          fields: ["outcome": .text("stopped"), "source": .text("fixture")]
        )
        return .stopped(requestID: requestID)
      }
    #endif
    let response = await link.stop(
      requestID: requestID,
      generationID: intent.generationID
    )
    state = await link.currentState()
    backendReadiness = await link.currentBackendReadiness()
    lifecycleStatus = await link.currentLifecycleStatus()
    record(
      kind: "app.controller-link.stop-response",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  func reconcileLifecycle() async -> ControllerLifecycleStatus? {
    #if DEBUG
      if usesE2EFixture {
        return lifecycleStatus
      }
    #endif
    state = await link.refresh()
    backendReadiness = await link.currentBackendReadiness()
    lifecycleStatus = await link.currentLifecycleStatus()
    if let lifecycleStatus {
      record(
        kind: "app.controller-link.lifecycle-reconciled",
        fields: [
          "simulation": .text(String(describing: lifecycleStatus.simulation))
        ]
      )
    }
    return lifecycleStatus
  }

  func refreshReadiness() {
    Task { [weak self] in
      guard let self else { return }
      state = await link.refresh()
      backendReadiness = await link.currentBackendReadiness()
      lifecycleStatus = await link.currentLifecycleStatus()
      record(kind: "app.controller-link.readiness-refreshed", fields: stateFields(state))
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
        backendReadiness = nil
        lifecycleStatus = nil
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
      backendReadiness = nil
      lifecycleStatus = nil
      record(kind: "app.controller-link.local-network-denied")
    case .failed:
      cancelScheduledReconnect()
      discoveryRetryPolicy.stopRetrying()
      state = .unavailable(.transportUnavailable)
      backendReadiness = nil
      lifecycleStatus = nil
      record(kind: "app.controller-link.connection-failed")
    }
  }

  private func attemptConnection(to service: ControllerService) async {
    guard discoveryRetryPolicy.beginConnectionAttemptIfAllowed() else { return }
    let connectionState = await link.connect(to: service)
    guard !Task.isCancelled else { return }
    state = connectionState
    backendReadiness = await link.currentBackendReadiness()
    lifecycleStatus = await link.currentLifecycleStatus()
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
    if let backendReadiness {
      switch backendReadiness {
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
    case .status(_, let readiness):
      return ["outcome": .text(String(describing: readiness))]
    case .lifecycleStatus(_, let status):
      return ["outcome": .text(String(describing: status.simulation))]
    case .paired:
      return ["outcome": .text("paired")]
    case .applied:
      return ["outcome": .text("applied")]
    case .appliedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("applied"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .extendedLifecycle(_, let generationID, let leaseExpiresAt):
      return [
        "outcome": .text("extended"),
        "generationID": .text(generationID.uuidString),
        "leaseExpiresAt": .date(leaseExpiresAt),
      ]
    case .stopped:
      return ["outcome": .text("stopped")]
    case .stoppedLifecycle(_, let generationID):
      var fields: SimulationDiagnosticFields = ["outcome": .text("stopped")]
      if let generationID {
        fields["generationID"] = .text(generationID.uuidString)
      }
      return fields
    case .failed(_, let reason):
      return ["outcome": .text("failed"), "reason": .text(reason.rawValue)]
    case .rejected(_, let reason):
      return ["outcome": .text("rejected"), "reason": .text(reason.rawValue)]
    }
  }
}
