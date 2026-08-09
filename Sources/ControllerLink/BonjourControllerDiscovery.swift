import Foundation
import Network
import dnssd

public enum ControllerDiscoveryFailure: Equatable, Sendable {
  case multipleControllers
  case transportUnavailable
}

public enum ControllerDiscoveryEvent: Equatable, Sendable {
  case localNetworkReady
  case notFound
  case found(ControllerService)
  case localNetworkDenied
  case failed(ControllerDiscoveryFailure)
}

public protocol ControllerDiscovering: Sendable {
  func events() -> AsyncStream<ControllerDiscoveryEvent>
  func stop()
}

public final class BonjourControllerDiscovery: ControllerDiscovering, @unchecked Sendable {
  private let queue = DispatchQueue(label: "dev.sayori.pinshift.controller-discovery")
  private let lock = NSLock()
  private var browser: NWBrowser?

  public init() {}

  public func events() -> AsyncStream<ControllerDiscoveryEvent> {
    AsyncStream { continuation in
      let browser = NWBrowser(
        for: .bonjour(type: ControllerService.serviceType, domain: nil),
        using: .tcp
      )
      lock.lock()
      self.browser?.cancel()
      self.browser = browser
      lock.unlock()

      browser.stateUpdateHandler = { state in
        if let event = Self.event(for: state) {
          continuation.yield(event)
        }
        switch state {
        case .failed:
          continuation.finish()
        case .cancelled:
          continuation.finish()
        default:
          break
        }
      }
      browser.browseResultsChangedHandler = { results, _ in
        let services = Set(results.compactMap(Self.service(from:)))
        switch services.count {
        case 0:
          continuation.yield(.notFound)
        case 1:
          continuation.yield(.found(services.first!))
        default:
          continuation.yield(.failed(.multipleControllers))
        }
      }
      continuation.onTermination = { @Sendable _ in
        browser.cancel()
      }
      browser.start(queue: queue)
    }
  }

  public func stop() {
    lock.lock()
    let browser = self.browser
    self.browser = nil
    lock.unlock()
    browser?.cancel()
  }

  static func isLocalNetworkPermissionDenied(_ error: NWError) -> Bool {
    switch error {
    case .dns(let code):
      code == kDNSServiceErr_PolicyDenied
    case .posix(let code):
      code == .EACCES
    default:
      false
    }
  }

  static func event(for state: NWBrowser.State) -> ControllerDiscoveryEvent? {
    switch state {
    case .ready:
      .localNetworkReady
    case .waiting(let error) where isLocalNetworkPermissionDenied(error):
      .localNetworkDenied
    case .failed:
      .failed(.transportUnavailable)
    default:
      nil
    }
  }

  private static func service(from result: NWBrowser.Result) -> ControllerService? {
    guard case .service(let name, let type, let domain, _) = result.endpoint else {
      return nil
    }
    return ControllerService(name: name, type: type, domain: domain)
  }
}
