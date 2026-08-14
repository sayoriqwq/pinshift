import Network
import XCTest

@testable import ControllerLink

final class NetworkControllerLinkTransportTests: XCTestCase {
  func testBuildsBonjourEndpointForDiscoveredService() {
    let service = ControllerService(
      name: "Mac",
      type: "_pinshift._tcp",
      domain: "local."
    )

    XCTAssertEqual(
      NetworkControllerLinkTransport.endpoint(for: service),
      .service(
        name: "Mac",
        type: "_pinshift._tcp",
        domain: "local.",
        interface: nil
      )
    )
  }

  func testBuildsHostPortEndpointForDirectService() {
    let service = ControllerService(host: "127.0.0.1", port: 48_321)

    XCTAssertEqual(
      NetworkControllerLinkTransport.endpoint(for: service),
      .hostPort(host: "127.0.0.1", port: 48_321)
    )
  }
}
