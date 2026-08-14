import CoreLocation
import Foundation
import XCTest

@MainActor
final class PinshiftUITests: XCTestCase {
  override func setUp() {
    super.setUp()
    continueAfterFailure = false
    MainActor.assumeIsolated {
      XCUIDevice.shared.location = nil
    }
    addUIInterruptionMonitor(withDescription: "Location permission") { alert in
      MainActor.assumeIsolated {
        for title in ["Allow While Using App", "使用 App 时允许", "使用 App 期间允许"] {
          let allow = alert.buttons[title]
          if allow.exists {
            allow.tap()
            return true
          }
        }

        let localizedAllow = alert.buttons.matching(
          NSPredicate(
            format:
              "(label CONTAINS[c] %@ AND NOT label BEGINSWITH[c] %@) OR (label CONTAINS %@ AND NOT label CONTAINS %@)",
            "Allow",
            "Don",
            "允许",
            "不允许"
          )
        ).firstMatch
        if localizedAllow.exists {
          localizedAllow.tap()
          return true
        }
        return false
      }
    }
  }

  override func tearDown() {
    MainActor.assumeIsolated {
      XCUIDevice.shared.location = nil
    }
    super.tearDown()
  }

  func testPinshiftAppExposesPublicGateObservationSeam() {
    let app = pinshiftApp()
    app.launch()
    app.tap()
    openSettings(in: app)

    let latitude = app.textFields["latitude-input"]
    scrollUp(until: latitude, in: app)
    XCTAssertTrue(latitude.waitForExistence(timeout: 5))
    XCTAssertTrue(app.textFields["longitude-input"].exists)
    XCTAssertTrue(app.buttons["save-selection"].exists)

    let observedLatitude = app.staticTexts["observed-latitude"]
    scrollUp(until: observedLatitude, in: app)
    XCTAssertTrue(observedLatitude.waitForExistence(timeout: 5))

    let observedLongitude = app.staticTexts["observed-longitude"]
    scrollUp(until: observedLongitude, in: app)
    XCTAssertTrue(observedLongitude.waitForExistence(timeout: 5))

    let observationSource = app.staticTexts["observation-source"]
    scrollUp(until: observationSource, in: app)
    XCTAssertTrue(observationSource.waitForExistence(timeout: 5))

    let startObservation = app.buttons["start-observation-window"]
    scrollUp(until: startObservation, in: app)
    XCTAssertTrue(startObservation.waitForExistence(timeout: 5))

    let matchStatus = app.staticTexts["match-status"]
    scrollUp(until: matchStatus, in: app)
    XCTAssertTrue(matchStatus.waitForExistence(timeout: 5))
  }

  func testPinshiftMapFirstHomeKeepsSecondaryToolsInSettings() {
    let app = selectedLocationFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_LOCATION_PERMISSION"] = "allowed"
    app.launchEnvironment["PINSHIFT_E2E_LOCAL_NETWORK_PERMISSION"] = "allowed"
    app.launch()
    app.tap()

    XCTAssertTrue(
      app.descendants(matching: .any)["home-map"].waitForExistence(timeout: 5)
    )
    XCTAssertTrue(app.buttons["open-location-picker"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["open-settings"].waitForExistence(timeout: 5))

    let homeScreenshot = XCTAttachment(screenshot: app.screenshot())
    homeScreenshot.name = "Pinshift home"
    homeScreenshot.lifetime = .keepAlways
    add(homeScreenshot)

    let primaryAction = app.buttons["apply-selected-location"]
    scrollUp(until: primaryAction, in: app)
    XCTAssertTrue(primaryAction.waitForExistence(timeout: 5))

    openSettings(in: app)
    XCTAssertTrue(app.staticTexts["controller-link-status"].waitForExistence(timeout: 5))
    XCTAssertTrue(
      app.segmentedControls["language-selector"].waitForExistence(timeout: 5)
    )

    let settingsScreenshot = XCTAttachment(screenshot: app.screenshot())
    settingsScreenshot.name = "Pinshift settings"
    settingsScreenshot.lifetime = .keepAlways
    add(settingsScreenshot)
  }

  func testLocalDiagnosticsAreaSupportsExportAndClearWithoutChangingSimulationState() {
    let app = permissionFixtureApp(location: "allowed", localNetwork: "allowed")
    app.launch()
    app.tap()

    let initialSimulationStatus =
      app.staticTexts.matching(identifier: "simulation-status").firstMatch
    scrollUp(until: initialSimulationStatus, in: app)
    XCTAssertTrue(initialSimulationStatus.waitForExistence(timeout: 5))
    let initialSimulationStatusLabel = initialSimulationStatus.label
    scrollToTop(in: app)

    openSettings(in: app)

    let status = app.staticTexts["diagnostics-status"]
    scrollUp(until: status, in: app)
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertTrue(waitForLabel(status, endingWith: "Enabled", timeout: 5))
    let size = app.staticTexts["diagnostics-size"]
    scrollUp(until: size, in: app)
    XCTAssertTrue(size.exists)
    let eventCount = app.staticTexts["diagnostics-event-count"]
    scrollUp(until: eventCount, in: app)
    XCTAssertTrue(eventCount.exists)

    let clear = app.buttons["diagnostics-clear"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.exists)
    clear.tap()
    XCTAssertTrue(
      waitForLabel(
        eventCount,
        endingWith: "0",
        timeout: 5
      )
    )

    returnHome(in: app)
    let simulationStatus = app.staticTexts.matching(identifier: "simulation-status").firstMatch
    scrollToTop(in: app)
    scrollUp(until: simulationStatus, in: app)
    XCTAssertTrue(simulationStatus.waitForExistence(timeout: 5))
    XCTAssertEqual(simulationStatus.label, initialSimulationStatusLabel)

    openSettings(in: app)
    scrollToTop(in: app)
    let export = app.buttons["diagnostics-export"]
    scrollUp(until: export, in: app)
    XCTAssertTrue(export.waitForExistence(timeout: 5))
    export.tap()
  }

  func testDiagnosticsSurviveFixtureApplyObservationClearAndAppRelaunch() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_DIAGNOSTICS_ARTIFACT_FIXTURE"] = "1"
    app.launch()
    app.tap()
    waitForDiagnostics(in: app)

    let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    selectAndBeginObservation(of: coordinate, in: app)
    applyAndVerifySimulation(of: coordinate, in: app)

    let clear = app.buttons["clear-simulation"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    clear.tap()
    let clearStatus = app.staticTexts["clear-status"]
    XCTAssertTrue(clearStatus.waitForExistence(timeout: 5))
    XCTAssertEqual(clearStatus.label, "Simulated Location cleared")

    guard let firstArtifact = exportDiagnosticsArtifact(in: app) else { return }
    guard let requestIDs = assertNormalDiagnosticSequence(firstArtifact) else {
      return
    }

    app.terminate()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_DIAGNOSTICS_ARTIFACT_FIXTURE"] = "1"
    app.launch()
    app.tap()

    waitForDiagnostics(in: app)
    guard let relaunchedArtifact = exportDiagnosticsArtifact(in: app) else { return }
    XCTAssertEqual(relaunchedArtifact.schemaVersion, firstArtifact.schemaVersion)
    XCTAssertEqual(relaunchedArtifact.side, firstArtifact.side)
    XCTAssertEqual(relaunchedArtifact.generationID, firstArtifact.generationID)
    XCTAssertGreaterThanOrEqual(
      relaunchedArtifact.events.count,
      firstArtifact.events.count
    )
    XCTAssertTrue(
      firstArtifact.events.allSatisfy { original in
        relaunchedArtifact.events.contains {
          $0.sessionID == original.sessionID
            && $0.sequence == original.sequence
            && $0.kind == original.kind
        }
      }
    )
    XCTAssertTrue(
      relaunchedArtifact.events.contains {
        $0.kind == "app.lifecycle.launched"
          && $0.requestID == nil
          && $0.sessionID != firstArtifact.events.last?.sessionID
      }
    )
    XCTAssertTrue(
      relaunchedArtifact.events.contains {
        $0.requestID == requestIDs.apply
      }
    )
    XCTAssertTrue(
      relaunchedArtifact.events.contains {
        $0.requestID == requestIDs.clear
      }
    )
    if let lastOriginal = firstArtifact.events.last,
      let lastOriginalIndex = relaunchedArtifact.events.firstIndex(where: {
        $0.sessionID == lastOriginal.sessionID
          && $0.sequence == lastOriginal.sequence
          && $0.kind == lastOriginal.kind
      }),
      let relaunchedLifecycleIndex = relaunchedArtifact.events.lastIndex(where: {
        $0.kind == "app.lifecycle.launched"
          && $0.sessionID != firstArtifact.events.last?.sessionID
      })
    {
      XCTAssertLessThan(lastOriginalIndex, relaunchedLifecycleIndex)
    } else {
      XCTFail("The relaunch lifecycle event was not appended after persisted events.")
    }
  }

  func testFailedClearStaysNonBlockingAndRecordsAutomaticClearFallback() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FAILURE_FIXTURE"] = "failed-clear"
    app.launchEnvironment["PINSHIFT_E2E_DIAGNOSTICS_ARTIFACT_FIXTURE"] = "1"
    app.launch()
    app.tap()
    waitForDiagnostics(in: app)
    clearDiagnostics(in: app)

    let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    selectAndBeginObservation(of: coordinate, in: app)
    applyAndVerifySimulation(of: coordinate, in: app)

    let clear = app.buttons["clear-simulation"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    clear.tap()

    let clearStatus = app.staticTexts["clear-status"]
    XCTAssertTrue(clearStatus.waitForExistence(timeout: 5))
    XCTAssertEqual(clearStatus.label, "Clear could not be confirmed")
    XCTAssertFalse(
      app.staticTexts.matching(
        NSPredicate(
          format: "identifier == %@ AND label == %@",
          "clear-status",
          "Simulated Location cleared"
        )
      ).firstMatch.exists
    )

    let simulationStatus = app.staticTexts.matching(identifier: "simulation-status")
      .matching(
        NSPredicate(
          format: "label == %@",
          "Verified by a fresh observation in this app"
        )
      )
      .firstMatch
    XCTAssertTrue(simulationStatus.waitForExistence(timeout: 5))

    openLocationPicker(in: app)
    XCTAssertTrue(app.buttons["use-map-center"].waitForExistence(timeout: 5))
    app.buttons["close-location-picker"].tap()
    let replacementApply = app.buttons["apply-selected-location"]
    scrollUp(until: replacementApply, in: app)
    XCTAssertTrue(replacementApply.waitForExistence(timeout: 5))
    XCTAssertTrue(replacementApply.isEnabled)

    openSettings(in: app)
    scrollToTop(in: app)
    let controllerStatus = app.staticTexts["controller-link-status"]
    XCTAssertTrue(controllerStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(controllerStatus.label.hasSuffix("Mac connected"))

    guard let artifact = exportDiagnosticsArtifact(in: app) else { return }
    let kinds = artifact.events.map(\.kind)
    XCTAssertTrue(kinds.contains("app.controller-link.clear-started"))
    XCTAssertTrue(kinds.contains("app.controller-link.clear-response"))
    XCTAssertTrue(kinds.contains("app.clear.unconfirmed"))
    XCTAssertFalse(kinds.contains("app.clear.acknowledged"))
    guard
      let clearStartedIndex = artifact.events.lastIndex(where: {
        $0.kind == "app.clear.started"
      }),
      let linkResponseIndex = index(
        of: "app.controller-link.clear-response",
        after: clearStartedIndex,
        in: artifact.events
      ),
      let failedIndex = index(
        of: "app.clear.unconfirmed",
        after: linkResponseIndex,
        in: artifact.events
      ),
      let clearRequestID = artifact.events[clearStartedIndex].requestID
    else {
      XCTFail("The exported artifact did not contain the ordered Clear failure.")
      return
    }
    XCTAssertLessThan(clearStartedIndex, linkResponseIndex)
    XCTAssertLessThan(linkResponseIndex, failedIndex)
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.clear.response" && $0.requestID == clearRequestID
      }
    )
  }

  func testLanguageSelectorSwitchesImmediatelyAndPersistsTheChoice() {
    let app = permissionFixtureApp(location: "allowed", localNetwork: "allowed")
    app.launchEnvironment["PINSHIFT_E2E_APP_LANGUAGE"] = "en"
    app.launch()
    openSettings(in: app)

    let selector = app.segmentedControls["language-selector"]
    XCTAssertTrue(selector.waitForExistence(timeout: 5))
    XCTAssertTrue(selector.buttons["English"].isSelected)
    XCTAssertTrue(app.staticTexts["Mac Controller"].waitForExistence(timeout: 5))

    let localNetworkStatus = app.staticTexts["local-network-permission-status"]
    XCTAssertTrue(localNetworkStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(waitForLabel(localNetworkStatus, endingWith: "Allowed"))

    selector.buttons["简体中文"].tap()

    XCTAssertTrue(selector.buttons["简体中文"].isSelected)
    XCTAssertTrue(app.staticTexts["Mac 模拟控制器"].waitForExistence(timeout: 5))
    XCTAssertTrue(waitForLabel(localNetworkStatus, endingWith: "已允许"))

    app.terminate()
    app.launchEnvironment.removeValue(forKey: "PINSHIFT_E2E_APP_LANGUAGE")
    app.launch()
    openSettings(in: app)

    let persistedSelector = app.segmentedControls["language-selector"]
    XCTAssertTrue(persistedSelector.waitForExistence(timeout: 5))
    XCTAssertTrue(persistedSelector.buttons["简体中文"].isSelected)
    XCTAssertTrue(app.staticTexts["Mac 模拟控制器"].waitForExistence(timeout: 5))

    persistedSelector.buttons["English"].tap()
    XCTAssertTrue(persistedSelector.buttons["English"].isSelected)
  }

  func testSavedLocationsPersistSelectionRenameAndDeleteWithoutApplying() {
    let app = savedLocationsFixtureApp()
    app.launch()
    app.tap()

    let coordinateA = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    let coordinateB = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
    saveNamedLocation("Shanghai", coordinate: coordinateA, in: app)
    saveNamedLocation("Berlin", coordinate: coordinateB, in: app)

    let firstRow = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    let secondRow = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    XCTAssertTrue(firstRow.waitForExistence(timeout: 5))
    XCTAssertTrue(secondRow.waitForExistence(timeout: 5))
    XCTAssertTrue(firstRow.label.contains("Shanghai"))
    XCTAssertTrue(firstRow.label.contains("31.230400"))
    XCTAssertTrue(secondRow.label.contains("Berlin"))
    XCTAssertTrue(secondRow.label.contains("52.520000"))
    XCTAssertFalse(firstRow.isSelected)
    XCTAssertTrue(secondRow.isSelected)

    assertSavedLocationSelectionIsInactive(in: app)

    app.terminate()
    app.launch()
    app.tap()

    let persistedFirstRow = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    XCTAssertTrue(persistedFirstRow.waitForExistence(timeout: 5))
    XCTAssertFalse(persistedFirstRow.isSelected)
    persistedFirstRow.tap()
    XCTAssertTrue(persistedFirstRow.isSelected)
    assertSelectedCoordinate(coordinateA, source: "Saved Location", in: app)
    assertSavedLocationSelectionIsInactive(in: app)

    let persistedSecondRow = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    XCTAssertTrue(persistedSecondRow.waitForExistence(timeout: 5))
    XCTAssertFalse(persistedSecondRow.isSelected)
    persistedSecondRow.tap()
    XCTAssertFalse(persistedFirstRow.isSelected)
    XCTAssertTrue(persistedSecondRow.isSelected)
    assertSelectedCoordinate(coordinateB, source: "Saved Location", in: app)
    assertSavedLocationSelectionIsInactive(in: app)

    let rename = savedLocationButton(
      withPrefix: "saved-location-rename-",
      in: app,
      index: 0
    )
    scrollUp(until: rename, in: app)
    XCTAssertTrue(rename.waitForExistence(timeout: 5))
    rename.tap()
    let renameAlert = app.alerts["Rename Saved Location"]
    XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
    let renameField = renameAlert.textFields.firstMatch
    XCTAssertTrue(renameField.waitForExistence(timeout: 5))
    replaceRenameText(in: renameField, with: "Shanghai QA", in: renameAlert)
    app.buttons["saved-location-confirm-rename"].firstMatch.tap()
    let renamedLocation = app.buttons
      .matching(NSPredicate(format: "label CONTAINS %@", "Shanghai QA"))
      .firstMatch
    scrollUp(until: renamedLocation, in: app)
    XCTAssertTrue(renamedLocation.waitForExistence(timeout: 5))
    assertSelectedCoordinate(coordinateB, source: "Saved Location", in: app)
    assertSavedLocationSelectionIsInactive(in: app)

    let deleteSecond = savedLocationButton(
      withPrefix: "saved-location-delete-",
      in: app,
      index: 1
    )
    scrollUp(until: deleteSecond, in: app)
    XCTAssertTrue(deleteSecond.waitForExistence(timeout: 5))
    deleteSecond.tap()
    XCTAssertTrue(
      app.buttons["saved-location-confirm-delete"].firstMatch.waitForExistence(timeout: 5)
    )
    app.buttons["saved-location-confirm-delete"].firstMatch.tap()
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Berlin"))
        .firstMatch.waitForExistence(timeout: 2)
    )
    assertSelectedCoordinate(coordinateB, source: "Saved Location", in: app)
    assertSavedLocationSelectionIsInactive(in: app)

    app.terminate()
    app.launch()
    app.tap()
    let persistedRenamed = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    XCTAssertTrue(persistedRenamed.waitForExistence(timeout: 5))
    XCTAssertTrue(
      persistedRenamed.label.contains("Shanghai QA")
    )
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Berlin"))
        .firstMatch.waitForExistence(timeout: 2)
    )
  }

  func testSavedLocationSelectionAndDeletionPreserveAppliedSimulationUntilReplacementOrClear()
  {
    let app = savedLocationsFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.tap()

    let coordinateA = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    let coordinateB = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
    saveNamedLocation("Shanghai", coordinate: coordinateA, in: app)
    saveNamedLocation("Berlin", coordinate: coordinateB, in: app)

    let first = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    scrollUp(until: first, in: app)
    XCTAssertTrue(first.waitForExistence(timeout: 5))
    first.tap()
    assertSelectedCoordinate(coordinateA, source: "Saved Location", in: app)

    applyAndAcknowledgeSimulation(in: app)
    assertAppliedSimulationRemainsActive(in: app)

    let second = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    scrollUp(until: second, in: app)
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    second.tap()
    assertSelectedCoordinate(coordinateB, source: "Saved Location", in: app)
    assertAppliedSimulationRemainsActive(in: app)

    let deleteSecond = savedLocationButton(
      withPrefix: "saved-location-delete-",
      in: app,
      index: 1
    )
    scrollUp(until: deleteSecond, in: app)
    XCTAssertTrue(deleteSecond.waitForExistence(timeout: 5))
    deleteSecond.tap()
    XCTAssertTrue(
      app.buttons["saved-location-confirm-delete"].firstMatch.waitForExistence(timeout: 5)
    )
    app.buttons["saved-location-confirm-delete"].firstMatch.tap()
    XCTAssertFalse(
      app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Berlin"))
        .firstMatch.waitForExistence(timeout: 2)
    )
    assertSelectedCoordinate(coordinateB, source: "Saved Location", in: app)
    assertAppliedSimulationRemainsActive(in: app)

    let clear = app.buttons["clear-simulation"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    XCTAssertTrue(clear.isEnabled)
    clear.tap()

    let cleared = app.staticTexts.matching(identifier: "clear-status")
      .matching(NSPredicate(format: "label == %@", "Simulated Location cleared"))
      .firstMatch
    XCTAssertTrue(cleared.waitForExistence(timeout: 5))
    let inactive = app.staticTexts.matching(identifier: "simulation-status")
      .matching(NSPredicate(format: "label == %@", "Selected — waiting to apply"))
      .firstMatch
    XCTAssertTrue(inactive.waitForExistence(timeout: 5))
    openSettings(in: app)
    scrollToTop(in: app)
    let inactiveAppliedStatus = app.staticTexts["applied-simulation-status"]
    XCTAssertTrue(inactiveAppliedStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(inactiveAppliedStatus.label.hasSuffix("Inactive"))
  }

  func testSavedLocationSaveFailureKeepsCollectionAndSimulationState() {
    let app = savedLocationsFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_APP_LANGUAGE"] = "zh-Hans"
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_SAVED_LOCATIONS_FAIL_ON_SAVE_NUMBER"] = "3"
    app.launch()
    app.tap()

    let coordinateA = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    let coordinateB = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
    saveNamedLocation("Shanghai", coordinate: coordinateA, in: app)
    saveNamedLocation("Berlin", coordinate: coordinateB, in: app)

    let second = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    scrollUp(until: second, in: app)
    XCTAssertTrue(second.waitForExistence(timeout: 5))
    second.tap()
    assertSelectedCoordinate(coordinateB, source: "已保存地点", in: app)

    applyAndAcknowledgeSimulation(in: app, acknowledgedLabelSuffix: "已确认")
    let firstBeforeFailure = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    let secondBeforeFailure = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    XCTAssertTrue(firstBeforeFailure.label.contains("Shanghai"))
    XCTAssertTrue(secondBeforeFailure.label.contains("Berlin"))
    let firstLabelBeforeFailure = firstBeforeFailure.label
    let secondLabelBeforeFailure = secondBeforeFailure.label

    let rename = savedLocationButton(
      withPrefix: "saved-location-rename-",
      in: app,
      index: 0
    )
    scrollUp(until: rename, in: app)
    XCTAssertTrue(rename.waitForExistence(timeout: 5))
    rename.tap()
    let renameAlert = app.alerts.firstMatch
    XCTAssertTrue(renameAlert.waitForExistence(timeout: 5))
    let renameField = renameAlert.textFields.firstMatch
    XCTAssertTrue(renameField.waitForExistence(timeout: 5))
    replaceRenameText(in: renameField, with: "Shanghai Failed", in: renameAlert)
    app.buttons["saved-location-confirm-rename"].firstMatch.tap()

    let error = app.staticTexts["saved-location-persistence-error"]
    scrollUp(until: error, in: app)
    XCTAssertTrue(error.waitForExistence(timeout: 5))
    XCTAssertEqual(error.label, "无法保存已保存地点；现有集合未更改。")

    let firstAfterFailure = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 0
    )
    let secondAfterFailure = savedLocationButton(
      withPrefix: "saved-location-select-",
      in: app,
      index: 1
    )
    XCTAssertEqual(firstAfterFailure.label, firstLabelBeforeFailure)
    XCTAssertEqual(secondAfterFailure.label, secondLabelBeforeFailure)
    assertSelectedCoordinate(coordinateB, source: "已保存地点", in: app)
    assertAppliedSimulationRemainsActive(in: app, acknowledgedLabelSuffix: "已确认")
    clearFixtureSimulation(in: app)
  }

  func testPermissionFixturesKeepDeniedAndRestrictedRecoveryDistinct() {
    let denied = permissionFixtureApp(location: "denied", localNetwork: "denied")
    denied.launch()
    openSettings(in: denied)

    let localNetworkStatus = denied.staticTexts["local-network-permission-status"]
    XCTAssertTrue(localNetworkStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(localNetworkStatus.label.hasSuffix("Denied"))
    let localNetworkSettings = denied.buttons["open-local-network-settings"]
    scrollUp(until: localNetworkSettings, in: denied)
    XCTAssertTrue(localNetworkSettings.waitForExistence(timeout: 5))

    let deniedLocation = denied.staticTexts["location-permission-status"]
    scrollUp(until: deniedLocation, in: denied)
    XCTAssertTrue(deniedLocation.waitForExistence(timeout: 5))
    XCTAssertTrue(deniedLocation.label.hasSuffix("Denied"))
    let locationSettings = denied.buttons["open-location-settings"]
    scrollUpInSmallSteps(until: locationSettings, in: denied)
    XCTAssertTrue(locationSettings.waitForExistence(timeout: 5))
    denied.terminate()

    let restricted = permissionFixtureApp(location: "restricted", localNetwork: "allowed")
    restricted.launch()
    openSettings(in: restricted)

    let allowedLocalNetwork = restricted.staticTexts["local-network-permission-status"]
    XCTAssertTrue(allowedLocalNetwork.waitForExistence(timeout: 5))
    XCTAssertTrue(allowedLocalNetwork.label.hasSuffix("Allowed"))
    let restrictedLocation = restricted.staticTexts["location-permission-status"]
    scrollUp(until: restrictedLocation, in: restricted)
    XCTAssertTrue(restrictedLocation.waitForExistence(timeout: 5))
    XCTAssertTrue(restrictedLocation.label.hasSuffix("Restricted"))
    XCTAssertFalse(restricted.buttons["open-location-settings"].exists)
  }

  func testPublicLocationSetAndReplaceAreVerifiedByPinshiftApp() {
    let app = pinshiftApp()
    if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
      app.resetAuthorizationStatus(for: .location)
    }
    app.launch()
    app.tap()
    defer { XCUIDevice.shared.location = nil }

    let primer = CLLocationCoordinate2D(latitude: -33.8688, longitude: 151.2093)
    XCUIDevice.shared.location = XCUILocation(
      location: CLLocation(latitude: primer.latitude, longitude: primer.longitude)
    )
    waitForObservedCoordinate(primer, in: app)

    let coordinateA = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
    let coordinateB = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)

    applyAndVerify(coordinateA, in: app)
    applyAndVerify(coordinateB, in: app)
  }

  func testMapSelectionReachesTheFreshObservationVerificationSeam() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    XCTAssertTrue(app.otherElements["location-map"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["use-map-center"].exists)
    app.buttons["use-map-center"].tap()
    XCTAssertTrue(
      app.staticTexts["location-selection-confirmation"].waitForExistence(timeout: 5)
    )
    app.buttons["close-location-picker"].tap()

    let selectionSource = app.staticTexts["selection-source"]
    scrollUp(until: selectionSource, in: app)
    XCTAssertTrue(selectionSource.waitForExistence(timeout: 5))
    XCTAssertTrue(selectionSource.label.hasSuffix("Map"))
    let selectedStatus = app.staticTexts.matching(identifier: "simulation-status")
      .matching(NSPredicate(format: "label == %@", "Selected — waiting to apply"))
      .firstMatch
    for _ in 0..<4 where !selectedStatus.exists {
      primaryScrollContainer(in: app).swipeUp()
    }
    XCTAssertTrue(selectedStatus.waitForExistence(timeout: 5))

    let coordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
    scrollToTop(in: app)
    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedLatitude.label.hasSuffix("31.230400"))
    XCTAssertTrue(selectedLongitude.label.hasSuffix("121.473700"))
    applyAndVerifySimulation(of: coordinate, in: app)
    clearFixtureSimulation(in: app)
  }

  func testLocationPickerKeepsMapActionsVisibleAndRequiresExplicitDismissal() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    let picker = app.otherElements["location-picker"]
    let map = app.otherElements["location-map"]
    let selectMapCenter = app.buttons["use-map-center"]
    let done = app.buttons["close-location-picker"]

    XCTAssertTrue(picker.waitForExistence(timeout: 5))
    XCTAssertTrue(map.waitForExistence(timeout: 5))
    XCTAssertEqual(map.label, "Map center")
    XCTAssertTrue(selectMapCenter.waitForExistence(timeout: 5))
    XCTAssertFalse(selectMapCenter.isSelected)
    XCTAssertTrue(done.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["map-visible-range"].exists)
    XCTAssertFalse(app.buttons["restore-opening-location"].exists)
    XCTAssertTrue(selectMapCenter.isHittable)
    XCTAssertTrue(done.isHittable)
    XCTAssertGreaterThanOrEqual(selectMapCenter.frame.width, 44)
    XCTAssertGreaterThanOrEqual(selectMapCenter.frame.height, 44)

    map.swipeDown()
    XCTAssertTrue(picker.waitForExistence(timeout: 2))

    selectMapCenter.tap()
    XCTAssertTrue(selectMapCenter.isSelected)
    XCTAssertTrue(
      app.staticTexts["location-selection-confirmation"].waitForExistence(timeout: 5)
    )
    done.tap()
    XCTAssertFalse(picker.waitForExistence(timeout: 2))
  }

  func testFineAdjustmentOpensAroundSelectedLocationWithOriginFeedback() {
    let app = selectedLocationFixtureApp()
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    let mapCenter = app.staticTexts["map-center-coordinate"]
    let displacement = app.staticTexts["fine-adjustment-displacement"]
    let visibleRange = app.staticTexts["map-visible-range"]
    let restore = app.buttons["restore-opening-location"]

    XCTAssertTrue(mapCenter.waitForExistence(timeout: 5))
    XCTAssertTrue(mapCenter.label.contains("31.230400"))
    XCTAssertTrue(mapCenter.label.contains("121.473700"))
    XCTAssertTrue(displacement.waitForExistence(timeout: 5))
    XCTAssertTrue(displacement.label.contains("0"))
    XCTAssertTrue(visibleRange.waitForExistence(timeout: 5))
    XCTAssertTrue(visibleRange.label.contains("500"))
    XCTAssertTrue(restore.waitForExistence(timeout: 5))
    XCTAssertTrue(restore.isHittable)
  }

  func testFineAdjustmentPinchInShrinksVisibleRangeWithoutCommittingSelection() {
    let app = selectedLocationFixtureApp()
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    let map = app.otherElements["location-map"]
    let visibleRange = app.staticTexts["map-visible-range"]
    XCTAssertTrue(map.waitForExistence(timeout: 5))
    XCTAssertTrue(map.isHittable)
    XCTAssertTrue(visibleRange.waitForExistence(timeout: 5))
    guard let openingRange = distanceMeters(from: visibleRange.label) else {
      return XCTFail("The initial visible map range was not accessible.")
    }
    map.pinch(withScale: 2.0, velocity: 1.0)
    let zoomedInRange = waitForVisibleRange(visibleRange) { current in
      return current < openingRange * 0.9
    }

    XCTAssertLessThan(zoomedInRange, openingRange * 0.9)
    assertFineAdjustmentMapRemainsInteractive(in: app)
    closeFineAdjustmentAndAssertSelectionWasNotApplied(in: app)
  }

  func testFineAdjustmentPinchOutExpandsVisibleRangeWithoutCommittingSelection() {
    let app = selectedLocationFixtureApp()
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    let map = app.otherElements["location-map"]
    let visibleRange = app.staticTexts["map-visible-range"]
    XCTAssertTrue(map.waitForExistence(timeout: 5))
    XCTAssertTrue(map.isHittable)
    XCTAssertTrue(visibleRange.waitForExistence(timeout: 5))
    guard let openingRange = distanceMeters(from: visibleRange.label) else {
      return XCTFail("The initial visible map range was not accessible.")
    }
    map.pinch(withScale: 0.5, velocity: -1.0)
    let zoomedOutRange = waitForVisibleRange(visibleRange) { current in
      return current > openingRange * 1.1
    }

    XCTAssertGreaterThan(zoomedOutRange, openingRange * 1.1)
    assertFineAdjustmentMapRemainsInteractive(in: app)
    closeFineAdjustmentAndAssertSelectionWasNotApplied(in: app)
  }

  func testFineAdjustmentPanLeavesSelectedLocationUnchangedUntilMapCenterCommit() {
    let app = selectedLocationFixtureApp()
    app.launch()
    app.tap()

    openLocationPicker(in: app)
    panMapAndWaitForDisplacement(in: app)
    app.buttons["close-location-picker"].tap()

    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedLatitude.label.hasSuffix("31.230400"))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedLongitude.label.hasSuffix("121.473700"))

    openLocationPicker(in: app)
    panMapAndWaitForDisplacement(in: app)
    app.buttons["use-map-center"].tap()
    waitForSelectionConfirmation(in: app)
    app.buttons["close-location-picker"].tap()

    scrollToTop(in: app)
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertFalse(selectedLongitude.label.hasSuffix("121.473700"))
  }

  func testFineAdjustmentRestoreReplacesACommittedCenterWithTheOpeningLocation() {
    let app = selectedLocationFixtureApp()
    app.launch()
    app.tap()

    openLocationPicker(in: app)
    panMapAndWaitForDisplacement(in: app)
    app.buttons["use-map-center"].tap()
    waitForSelectionConfirmation(in: app)
    scrollPickerToTop(in: app)
    app.buttons["restore-opening-location"].tap()

    let restoreConfirmation = app.staticTexts["location-restoration-confirmation"]
    XCTAssertTrue(restoreConfirmation.waitForExistence(timeout: 5))
    app.buttons["close-location-picker"].tap()

    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedLatitude.label.hasSuffix("31.230400"))
    XCTAssertTrue(selectedLongitude.label.hasSuffix("121.473700"))
  }

  func testFineAdjustmentCanReplaceAnAppliedSimulationWithoutClearingFirst() {
    let app = selectedLocationFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.navigationBars["Pinshift"].tap()

    let apply = app.buttons["apply-selected-location"]
    scrollUp(until: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    apply.tap()
    XCTAssertTrue(
      app.staticTexts["applied-acknowledgement"].waitForExistence(timeout: 5)
    )

    openLocationPicker(in: app)
    panMapAndWaitForDisplacement(in: app)
    app.buttons["use-map-center"].tap()
    waitForSelectionConfirmation(in: app)
    app.buttons["close-location-picker"].tap()

    let acknowledgement = app.staticTexts["applied-acknowledgement"]
    XCTAssertTrue(acknowledgement.waitForExistence(timeout: 5))
    let replacementApply = app.buttons["apply-selected-location"]
    scrollUp(until: replacementApply, in: app)
    XCTAssertTrue(replacementApply.waitForExistence(timeout: 5))
    XCTAssertTrue(replacementApply.isEnabled)
    replacementApply.tap()
    XCTAssertTrue(acknowledgement.waitForExistence(timeout: 5))
    clearFixtureSimulation(in: app)
  }

  func testTemporarySimulationHasFixedCountdownReplacementAndClearNow() {
    let app = selectedLocationFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.navigationBars["Pinshift"].tap()

    let apply = app.buttons["apply-selected-location"]
    scrollUp(until: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertTrue(apply.isEnabled)
    apply.tap()

    let card = app.otherElements["active-simulation-card"]
    scrollUp(until: card, in: app)
    XCTAssertTrue(card.waitForExistence(timeout: 5))
    XCTAssertTrue(app.staticTexts["simulation-auto-clear-time"].exists)
    XCTAssertTrue(app.staticTexts["simulation-auto-clear-countdown"].exists)
    XCTAssertTrue(app.buttons["apply-selected-location"].exists)
    XCTAssertTrue(app.buttons["apply-selected-location"].isEnabled)
    XCTAssertFalse(
      app.staticTexts.matching(identifier: "clear-status")
        .matching(NSPredicate(format: "label == %@", "Simulated Location cleared"))
        .firstMatch.exists
    )

    let clear = app.buttons["clear-simulation"]
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    clear.tap()
    let cleared = app.staticTexts.matching(identifier: "clear-status")
      .matching(NSPredicate(format: "label == %@", "Simulated Location cleared"))
      .firstMatch
    XCTAssertTrue(cleared.waitForExistence(timeout: 5))
  }

  func testReplacementApplyRemainsEnabledWhileEarlierResponseIsPending() {
    let app = selectedLocationFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_APPLY_DELAY_MILLISECONDS"] = "2000"
    app.launch()
    app.navigationBars["Pinshift"].tap()

    let apply = app.buttons["apply-selected-location"]
    scrollUp(until: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertTrue(apply.isEnabled)
    apply.tap()

    let applying = app.staticTexts.matching(identifier: "simulation-status")
      .matching(
        NSPredicate(
          format: "label == %@",
          "Applying temporary location…"
        )
      )
      .firstMatch
    XCTAssertTrue(applying.waitForExistence(timeout: 5))
    XCTAssertTrue(
      apply.isEnabled,
      "An earlier in-flight Apply must not disable replacement Apply."
    )

    apply.tap()
    let card = app.otherElements["active-simulation-card"]
    scrollUp(until: card, in: app)
    XCTAssertTrue(card.waitForExistence(timeout: 8))
    clearFixtureSimulation(in: app)
  }

  func testFineAdjustmentFeedbackIsLocalizedInSimplifiedChinese() {
    let app = selectedLocationFixtureApp()
    app.launchEnvironment["PINSHIFT_E2E_APP_LANGUAGE"] = "zh-Hans"
    app.launch()
    app.tap()

    openLocationPicker(in: app)

    let displacement = app.staticTexts["fine-adjustment-displacement"]
    XCTAssertTrue(displacement.waitForExistence(timeout: 5))
    XCTAssertTrue(displacement.label.contains("米"))
    XCTAssertEqual(
      app.buttons["restore-opening-location"].label,
      "恢复打开时位置"
    )
  }

  func testSearchResultReachesTheFreshObservationVerificationSeam() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_SEARCH_FIXTURE"] = "1"
    app.launchEnvironment["PINSHIFT_E2E_CONTROLLER_LINK_FIXTURE"] = "1"
    app.launch()
    app.tap()

    openLocationPicker(in: app)
    let field = app.textFields["place-search-input"]
    XCTAssertTrue(field.waitForExistence(timeout: 5))
    field.tap()
    field.typeText("fixture")
    app.buttons["search-places"].tap()

    let result = app.buttons["place-search-result"]
    XCTAssertTrue(result.waitForExistence(timeout: 5))
    result.tap()
    waitForSelectionConfirmation(in: app)
    app.buttons["close-location-picker"].tap()

    scrollToTop(in: app)
    let selectionSource = app.staticTexts["selection-source"]
    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollUp(until: selectionSource, in: app)
    XCTAssertTrue(selectionSource.waitForExistence(timeout: 5))
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectionSource.label.hasSuffix("Place search"))
    XCTAssertTrue(selectedLatitude.label.hasSuffix("35.676200"))
    XCTAssertTrue(selectedLongitude.label.hasSuffix("139.650300"))
    applyAndVerifySimulation(
      of: CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503),
      in: app
    )
  }

  func testSearchEmptyAndFailureStatesPreserveThePreviousSelection() {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_SEARCH_FIXTURE"] = "1"
    app.launch()
    app.tap()

    openLocationPicker(in: app)
    app.buttons["use-map-center"].tap()
    app.buttons["close-location-picker"].tap()
    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    let previousLatitude = selectedLatitude.label
    let previousLongitude = selectedLongitude.label

    openLocationPicker(in: app)
    let field = app.textFields["place-search-input"]
    replaceText(in: field, with: "empty")
    app.buttons["search-places"].tap()
    let status = app.staticTexts["place-search-status"]
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    XCTAssertEqual(status.label, "No places found. Try a more specific query.")

    replaceText(in: field, with: "failure")
    app.buttons["search-places"].tap()
    XCTAssertTrue(
      status.waitForExistence(timeout: 5)
    )
    XCTAssertEqual(
      status.label,
      "Place search is unavailable. Check your network connection and try again; your previous selection is unchanged."
    )
    app.buttons["close-location-picker"].tap()

    let selectionSource = app.staticTexts["selection-source"]
    scrollUp(until: selectionSource, in: app)
    XCTAssertTrue(selectionSource.waitForExistence(timeout: 5))
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectionSource.label.hasSuffix("Map"))
    XCTAssertEqual(selectedLatitude.label, previousLatitude)
    XCTAssertEqual(selectedLongitude.label, previousLongitude)
  }

  func testPublicLocationBackendRemainsStableForTenMinutes() throws {
    if ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] != nil {
      throw XCTSkip("The ten-minute backend gate is recorded only on a physical device.")
    }

    let app = pinshiftApp()
    app.launch()
    app.tap()
    defer { XCUIDevice.shared.location = nil }

    let coordinateA = CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090)
    let coordinateB = CLLocationCoordinate2D(latitude: 52.5200, longitude: 13.4050)
    let minimumDuration: TimeInterval = 600
    let startedAt = Date()
    var completedRounds = 0

    repeat {
      applyAndVerify(coordinateA, in: app)
      applyAndVerify(coordinateB, in: app)
      clearAndVerifyProxyInactive(in: app)
      completedRounds += 1
      XCTContext.runActivity(named: "Completed public A/B/clear round \(completedRounds)") { _ in }
    } while Date().timeIntervalSince(startedAt) < minimumDuration

    let duration = Date().timeIntervalSince(startedAt)
    XCTAssertGreaterThanOrEqual(completedRounds, 2)
    XCTAssertGreaterThanOrEqual(duration, minimumDuration)
    XCTContext.runActivity(
      named:
        "Public location gate completed \(completedRounds) rounds in \(duration.formatted(.number.precision(.fractionLength(1)))) seconds"
    ) { _ in }
  }

  private func applyAndVerify(
    _ coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    selectAndBeginObservation(of: coordinate, in: app)

    verifyFreshObservation(of: coordinate, in: app)
  }

  private func verifyFreshObservation(
    of coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    openSettings(in: app)
    let start = app.buttons["start-observation-window"]
    for _ in 0..<10 where !start.exists {
      app.collectionViews.firstMatch.swipeUp()
    }
    XCTAssertTrue(start.waitForExistence(timeout: 5))
    start.tap()

    XCUIDevice.shared.location = XCUILocation(
      location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    )

    let status = app.staticTexts["match-status"]
    for _ in 0..<4 where !status.exists {
      app.collectionViews.firstMatch.swipeUp()
    }
    let matched = app.staticTexts.matching(identifier: "match-status")
      .matching(NSPredicate(format: "label == %@", "GPX baseline matched"))
      .firstMatch
    XCTAssertTrue(matched.waitForExistence(timeout: 15))

    let observedTimestamp = app.staticTexts["observed-timestamp"]
    for _ in 0..<4 where !observedTimestamp.exists {
      app.collectionViews.firstMatch.swipeDown()
    }
    XCTAssertTrue(observedTimestamp.waitForExistence(timeout: 5))
    let observedTimestampLabel = observedTimestamp.label

    let elapsed = app.staticTexts["match-elapsed"]
    let distance = app.staticTexts["match-distance"]
    for _ in 0..<4 where !elapsed.exists || !distance.exists {
      app.collectionViews.firstMatch.swipeUp()
    }
    XCTAssertTrue(elapsed.waitForExistence(timeout: 5))
    XCTAssertTrue(distance.waitForExistence(timeout: 5))
    XCTContext.runActivity(
      named:
        "Pinshift app verified fresh observation (\(observedTimestampLabel); \(elapsed.label); \(distance.label))"
    ) { _ in }
  }

  private func applyAndVerifySimulation(
    of coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    returnHome(in: app)
    let apply = app.buttons["apply-selected-location"]
    scrollUp(until: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertTrue(apply.isEnabled)
    apply.tap()

    let applied = app.staticTexts.matching(identifier: "simulation-status")
      .matching(
        NSPredicate(
          format: "label == %@",
          "Applied; waiting for a fresh observation"
        )
      )
      .firstMatch
    XCTAssertTrue(applied.waitForExistence(timeout: 5))

    XCUIDevice.shared.location = XCUILocation(
      location: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
    )

    let verified = app.staticTexts.matching(identifier: "simulation-status")
      .matching(
        NSPredicate(
          format: "label == %@",
          "Verified by a fresh observation in this app"
        )
      )
      .firstMatch
    XCTAssertTrue(verified.waitForExistence(timeout: 15))
  }

  private func clearAndVerifyProxyInactive(in app: XCUIApplication) {
    XCUIDevice.shared.location = nil
    XCTAssertNil(
      XCUIDevice.shared.location,
      "The public XCUIDevice location getter still reports an active proxy after clear."
    )

    openSettings(in: app)
    let recencyNote = app.staticTexts["observation-recency-note"]
    for _ in 0..<4 where !recencyNote.exists {
      app.collectionViews.firstMatch.swipeDown()
    }
    XCTAssertTrue(recencyNote.waitForExistence(timeout: 5))
    XCTAssertEqual(
      recencyNote.label,
      "This is the last successful Core Location observation. It may remain after a simulation stops and does not indicate an active simulation."
    )
    XCTContext.runActivity(
      named: "Public location proxy cleared; Pinshift app retains only last-observation evidence"
    ) { _ in }
  }

  private func selectAndBeginObservation(
    of coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    openSettings(in: app)
    scrollToTop(in: app)
    let latitude = app.textFields["latitude-input"]
    scrollUp(until: latitude, in: app)
    XCTAssertTrue(latitude.waitForExistence(timeout: 5))

    replaceText(
      in: latitude,
      with: String(format: "%.6f", coordinate.latitude)
    )
    replaceText(
      in: app.textFields["longitude-input"],
      with: String(format: "%.6f", coordinate.longitude)
    )
    app.buttons["Return"].tap()
    app.buttons["save-selection"].tap()

  }

  private func waitForObservedCoordinate(
    _ coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    openSettings(in: app)
    let observedLatitude = app.staticTexts["observed-latitude"]
    scrollUp(until: observedLatitude, in: app)
    let expectedSuffix = String(format: "%.6f", coordinate.latitude)
    let matchingLatitude = app.staticTexts.matching(identifier: "observed-latitude")
      .matching(NSPredicate(format: "label ENDSWITH %@", expectedSuffix))
      .firstMatch
    XCTAssertTrue(matchingLatitude.waitForExistence(timeout: 10))
  }

  private func replaceText(in field: XCUIElement, with text: String) {
    field.tap()
    if let existing = field.value as? String {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    }
    field.typeText(text)
  }

  private func replaceRenameText(
    in field: XCUIElement,
    with text: String,
    in alert: XCUIElement
  ) {
    field.tap()
    if let existing = field.value as? String, !existing.isEmpty,
      existing != "Saved Location Name"
    {
      field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: existing.count))
    }
    alert.textFields.firstMatch.typeText(text)
  }

  private func openLocationPicker(in app: XCUIApplication) {
    returnHome(in: app)
    let button = app.buttons["open-location-picker"]
    for _ in 0..<5 where !button.exists {
      primaryScrollContainer(in: app).swipeUp()
    }
    XCTAssertTrue(button.waitForExistence(timeout: 5))
    button.tap()
  }

  private func panMapAndWaitForDisplacement(in app: XCUIApplication) {
    let map = app.otherElements["location-map"]
    XCTAssertTrue(map.waitForExistence(timeout: 5))
    map.swipeLeft()

    let displacement = app.staticTexts["fine-adjustment-displacement"]
    let startedAt = Date()
    while Date().timeIntervalSince(startedAt) < 5 {
      if let meters = distanceMeters(from: displacement.label), meters > 1 {
        return
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }
    XCTFail("The map displacement did not exceed 1 m.")
  }

  private func assertFineAdjustmentMapRemainsInteractive(in app: XCUIApplication) {
    let map = app.otherElements["location-map"]
    let useMapCenter = app.buttons["use-map-center"]
    let done = app.buttons["close-location-picker"]

    XCTAssertTrue(map.exists)
    XCTAssertTrue(map.isHittable)
    XCTAssertTrue(useMapCenter.exists)
    XCTAssertTrue(useMapCenter.isHittable)
    XCTAssertTrue(done.exists)
    XCTAssertTrue(done.isHittable)
  }

  private func closeFineAdjustmentAndAssertSelectionWasNotApplied(
    in app: XCUIApplication
  ) {
    app.buttons["close-location-picker"].tap()

    let selectedLatitude = app.staticTexts["selected-latitude"]
    let selectedLongitude = app.staticTexts["selected-longitude"]
    scrollToTop(in: app)
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    scrollUp(until: selectedLongitude, in: app)
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(selectedLatitude.label.hasSuffix("31.230400"))
    XCTAssertTrue(selectedLongitude.label.hasSuffix("121.473700"))

    let selectedStatus = app.staticTexts.matching(identifier: "simulation-status")
      .matching(NSPredicate(format: "label == %@", "Selected — waiting to apply"))
      .firstMatch
    scrollUp(until: selectedStatus, in: app)
    XCTAssertTrue(selectedStatus.waitForExistence(timeout: 5))
    XCTAssertFalse(app.staticTexts["applied-acknowledgement"].exists)
  }

  private func waitForVisibleRange(
    _ element: XCUIElement,
    satisfying predicate: (Double) -> Bool,
    timeout: TimeInterval = 5
  ) -> Double {
    let startedAt = Date()
    while Date().timeIntervalSince(startedAt) < timeout {
      if let value = distanceMeters(from: element.label), predicate(value) {
        return value
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.1))
    }

    XCTFail("The visible map range did not reach the expected pinch direction.")
    return distanceMeters(from: element.label) ?? .nan
  }

  private func distanceMeters(from label: String) -> Double? {
    let regex = try! NSRegularExpression(
      pattern: #"([0-9]+(?:\.[0-9]+)?)\s*(km|m)"#
    )
    let fullRange = NSRange(label.startIndex..<label.endIndex, in: label)
    guard
      let match = regex.firstMatch(in: label, range: fullRange),
      let valueRange = Range(match.range(at: 1), in: label),
      let unitRange = Range(match.range(at: 2), in: label),
      let value = Double(label[valueRange])
    else {
      return nil
    }

    return value * (label[unitRange] == "km" ? 1_000 : 1)
  }

  private func waitForSelectionConfirmation(in app: XCUIApplication) {
    let confirmation = app.staticTexts["location-selection-confirmation"]
    for _ in 0..<4 where !confirmation.exists {
      app.scrollViews.firstMatch.swipeUp()
    }
    XCTAssertTrue(confirmation.waitForExistence(timeout: 5))
  }

  private func scrollPickerToTop(in app: XCUIApplication) {
    let scrollView = app.scrollViews.firstMatch
    for _ in 0..<6 {
      scrollView.swipeDown()
    }
  }

  private func permissionFixtureApp(
    location: String,
    localNetwork: String
  ) -> XCUIApplication {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_LOCATION_PERMISSION"] = location
    app.launchEnvironment["PINSHIFT_E2E_LOCAL_NETWORK_PERMISSION"] = localNetwork
    return app
  }

  private func waitForDiagnostics(in app: XCUIApplication) {
    openSettings(in: app)
    scrollToTop(in: app)
    let status = app.staticTexts["diagnostics-status"]
    scrollUp(until: status, in: app)
    XCTAssertTrue(status.waitForExistence(timeout: 5))
    let eventCount = app.staticTexts["diagnostics-event-count"]
    scrollUp(until: eventCount, in: app)
    XCTAssertTrue(eventCount.waitForExistence(timeout: 5))
  }

  private func clearDiagnostics(in app: XCUIApplication) {
    openSettings(in: app)
    scrollToTop(in: app)
    let clear = app.buttons["diagnostics-clear"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    clear.tap()
    let eventCount = app.staticTexts["diagnostics-event-count"]
    XCTAssertTrue(waitForLabel(eventCount, endingWith: ", 0", timeout: 5))
  }

  private func exportDiagnosticsArtifact(
    in app: XCUIApplication
  ) -> ExportedDiagnosticArtifact? {
    openSettings(in: app)
    scrollToTop(in: app)
    let export = app.buttons["diagnostics-export"]
    scrollUp(until: export, in: app)
    XCTAssertTrue(export.waitForExistence(timeout: 5))
    export.tap()

    let seam = app.descendants(matching: .any)["diagnostics-export-artifact"]
    scrollUp(until: seam, in: app)
    XCTAssertTrue(seam.waitForExistence(timeout: 5))
    let rawArtifact = (seam.value as? String) ?? seam.label
    guard
      let data = rawArtifact.data(using: .utf8),
      let artifact = try? JSONDecoder().decode(
        ExportedDiagnosticArtifact.self,
        from: data
      )
    else {
      XCTFail("The Export artifact seam did not contain a decodable schema artifact.")
      return nil
    }
    return artifact
  }

  private func assertNormalDiagnosticSequence(
    _ artifact: ExportedDiagnosticArtifact
  ) -> (apply: UUID, clear: UUID)? {
    XCTAssertEqual(artifact.schemaVersion, 1)
    XCTAssertEqual(artifact.side, "pinshift-app")
    XCTAssertFalse(artifact.createdAt.isEmpty)
    guard
      let launchIndex = artifact.events.lastIndex(where: {
        $0.kind == "app.lifecycle.launched"
      })
    else {
      XCTFail("The exported artifact did not contain an app lifecycle event.")
      return nil
    }
    guard
      let selectionIndex = index(
        of: "app.selection.replaced",
        after: launchIndex,
        in: artifact.events
      ),
      let applyIndex = index(
        of: "app.apply.started",
        after: selectionIndex,
        in: artifact.events
      ),
      let observationIndex = index(
        of: "app.apply.verification-result",
        after: applyIndex,
        in: artifact.events
      ),
      let clearStartedIndex = index(
        of: "app.clear.started",
        after: observationIndex,
        in: artifact.events
      ),
      let clearAcknowledgedIndex = index(
        of: "app.clear.acknowledged",
        after: clearStartedIndex,
        in: artifact.events
      )
    else {
      XCTFail("The exported artifact did not contain the ordered normal journey.")
      return nil
    }
    XCTAssertLessThan(launchIndex, selectionIndex)
    XCTAssertLessThan(selectionIndex, applyIndex)
    XCTAssertLessThan(applyIndex, observationIndex)
    XCTAssertLessThan(observationIndex, clearStartedIndex)
    XCTAssertLessThan(clearStartedIndex, clearAcknowledgedIndex)

    guard let applyRequestID = artifact.events[applyIndex].requestID else {
      XCTFail("The Apply event did not contain a request ID.")
      return nil
    }
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.apply.response" && $0.requestID == applyRequestID
      }
    )
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.apply.acknowledged" && $0.requestID == applyRequestID
      }
    )
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.observation.verification-updated"
          && $0.sequence > artifact.events[applyIndex].sequence
      }
    )

    guard let clearRequestID = artifact.events[clearStartedIndex].requestID else {
      XCTFail("The Clear event did not contain a request ID.")
      return nil
    }
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.clear.response" && $0.requestID == clearRequestID
      }
    )
    XCTAssertTrue(
      artifact.events.contains {
        $0.kind == "app.clear.acknowledged"
          && $0.requestID == clearRequestID
      }
    )
    return (applyRequestID, clearRequestID)
  }

  private func index(
    of kind: String,
    after index: Int,
    in events: [ExportedDiagnosticEvent]
  ) -> Int? {
    events.indices.first(where: { $0 > index && events[$0].kind == kind })
  }

  private func stringValue(
    _ key: String,
    in fields: [String: ExportedDiagnosticValue]
  ) -> String? {
    guard case .string(let value) = fields[key] else { return nil }
    return value
  }

  private func savedLocationsFixtureApp() -> XCUIApplication {
    let app = permissionFixtureApp(location: "allowed", localNetwork: "allowed")
    app.launchEnvironment["PINSHIFT_E2E_SAVED_LOCATIONS_RESET_TOKEN"] = UUID().uuidString
    return app
  }

  private func saveNamedLocation(
    _ name: String,
    coordinate: CLLocationCoordinate2D,
    in app: XCUIApplication
  ) {
    openSettings(in: app)
    scrollToTop(in: app)
    let latitude = app.textFields["latitude-input"]
    scrollUp(until: latitude, in: app)
    XCTAssertTrue(latitude.waitForExistence(timeout: 5))
    replaceText(in: latitude, with: String(format: "%.6f", coordinate.latitude))
    replaceText(
      in: app.textFields["longitude-input"],
      with: String(format: "%.6f", coordinate.longitude)
    )
    app.buttons["Return"].tap()
    app.buttons["save-selection"].tap()

    let saveCurrent = app.buttons["save-current-location"]
    scrollUp(until: saveCurrent, in: app)
    XCTAssertTrue(saveCurrent.waitForExistence(timeout: 5))
    XCTAssertTrue(saveCurrent.isEnabled)
    saveCurrent.tap()
    let saveAlert = app.alerts.firstMatch
    XCTAssertTrue(saveAlert.waitForExistence(timeout: 5))
    let nameField = saveAlert.textFields.firstMatch
    XCTAssertTrue(nameField.waitForExistence(timeout: 5))
    nameField.tap()
    nameField.typeText(name)
    app.buttons["saved-location-confirm-save"].firstMatch.tap()
    let savedLocation = app.buttons
      .matching(NSPredicate(format: "label CONTAINS %@", name))
      .firstMatch
    scrollUp(until: savedLocation, in: app)
    XCTAssertTrue(savedLocation.waitForExistence(timeout: 5))
  }

  private func applyAndAcknowledgeSimulation(
    in app: XCUIApplication,
    acknowledgedLabelSuffix: String = "Acknowledged"
  ) {
    returnHome(in: app)
    let apply = app.buttons["apply-selected-location"]
    scrollUp(until: apply, in: app)
    XCTAssertTrue(apply.waitForExistence(timeout: 5))
    XCTAssertTrue(apply.isEnabled)
    apply.tap()

    openSettings(in: app)
    let appliedStatus = app.staticTexts["applied-simulation-status"]
    scrollToTop(in: app)
    XCTAssertTrue(appliedStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(appliedStatus.label.hasSuffix(acknowledgedLabelSuffix))
  }

  private func assertAppliedSimulationRemainsActive(
    in app: XCUIApplication,
    acknowledgedLabelSuffix: String = "Acknowledged"
  ) {
    openSettings(in: app)
    let appliedStatus = app.staticTexts["applied-simulation-status"]
    scrollToTop(in: app)
    XCTAssertTrue(appliedStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(appliedStatus.label.hasSuffix(acknowledgedLabelSuffix))

    returnHome(in: app)
    let clear = app.buttons["clear-simulation"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    XCTAssertTrue(clear.isEnabled)
  }

  private func clearFixtureSimulation(in app: XCUIApplication) {
    returnHome(in: app)
    let clear = app.buttons["clear-simulation"]
    scrollUp(until: clear, in: app)
    XCTAssertTrue(clear.waitForExistence(timeout: 5))
    clear.tap()
    let cleared = app.staticTexts.matching(identifier: "clear-status")
      .matching(
        NSPredicate(
          format: "label == %@ OR label == %@",
          "Simulated Location cleared",
          "已清除模拟位置"
        )
      )
      .firstMatch
    XCTAssertTrue(cleared.waitForExistence(timeout: 5))
  }

  private func savedLocationButton(
    withPrefix prefix: String,
    in app: XCUIApplication,
    index: Int
  ) -> XCUIElement {
    openSettings(in: app)
    scrollToTop(in: app)
    let savedLocationsAction = app.buttons["save-current-location"]
    scrollUp(until: savedLocationsAction, in: app)
    let savedLocation = app.buttons
      .matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
      .element(boundBy: index)
    scrollUp(until: savedLocation, in: app)
    return savedLocation
  }

  private func assertSavedLocationSelectionIsInactive(in app: XCUIApplication) {
    openSettings(in: app)
    let appliedStatus = app.staticTexts["applied-simulation-status"]
    scrollToTop(in: app)
    XCTAssertTrue(appliedStatus.waitForExistence(timeout: 5))
    XCTAssertTrue(
      appliedStatus.label.hasSuffix("Inactive")
        || appliedStatus.label.hasSuffix("Unknown until the Mac reconnects")
    )

    returnHome(in: app)
    let selected = app.staticTexts.matching(identifier: "simulation-status")
      .matching(NSPredicate(format: "label == %@", "Selected — waiting to apply"))
      .firstMatch
    scrollUp(until: selected, in: app)
    XCTAssertTrue(selected.waitForExistence(timeout: 5))
  }

  private func assertSelectedCoordinate(
    _ coordinate: CLLocationCoordinate2D,
    source: String,
    in app: XCUIApplication
  ) {
    scrollToTop(in: app)
    let selectedLatitude = app.staticTexts["selected-latitude"]
    scrollUp(until: selectedLatitude, in: app)
    XCTAssertTrue(selectedLatitude.waitForExistence(timeout: 5))
    XCTAssertTrue(
      selectedLatitude.label.hasSuffix(String(format: "%.6f", coordinate.latitude))
    )
    let selectedLongitude = app.staticTexts["selected-longitude"]
    XCTAssertTrue(selectedLongitude.waitForExistence(timeout: 5))
    XCTAssertTrue(
      selectedLongitude.label.hasSuffix(String(format: "%.6f", coordinate.longitude))
    )
    let selectionSource = app.staticTexts["selection-source"]
    scrollUp(until: selectionSource, in: app)
    XCTAssertTrue(selectionSource.waitForExistence(timeout: 5))
    XCTAssertTrue(selectionSource.label.hasSuffix(source))
  }

  private func pinshiftApp() -> XCUIApplication {
    let app = XCUIApplication()
    app.launchEnvironment["PINSHIFT_E2E_APP_LANGUAGE"] = "en"
    return app
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

  private func selectedLocationFixtureApp() -> XCUIApplication {
    let app = pinshiftApp()
    app.launchEnvironment["PINSHIFT_E2E_SELECTED_LOCATION"] = "31.230400,121.473700"
    return app
  }

  private func waitForLabel(
    _ element: XCUIElement,
    equalTo expectedLabel: String,
    timeout: TimeInterval = 5
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label == %@", expectedLabel),
      object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func waitForLabel(
    _ element: XCUIElement,
    endingWith expectedSuffix: String,
    timeout: TimeInterval = 5
  ) -> Bool {
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label ENDSWITH %@", expectedSuffix),
      object: element
    )
    return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
  }

  private func scrollUp(until element: XCUIElement, in app: XCUIApplication) {
    let scrollContainer = primaryScrollContainer(in: app)
    for _ in 0..<8 where !element.exists || !element.isHittable {
      scrollContainer.swipeUp()
    }
  }

  private func scrollToTop(in app: XCUIApplication) {
    let scrollContainer = primaryScrollContainer(in: app)
    for _ in 0..<6 {
      scrollContainer.swipeDown()
    }
  }

  private func scrollUpInSmallSteps(until element: XCUIElement, in app: XCUIApplication) {
    let collectionView = primaryScrollContainer(in: app)
    for _ in 0..<6 where !element.exists || !element.isHittable {
      let start = collectionView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
      let finish = collectionView.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.55))
      start.press(forDuration: 0.05, thenDragTo: finish)
    }
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
}

private struct ExportedDiagnosticArtifact: Decodable {
  let schemaVersion: Int
  let side: String
  let generationID: UUID
  let createdAt: String
  let events: [ExportedDiagnosticEvent]
}

private struct ExportedDiagnosticEvent: Decodable {
  let sessionID: UUID
  let sequence: UInt64
  let kind: String
  let requestID: UUID?
  let fields: [String: ExportedDiagnosticValue]
}

private enum ExportedDiagnosticValue: Decodable {
  case string(String)
  case number(Double)
  case integer(Int64)
  case boolean(Bool)
  case array([ExportedDiagnosticValue])
  case object([String: ExportedDiagnosticValue])
  case null

  init(from decoder: Decoder) throws {
    if let keyed = try? decoder.container(keyedBy: AnyCodingKey.self) {
      var values: [String: ExportedDiagnosticValue] = [:]
      for key in keyed.allKeys {
        values[key.stringValue] = try keyed.decode(
          ExportedDiagnosticValue.self,
          forKey: key
        )
      }
      self = .object(values)
      return
    }

    if var unkeyed = try? decoder.unkeyedContainer() {
      var values: [ExportedDiagnosticValue] = []
      while !unkeyed.isAtEnd {
        values.append(try unkeyed.decode(ExportedDiagnosticValue.self))
      }
      self = .array(values)
      return
    }

    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .boolean(value)
    } else if let value = try? container.decode(Int64.self) {
      self = .integer(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else {
      self = .string(try container.decode(String.self))
    }
  }
}

private struct AnyCodingKey: CodingKey {
  let stringValue: String
  let intValue: Int?

  init?(stringValue: String) {
    self.stringValue = stringValue
    intValue = nil
  }

  init?(intValue: Int) {
    stringValue = String(intValue)
    self.intValue = intValue
  }
}
