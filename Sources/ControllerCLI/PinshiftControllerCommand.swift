import ArgumentParser
import ControllerLink
import Foundation
import SimulationController

public struct ActiveDeviceOptions: ParsableArguments {
  @Option(
    name: .long,
    help: "Active Test Device name or identifier. Falls back to PINSHIFT_DEVICE."
  )
  public var device: String?

  @Option(
    name: .long,
    help: "Xcode developer directory. Falls back to PINSHIFT_DEVELOPER_DIR."
  )
  public var developerDirectory: String?

  public init() {}
}

public struct PinshiftControllerCommand: AsyncParsableCommand {
  public static let configuration = CommandConfiguration(
    commandName: "pinshift-controller",
    abstract: "Control temporary locations on an Xcode-connected device.",
    subcommands: [
      Status.self, Clear.self, Reset.self, Doctor.self, Tutorial.self, Link.self,
    ],
    defaultSubcommand: Status.self
  )

  public init() {}

  public struct Doctor: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Run read-only Xcode, device, signing, identity, and permission readiness checks."
    )

    @OptionGroup public var activeDevice: ActiveDeviceOptions

    @Option(name: .long, help: "Keychain label for the controller identity.")
    public var identityLabel = "Pinshift Controller"

    public init() {}

    public func run() async throws {
      let runtime = ControllerCLIRuntime.resolveConfiguration(
        device: activeDevice.device,
        developerDirectory: activeDevice.developerDirectory
      )
      let configuration = ControllerDoctorConfiguration(
        device: runtime.device,
        developerDirectory: runtime.developerDirectory,
        identityLabel: identityLabel
      )
      let snapshot = FoundationControllerDoctorProbe().snapshot(configuration: configuration)
      let report = ControllerDoctor.evaluate(snapshot, configuration: configuration)
      print(report.output)
      guard report.exitCode == 0 else {
        throw ExitCode(report.exitCode)
      }
    }
  }

  public struct Tutorial: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Print the current Xcode/devicectl setup and usage tutorial."
    )

    public init() {}

    public func run() async throws {
      print(ControllerTutorial.output)
    }
  }

  public struct Status: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Report the Injection Backend state."
    )

    public init() {}

    @OptionGroup public var activeDevice: ActiveDeviceOptions

    public func run() async throws {
      try await emit(await makeRunner(activeDevice).run(.status))
    }
  }

  public struct Clear: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Clear the current temporary location now."
    )

    @Option(name: .long, help: "Optional request UUID for correlation.")
    public var requestID: String?

    @OptionGroup public var activeDevice: ActiveDeviceOptions

    public init() {}

    public func run() async throws {
      let parsedRequestID: UUID
      if let requestID {
        guard let value = UUID(uuidString: requestID) else {
          throw ValidationError("--request-id must be a UUID.")
        }
        parsedRequestID = value
      } else {
        parsedRequestID = UUID()
      }
      try await emit(
        await makeRunner(activeDevice).run(.clear(requestID: parsedRequestID))
      )
    }
  }

  public struct Reset: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Idempotently clear any active temporary location."
    )

    @Option(name: .long, help: "Optional request UUID for correlation.")
    public var requestID: String?

    @OptionGroup public var activeDevice: ActiveDeviceOptions

    public init() {}

    public func run() async throws {
      let parsedRequestID: UUID
      if let requestID {
        guard let value = UUID(uuidString: requestID) else {
          throw ValidationError("--request-id must be a UUID.")
        }
        parsedRequestID = value
      } else {
        parsedRequestID = UUID()
      }
      try await emit(
        await makeRunner(activeDevice).run(.reset(requestID: parsedRequestID))
      )
    }
  }

  public struct Link: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
      abstract: "Manage the trusted local-network Controller Link.",
      subcommands: [Identity.self, Serve.self]
    )

    public init() {}

    public struct Identity: AsyncParsableCommand {
      public static let configuration = CommandConfiguration(
        abstract: "Manage the Mac controller TLS identity.",
        subcommands: [Create.self, AuthorizeCurrentExecutable.self]
      )

      public init() {}

      public struct Create: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
          abstract: "Create the controller's Keychain-backed TLS identity once."
        )

        @Option(name: .long, help: "Keychain label for the controller identity.")
        public var label = "Pinshift Controller"

        public init() {}

        public func run() async throws {
          do {
            _ = try KeychainTLSIdentity.load(label: label)
            print("The controller TLS identity is ready in Keychain.")
            return
          } catch KeychainTLSIdentityError.notFound {
          }

          let executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
          try await ControllerIdentityProvisioner().create(
            label: label,
            trustedExecutableURL: executableURL
          )
          _ = try KeychainTLSIdentity.load(label: label)
          print("The controller TLS identity was created in Keychain.")
        }
      }

      public struct AuthorizeCurrentExecutable: AsyncParsableCommand {
        public static let configuration = CommandConfiguration(
          commandName: "authorize-current-executable",
          abstract: "Add this signed controller to the existing private-key ACL."
        )

        @Option(name: .long, help: "Keychain label for the controller identity.")
        public var label = "Pinshift Controller"

        public init() {}

        public func run() async throws {
          do {
            _ = try ControllerIdentityAccessAuthorizer(
              manager: MacKeychainControllerIdentityAccessManager()
            ).authorize(label: label)
            print("The existing controller identity was preserved and authorized.")
          } catch KeychainTLSIdentityError.notFound {
            throw ValidationError(
              "The existing controller identity is missing. No identity was created or replaced."
            )
          } catch ControllerIdentityAccessAuthorizationError.identityChanged {
            throw ValidationError(
              "The controller identity changed during authorization. Stop and inspect Keychain; no replacement was requested."
            )
          } catch let error as ControllerIdentityAccessAuthorizationError {
            throw ValidationError(
              "The existing controller identity could not be authorized (\(error)). It was not deleted or replaced."
            )
          } catch {
            throw ValidationError(
              "The existing controller identity could not be authorized. It was not deleted or replaced."
            )
          }
        }
      }
    }

    public struct Serve: AsyncParsableCommand {
      public static let configuration = CommandConfiguration(
        abstract: "Advertise one TLS controller and display a short-lived pairing code."
      )

      @Option(name: .long, help: "Keychain label for the controller identity.")
      public var identityLabel = "Pinshift Controller"

      @Option(
        name: .long,
        help: "Optional foreground session duration. Zero waits for Ctrl-C or termination."
      )
      public var seconds: Double = 0

      @Option(
        name: .long,
        help: "Pairing-code validity in seconds (60 through 3600). Defaults to 300."
      )
      public var pairingCodeValiditySeconds: Double = 300

      @Option(
        name: .long,
        help: "Write the short-lived code to an owner-only file instead of terminal output."
      )
      public var pairingCodeFile: String?

      @OptionGroup public var activeDevice: ActiveDeviceOptions

      public init() {}

      public func validate() throws {
        guard seconds == 0 || (60...86_400).contains(seconds) else {
          throw ValidationError("--seconds must be zero or from 60 through 86400.")
        }
        guard (60...3_600).contains(pairingCodeValiditySeconds) else {
          throw ValidationError(
            "--pairing-code-validity-seconds must be from 60 through 3600."
          )
        }
      }

      public func run() async throws {
        let ownership = try ControllerSessionLock.acquire()
        defer { ownership.release() }
        let tlsIdentity: SecIdentity
        do {
          tlsIdentity = try KeychainTLSIdentity.load(label: identityLabel)
        } catch KeychainTLSIdentityError.notFound {
          throw ValidationError(
            "The controller TLS identity is missing. Run `pinshift-controller link identity create` once."
          )
        }
        let identity = try KeychainTLSIdentity.fingerprint(of: tlsIdentity)
        let suppliedCode = ProcessInfo.processInfo.environment[
          ControllerCLIRuntime.e2ePairingCodeEnvironmentKey
        ]
        if let suppliedCode {
          guard suppliedCode.count == 6, suppliedCode.allSatisfy(\.isNumber) else {
            throw ValidationError(
              "PINSHIFT_E2E_PAIRING_CODE must contain exactly six digits."
            )
          }
        }
        let code = try suppliedCode ?? PairingCodeGenerator.generate()
        let authority = try PairingCodeAuthority(
          code: code,
          identity: identity,
          expiresAt: Date().addingTimeInterval(pairingCodeValiditySeconds)
        )
        let diagnostics = ControllerCLIRuntime.makeDiagnostics()
        await diagnostics.record(
          kind: "controller.lifecycle.startup-attempted",
          fields: [
            "developerDirectory": .text(
              activeDevice.developerDirectory
                ?? ControllerCLIRuntime.defaultDeveloperDirectory
            )
          ]
        )
        let simulationController = ControllerCLIRuntime.makeController(
          device: activeDevice.device,
          developerDirectory: activeDevice.developerDirectory,
          diagnostics: diagnostics
        )
        await ControllerCLIRuntime.prepareSession(controller: simulationController)
        let renewal = AppRenewalService(
          diagnostics: diagnostics,
          execute: AppRenewalExecutor(
            repository: ProcessInfo.processInfo.environment["PINSHIFT_REPOSITORY_ROOT"].map {
              URL(fileURLWithPath: $0)
            },
            configuration: ControllerCLIRuntime.resolveConfiguration(
              device: activeDevice.device, developerDirectory: activeDevice.developerDirectory)
          ).execute
        )
        let session = ControllerServerSession(
          identity: identity,
          pairingAuthority: authority,
          authorizationStore: KeychainControllerAuthorizationStore(
            service: "dev.sayori.pinshift.controller-server-authorization",
            account: ControllerAuthorization.pairedAppKeychainAccount
          ),
          commandHandler: SimulationControllerCommandHandler(
            controller: simulationController,
            diagnostics: diagnostics,
            renewal: renewal
          ),
          diagnostics: diagnostics
        )
        let server = TLSControllerServer(identity: tlsIdentity, session: session)
        do {
          try await server.start()
        } catch {
          await diagnostics.record(
            kind: "controller.lifecycle.startup-failed",
            fields: ["error": .text(String(describing: error))]
          )
          throw error
        }
        await diagnostics.record(kind: "controller.lifecycle.ready")
        defer { server.stop() }

        let privateCodeFile = try pairingCodeFile.map {
          try OwnerOnlyPairingCodeFile.create(
            at: URL(fileURLWithPath: $0),
            contents: Data(code.utf8),
            replacingOwnedExisting: true
          )
        }
        defer {
          privateCodeFile?.removeIfOwned()
        }
        if privateCodeFile != nil {
          print("Controller Link is ready. The short-lived pairing code was written privately.")
        } else {
          print("Controller Link is ready. Pairing code: \(code) (expires in 5 minutes).")
        }
        print("Temporary Simulated Locations clear automatically after 3 minutes.")
        print("Keep this terminal open. Ctrl-C performs a real Clear before exit.")
        try await ControllerCLIRuntime.runForegroundSession(
          controller: simulationController,
          runFor: seconds == 0 ? nil : seconds,
          stopAcceptingCommands: {
            server.stop()
            await renewal.stopAcceptingRequests()
          },
          finishAcceptedWork: { await renewal.finishAcceptedWork() }
        )
      }
    }
  }
}

private func makeRunner(_ activeDevice: ActiveDeviceOptions) -> ControllerCLIRunner {
  ControllerCLIRuntime.makeRunner(
    device: activeDevice.device,
    developerDirectory: activeDevice.developerDirectory
  )
}

private func emit(_ result: ControllerCLIResult) async throws {
  print(result.output)
  guard result.exitCode == 0 else {
    throw ExitCode(result.exitCode)
  }
}
