import Foundation
import XCTest

final class ControllerInstallationResolverTests: XCTestCase {
  private var fixtureRoot: URL!
  private var fakeBin: URL!
  private var commonScript: URL {
    URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appending(path: "bin/_pinshift-common.fish")
  }

  override func setUpWithError() throws {
    fixtureRoot = FileManager.default.temporaryDirectory
      .appending(path: "pinshift-resolver-\(UUID().uuidString)")
    fakeBin = fixtureRoot.appending(path: "fake-bin")
    let controllerRoot = fixtureRoot.appending(path: ".build/controller")
    let executable = controllerRoot.appending(path: "bin/pinshift-controller")
    try FileManager.default.createDirectory(
      at: executable.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(at: fakeBin, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: fixtureRoot.appending(path: "Sources"),
      withIntermediateDirectories: true
    )
    try "// fixture\n".write(
      to: fixtureRoot.appending(path: "Package.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "struct Fixture {}\n".write(
      to: fixtureRoot.appending(path: "Sources/Fixture.swift"),
      atomically: true,
      encoding: .utf8
    )
    try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
    try makeExecutable(executable)

    let fakeCodesign = fakeBin.appending(path: "codesign")
    try """
    #!/bin/sh
    if [ "$1" = "--verify" ]; then
      exit "${FAKE_CODESIGN_VERIFY_STATUS:-0}"
    fi
    if [ "$1" = "-d" ]; then
      printf '%s\n' "${FAKE_CODESIGN_REQUIREMENT}" >&2
      exit 0
    fi
    exit 2
    """.write(to: fakeCodesign, atomically: true, encoding: .utf8)
    try makeExecutable(fakeCodesign)

    let fingerprint = try runFish("pinshift_controller_source_fingerprint").output
      .trimmingCharacters(in: .whitespacesAndNewlines)
    try "\(fingerprint)\n".write(
      to: controllerRoot.appending(path: "source-fingerprint"),
      atomically: true,
      encoding: .utf8
    )
  }

  override func tearDownWithError() throws {
    if let fixtureRoot {
      try? FileManager.default.removeItem(at: fixtureRoot)
    }
  }

  func testResolverExecutesEveryInstallationSafetyGuard() throws {
    let validRequirement =
      "designated => identifier \"dev.sayori.pinshift.controller\" and anchor apple generic"
    let requirementFile = fixtureRoot.appending(path: ".build/controller/designated-requirement")
    try "\(validRequirement)\n".write(
      to: requirementFile,
      atomically: true,
      encoding: .utf8
    )

    var result = try runResolver(requirement: validRequirement)
    XCTAssertEqual(result.status, 0, result.output)

    result = try runResolver(requirement: validRequirement, verifyStatus: 1)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("signature is invalid"))

    result = try runResolver(
      requirement: "designated => identifier \"wrong.identifier\" and anchor apple generic"
    )
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("required fixed identifier"))

    result = try runResolver(
      requirement:
        "designated => identifier \"dev.sayori.pinshift.controller\" and cdhash H\"00\""
    )
    XCTAssertNotEqual(result.status, 0)

    result = try runResolver(
      requirement:
        "designated => identifier \"dev.sayori.pinshift.controller\" and certificate leaf = H\"changed\""
    )
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("signing identity changed"))

    try "stale\n".write(
      to: fixtureRoot.appending(path: ".build/controller/source-fingerprint"),
      atomically: true,
      encoding: .utf8
    )
    result = try runResolver(requirement: validRequirement)
    XCTAssertNotEqual(result.status, 0)
    XCTAssertTrue(result.output.contains("source changed"))
  }

  func testDailyDoctorAndClearDispatchThroughTheVerifiedInstallation() throws {
    let scripts = fixtureRoot.appending(path: "bin")
    try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
    for name in ["pinshift", "_pinshift-common.fish"] {
      try FileManager.default.copyItem(
        at: commonScript.deletingLastPathComponent().appending(path: name),
        to: scripts.appending(path: name))
    }
    let requirement =
      "designated => identifier \"dev.sayori.pinshift.controller\" and anchor apple generic"
    try requirement.write(
      to: fixtureRoot.appending(path: ".build/controller/designated-requirement"),
      atomically: true, encoding: .utf8)
    try "#!/bin/sh\nprintf '%s' \"$*\"\nexit 23\n".write(
      to: fixtureRoot.appending(path: ".build/controller/bin/pinshift-controller"),
      atomically: true, encoding: .utf8)
    for (command, expected) in [
      ("doctor", "doctor"), ("check", "doctor"), ("clear", "reset"), ("reset", "reset"),
    ] {
      let result = try runFish(
        "fish '\(scripts.appending(path: "pinshift").path)' \(command)",
        environment: [
          "PINSHIFT_DEVICE": "fixture-device",
          "PINSHIFT_DEVELOPER_DIR": fixtureRoot.path,
          "FAKE_CODESIGN_REQUIREMENT": requirement,
        ])
      XCTAssertEqual(result.status, 23, result.output)
      XCTAssertEqual(result.output, expected)
    }
  }

  private func runResolver(
    requirement: String,
    verifyStatus: Int = 0
  ) throws -> (status: Int32, output: String) {
    try runFish(
      "pinshift_controller_executable",
      environment: [
        "FAKE_CODESIGN_REQUIREMENT": requirement,
        "FAKE_CODESIGN_VERIFY_STATUS": String(verifyStatus),
      ]
    )
  }

  private func runFish(
    _ command: String,
    environment: [String: String] = [:]
  ) throws -> (status: Int32, output: String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
      "fish",
      "-lc",
      "set -gx PATH '\(fakeBin.path)' $PATH; source '\(commonScript.path)'; cd '\(fixtureRoot.path)'; \(command)",
    ]
    process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
    process.standardOutput = output
    process.standardError = output
    try process.run()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    )
  }

  private func makeExecutable(_ url: URL) throws {
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: url.path
    )
  }
}
