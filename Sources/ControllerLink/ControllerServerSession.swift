import Foundation

#if SWIFT_PACKAGE
  import SimulationDiagnostics
#endif

public actor ControllerServerSession {
  private let identity: ControllerIdentity
  private let pairingAuthority: PairingCodeAuthority
  private let authorizationStore: any ControllerAuthorizationStore
  private let commandHandler: any ControllerCommandHandling
  private let diagnostics: SimulationDiagnosticRecorder?
  private let now: @Sendable () -> Date
  private let makeAuthorization: @Sendable () throws -> ControllerAuthorization

  public init(
    identity: ControllerIdentity,
    pairingAuthority: PairingCodeAuthority,
    authorizationStore: any ControllerAuthorizationStore,
    commandHandler: any ControllerCommandHandling = UnavailableControllerCommandHandler(),
    now: @escaping @Sendable () -> Date = Date.init,
    makeAuthorization: @escaping @Sendable () throws -> ControllerAuthorization = {
      try ControllerAuthorization.generate()
    },
    diagnostics: SimulationDiagnosticRecorder? = nil
  ) {
    self.identity = identity
    self.pairingAuthority = pairingAuthority
    self.authorizationStore = authorizationStore
    self.commandHandler = commandHandler
    self.diagnostics = diagnostics
    self.now = now
    self.makeAuthorization = makeAuthorization
  }

  public func process(_ request: ControllerLinkRequest) async -> ControllerLinkResponse {
    await record(
      kind: "controller.link.request.received",
      requestID: request.requestID,
      fields: requestFields(request)
    )
    let response: ControllerLinkResponse
    switch request {
    case .status(let requestID, let presentedAuthorization):
      guard let presentedAuthorization,
        await isAuthorized(presentedAuthorization)
      else {
        response = .rejected(requestID: requestID, reason: .pairingRequired)
        break
      }
      response = await processCommand(.status(requestID: requestID))

    case .pair(let requestID, let code):
      do {
        _ = try await pairingAuthority.redeem(
          code: code,
          presentedIdentity: identity,
          at: now()
        )
        let authorization = try makeAuthorization()
        try await authorizationStore.save(authorization)
        response = .paired(requestID: requestID, authorization: authorization)
      } catch let error as PairingCodeError {
        response = .rejected(requestID: requestID, reason: map(error))
      } catch {
        response = .rejected(requestID: requestID, reason: .invalidRequest)
      }

    case .apply(
      let requestID,
      let presentedAuthorization,
      let latitude,
      let longitude
    ):
      guard await isAuthorized(presentedAuthorization) else {
        response = .rejected(requestID: requestID, reason: .authorizationFailed)
        break
      }
      guard
        latitude.isFinite,
        longitude.isFinite,
        (-90.0...90.0).contains(latitude),
        (-180.0...180.0).contains(longitude)
      else {
        response = .failed(requestID: requestID, reason: .invalidCoordinate)
        break
      }
      response = await processCommand(
        .apply(requestID: requestID, latitude: latitude, longitude: longitude)
      )

    case .clear(
      let requestID,
      let presentedAuthorization,
      let targetOperationID
    ):
      guard await isAuthorized(presentedAuthorization) else {
        response = .rejected(requestID: requestID, reason: .authorizationFailed)
        break
      }
      response = await processCommand(
        .clear(
          requestID: requestID,
          targetOperationID: targetOperationID
        )
      )
    }
    await record(
      kind: "controller.link.response.sent",
      requestID: response.requestID,
      fields: responseFields(response)
    )
    return response
  }

  private func processCommand(_ command: ControllerCommand) async -> ControllerLinkResponse {
    let result = await commandHandler.handle(command)
    guard result.requestID == command.requestID else {
      return .failed(
        requestID: command.requestID,
        reason: .responseIdentityMismatch
      )
    }
    switch result {
    case .status(let requestID, let status):
      guard case .status = command else {
        return .failed(requestID: command.requestID, reason: .responseIdentityMismatch)
      }
      return .status(requestID: requestID, status: status)
    case .applied(let requestID, let automaticClearAt):
      guard case .apply = command else {
        return .failed(requestID: command.requestID, reason: .responseIdentityMismatch)
      }
      return .applied(requestID: requestID, automaticClearAt: automaticClearAt)
    case .cleared(let requestID):
      guard case .clear = command else {
        return .failed(requestID: command.requestID, reason: .responseIdentityMismatch)
      }
      return .cleared(requestID: requestID)
    case .failed(let requestID, let reason):
      if case .status = command {
        return .status(
          requestID: requestID,
          status: ControllerStatus(
            readiness: .unavailable(reason),
            simulation: .idle
          )
        )
      }
      return .failed(requestID: requestID, reason: reason)
    }
  }

  private func isAuthorized(_ presentedAuthorization: ControllerAuthorization) async -> Bool {
    do {
      guard let storedAuthorization = try await authorizationStore.load() else {
        return false
      }
      return storedAuthorization.securelyMatches(presentedAuthorization)
    } catch {
      return false
    }
  }

  private func requestFields(_ request: ControllerLinkRequest) -> SimulationDiagnosticFields {
    switch request {
    case .status:
      return ["command": .text("status")]
    case .pair:
      return ["command": .text("pair")]
    case .apply(_, _, let latitude, let longitude):
      return [
        "command": .text("apply"),
        "latitude": .number(latitude),
        "longitude": .number(longitude),
      ]
    case .clear:
      return ["command": .text("clear")]
    }
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

  private func record(
    kind: String,
    requestID: UUID,
    fields: SimulationDiagnosticFields
  ) async {
    await diagnostics?.record(kind: kind, requestID: requestID, fields: fields)
  }

  private func map(_ error: PairingCodeError) -> ControllerLinkRejection {
    switch error {
    case .invalidFormat, .incorrect:
      .invalidPairingCode
    case .identityMismatch:
      .identityMismatch
    case .expired:
      .expiredPairingCode
    case .alreadyUsed:
      .pairingCodeAlreadyUsed
    case .tooManyAttempts:
      .tooManyPairingAttempts
    }
  }
}
