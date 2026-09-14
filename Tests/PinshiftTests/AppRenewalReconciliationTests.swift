import Foundation
import Testing

@testable import Pinshift

@MainActor
struct AppRenewalReconciliationTests {
  @Test(arguments: [false, true])
  func reconcilesOnlyTheRequestedOperation(pollBeforeFailure: Bool) async throws {
    let identity = try ControllerIdentity(fingerprint: Data(repeating: 0x11, count: 32))
    let authorization = try ControllerAuthorization(bytes: Data(repeating: 0x12, count: 32))
    let transport = RenewalReconciliationTransport(identity: identity)
    let link = TrustedControllerLink(
      trust: ControllerTrust(store: InMemoryControllerTrustStore(identity: identity)),
      authorizationStore: InMemoryControllerAuthorizationStore(authorization: authorization),
      transport: transport)
    _ = await link.connect(to: ControllerService(name: "fixture"))
    let model = ControllerLinkViewModel(link: link)
    model.refreshStatus()
    try await wait { model.canRenewApp }
    model.renewApp()
    let requestID = try await transport.waitForRequest()

    if pollBeforeFailure {
      await transport.publish(AppRenewalStatus(operationID: requestID, phase: .signing))
      model.refreshStatus()
      try await wait { model.renewalStatus?.operationID == requestID }
    }
    await transport.failRequest()
    try await wait { !model.isRequestingRenewal }
    #expect(model.renewalRequestFailed == !pollBeforeFailure)

    if !pollBeforeFailure {
      let older = AppRenewalStatus(operationID: UUID(), phase: .installed,
        installedExpiresAt: Date().addingTimeInterval(86400))
      await transport.publish(older)
      model.refreshStatus()
      try await wait { model.renewalStatus == older }
      #expect(model.renewalRequestFailed)
    }
    let installed = AppRenewalStatus(operationID: requestID, phase: .installed,
      installedExpiresAt: Date().addingTimeInterval(86400))
    await transport.publish(installed)
    model.refreshStatus()
    try await wait { model.renewalStatus == installed }
    #expect(!model.renewalRequestFailed)
  }

  private func wait(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
      if condition() { return }
      try await Task.sleep(for: .milliseconds(5))
    }
    try #require(condition())
  }
}

private actor RenewalReconciliationTransport: ControllerLinkTransport {
  let identity: ControllerIdentity
  private var renewal = AppRenewalStatus()
  private var requestID: UUID?
  private var pending: CheckedContinuation<Void, Never>?

  init(identity: ControllerIdentity) { self.identity = identity }

  func publish(_ status: AppRenewalStatus) { renewal = status }
  func failRequest() { pending?.resume(); pending = nil }

  func waitForRequest() async throws -> UUID {
    for _ in 0..<200 where requestID == nil {
      try await Task.sleep(for: .milliseconds(5))
    }
    return try #require(requestID)
  }

  func send(_ request: ControllerLinkRequest, to service: ControllerService,
    expectedIdentity: ControllerIdentity?) async throws -> ControllerTransportReply {
    let response: ControllerLinkResponse
    if case .renewApp(let id, _) = request {
      requestID = id
      await withCheckedContinuation { pending = $0 }
      response = .failed(requestID: id, reason: .controllerUnavailable)
    } else {
      response = .status(requestID: request.requestID,
        status: ControllerStatus(readiness: .ready, simulation: .idle, renewal: renewal))
    }
    return ControllerTransportReply(presentedIdentity: identity, response: response)
  }
}
