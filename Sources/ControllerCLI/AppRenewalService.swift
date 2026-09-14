import ControllerLink
import Foundation
import SimulationDiagnostics

/// One renewal job owned by the explicitly running Mac session, not a phone request.
public actor AppRenewalService {
  public typealias Execute = @Sendable (@escaping @Sendable (AppRenewalStatus.Phase, Date?) async -> Void) async throws -> Void
  private let execute: Execute
  private let diagnostics: SimulationDiagnosticRecorder?
  private var current = AppRenewalStatus()
  private var accepted = Set<UUID>()
  private var running = false
  private var acceptsRequests = true
  private var job: Task<Void, Never>?

  public init(diagnostics: SimulationDiagnosticRecorder? = nil, execute: @escaping Execute) {
    self.diagnostics = diagnostics
    self.execute = execute
  }

  public func snapshot() -> AppRenewalStatus { current }

  public func start(requestID: UUID) -> AppRenewalStatus {
    guard acceptsRequests else {
      return AppRenewalStatus(operationID: requestID, phase: .failed,
        installedExpiresAt: current.installedExpiresAt, failure: .processFailed,
        detail: "The controller session is shutting down.")
    }
    guard accepted.insert(requestID).inserted, !running else { return current }
    running = true
    current = AppRenewalStatus(operationID: requestID, phase: .checking,
      installedExpiresAt: current.installedExpiresAt)
    job = Task { await run(requestID: requestID) }
    return current
  }

  public func stopAcceptingRequests() { acceptsRequests = false }

  /// Called only after simulation cleanup, with foreground signal handlers still installed.
  public func finishAcceptedWork(onWaiting: @Sendable () async -> Void = {
    print("Waiting for the accepted App renewal to finish. Press Ctrl-C again to force exit.")
  }) async {
    guard running, let job else { return }
    await onWaiting()
    await job.value
  }

  private func run(requestID: UUID) async {
    defer { running = false }
    do {
      try await execute { phase, expiry in
        await self.update(requestID: requestID, phase: phase, expiry: expiry)
      }
      guard current.phase == .installed else {
        throw RenewalExecutionError.unconfirmed
      }
    } catch {
      let failure: AppRenewalStatus.Failure = switch current.phase {
      case .checking: .preparationRequired
      case .signing: .signingFailed
      case .verifying: .verificationFailed
      case .installing: .installationUnconfirmed
      default: .processFailed
      }
      current = AppRenewalStatus(operationID: requestID, phase: .failed,
        installedExpiresAt: current.installedExpiresAt, failure: failure,
        detail: SimulationDiagnosticText.sanitized(String(describing: error)))
    }
    await record()
  }

  private func update(requestID: UUID, phase: AppRenewalStatus.Phase, expiry: Date?) async {
    // Installation requires both the verified candidate expiry and device acknowledgement.
    guard phase != .installed || expiry != nil else { return }
    current = AppRenewalStatus(operationID: requestID, phase: phase,
      installedExpiresAt: phase == .installed ? expiry : current.installedExpiresAt)
    await record()
  }

  private func record() async {
    var fields: SimulationDiagnosticFields = ["phase": .text(current.phase.rawValue)]
    if let detail = current.detail { fields["error"] = .text(detail) }
    if let expiry = current.installedExpiresAt { fields["installedExpiresAt"] = .date(expiry) }
    await diagnostics?.record(kind: "controller.app-renewal", requestID: current.operationID, fields: fields)
  }
}

private enum RenewalExecutionError: Error, CustomStringConvertible {
  case unavailable, unconfirmed, process(Int32, String)

  var description: String {
    switch self {
    case .unavailable: "The local renewal command or configured device is unavailable."
    case .unconfirmed: "The renewal did not confirm installation."
    // Preserve line breaks so sanitizing one credential does not discard later evidence.
    case .process(let status, let output): "Renewal process exited with status \(status):\n\(output)"
    }
  }
}

/// Fixed local command; none of its paths, arguments, or device identity comes from the phone.
public struct AppRenewalExecutor: Sendable {
  private let repository: URL?
  private let configuration: ControllerRuntimeConfiguration
  private let environment: [String: String]

  public init(repository: URL?, configuration: ControllerRuntimeConfiguration,
    environment: [String: String] = ProcessInfo.processInfo.environment) {
    self.repository = repository
    self.configuration = configuration
    self.environment = environment
  }

  public func execute(report: @escaping @Sendable (AppRenewalStatus.Phase, Date?) async -> Void) async throws {
    guard let repository, let device = configuration.device, !device.isEmpty else { throw RenewalExecutionError.unavailable }
    let script = repository.appending(path: "bin/pinshift-resign-app")
    guard FileManager.default.isExecutableFile(atPath: script.path) else { throw RenewalExecutionError.unavailable }
    let directory = FileManager.default.temporaryDirectory.appending(path: "pinshift-renewal-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let progress = directory.appending(path: "progress.json")
    let log = directory.appending(path: "process.log")
    FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
    let output = try FileHandle(forWritingTo: log)
    defer { try? output.close() }
    let process = Process()
    process.executableURL = script
    process.arguments = ["--force", "--no-launch"]
    process.currentDirectoryURL = repository
    var childEnvironment = environment
    childEnvironment["PINSHIFT_DEVICE"] = device
    childEnvironment["PINSHIFT_DEVELOPER_DIR"] = configuration.developerDirectory
    childEnvironment["PINSHIFT_RENEWAL_PROGRESS"] = progress.path
    process.environment = childEnvironment
    process.standardOutput = output
    process.standardError = output
    try process.run()
    var previous: Data?
    repeat {
      // Snapshot before reading so an exit always gets one final progress read.
      let isRunning = process.isRunning
      if let data = try? Data(contentsOf: progress), data != previous,
        let event = try? JSONDecoder().decode(Progress.self, from: data) {
        previous = data
        await report(event.phase, event.expiry.map(Date.init(timeIntervalSince1970:)))
      }
      if !isRunning { break }
      // The request already returned; this cooperative wait leaves cleanup and status responsive.
      try await Task.sleep(for: .milliseconds(150))
    } while true
    guard process.terminationStatus == 0 else {
      let handle = try FileHandle(forReadingFrom: log)
      defer { try? handle.close() }
      let end = try handle.seekToEnd()
      try handle.seek(toOffset: end > 8192 ? end - 8192 : 0)
      let tail = try handle.readToEnd() ?? Data()
      throw RenewalExecutionError.process(process.terminationStatus, String(decoding: tail, as: UTF8.self))
    }
  }

  private struct Progress: Decodable {
    let phase: AppRenewalStatus.Phase
    let expiry: TimeInterval?
  }
}
