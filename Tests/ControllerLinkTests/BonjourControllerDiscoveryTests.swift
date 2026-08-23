import Network
import XCTest
import dnssd

@testable import ControllerLink

final class BonjourControllerDiscoveryTests: XCTestCase {
  func testBrowserEnablesPeerToPeerDiscovery() {
    XCTAssertTrue(BonjourControllerDiscovery.browserParameters().includePeerToPeer)
  }

  func testBrowserReadyAndPolicyDeniedBecomeDistinctPermissionEvents() {
    XCTAssertEqual(
      BonjourControllerDiscovery.event(for: .ready),
      .localNetworkReady
    )
    XCTAssertEqual(
      BonjourControllerDiscovery.event(
        for: .waiting(.dns(DNSServiceErrorType(kDNSServiceErr_PolicyDenied)))
      ),
      .localNetworkDenied
    )
    XCTAssertNil(BonjourControllerDiscovery.event(for: .setup))
  }
}
