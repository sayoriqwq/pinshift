import Foundation

public struct ControllerService: Codable, Hashable, Sendable {
  public static let serviceType = "_remote-location._tcp"

  public let name: String
  public let type: String
  public let domain: String?

  public init(
    name: String,
    type: String = ControllerService.serviceType,
    domain: String? = nil
  ) {
    self.name = name
    self.type = type
    self.domain = domain
  }
}

public enum ControllerLinkRequest: Codable, Equatable, Sendable {
  case status(requestID: UUID, authorization: ControllerAuthorization?)
  case lifecycleStatus(requestID: UUID, authorization: ControllerAuthorization)
  case pair(requestID: UUID, code: String)
  case apply(
    requestID: UUID,
    authorization: ControllerAuthorization,
    latitude: Double,
    longitude: Double
  )
  case applyLifecycle(
    requestID: UUID,
    generationID: UUID,
    authorization: ControllerAuthorization,
    latitude: Double,
    longitude: Double,
    requestedLeaseDuration: TimeInterval
  )
  case extendLifecycle(
    requestID: UUID,
    generationID: UUID,
    authorization: ControllerAuthorization,
    extensionDuration: TimeInterval
  )
  case stop(requestID: UUID, authorization: ControllerAuthorization)
  case stopLifecycle(
    requestID: UUID,
    generationID: UUID?,
    authorization: ControllerAuthorization
  )

  public var requestID: UUID {
    switch self {
    case .status(let requestID, _),
      .lifecycleStatus(let requestID, _),
      .pair(let requestID, _),
      .apply(let requestID, _, _, _),
      .applyLifecycle(let requestID, _, _, _, _, _),
      .extendLifecycle(let requestID, _, _, _),
      .stop(let requestID, _),
      .stopLifecycle(let requestID, _, _):
      requestID
    }
  }
}

public enum ControllerLinkRejection: String, Codable, Error, Equatable, Sendable {
  case pairingRequired
  case invalidPairingCode
  case expiredPairingCode
  case pairingCodeAlreadyUsed
  case tooManyPairingAttempts
  case identityMismatch
  case authorizationFailed
  case invalidRequest
}

public enum ControllerLinkResponse: Codable, Equatable, Sendable {
  case status(requestID: UUID, readiness: ControllerBackendReadiness)
  case lifecycleStatus(requestID: UUID, status: ControllerLifecycleStatus)
  case paired(requestID: UUID, authorization: ControllerAuthorization)
  case applied(requestID: UUID)
  case appliedLifecycle(requestID: UUID, generationID: UUID, leaseExpiresAt: Date)
  case extendedLifecycle(requestID: UUID, generationID: UUID, leaseExpiresAt: Date)
  case stopped(requestID: UUID)
  case stoppedLifecycle(requestID: UUID, generationID: UUID?)
  case failed(requestID: UUID, reason: ControllerCommandFailure)
  case rejected(requestID: UUID, reason: ControllerLinkRejection)

  public var requestID: UUID {
    switch self {
    case .status(let requestID, _),
      .lifecycleStatus(let requestID, _),
      .paired(let requestID, _),
      .applied(let requestID),
      .appliedLifecycle(let requestID, _, _),
      .extendedLifecycle(let requestID, _, _),
      .stopped(let requestID),
      .stoppedLifecycle(let requestID, _),
      .failed(let requestID, _),
      .rejected(let requestID, _):
      requestID
    }
  }
}

public struct ControllerTransportReply: Equatable, Sendable {
  public let presentedIdentity: ControllerIdentity
  public let response: ControllerLinkResponse

  public init(
    presentedIdentity: ControllerIdentity,
    response: ControllerLinkResponse
  ) {
    self.presentedIdentity = presentedIdentity
    self.response = response
  }
}

public protocol ControllerLinkTransport: Sendable {
  func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) async throws -> ControllerTransportReply
}

public actor TrustedControllerLink {
  private let trust: ControllerTrust
  private let authorizationStore: any ControllerAuthorizationStore
  private let transport: any ControllerLinkTransport
  private var stateMachine = ControllerLinkStateMachine()
  private var currentService: ControllerService?
  private var pendingIdentity: ControllerIdentity?
  private var backendReadiness: ControllerBackendReadiness?
  private var lifecycleStatus: ControllerLifecycleStatus?

  public init(
    trust: ControllerTrust,
    authorizationStore: any ControllerAuthorizationStore,
    transport: any ControllerLinkTransport
  ) {
    self.trust = trust
    self.authorizationStore = authorizationStore
    self.transport = transport
  }

  public func connect(to service: ControllerService) async -> ControllerLinkState {
    currentService = service
    backendReadiness = nil
    lifecycleStatus = nil
    let trustedIdentity: ControllerIdentity?
    do {
      trustedIdentity = try await trust.trustedIdentity()
    } catch {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }

    let authorization: ControllerAuthorization?
    do {
      authorization = try await authorizationStore.load()
    } catch {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    let request: ControllerLinkRequest
    if let authorization {
      request = .lifecycleStatus(
        requestID: UUID(),
        authorization: authorization
      )
    } else {
      request = .status(requestID: UUID(), authorization: nil)
    }
    let reply: ControllerTransportReply
    do {
      reply = try await transport.send(
        request,
        to: service,
        expectedIdentity: trustedIdentity
      )
    } catch {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    guard reply.response.requestID == request.requestID else {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }

    if let trustedIdentity {
      guard reply.presentedIdentity == trustedIdentity else {
        stateMachine.discovered(reply.presentedIdentity, trust: .identityMismatch)
        return stateMachine.state
      }
      if case .rejected(_, .pairingRequired) = reply.response {
        pendingIdentity = trustedIdentity
        stateMachine.discovered(trustedIdentity, trust: .pairingRequired)
        return stateMachine.state
      }
      guard authorization != nil else {
        stateMachine.transportUnavailable()
        return stateMachine.state
      }
      switch reply.response {
      case .lifecycleStatus(_, let status):
        lifecycleStatus = status
        backendReadiness = status.readiness
      case .status(_, let readiness):
        lifecycleStatus = ControllerLifecycleStatus(
          readiness: readiness,
          cleanupReadiness: .unsupportedController,
          simulation: .noActive
        )
        backendReadiness = readiness
      default:
        stateMachine.transportUnavailable()
        return stateMachine.state
      }
      pendingIdentity = nil
      stateMachine.discovered(trustedIdentity, trust: .trusted)
      return stateMachine.state
    }

    guard case .rejected(_, .pairingRequired) = reply.response else {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    pendingIdentity = reply.presentedIdentity
    stateMachine.discovered(reply.presentedIdentity, trust: .pairingRequired)
    return stateMachine.state
  }

  public func pair(code: String) async -> ControllerLinkState {
    guard let service = currentService, let identity = pendingIdentity else {
      stateMachine.pairingFailed()
      return stateMachine.state
    }

    let request = ControllerLinkRequest.pair(requestID: UUID(), code: code)
    let reply: ControllerTransportReply
    do {
      reply = try await transport.send(
        request,
        to: service,
        expectedIdentity: identity
      )
    } catch {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    guard
      reply.presentedIdentity == identity,
      reply.response.requestID == request.requestID
    else {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }

    guard case .paired(_, let authorization) = reply.response else {
      stateMachine.pairingFailed()
      return stateMachine.state
    }
    do {
      try await authorizationStore.save(authorization)
      try await trust.remember(identity)
    } catch {
      try? await authorizationStore.remove()
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    pendingIdentity = nil
    stateMachine.pairingSucceeded(identity)
    return stateMachine.state
  }

  public func apply(
    requestID: UUID,
    generationID: UUID? = nil,
    latitude: Double,
    longitude: Double,
    requestedLeaseDuration: TimeInterval = 900
  ) async -> ControllerLinkResponse {
    let needsRefresh: Bool
    if case .connected = stateMachine.state {
      needsRefresh = backendReadiness == nil
    } else {
      needsRefresh = true
    }
    if needsRefresh {
      _ = await refresh()
    }

    switch backendReadiness {
    case .ready:
      break
    case .unavailable(let reason):
      return .failed(requestID: requestID, reason: reason)
    case nil:
      return .failed(requestID: requestID, reason: .controllerUnavailable)
    }
    switch lifecycleStatus?.cleanupReadiness {
    case .ready:
      break
    case .unavailable(let reason):
      return .failed(requestID: requestID, reason: reason)
    case .unsupportedController, nil:
      return .failed(requestID: requestID, reason: .controllerUpgradeRequired)
    }
    let response = await sendAuthorized(
      requestID: requestID,
      makeRequest: { authorization in
        .applyLifecycle(
          requestID: requestID,
          generationID: generationID ?? requestID,
          authorization: authorization,
          latitude: latitude,
          longitude: longitude,
          requestedLeaseDuration: requestedLeaseDuration
        )
      },
      accepts: { response in
        switch response {
        case .applied, .appliedLifecycle:
          return true
        default:
          return false
        }
      }
    )
    if case .appliedLifecycle(_, let generationID, let leaseExpiresAt) = response {
      lifecycleStatus = ControllerLifecycleStatus(
        readiness: .ready,
        simulation: .applied(
          generationID: generationID,
          leaseExpiresAt: leaseExpiresAt
        )
      )
      backendReadiness = .ready
    }
    return response
  }

  public func stop(
    requestID: UUID,
    generationID: UUID? = nil
  ) async -> ControllerLinkResponse {
    switch stateMachine.state {
    case .connected:
      break
    default:
      _ = await refresh()
    }

    let response = await sendAuthorized(
      requestID: requestID,
      makeRequest: { authorization in
        .stopLifecycle(
          requestID: requestID,
          generationID: generationID,
          authorization: authorization
        )
      },
      accepts: { response in
        switch response {
        case .stopped, .stoppedLifecycle:
          return true
        default:
          return false
        }
      }
    )
    if case .stoppedLifecycle(_, let generationID) = response {
      lifecycleStatus = ControllerLifecycleStatus(
        readiness: .ready,
        simulation: .stopped(generationID: generationID)
      )
      backendReadiness = .ready
    }
    return response
  }

  public func extendLease(
    requestID: UUID,
    generationID: UUID,
    extensionDuration: TimeInterval = 900
  ) async -> ControllerLinkResponse {
    switch stateMachine.state {
    case .connected:
      break
    default:
      _ = await refresh()
    }

    let response = await sendAuthorized(
      requestID: requestID,
      makeRequest: { authorization in
        .extendLifecycle(
          requestID: requestID,
          generationID: generationID,
          authorization: authorization,
          extensionDuration: extensionDuration
        )
      },
      accepts: { response in
        if case .extendedLifecycle = response { return true }
        return false
      }
    )
    if case .extendedLifecycle(_, let generationID, let leaseExpiresAt) = response {
      lifecycleStatus = ControllerLifecycleStatus(
        readiness: .ready,
        simulation: .applied(
          generationID: generationID,
          leaseExpiresAt: leaseExpiresAt
        )
      )
      backendReadiness = .ready
    }
    return response
  }

  public func currentState() -> ControllerLinkState {
    stateMachine.state
  }

  public func currentBackendReadiness() -> ControllerBackendReadiness? {
    backendReadiness
  }

  public func currentLifecycleStatus() -> ControllerLifecycleStatus? {
    lifecycleStatus
  }

  public func refresh() async -> ControllerLinkState {
    guard let currentService else {
      stateMachine.transportUnavailable()
      backendReadiness = nil
      return stateMachine.state
    }
    return await connect(to: currentService)
  }

  public func forgetController() async -> ControllerLinkState {
    do {
      try await trust.forget()
      try await authorizationStore.remove()
    } catch {
      stateMachine.transportUnavailable()
      return stateMachine.state
    }
    currentService = nil
    pendingIdentity = nil
    backendReadiness = nil
    lifecycleStatus = nil
    stateMachine.resetDiscovery()
    return stateMachine.state
  }

  public func disconnected() -> ControllerLinkState {
    stateMachine.disconnected()
    backendReadiness = nil
    lifecycleStatus = nil
    return stateMachine.state
  }

  public func localNetworkPermissionDenied() -> ControllerLinkState {
    stateMachine.localNetworkPermissionDenied()
    backendReadiness = nil
    lifecycleStatus = nil
    return stateMachine.state
  }

  private func sendAuthorized(
    requestID: UUID,
    makeRequest: (ControllerAuthorization) -> ControllerLinkRequest,
    accepts: (ControllerLinkResponse) -> Bool
  ) async -> ControllerLinkResponse {
    guard
      let service = currentService,
      case .connected(let identity) = stateMachine.state
    else {
      return .failed(requestID: requestID, reason: .controllerUnavailable)
    }

    let authorization: ControllerAuthorization
    do {
      guard let storedAuthorization = try await authorizationStore.load() else {
        stateMachine.transportUnavailable()
        return .failed(requestID: requestID, reason: .controllerUnavailable)
      }
      authorization = storedAuthorization
    } catch {
      stateMachine.transportUnavailable()
      return .failed(requestID: requestID, reason: .controllerUnavailable)
    }

    let request = makeRequest(authorization)
    let reply: ControllerTransportReply
    do {
      reply = try await transport.send(
        request,
        to: service,
        expectedIdentity: identity
      )
    } catch {
      stateMachine.transportUnavailable()
      return .failed(requestID: requestID, reason: .controllerUnavailable)
    }

    guard reply.presentedIdentity == identity else {
      stateMachine.discovered(reply.presentedIdentity, trust: .identityMismatch)
      return .failed(requestID: requestID, reason: .responseIdentityMismatch)
    }
    guard reply.response.requestID == requestID else {
      stateMachine.transportUnavailable()
      return .failed(requestID: requestID, reason: .responseIdentityMismatch)
    }
    if accepts(reply.response) {
      return reply.response
    }
    switch reply.response {
    case .failed, .rejected:
      return reply.response
    case .status, .lifecycleStatus, .paired, .applied, .appliedLifecycle,
      .extendedLifecycle,
      .stopped, .stoppedLifecycle:
      stateMachine.transportUnavailable()
      return .failed(requestID: requestID, reason: .responseIdentityMismatch)
    }
  }
}
