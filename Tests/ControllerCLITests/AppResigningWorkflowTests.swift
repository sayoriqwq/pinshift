import Foundation
import XCTest

final class AppResigningWorkflowTests: XCTestCase {
  private let bundleIdentifier = "dev.sayori.pinshift"
  private let teamIdentifier = "TESTTEAM123"
  private var fixtureRoot: URL!
  private var fakeBin: URL!
  private var profiles: URL!
  private var workRoot: URL!
  private var eventLog: URL!
  private var candidateProfile: URL!

  private var resignScript: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "bin/pinshift-resign-app")
  }

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appending(path: "pinshift-resign-\(UUID().uuidString)")
    fakeBin = fixtureRoot.appending(path: "fake-bin")
    profiles = fixtureRoot.appending(path: "profiles")
    workRoot = fixtureRoot.appending(path: "work")
    eventLog = fixtureRoot.appending(path: "events.log")
    candidateProfile = fixtureRoot.appending(path: "candidate.mobileprovision")

    for directory in [fakeBin!, profiles!, workRoot!, fixtureRoot.appending(path: "Developer")] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    try "".write(to: eventLog, atomically: true, encoding: .utf8)
    try installFakeTools()
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
  }

  func testFreshProfileIsANoOpByDefault() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )

    let result = try runResign()

    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("skipping renewal"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: appProfile.path))
    XCTAssertEqual(try events(), ["security app.mobileprovision"])
  }

  func testForceArchivesOnlyExactAppProfileAndBuildsVerifiesInstallsThenLaunches() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )
    let uiTestProfile = try writeProfile(
      named: "ui-tests.mobileprovision",
      applicationIdentifier:
        "\(teamIdentifier).dev.sayori.pinshift.uitests.xctrunner",
      expiration: "2099-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")

    let result = try runResign(arguments: ["--force"])

    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertFalse(FileManager.default.fileExists(atPath: appProfile.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: uiTestProfile.path))
    let archivedProfiles = try FileManager.default.subpathsOfDirectory(atPath: workRoot.path)
      .filter { $0.hasSuffix("-app.mobileprovision") }
    XCTAssertEqual(archivedProfiles.count, 1)
    XCTAssertFalse(
      try FileManager.default.subpathsOfDirectory(atPath: workRoot.path)
        .contains { $0.hasSuffix("-ui-tests.mobileprovision") }
    )
    try assertEventsContainInOrder(["xcodebuild", "codesign", "xcrun install", "xcrun launch"])
  }

  func testUnadvancedExpirationDoesNotInstallAndRestoresOldProfile() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-10T08:49:25Z")
    let originalContents = try String(contentsOf: appProfile, encoding: .utf8)

    let result = try runResign(
      arguments: ["--force"],
      environment: ["FAKE_REGENERATED_PROFILE_PATH": appProfile.path]
    )

    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("did not advance"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: appProfile.path))
    XCTAssertEqual(try String(contentsOf: appProfile, encoding: .utf8), originalContents)
    XCTAssertEqual(
      try FileManager.default.subpathsOfDirectory(atPath: workRoot.path)
        .filter { $0.contains("generated-") && $0.hasSuffix("app.mobileprovision") }.count,
      1
    )
    let recordedEvents = try events()
    XCTAssertTrue(recordedEvents.contains("xcodebuild"))
    XCTAssertTrue(recordedEvents.contains("codesign"))
    XCTAssertFalse(recordedEvents.contains("xcrun install"))
    XCTAssertFalse(recordedEvents.contains("xcrun launch"))
  }

  func testBuildFailureRestoresOldProfile() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )

    let result = try runResign(
      arguments: ["--force"],
      environment: ["FAKE_XCODEBUILD_STATUS": "65"]
    )

    XCTAssertEqual(result.status, 65)
    XCTAssertTrue(result.output.contains("old profile will be restored"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: appProfile.path))
    let recordedEvents = try events()
    XCTAssertTrue(recordedEvents.contains("xcodebuild"))
    XCTAssertFalse(recordedEvents.contains("codesign"))
    XCTAssertFalse(recordedEvents.contains("xcrun install"))
  }

  func testLockedPhoneLaunchIsNonFatalAfterSuccessfulInstall() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")

    let result = try runResign(
      arguments: ["--force"],
      environment: ["FAKE_LAUNCH_LOCKED": "1"]
    )

    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("Unlock the iPhone"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: appProfile.path))
    try assertEventsContainInOrder(["xcodebuild", "codesign", "xcrun install", "xcrun launch"])
  }

  func testNonzeroInstallResultPreservesNewProfileAndCandidateAsUncertain() throws {
    let appProfile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")

    let result = try runResign(
      arguments: ["--force"],
      environment: [
        "FAKE_INSTALL_STATUS": "1",
        "FAKE_REGENERATED_PROFILE_PATH": appProfile.path,
      ]
    )

    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("may or may not contain the renewed app"))
    XCTAssertTrue(
      try String(contentsOf: appProfile, encoding: .utf8)
        .contains("2099-08-17T08:49:25Z")
    )
    XCTAssertTrue(
      try FileManager.default.subpathsOfDirectory(atPath: workRoot.path)
        .contains { $0.hasSuffix("Pinshift.app/embedded.mobileprovision") }
    )
    let recordedEvents = try events()
    XCTAssertTrue(recordedEvents.contains("xcrun install"))
    XCTAssertFalse(recordedEvents.contains("xcrun launch"))
  }

  func testDailyRetryResumesInstallationAfterDeviceFailureDespiteFreshCachedProfile() throws {
    try assertDailyRetryResumesInstallation(initialFailure: ["FAKE_INSTALL_STATUS": "1"])
  }

  func testDailyRetryRequiresFreshInstallAcknowledgementAfterUnconfirmedResult() throws {
    try assertDailyRetryResumesInstallation(initialFailure: ["FAKE_INSTALL_UNCONFIRMED": "1"])
  }

  private func assertDailyRetryResumesInstallation(initialFailure: [String: String]) throws {
    let profile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2020-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")
    let first = try runDaily(
      environment: initialFailure.merging([
        "FAKE_REGENERATED_PROFILE_PATH": profile.path
      ]) { _, new in new })
    XCTAssertEqual(first.status, 0, first.output)
    XCTAssertTrue(first.output.contains("App preparation was not confirmed"))
    XCTAssertTrue(try String(contentsOf: profile, encoding: .utf8).contains("2099-08-17"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))

    // Default daily startup must install the preserved build, not skip because its cache is fresh.
    let second = try runDaily()
    XCTAssertEqual(second.status, 0, second.output)
    XCTAssertTrue(second.output.contains("Resuming the unconfirmed Pinshift installation"))
    XCTAssertTrue(second.output.contains("installed without uninstalling"))
    XCTAssertFalse(second.output.contains("skipping renewal"))
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingInstall.path))
    let recorded = try events()
    XCTAssertEqual(recorded.filter { $0 == "xcodebuild" }.count, 1)
    XCTAssertEqual(recorded.filter { $0 == "codesign" }.count, 2)
    XCTAssertEqual(recorded.filter { $0 == "xcrun install" }.count, 2)
    XCTAssertEqual(recorded.filter { $0 == "xcrun launch" }.count, 1)
    XCTAssertEqual(recorded.filter { $0 == "controller link serve" }.count, 2)
  }

  func testForceBuildsCurrentSourceInsteadOfInstallingAnOlderPendingCandidate() throws {
    try preparePendingInstallation()
    try writeCandidate(expiration: "2100-08-17T08:49:25Z")
    let installedProfile = fixtureRoot.appending(path: "installed.mobileprovision")
    let result = try runResign(
      arguments: ["--force"],
      environment: [
        "FAKE_REGENERATED_PROFILE_PATH": profiles.appending(path: "app.mobileprovision").path,
        "FAKE_INSTALLED_PROFILE_PATH": installedProfile.path,
      ])
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("building the current source"))
    XCTAssertFalse(result.output.contains("Resuming the unconfirmed"))
    XCTAssertEqual(try events().filter { $0 == "xcodebuild" }.count, 2)
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 2)
    XCTAssertTrue(
      try String(
        contentsOf: profiles.appending(path: "app.mobileprovision"), encoding: .utf8
      ).contains("2100-08-17"))
    XCTAssertEqual(try Data(contentsOf: installedProfile), try Data(contentsOf: candidateProfile))
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testFailedForcedRebuildPreservesEarlierPendingInstallationForDailyRetry() throws {
    try preparePendingInstallation()
    let pendingBefore = try Data(contentsOf: pendingInstall)
    let forced = try runResign(
      arguments: ["--force"], environment: ["FAKE_XCODEBUILD_STATUS": "1"]
    )
    XCTAssertNotEqual(forced.status, 0, forced.output)
    XCTAssertEqual(try Data(contentsOf: pendingInstall), pendingBefore)
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 1)

    let retry = try runDaily()
    XCTAssertEqual(retry.status, 0, retry.output)
    XCTAssertTrue(retry.output.contains("Resuming the unconfirmed"))
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testExpiredPendingBuildRenewsAgainOnDefaultDailyStartup() throws {
    try preparePendingInstallation()
    var record = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: pendingInstall)) as? [String: Any]
    )
    // Represent returning after the pending build's expiry, without waiting on wall-clock time.
    record["expiry"] = 1_600_000_000
    try JSONSerialization.data(withJSONObject: record).write(to: pendingInstall)
    try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2020-08-17T08:49:25Z"
    )
    let result = try runDaily()
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("pending app build has expired"))
    XCTAssertTrue(result.output.contains("installed without uninstalling"))
    XCTAssertEqual(try events().filter { $0 == "xcodebuild" }.count, 2)
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testPendingInstallationCannotResumeOnADifferentDevice() throws {
    try preparePendingInstallation()
    let result = try runResign(environment: ["PINSHIFT_DEVICE": "different-iphone"])
    XCTAssertNotEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("original Active Test Device"))
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testPendingRetryDoesNotAcceptAnOldSuccessfulLookingInstallResult() throws {
    // The first tool invocation writes success JSON but exits nonzero.
    try preparePendingInstallation()
    let retry = try runResign(environment: ["FAKE_INSTALL_UNCONFIRMED": "1"])
    XCTAssertNotEqual(retry.status, 0, retry.output)
    XCTAssertTrue(retry.output.contains("installation result could not be verified"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 2)
    XCTAssertFalse(try events().contains("xcrun launch"))
  }

  func testPendingInstallationRevalidatesSignatureBeforeTouchingDevice() throws {
    try preparePendingInstallation()
    let retry = try runResign(environment: ["FAKE_CODESIGN_STATUS": "1"])
    XCTAssertNotEqual(retry.status, 0, retry.output)
    XCTAssertTrue(retry.output.contains("failed code-signature verification"))
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testPendingInstallationRejectsChangedIdentityAndExpiredCandidate() throws {
    try preparePendingInstallation()
    let record = try XCTUnwrap(
      JSONSerialization.jsonObject(with: Data(contentsOf: pendingInstall)) as? [String: Any]
    )
    let staging = try XCTUnwrap(record["staging"] as? String)
    let preservedProfile = workRoot.appending(
      path:
        "\(staging)/DerivedData/Build/Products/Debug-iphoneos/Pinshift.app/embedded.mobileprovision"
    )
    let original = try String(contentsOf: preservedProfile, encoding: .utf8)
    try original.replacingOccurrences(of: teamIdentifier, with: "OTHERTEAM")
      .write(to: preservedProfile, atomically: true, encoding: .utf8)
    let changedIdentity = try runResign()
    XCTAssertNotEqual(changedIdentity.status, 0, changedIdentity.output)
    XCTAssertTrue(changedIdentity.output.contains("changed the app signing identity"))

    try original.replacingOccurrences(of: "2099-08-17", with: "2020-08-17")
      .write(to: preservedProfile, atomically: true, encoding: .utf8)
    let expired = try runResign()
    XCTAssertNotEqual(expired.status, 0, expired.output)
    XCTAssertTrue(expired.output.contains("did not advance"))
    XCTAssertEqual(try events().filter { $0 == "xcrun install" }.count, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  private var pendingInstall: URL {
    workRoot.appending(path: "pinshift-pending-install.json")
  }

  private func preparePendingInstallation() throws {
    let profile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2020-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")
    let result = try runResign(environment: [
      "FAKE_INSTALL_STATUS": "1", "FAKE_REGENERATED_PROFILE_PATH": profile.path,
    ])
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: pendingInstall.path))
  }

  func testExplicitStartSkipsFreshSigningAndStartsForegroundController() throws {
    try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2099-08-10T08:49:25Z"
    )
    let result = try runDaily(arguments: ["start"])
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertEqual(try events(), ["security app.mobileprovision", "controller link serve"])
  }

  func testDailyEntryRenewsExpiredSignatureBeforeStartingController() throws {
    try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2020-08-10T08:49:25Z"
    )
    try writeCandidate(expiration: "2099-08-17T08:49:25Z")
    let result = try runDaily()
    XCTAssertEqual(result.status, 0, result.output)
    try assertEventsContainInOrder([
      "xcodebuild", "codesign", "xcrun install", "xcrun launch", "controller link serve",
    ])
  }

  func testDailyMaintenanceFailurePreservesExistingProfileAndSession() throws {
    let expiration = ISO8601DateFormatter().string(from: Date().addingTimeInterval(3_600))
    let profile = try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: expiration
    )
    let result = try runDaily(environment: ["FAKE_XCODEBUILD_STATUS": "65"])
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("App preparation was not confirmed"))
    XCTAssertTrue(result.output.contains("Apple Accounts"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: profile.path))
    try assertEventsContainInOrder(["xcodebuild", "controller link serve"])
    XCTAssertFalse(try events().contains("xcrun install"))
  }

  func testInterruptedPreparationDoesNotStartController() throws {
    try writeProfile(
      named: "app.mobileprovision",
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: "2020-08-10T08:49:25Z"
    )
    let result = try runDaily(environment: ["FAKE_XCODEBUILD_STATUS": "130"])
    XCTAssertEqual(result.status, 130, result.output)
    XCTAssertFalse(try events().contains("controller link serve"))
  }

  func testDailyMissingProfileExplainsSetupWithoutClaimingAppReadiness() throws {
    let result = try runDaily()
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(result.output.contains("Signing & Capabilities"))
    XCTAssertTrue(result.output.contains("Trust This Computer"))
    XCTAssertTrue(result.output.contains("not confirmation that the app is ready"))
    XCTAssertEqual(try events(), ["controller link serve"])
  }

  func testDailyHelpAndInvalidArgumentsDoNotPrepareOrStart() throws {
    for arguments in [["--help"], ["start", "unexpected"]] {
      let result = try runDaily(arguments: arguments)
      XCTAssertEqual(result.status, arguments == ["--help"] ? 0 : 2, result.output)
    }
    XCTAssertEqual(try events(), [])
  }

  private func runDaily(
    arguments: [String] = [], environment: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let scripts = fixtureRoot.appending(path: "bin")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    for name in [
      "pinshift", "pinshift-start", "pinshift-resign-app", "_pinshift-common.fish",
      "_pinshift-app-signing.fish",
    ] {
      let source = resignScript.deletingLastPathComponent().appending(path: name)
      let destination = scripts.appending(path: name)
      if FileManager.default.fileExists(atPath: destination.path) {
        try FileManager.default.removeItem(at: destination)
      }
      try FileManager.default.copyItem(at: source, to: destination)
    }
    // Only the stable-controller resolver is replaced; daily dispatch and signing run unchanged.
    let common = scripts.appending(path: "_pinshift-common.fish")
    var contents = try String(contentsOf: common, encoding: .utf8)
    contents += "\nfunction pinshift_controller_executable\n echo $FAKE_CONTROLLER\nend\n"
    try contents.write(to: common, atomically: true, encoding: .utf8)
    try writeExecutable(
      named: "controller",
      contents: """
        #!/bin/sh
        printf 'controller %s %s\n' "$1" "$2" >> "$FAKE_EVENT_LOG"
        """)
    return try runResign(
      arguments: arguments,
      environment: environment.merging([
        "FAKE_CONTROLLER": fakeBin.appending(path: "controller").path
      ]) {
        _, new in new
      },
      script: scripts.appending(path: "pinshift")
    )
  }

  private func installFakeTools() throws {
    try writeExecutable(
      named: "security",
      contents: """
        #!/bin/sh
        printf 'security %s\n' "$(basename "$4")" >> "$FAKE_EVENT_LOG"
        /bin/cat "$4"
        """
    )
    try writeExecutable(
      named: "xcodebuild",
      contents: """
        #!/bin/sh
        printf 'xcodebuild\n' >> "$FAKE_EVENT_LOG"
        if [ "${FAKE_XCODEBUILD_STATUS:-0}" -ne 0 ]; then
          printf 'simulated build failure\n'
          exit "$FAKE_XCODEBUILD_STATUS"
        fi
        derived_data=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '-derivedDataPath' ]; then
            derived_data="$2"
            break
          fi
          shift
        done
        app="$derived_data/Build/Products/Debug-iphoneos/Pinshift.app"
        /bin/mkdir -p "$app"
        /bin/cp "$FAKE_CANDIDATE_PROFILE" "$app/embedded.mobileprovision"
        if [ -n "${FAKE_REGENERATED_PROFILE_PATH:-}" ]; then
          /bin/cp "$FAKE_CANDIDATE_PROFILE" "$FAKE_REGENERATED_PROFILE_PATH"
        fi
        /usr/bin/printf '%s\n' \\
          '<?xml version="1.0" encoding="UTF-8"?>' \\
          '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \\
          '<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>dev.sayori.pinshift</string></dict></plist>' \\
          > "$app/Info.plist"
        """
    )
    try writeExecutable(
      named: "codesign",
      contents: """
        #!/bin/sh
        printf 'codesign\n' >> "$FAKE_EVENT_LOG"
        exit "${FAKE_CODESIGN_STATUS:-0}"
        """
    )
    try writeExecutable(
      named: "xcrun",
      contents: """
        #!/bin/sh
        json_output=''
        previous=''
        for argument in "$@"; do
          if [ "$previous" = '--json-output' ]; then
            json_output="$argument"
          fi
          previous="$argument"
        done
        case " $* " in
        *' device install app '*)
          printf 'xcrun install\n' >> "$FAKE_EVENT_LOG"
          if [ -n "${FAKE_INSTALLED_PROFILE_PATH:-}" ]; then
            /bin/cp "$previous/embedded.mobileprovision" "$FAKE_INSTALLED_PROFILE_PATH"
          fi
          if [ "${FAKE_INSTALL_UNCONFIRMED:-0}" -eq 1 ]; then
            exit 0
          fi
          /usr/bin/printf '%s\n' '{"info":{"outcome":"success"}}' > "$json_output"
          exit "${FAKE_INSTALL_STATUS:-0}"
          ;;
          *' device process launch '*)
            printf 'xcrun launch\n' >> "$FAKE_EVENT_LOG"
            if [ "${FAKE_LAUNCH_LOCKED:-0}" -eq 1 ]; then
              printf 'The device was Locked and could not be unlocked\n'
              exit 1
            fi
            /usr/bin/printf '%s\n' '{"info":{"outcome":"success"}}' > "$json_output"
            ;;
          *) exit 2 ;;
        esac
        """
    )
  }

  @discardableResult
  private func writeProfile(
    named name: String,
    applicationIdentifier: String,
    expiration: String
  ) throws -> URL {
    let url = profiles.appending(path: name)
    try profilePlist(
      applicationIdentifier: applicationIdentifier,
      expiration: expiration
    ).write(to: url, atomically: true, encoding: .utf8)
    return url
  }

  private func writeCandidate(expiration: String) throws {
    try profilePlist(
      applicationIdentifier: "\(teamIdentifier).\(bundleIdentifier)",
      expiration: expiration
    ).write(to: candidateProfile, atomically: true, encoding: .utf8)
  }

  private func profilePlist(applicationIdentifier: String, expiration: String) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0"><dict>
      <key>TeamIdentifier</key><array><string>\(teamIdentifier)</string></array>
      <key>ApplicationIdentifierPrefix</key><array><string>\(teamIdentifier)</string></array>
      <key>ExpirationDate</key><date>\(expiration)</date>
      <key>Platform</key><array><string>iOS</string></array>
      <key>Entitlements</key><dict>
        <key>application-identifier</key><string>\(applicationIdentifier)</string>
      </dict>
    </dict></plist>
    """
  }

  private func runResign(
    arguments: [String] = [],
    environment: [String: String] = [:],
    script: URL? = nil
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["fish", (script ?? resignScript).path] + arguments
    process.environment = ProcessInfo.processInfo.environment.merging(
      [
        "PATH": "\(fakeBin.path):/etc/profiles/per-user/sayori/bin:/usr/bin:/bin",
        "PINSHIFT_DEVELOPER_DIR": fixtureRoot.appending(path: "Developer").path,
        "PINSHIFT_DEVICE": "test-iphone",
        "PINSHIFT_PROVISIONING_PROFILE_DIRECTORY": profiles.path,
        "PINSHIFT_RESIGN_WORK_ROOT": workRoot.path,
        "FAKE_EVENT_LOG": eventLog.path,
        "FAKE_CANDIDATE_PROFILE": candidateProfile.path,
      ].merging(environment) { _, new in new }
    ) { _, new in new }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func events() throws -> [String] {
    try String(contentsOf: eventLog, encoding: .utf8)
      .split(separator: "\n")
      .map(String.init)
  }

  private func assertEventsContainInOrder(
    _ expected: [String],
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws {
    let recorded = try events()
    var searchStart = recorded.startIndex
    for event in expected {
      guard let index = recorded[searchStart...].firstIndex(of: event) else {
        XCTFail(
          "Missing \(event) after index \(searchStart); events: \(recorded)", file: file, line: line
        )
        return
      }
      searchStart = recorded.index(after: index)
    }
  }

  private func writeExecutable(named name: String, contents: String) throws {
    let url = fakeBin.appending(path: name)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }
}
