import Foundation

public struct AppRenewalStatus: Codable, Equatable, Sendable {
  public enum Phase: String, Codable, Sendable {
    case idle, checking, signing, verifying, installing, installed, failed

    public var isRunning: Bool {
      switch self {
      case .checking, .signing, .verifying, .installing: true
      case .idle, .installed, .failed: false
      }
    }
  }

  public enum Failure: String, Codable, Sendable {
    case preparationRequired, signingFailed, verificationFailed, installationUnconfirmed, processFailed
  }

  public let operationID: UUID?
  public let phase: Phase
  public let updatedAt: Date
  /// Expiry of the last app whose installation this controller session confirmed.
  /// It is not a claim about an arbitrary cached provisioning profile or subsequent installs.
  public let installedExpiresAt: Date?
  public let failure: Failure?
  /// Raw process evidence, for diagnostic details only; never use as primary UI copy.
  public let detail: String?

  public init(operationID: UUID? = nil, phase: Phase = .idle, updatedAt: Date = Date(),
    installedExpiresAt: Date? = nil, failure: Failure? = nil, detail: String? = nil) {
    self.operationID = operationID
    self.phase = phase
    self.updatedAt = updatedAt
    self.installedExpiresAt = installedExpiresAt
    self.failure = failure
    self.detail = detail
  }
}
