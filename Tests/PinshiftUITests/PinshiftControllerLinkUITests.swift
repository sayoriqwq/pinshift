import XCTest

@MainActor
final class PinshiftControllerLinkUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    addUIInterruptionMonitor(withDescription: "Required app permissions") { alert in
      MainActor.assumeIsolated {
        for title in [
          "Allow", "OK", "Allow While Using App",
          "允许", "好", "使用 App 时允许", "使用 App 期间允许",
        ] {
          let button = alert.buttons[title]
          if button.exists {
            button.tap()
            return true
          }
        }
        return false
      }
    }
  }

  func testDiscoversPairsAndPinsTheMacController() throws {
    guard let pairingCode = ProcessInfo.processInfo.environment["REMOTE_LOCATION_PAIRING_CODE"]
    else {
      throw XCTSkip("A short-lived Mac pairing code is required for this smoke test.")
    }

    let app = pinshiftApp()
    app.launch()
    app.tap()
    openSettings(in: app)

    let connected = connectedStatus(in: app)
    if connected.waitForExistence(timeout: 8) {
      return
    }

    let pairingField = app.textFields["controller-pairing-code"]
    XCTAssertTrue(pairingField.waitForExistence(timeout: 20))
    pairingField.tap()
    pairingField.typeText(pairingCode)
    app.buttons["pair-controller"].tap()

    XCTAssertTrue(connected.waitForExistence(timeout: 20))
  }

  func testPhysicalMapSearchApplyReplaceVerifyAndStop() throws {
    if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
      throw XCTSkip("This end-to-end controller journey runs only on the physical iPhone.")
    }
    guard let pairingCode = ProcessInfo.processInfo.environment["REMOTE_LOCATION_PAIRING_CODE"]
    else {
      throw XCTSkip("A short-lived Mac pairing code is required for this smoke test.")
    }

    let app = pinshiftApp()
    app.launchEnvironment["REMOTE_LOCATION_E2E_SEARCH_FIXTURE"] = "1"
    app.launch()
    app.tap()
    try ensureConnected(app, pairingCode: pairingCode)

    openLocationPicker(in: app)
    XCTAssertTrue(app.otherElements["location-map"].waitForExistence(timeout: 10))
    app.buttons["use-map-center"].tap()
    XCTAssertTrue(
      app.staticTexts["location-selection-confirmation"].waitForExistence(timeout: 5)
    )
    app.buttons["close-location-picker"].tap()
    applyAndWaitForVerification(in: app)

    openLocationPicker(in: app)
    let search = app.textFields["place-search-input"]
    XCTAssertTrue(search.waitForExistence(timeout: 10))
    search.tap()
    search.typeText("fixture")
    app.buttons["search-places"].tap()
    let result = app.buttons["place-search-result"]
    XCTAssertTrue(result.waitForExistence(timeout: 10))
    result.tap()
    XCTAssertTrue(
      app.staticTexts["location-selection-confirmation"].waitForExistence(timeout: 5)
    )
    app.buttons["close-location-picker"].tap()
    applyAndWaitForVerification(in: app)

    let stop = app.buttons["stop-simulation"]
    scroll(upTo: stop, in: app)
    XCTAssertTrue(stop.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(stop, timeout: 10))
    stop.tap()
    let cleared = app.staticTexts.matching(identifier: "stop-status")
      .matching(NSPredicate(format: "label == %@", "Simulated Location cleared"))
      .firstMatch
    XCTAssertTrue(cleared.waitForExistence(timeout: 20))
  }

  private func ensureConnected(_ app: XCUIApplication, pairingCode: String) throws {
    openSettings(in: app)
    let connected = connectedStatus(in: app)
    scroll(upTo: connected, in: app)
    if connected.waitForExistence(timeout: 8) {
      return
    }
    let pairingField = app.textFields["controller-pairing-code"]
    scroll(upTo: pairingField, in: app)
    XCTAssertTrue(pairingField.waitForExistence(timeout: 20))
    pairingField.tap()
    pairingField.typeText(pairingCode)
    app.buttons["pair-controller"].tap()
    XCTAssertTrue(connected.waitForExistence(timeout: 20))
  }

  private func pinshiftApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["REMOTE_LOCATION_E2E_APP_LANGUAGE"] = "en"
    return app
  }

  private func connectedStatus(in app: XCUIApplication) -> XCUIElement {
    app.staticTexts.matching(identifier: "controller-link-status")
      .matching(NSPredicate(format: "label == %@", "Trusted controller connected"))
      .firstMatch
  }

  private func openLocationPicker(in app: XCUIApplication) {
    returnHome(in: app)
    let button = app.buttons["open-location-picker"]
    for _ in 0..<10 where !button.exists {
      primaryScrollContainer(in: app).swipeDown()
    }
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
  }

  private func applyAndWaitForVerification(in app: XCUIApplication) {
    let apply = app.buttons["apply-selected-location"]
    scroll(upTo: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertTrue(waitUntilEnabled(apply, timeout: 15))
    apply.tap()

    let verified = app.staticTexts.matching(identifier: "simulation-status")
      .matching(
        NSPredicate(format: "label == %@", "Verified by a fresh observation in this app")
      )
      .firstMatch
    scroll(upTo: verified, in: app)
    XCTAssertTrue(verified.waitForExistence(timeout: 25))
  }

  private func scroll(upTo element: XCUIElement, in app: XCUIApplication) {
    let scrollContainer = primaryScrollContainer(in: app)
    for _ in 0..<10 where !element.exists {
      scrollContainer.swipeUp()
    }
  }

  private func openSettings(in app: XCUIApplication) {
    if app.navigationBars["Settings"].exists || app.navigationBars["设置"].exists {
      return
    }

    let settings = app.buttons["open-settings"]
    XCTAssertTrue(settings.waitForExistence(timeout: 5))
    settings.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["settings-list"].waitForExistence(timeout: 5)
    )
  }

  private func returnHome(in app: XCUIApplication) {
    if app.descendants(matching: .any)["pinshift-home"].exists {
      return
    }

    let back = app.navigationBars.buttons
      .matching(NSPredicate(format: "label == %@", "Pinshift"))
      .firstMatch
    XCTAssertTrue(back.waitForExistence(timeout: 5))
    back.tap()
    XCTAssertTrue(
      app.descendants(matching: .any)["pinshift-home"].waitForExistence(timeout: 5)
    )
  }

  private func primaryScrollContainer(in app: XCUIApplication) -> XCUIElement {
    let settings = app.collectionViews["settings-list"]
    if settings.exists {
      return settings
    }

    let home = app.scrollViews["pinshift-home"]
    if home.exists {
      return home
    }

    if app.collectionViews.firstMatch.exists {
      return app.collectionViews.firstMatch
    }
    return app.scrollViews.firstMatch
  }

  private func waitUntilEnabled(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "enabled == true"),
      object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }
}
