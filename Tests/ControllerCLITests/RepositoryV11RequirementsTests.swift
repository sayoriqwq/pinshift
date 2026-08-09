import Foundation
import XCTest

final class RepositoryV11RequirementsTests: XCTestCase {
  private var repositoryRoot: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  func testDailyHelpersUseOnlyTheInstalledController() throws {
    for helper in ["rl-start", "rl-doctor", "rl-reset"] {
      let contents = try String(
        contentsOf: repositoryRoot.appending(path: "bin/\(helper)"),
        encoding: .utf8
      )
      XCTAssertFalse(contents.contains("swift run"), "\(helper) must not compile on daily use")
      XCTAssertTrue(
        contents.contains("rl_controller_executable"),
        "\(helper) must resolve the verified installed controller"
      )
    }
  }

  func testDailyStartDefersItsDefaultLeaseToTheControllerOwnedPolicy() throws {
    let contents = try String(
      contentsOf: repositoryRoot.appending(path: "bin/rl-start"),
      encoding: .utf8
    )

    XCTAssertFalse(contents.contains("set --local lease_seconds 300"))
    XCTAssertFalse(contents.contains("after 300 seconds by default"))
    XCTAssertTrue(contents.contains("15 minutes by default"))
    XCTAssertTrue(contents.contains("set --append serve_arguments --lease-seconds"))
  }

  func testDiagnosticsHelperLocatesOrCopiesTheMacPackageWithoutRunningRecovery() throws {
    let helperURL = repositoryRoot.appending(path: "bin/rl-diagnostics")
    XCTAssertTrue(FileManager.default.isExecutableFile(atPath: helperURL.path))
    let contents = try String(contentsOf: helperURL, encoding: .utf8)

    XCTAssertTrue(contents.contains("mac-controller.jsonl"))
    XCTAssertTrue(contents.contains("mac-controller.metadata.json"))
    XCTAssertTrue(contents.contains("_flag_copy_to"))
    XCTAssertFalse(contents.contains("rl-reset"))
    XCTAssertFalse(contents.contains("devicectl"))
    XCTAssertFalse(contents.contains("xcrun"))
  }

  func testDiagnosticsCopyIncludesParseableMetadataAndEvents() throws {
    let source = temporaryDirectory()
    let destination = temporaryDirectory()
    defer {
      try? FileManager.default.removeItem(at: source)
      try? FileManager.default.removeItem(at: destination)
    }
    let event = "{\"schemaVersion\":1,\"kind\":\"controller.devicectl.started\"}\\n"
    let metadata = "{\"schemaVersion\":1,\"generationID\":\"00000000-0000-0000-0000-000000000001\"}"
    try event.data(using: .utf8)!.write(
      to: source.appendingPathComponent("mac-controller.jsonl")
    )
    try metadata.data(using: .utf8)!.write(
      to: source.appendingPathComponent("mac-controller.metadata.json")
    )

    let process = Process()
    process.executableURL = repositoryRoot.appending(path: "bin/rl-diagnostics")
    process.arguments = ["--copy-to", destination.path]
    process.environment = [
      "PATH": "/etc/profiles/per-user/sayori/bin:/usr/bin:/bin",
      "REMOTE_LOCATION_DIAGNOSTICS_DIRECTORY": source.path,
    ]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)

    let copiedMetadata = try Data(
      contentsOf: destination.appendingPathComponent(
        "mac-controller.metadata.json"
      ))
    let copiedEvents = try String(
      contentsOf: destination.appendingPathComponent(
        "mac-controller.jsonl"
      ), encoding: .utf8)
    let object = try JSONSerialization.jsonObject(with: copiedMetadata) as? [String: Any]
    XCTAssertEqual(object?["schemaVersion"] as? Int, 1)
    XCTAssertNotNil(object?["generationID"] as? String)
    XCTAssertTrue(copiedEvents.contains("controller.devicectl.started"))
  }

  private func temporaryDirectory() -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func testInstallWorkflowIsExplicitAndNeverUsesAnAllowAllKeyACL() throws {
    let installerURL = repositoryRoot.appending(path: "bin/rl-install")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: installerURL.path),
      "The repository must provide an executable rl-install workflow"
    )
    let contents = try String(contentsOf: installerURL, encoding: .utf8)
    XCTAssertFalse(contents.contains("create-keypair -A"))
    XCTAssertFalse(contents.contains("set-key-partition-list"))
    XCTAssertTrue(contents.contains("codesign --verify"))
  }

  func testInstallRegistersCleanupGuardianOutsideTheControllerLinkProcess() throws {
    let contents = try String(
      contentsOf: repositoryRoot.appending(path: "bin/rl-install"),
      encoding: .utf8
    )
    let template = try String(
      contentsOf: repositoryRoot.appending(
        path: "Support/dev.sayori.remotelocation.cleanup-guardian.plist"
      ),
      encoding: .utf8
    )

    XCTAssertTrue(contents.contains("launchctl bootstrap"))
    XCTAssertTrue(contents.contains("launchctl kickstart -k"))
    let guardianBootout = try XCTUnwrap(
      contents.range(of: "launchctl bootout gui/$user_id/$guardian_label")
    )
    let executablePublish = try XCTUnwrap(contents.range(of: "cp $candidate $executable"))
    XCTAssertLessThan(guardianBootout.lowerBound, executablePublish.lowerBound)
    XCTAssertTrue(template.contains("cleanup-guardian"))
    XCTAssertTrue(template.contains("<key>KeepAlive</key>"))
    XCTAssertTrue(template.contains("<key>RunAtLoad</key>"))
  }

  func testAppResigningWorkflowValidatesBeforeUpdatingTheExistingApp() throws {
    let helperURL = repositoryRoot.appending(path: "bin/rl-resign-app")
    XCTAssertTrue(
      FileManager.default.isExecutableFile(atPath: helperURL.path),
      "The repository must provide an executable app renewal workflow"
    )

    let contents = try String(contentsOf: helperURL, encoding: .utf8)
    let signingHelpers = try String(
      contentsOf: repositoryRoot.appending(path: "bin/_rl-app-signing.fish"),
      encoding: .utf8
    )

    XCTAssertTrue(contents.contains("-allowProvisioningUpdates"))
    XCTAssertTrue(contents.contains("embedded.mobileprovision"))
    XCTAssertTrue(contents.contains("codesign --verify --deep --strict"))
    XCTAssertTrue(contents.contains("dev.sayori.remotelocation.learning"))
    XCTAssertTrue(contents.contains("devicectl device install app"))
    XCTAssertFalse(contents.contains("device uninstall"))
    XCTAssertTrue(signingHelpers.contains("ApplicationIdentifierPrefix.0"))
    XCTAssertTrue(signingHelpers.contains("$prefix.$bundle_identifier"))

    let verification = try XCTUnwrap(contents.range(of: "codesign --verify --deep --strict"))
    let installation = try XCTUnwrap(contents.range(of: "devicectl device install app"))
    XCTAssertLessThan(verification.lowerBound, installation.lowerBound)
  }

  func testInstalledControllerResolverRejectsEveryUnsafeInstallationState() throws {
    let contents = try String(
      contentsOf: repositoryRoot.appending(path: "bin/_rl-common.fish"),
      encoding: .utf8
    )

    XCTAssertTrue(contents.contains("not test -x $executable"), "missing executable")
    XCTAssertTrue(contents.contains("codesign --verify --strict $executable"), "invalid signature")
    XCTAssertTrue(
      contents.contains("The controller source changed after installation"), "stale source")
    XCTAssertTrue(
      contents.contains("$actual_requirement\" != \"$expected_requirement"), "requirement rotation")
    XCTAssertTrue(contents.contains("required fixed identifier"), "fixed identifier")
  }

  func testRequirementRotationIsRejectedBeforeKeychainAuthorization() throws {
    let contents = try String(
      contentsOf: repositoryRoot.appending(path: "bin/rl-install"),
      encoding: .utf8
    )
    let requirementCheck = try XCTUnwrap(contents.range(of: "The signing requirement changed"))
    let authorization = try XCTUnwrap(
      contents.range(of: "authorize-current-executable")
    )
    XCTAssertLessThan(requirementCheck.lowerBound, authorization.lowerBound)
  }

  func testAuthorizationMigrationIncludesTheExistingServerAuthorizationStoreWithoutReplacingIt()
    throws
  {
    let contents = try String(
      contentsOf: repositoryRoot.appending(
        path: "Sources/ControllerCLI/ControllerIdentityAccessAuthorizer.swift"
      ),
      encoding: .utf8
    )
    XCTAssertTrue(contents.contains("controller-server-authorization"))
    XCTAssertTrue(contents.contains("SecKeychainFindGenericPassword"))
    XCTAssertTrue(contents.contains("kSecACLAuthorizationDecrypt"))
    XCTAssertFalse(contents.contains("SecKeychainItemDelete"))
  }

  func testLearningAppDeclaresALaunchScreen() throws {
    let infoURL = repositoryRoot.appending(
      path: "Config/RemoteLocationLearning-Info.plist"
    )
    let data = try Data(contentsOf: infoURL)
    let value = try PropertyListSerialization.propertyList(from: data, format: nil)
    let info = try XCTUnwrap(value as? [String: Any])
    XCTAssertTrue(
      info["UILaunchScreen"] != nil || info["UILaunchStoryboardName"] != nil,
      "A launch screen is required to avoid iPhone compatibility letterboxing"
    )
  }

  func testLearningAppBuildConfigurationCompilesTheBrandedAppIcon() throws {
    let specification = try String(
      contentsOf: repositoryRoot.appending(path: "project.yml"),
      encoding: .utf8
    )
    XCTAssertTrue(
      specification.contains("ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon"),
      "The XcodeGen source of truth must select the AppIcon set"
    )

    let project = try String(
      contentsOf: repositoryRoot.appending(
        path: "RemoteLocation.xcodeproj/project.pbxproj"
      ),
      encoding: .utf8
    )
    XCTAssertEqual(
      project.components(separatedBy: "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
        .count - 1,
      2,
      "Both generated Learning App build configurations must select AppIcon"
    )

    let catalogData = try Data(
      contentsOf: repositoryRoot.appending(
        path: "App/Assets.xcassets/AppIcon.appiconset/Contents.json"
      )
    )
    let catalog = try XCTUnwrap(
      JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
    )
    let images = try XCTUnwrap(catalog["images"] as? [[String: Any]])
    XCTAssertTrue(
      images.contains { $0["filename"] as? String == "AppIcon.png" },
      "The selected AppIcon set must retain its source image"
    )
  }
}
