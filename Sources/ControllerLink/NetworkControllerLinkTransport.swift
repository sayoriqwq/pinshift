import Foundation
import Network
import Security

public enum ControllerLinkNetworkError: Error, Equatable, Sendable {
  case connectionFailed
  case connectionClosed
  case malformedFrame
  case timedOut
  case tlsIdentityMismatch
}

public struct NetworkControllerLinkTransport: ControllerLinkTransport {
  private let timeoutSeconds: TimeInterval

  public init(timeoutSeconds: TimeInterval = 10) {
    self.timeoutSeconds = timeoutSeconds
  }

  public func send(
    _ request: ControllerLinkRequest,
    to service: ControllerService,
    expectedIdentity: ControllerIdentity?
  ) async throws -> ControllerTransportReply {
    let identityCapture = TLSIdentityCapture()
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_min_tls_protocol_version(
      tls.securityProtocolOptions,
      .TLSv13
    )
    let verifyQueue = DispatchQueue(label: "dev.sayori.pinshift.controller-tls-verify")
    sec_protocol_options_set_verify_block(
      tls.securityProtocolOptions,
      { _, protocolTrust, complete in
        guard
          let identity = try? ControllerIdentity(
            leafCertificateIn: sec_trust_copy_ref(protocolTrust).takeRetainedValue()
          )
        else {
          identityCapture.reject()
          complete(false)
          return
        }
        identityCapture.capture(identity)
        guard expectedIdentity == nil || expectedIdentity == identity else {
          identityCapture.reject()
          complete(false)
          return
        }
        complete(true)
      },
      verifyQueue
    )

    let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    let endpoint = NWEndpoint.service(
      name: service.name,
      type: service.type,
      domain: service.domain ?? "",
      interface: nil
    )
    let connection = NWConnection(to: endpoint, using: parameters)
    let frame = try ControllerLinkFrameCodec.encode(request)

    return try await withCheckedThrowingContinuation { continuation in
      let completion = ControllerLinkCompletion<ControllerTransportReply>(continuation)
      let queue = DispatchQueue(label: "dev.sayori.pinshift.controller-client")
      connection.stateUpdateHandler = { (state: NWConnection.State) in
        switch state {
        case .ready:
          connection.send(
            content: frame,
            completion: .contentProcessed { error in
              if error != nil {
                completion.resume(throwing: ControllerLinkNetworkError.connectionFailed)
                connection.cancel()
                return
              }
              receiveControllerFrame(on: connection) { result in
                defer { connection.cancel() }
                do {
                  let data = try result.get()
                  let response = try ControllerLinkFrameCodec.decode(
                    ControllerLinkResponse.self,
                    from: data
                  )
                  guard let identity = identityCapture.identity() else {
                    throw ControllerLinkNetworkError.connectionFailed
                  }
                  completion.resume(
                    returning: ControllerTransportReply(
                      presentedIdentity: identity,
                      response: response
                    )
                  )
                } catch let error as ControllerLinkNetworkError {
                  completion.resume(throwing: error)
                } catch {
                  completion.resume(throwing: ControllerLinkNetworkError.malformedFrame)
                }
              }
            })
        case .failed:
          completion.resume(
            throwing: identityCapture.wasRejected()
              ? ControllerLinkNetworkError.tlsIdentityMismatch
              : ControllerLinkNetworkError.connectionFailed
          )
          connection.cancel()
        case .cancelled:
          completion.resume(throwing: ControllerLinkNetworkError.connectionClosed)
        default:
          break
        }
      }
      connection.start(queue: queue)
      queue.asyncAfter(deadline: .now() + timeoutSeconds) {
        completion.resume(throwing: ControllerLinkNetworkError.timedOut)
        connection.cancel()
      }
    }
  }
}

enum ControllerLinkFrameCodec {
  static let maximumPayloadBytes = 64 * 1_024

  static func encode<Value: Encodable>(_ value: Value) throws -> Data {
    let payload = try JSONEncoder().encode(value)
    guard payload.count > 0, payload.count <= maximumPayloadBytes else {
      throw ControllerLinkNetworkError.malformedFrame
    }
    var length = UInt32(payload.count).bigEndian
    var frame = withUnsafeBytes(of: &length) { Data($0) }
    frame.append(payload)
    return frame
  }

  static func decode<Value: Decodable>(_ type: Value.Type, from frame: Data) throws -> Value {
    guard frame.count >= 4 else {
      throw ControllerLinkNetworkError.malformedFrame
    }
    let length = frame.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    guard length > 0, Int(length) <= maximumPayloadBytes, frame.count == Int(length) + 4 else {
      throw ControllerLinkNetworkError.malformedFrame
    }
    return try JSONDecoder().decode(type, from: frame.dropFirst(4))
  }

  static func payloadLength(in prefix: Data) -> Int {
    guard prefix.count == 4 else { return 0 }
    return Int(prefix.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
  }
}

private final class TLSIdentityCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var storedIdentity: ControllerIdentity?
  private var rejected = false

  func capture(_ identity: ControllerIdentity) {
    lock.lock()
    storedIdentity = identity
    lock.unlock()
  }

  func reject() {
    lock.lock()
    rejected = true
    lock.unlock()
  }

  func identity() -> ControllerIdentity? {
    lock.lock()
    defer { lock.unlock() }
    return storedIdentity
  }

  func wasRejected() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return rejected
  }
}

private final class ControllerLinkCompletion<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, any Error>?

  init(_ continuation: CheckedContinuation<Value, any Error>) {
    self.continuation = continuation
  }

  func resume(returning value: Value) {
    take()?.resume(returning: value)
  }

  func resume(throwing error: any Error) {
    take()?.resume(throwing: error)
  }

  private func take() -> CheckedContinuation<Value, any Error>? {
    lock.lock()
    defer { lock.unlock() }
    let continuation = self.continuation
    self.continuation = nil
    return continuation
  }
}

func receiveControllerFrame(
  on connection: NWConnection,
  completion: @escaping @Sendable (Result<Data, any Error>) -> Void
) {
  connection.receive(minimumIncompleteLength: 4, maximumLength: 4) {
    prefix,
    _,
    isComplete,
    error in
    guard error == nil, !isComplete, let prefix, prefix.count == 4 else {
      completion(.failure(ControllerLinkNetworkError.connectionClosed))
      return
    }
    let length = ControllerLinkFrameCodec.payloadLength(in: prefix)
    guard length > 0, length <= ControllerLinkFrameCodec.maximumPayloadBytes else {
      completion(.failure(ControllerLinkNetworkError.malformedFrame))
      return
    }
    connection.receive(minimumIncompleteLength: length, maximumLength: length) {
      payload,
      _,
      _,
      error in
      guard error == nil, let payload, payload.count == length else {
        completion(.failure(ControllerLinkNetworkError.connectionClosed))
        return
      }
      var frame = prefix
      frame.append(payload)
      completion(.success(frame))
    }
  }
}

func sendControllerResponse(_ response: ControllerLinkResponse, on connection: NWConnection) {
  do {
    let frame = try ControllerLinkFrameCodec.encode(response)
    connection.send(
      content: frame,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  } catch {
    connection.cancel()
  }
}
