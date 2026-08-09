import Foundation

public struct ControllerDoctorConfiguration: Equatable, Sendable {
  public let device: String?
  public let developerDirectory: String
  public let identityLabel: String

  public init(device: String?, developerDirectory: String, identityLabel: String) {
    self.device = device
    self.developerDirectory = developerDirectory
    self.identityLabel = identityLabel
  }
}

public enum ControllerDoctorDeviceState: Equatable, Sendable {
  case available
  case notConfigured
  case unavailable
  case developerModeDisabled
  case developerDiskImageIncompatible
}

public struct ControllerDoctorSnapshot: Equatable, Sendable {
  public let activeDeveloperDirectory: String?
  public let xcodeVersion: String?
  public let firstLaunchReady: Bool
  public let deviceState: ControllerDoctorDeviceState
  public let signingReady: Bool
  public let controllerIdentityReady: Bool

  public init(
    activeDeveloperDirectory: String?,
    xcodeVersion: String?,
    firstLaunchReady: Bool,
    deviceState: ControllerDoctorDeviceState,
    signingReady: Bool,
    controllerIdentityReady: Bool
  ) {
    self.activeDeveloperDirectory = activeDeveloperDirectory
    self.xcodeVersion = xcodeVersion
    self.firstLaunchReady = firstLaunchReady
    self.deviceState = deviceState
    self.signingReady = signingReady
    self.controllerIdentityReady = controllerIdentityReady
  }
}

public enum ControllerDoctorCheckID: String, Equatable, Sendable {
  case fullXcode
  case developerDirectory
  case firstLaunch
  case activeDevice
  case developerMode
  case developerDiskImage
  case signing
  case controllerIdentity
  case appPermissions
}

public enum ControllerDoctorCheckStatus: String, Equatable, Sendable {
  case pass
  case warning
  case fail
}

public struct ControllerDoctorCheck: Equatable, Sendable {
  public let id: ControllerDoctorCheckID
  public let status: ControllerDoctorCheckStatus
  public let summary: String
  public let recovery: String

  public init(
    id: ControllerDoctorCheckID,
    status: ControllerDoctorCheckStatus,
    summary: String,
    recovery: String = ""
  ) {
    self.id = id
    self.status = status
    self.summary = summary
    self.recovery = recovery
  }
}

public struct ControllerDoctorReport: Equatable, Sendable {
  public let exitCode: Int32
  public let output: String
  public let checks: [ControllerDoctorCheck]

  public init(exitCode: Int32, output: String, checks: [ControllerDoctorCheck]) {
    self.exitCode = exitCode
    self.output = output
    self.checks = checks
  }
}

public enum ControllerDoctor {
  public static func evaluate(
    _ snapshot: ControllerDoctorSnapshot,
    configuration: ControllerDoctorConfiguration
  ) -> ControllerDoctorReport {
    let checks = [
      fullXcodeCheck(snapshot),
      developerDirectoryCheck(snapshot, configuration: configuration),
      firstLaunchCheck(snapshot),
      activeDeviceCheck(snapshot),
      developerModeCheck(snapshot),
      developerDiskImageCheck(snapshot),
      signingCheck(snapshot),
      controllerIdentityCheck(snapshot),
      appPermissionsCheck(),
    ]
    let exitCode: Int32 = checks.contains { $0.status == .fail } ? 1 : 0
    let lines = checks.flatMap { check -> [String] in
      let prefix: String
      switch check.status {
      case .pass:
        prefix = "PASS"
      case .warning:
        prefix = "WARN"
      case .fail:
        prefix = "FAIL"
      }
      var result = ["[\(prefix)] \(check.summary)"]
      if !check.recovery.isEmpty {
        result.append("  Recovery: \(check.recovery)")
      }
      return result
    }
    let output = (["Pinshift Doctor (read-only)"] + lines + ["No settings were changed."])
      .joined(separator: "\n")

    return ControllerDoctorReport(exitCode: exitCode, output: output, checks: checks)
  }

  private static func fullXcodeCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    guard snapshot.xcodeVersion != nil else {
      return ControllerDoctorCheck(
        id: .fullXcode,
        status: .fail,
        summary: "The configured developer directory does not expose a full Xcode toolchain.",
        recovery:
          "Install or restore Xcode, then pass its Contents/Developer directory with --developer-directory."
      )
    }
    return ControllerDoctorCheck(
      id: .fullXcode,
      status: .pass,
      summary: "A full Xcode toolchain is available."
    )
  }

  private static func developerDirectoryCheck(
    _ snapshot: ControllerDoctorSnapshot,
    configuration: ControllerDoctorConfiguration
  ) -> ControllerDoctorCheck {
    guard let active = snapshot.activeDeveloperDirectory else {
      return ControllerDoctorCheck(
        id: .developerDirectory,
        status: .fail,
        summary: "The active developer directory could not be read.",
        recovery: "Pass the full Xcode Contents/Developer path with --developer-directory."
      )
    }
    if active.contains("CommandLineTools") {
      return ControllerDoctorCheck(
        id: .developerDirectory,
        status: .warning,
        summary: "The global developer directory points to Command Line Tools.",
        recovery:
          "Keep using --developer-directory for this command; it does not change the global selection."
      )
    }
    if standardized(active) != standardized(configuration.developerDirectory) {
      return ControllerDoctorCheck(
        id: .developerDirectory,
        status: .warning,
        summary: "The global developer directory differs from this controller's Xcode toolchain.",
        recovery:
          "The controller will use --developer-directory for this command and does not change the global selection."
      )
    }
    return ControllerDoctorCheck(
      id: .developerDirectory,
      status: .pass,
      summary: "The active developer directory matches the configured Xcode toolchain."
    )
  }

  private static func firstLaunchCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    guard snapshot.firstLaunchReady else {
      return ControllerDoctorCheck(
        id: .firstLaunch,
        status: .fail,
        summary: "Xcode first-launch setup is incomplete.",
        recovery: "Please open Xcode once and finish its first-launch setup, then run doctor again."
      )
    }
    return ControllerDoctorCheck(
      id: .firstLaunch,
      status: .pass,
      summary: "Xcode first-launch setup is complete."
    )
  }

  private static func activeDeviceCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    switch snapshot.deviceState {
    case .available:
      return ControllerDoctorCheck(
        id: .activeDevice,
        status: .pass,
        summary: "The configured iPhone is available to the Xcode device workflow."
      )
    case .notConfigured:
      return ControllerDoctorCheck(
        id: .activeDevice,
        status: .fail,
        summary: "No active iPhone is configured.",
        recovery:
          "Connect an iPhone and pass its private selector with --device or PINSHIFT_DEVICE."
      )
    case .unavailable:
      return ControllerDoctorCheck(
        id: .activeDevice,
        status: .fail,
        summary: "The configured iPhone is not currently available.",
        recovery:
          "Unlock and reconnect the iPhone, confirm Trust if prompted, then run doctor again."
      )
    case .developerModeDisabled:
      return ControllerDoctorCheck(
        id: .activeDevice,
        status: .fail,
        summary: "The configured iPhone is connected but not ready for development.",
        recovery: "Enable Developer Mode on the iPhone, reconnect it, and run doctor again."
      )
    case .developerDiskImageIncompatible:
      return ControllerDoctorCheck(
        id: .activeDevice,
        status: .pass,
        summary: "The configured iPhone is visible to Xcode."
      )
    }
  }

  private static func developerModeCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    switch snapshot.deviceState {
    case .available, .developerDiskImageIncompatible:
      return ControllerDoctorCheck(
        id: .developerMode,
        status: .pass,
        summary: "Developer Mode is available for the configured iPhone."
      )
    case .developerModeDisabled:
      return ControllerDoctorCheck(
        id: .developerMode,
        status: .fail,
        summary: "Developer Mode is disabled on the configured iPhone.",
        recovery:
          "Enable Developer Mode in iPhone Settings > Privacy & Security, restart if prompted, and confirm it after restart."
      )
    case .notConfigured, .unavailable:
      return ControllerDoctorCheck(
        id: .developerMode,
        status: .warning,
        summary: "Developer Mode could not be checked without an available iPhone.",
        recovery: "Resolve the active-device check, then run doctor again."
      )
    }
  }

  private static func developerDiskImageCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    switch snapshot.deviceState {
    case .available:
      return ControllerDoctorCheck(
        id: .developerDiskImage,
        status: .pass,
        summary: "The Xcode device support image is compatible."
      )
    case .developerDiskImageIncompatible:
      return ControllerDoctorCheck(
        id: .developerDiskImage,
        status: .fail,
        summary: "Xcode cannot prepare a compatible developer disk image for this iPhone.",
        recovery:
          "Use an Xcode version that supports the iPhone OS version, then reconnect the iPhone."
      )
    case .developerModeDisabled, .notConfigured, .unavailable:
      return ControllerDoctorCheck(
        id: .developerDiskImage,
        status: .warning,
        summary: "Developer disk image compatibility could not be checked yet.",
        recovery: "Resolve the earlier device readiness failure, then run doctor again."
      )
    }
  }

  private static func signingCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    guard snapshot.signingReady else {
      return ControllerDoctorCheck(
        id: .signing,
        status: .fail,
        summary: "No usable Apple Development signing identity was found.",
        recovery:
          "Open the app target's Signing & Capabilities in Xcode and select an available development team."
      )
    }
    return ControllerDoctorCheck(
      id: .signing,
      status: .pass,
      summary: "A development signing identity is available."
    )
  }

  private static func controllerIdentityCheck(
    _ snapshot: ControllerDoctorSnapshot
  ) -> ControllerDoctorCheck {
    guard snapshot.controllerIdentityReady else {
      return ControllerDoctorCheck(
        id: .controllerIdentity,
        status: .fail,
        summary: "The Controller Link identity is missing from Keychain.",
        recovery:
          "Run `pinshift-controller link identity create` once, then run doctor again."
      )
    }
    return ControllerDoctorCheck(
      id: .controllerIdentity,
      status: .pass,
      summary: "The Keychain-backed Controller Link identity is ready."
    )
  }

  private static func appPermissionsCheck() -> ControllerDoctorCheck {
    ControllerDoctorCheck(
      id: .appPermissions,
      status: .warning,
      summary: "Location and Local Network permissions are confirmed inside the iPhone app.",
      recovery:
        "Launch the app, follow its permission guidance, and use its Settings buttons if access was denied."
    )
  }

  private static func standardized(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
  }
}
