import Foundation
import Network
import Security

public enum TLSControllerServerError: Error, Equatable, Sendable {
  case invalidIdentity
  case listenerFailed
}

public final class TLSControllerServer: @unchecked Sendable {
  private let identity: SecIdentity
  private let session: ControllerServerSession
  private let serviceName: String
  private let queue = DispatchQueue(label: "dev.sayori.pinshift.controller-server")
  private let lock = NSLock()
  private var listener: NWListener?

  public init(
    identity: SecIdentity,
    session: ControllerServerSession,
    serviceName: String = "Pinshift Controller"
  ) {
    self.identity = identity
    self.session = session
    self.serviceName = serviceName
  }

  public func start() async throws {
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      guard let protocolIdentity = sec_identity_create(identity) else {
        continuation.resume(throwing: TLSControllerServerError.invalidIdentity)
        return
      }
      let tls = NWProtocolTLS.Options()
      sec_protocol_options_set_local_identity(
        tls.securityProtocolOptions,
        protocolIdentity
      )
      sec_protocol_options_set_min_tls_protocol_version(
        tls.securityProtocolOptions,
        .TLSv13
      )
      let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())

      do {
        let listener = try NWListener(using: parameters)
        listener.service = NWListener.Service(
          name: serviceName,
          type: ControllerService.serviceType
        )
        lock.lock()
        self.listener = listener
        lock.unlock()

        let completion = ControllerServerStartCompletion(continuation)
        listener.stateUpdateHandler = { state in
          switch state {
          case .ready:
            completion.resume()
          case .failed, .cancelled:
            completion.resume(throwing: TLSControllerServerError.listenerFailed)
          default:
            break
          }
        }
        listener.newConnectionHandler = { [weak self] connection in
          self?.handle(connection)
        }
        listener.start(queue: queue)
      } catch {
        continuation.resume(throwing: TLSControllerServerError.listenerFailed)
      }
    }
  }

  public func stop() {
    lock.lock()
    let listener = self.listener
    self.listener = nil
    lock.unlock()
    listener?.cancel()
  }

  private func handle(_ connection: NWConnection) {
    connection.stateUpdateHandler = { state in
      if case .failed = state {
        connection.cancel()
      }
    }
    connection.start(queue: queue)
    receiveControllerFrame(on: connection) { [session] result in
      do {
        let frame = try result.get()
        let request = try ControllerLinkFrameCodec.decode(
          ControllerLinkRequest.self,
          from: frame
        )
        Task {
          let response = await session.process(request)
          sendControllerResponse(response, on: connection)
        }
      } catch {
        connection.cancel()
      }
    }
  }
}

public enum KeychainTLSIdentityError: Error, Equatable, Sendable {
  case notFound
  case unexpectedStatus(OSStatus)
  case invalidIdentity
}

public enum KeychainTLSIdentity {
  public static func load(label: String) throws -> SecIdentity {
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecAttrLabel: label,
      kSecMatchLimit: kSecMatchLimitOne,
      kSecReturnRef: true,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      throw KeychainTLSIdentityError.notFound
    }
    guard status == errSecSuccess else {
      throw KeychainTLSIdentityError.unexpectedStatus(status)
    }
    guard let identity = result as! SecIdentity? else {
      throw KeychainTLSIdentityError.invalidIdentity
    }
    return identity
  }

  public static func fingerprint(of identity: SecIdentity) throws -> ControllerIdentity {
    var certificate: SecCertificate?
    let status = SecIdentityCopyCertificate(identity, &certificate)
    guard status == errSecSuccess, let certificate else {
      throw KeychainTLSIdentityError.invalidIdentity
    }
    return try ControllerIdentity(certificateDER: SecCertificateCopyData(certificate) as Data)
  }
}

private final class ControllerServerStartCompletion: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?

  init(_ continuation: CheckedContinuation<Void, any Error>) {
    self.continuation = continuation
  }

  func resume() {
    take()?.resume()
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Void, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let continuation = self.continuation
    self.continuation = nil
    return continuation
  }
}
