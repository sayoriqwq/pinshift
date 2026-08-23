import Foundation

public struct ControllerService: Codable, Hashable, Sendable {
  public static let serviceType = "_pinshift._tcp"

  public let name: String
  public let type: String
  public let domain: String?
  public let host: String?
  public let port: UInt16?

  public init(
    name: String,
    type: String = ControllerService.serviceType,
    domain: String? = nil
  ) {
    self.name = name
    self.type = type
    self.domain = domain
    host = nil
    port = nil
  }

  public init(host: String, port: UInt16) {
    name = host
    type = ControllerService.serviceType
    domain = nil
    self.host = host
    self.port = port
  }
}

public enum ControllerLinkRequest: Codable, Equatable, Sendable {
  case status(requestID: UUID, authorization: ControllerAuthorization?)
  case pair(requestID: UUID, code: String)
  case apply(
    requestID: UUID,
    authorization: ControllerAuthorization,
    latitude: Double,
    longitude: Double
  )
  case clear(
    requestID: UUID,
    authorization: ControllerAuthorization
  )

  public var requestID: UUID {
    switch self {
    case .status(let requestID, _),
      .pair(let requestID, _),
      .apply(let requestID, _, _, _),
      .clear(let requestID, _):
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
  case status(requestID: UUID, status: ControllerStatus)
  case paired(requestID: UUID, authorization: ControllerAuthorization)
  case applied(requestID: UUID, automaticClearAt: Date)
  case cleared(requestID: UUID)
  case failed(requestID: UUID, reason: ControllerCommandFailure)
  case rejected(requestID: UUID, reason: ControllerLinkRejection)

  public var requestID: UUID {
    switch self {
    case .status(let requestID, _),
      .paired(let requestID, _),
      .applied(let requestID, _),
      .cleared(let requestID),
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
  private var controllerStatus: ControllerStatus?
  private var mutationRevision: UInt64 = 0

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
    controllerStatus = nil
    let expectedMutationRevision = mutationRevision
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
    let request = ControllerLinkRequest.status(
      requestID: UUID(),
      authorization: authorization
    )
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
      guard authorization != nil, case .status(_, let status) = reply.response else {
        stateMachine.transportUnavailable()
        return stateMachine.state
      }
      if mutationRevision == expectedMutationRevision {
        controllerStatus = status
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
    latitude: Double,
    longitude: Double
  ) async -> ControllerLinkResponse {
    let revision = beginMutation()
    if case .connected = stateMachine.state {
      // Historical status is deliberately not an Apply precondition.
    } else {
      _ = await refresh()
    }

    let response = await sendAuthorized(
      requestID: requestID,
      makeRequest: { authorization in
        .apply(
          requestID: requestID,
          authorization: authorization,
          latitude: latitude,
          longitude: longitude
        )
      },
      accepts: { response in
        if case .applied = response { return true }
        return false
      }
    )
    if case .applied(_, let automaticClearAt) = response,
      mutationRevision == revision
    {
      controllerStatus = ControllerStatus(
        readiness: .ready,
        simulation: .active(
          operationID: requestID,
          latitude: latitude,
          longitude: longitude,
          automaticClearAt: automaticClearAt
        )
      )
    }
    return response
  }

  public func clear(requestID: UUID) async -> ControllerLinkResponse {
    let revision = beginMutation()
    if case .connected = stateMachine.state {
      // Clear is a convenience and needs no historical-state precondition.
    } else {
      _ = await refresh()
    }

    let response = await sendAuthorized(
      requestID: requestID,
      makeRequest: { authorization in
        .clear(
          requestID: requestID,
          authorization: authorization
        )
      },
      accepts: { response in
        if case .cleared = response { return true }
        return false
      }
    )
    if case .cleared = response, mutationRevision == revision {
      controllerStatus = ControllerStatus(readiness: .ready, simulation: .idle)
    }
    return response
  }

  public func currentState() -> ControllerLinkState {
    stateMachine.state
  }

  public func currentStatus() -> ControllerStatus? {
    controllerStatus
  }

  public func refresh() async -> ControllerLinkState {
    guard let currentService else {
      stateMachine.transportUnavailable()
      controllerStatus = nil
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
    controllerStatus = nil
    stateMachine.resetDiscovery()
    return stateMachine.state
  }

  public func disconnected() -> ControllerLinkState {
    stateMachine.disconnected()
    controllerStatus = nil
    return stateMachine.state
  }

  public func localNetworkPermissionDenied() -> ControllerLinkState {
    stateMachine.localNetworkPermissionDenied()
    controllerStatus = nil
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
    case .status, .paired, .applied, .cleared:
      stateMachine.transportUnavailable()
      return .failed(requestID: requestID, reason: .responseIdentityMismatch)
    }
  }

  private func beginMutation() -> UInt64 {
    mutationRevision &+= 1
    return mutationRevision
  }
}
