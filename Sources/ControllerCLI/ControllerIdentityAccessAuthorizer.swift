import ControllerLink
import Foundation
import Security

public enum ControllerIdentityAccessAuthorizationError: Error, Equatable, Sendable {
  case identityChanged
  case missingPrivateKey
  case missingUsageACL
  case unsafeAllowAllACL
  case signatureVerificationFailed
  case rollbackFailed(OSStatus)
  case unexpectedStatus(OSStatus)
}

public protocol ControllerIdentityAccessManaging: Sendable {
  func fingerprint(label: String) throws -> ControllerIdentity
  func authorizeCurrentApplication(
    label: String,
    preserving identity: ControllerIdentity
  ) throws
}

public struct ControllerIdentityAccessAuthorizer: Sendable {
  private let manager: any ControllerIdentityAccessManaging

  public init(manager: any ControllerIdentityAccessManaging) {
    self.manager = manager
  }

  @discardableResult
  public func authorize(label: String) throws -> ControllerIdentity {
    let originalIdentity = try manager.fingerprint(label: label)
    try manager.authorizeCurrentApplication(label: label, preserving: originalIdentity)
    let preservedIdentity = try manager.fingerprint(label: label)
    guard preservedIdentity == originalIdentity else {
      throw ControllerIdentityAccessAuthorizationError.identityChanged
    }
    return preservedIdentity
  }
}

public struct MacKeychainControllerIdentityAccessManager:
  ControllerIdentityAccessManaging, Sendable
{
  private static let controllerAuthorizationService =
    "dev.sayori.pinshift.controller-server-authorization"
  private static let controllerAuthorizationAccount =
    ControllerAuthorization.pairedAppKeychainAccount

  public init() {}

  public func fingerprint(label: String) throws -> ControllerIdentity {
    try KeychainTLSIdentity.fingerprint(of: KeychainTLSIdentity.load(label: label))
  }

  public func authorizeCurrentApplication(
    label: String,
    preserving expectedIdentity: ControllerIdentity
  ) throws {
    let identity = try KeychainTLSIdentity.load(label: label)
    let privateKey = try copyPrivateKey(from: identity)
    let keychainItem = unsafeBitCast(privateKey, to: SecKeychainItem.self)
    let access = try copyAccess(for: keychainItem)
    let currentApplication = try makeCurrentTrustedApplication()
    let currentApplicationData = try trustedApplicationData(currentApplication)

    var matchedUsageACL = false
    var snapshots: [ACLSnapshot] = []
    do {
      for authorization in [kSecACLAuthorizationSign, kSecACLAuthorizationDecrypt] {
        let accessControlLists = copyMatchingACLs(access, authorization: authorization)
        matchedUsageACL = matchedUsageACL || !accessControlLists.isEmpty

        for accessControlList in accessControlLists {
          let contents = try copyContents(of: accessControlList)
          guard let trustedApplications = contents.trustedApplications else {
            throw ControllerIdentityAccessAuthorizationError.unsafeAllowAllACL
          }
          let alreadyTrusted = try trustedApplications.contains {
            try trustedApplicationData($0) == currentApplicationData
          }
          guard !alreadyTrusted else { continue }

          let updatedApplications = trustedApplications + [currentApplication]
          let status = SecACLSetContents(
            accessControlList,
            updatedApplications as CFArray,
            contents.description,
            contents.promptSelector
          )
          guard status == errSecSuccess else {
            throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
          }
          snapshots.append(ACLSnapshot(accessControlList: accessControlList, contents: contents))
        }
      }

      guard matchedUsageACL else {
        throw ControllerIdentityAccessAuthorizationError.missingUsageACL
      }
      if !snapshots.isEmpty {
        let status = SecKeychainItemSetAccess(keychainItem, access)
        guard status == errSecSuccess else {
          throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
        }
      }
      try verifySigningAccess(privateKey)
      guard try fingerprint(label: label) == expectedIdentity else {
        throw ControllerIdentityAccessAuthorizationError.identityChanged
      }
    } catch {
      guard !snapshots.isEmpty else { throw error }
      do {
        try restore(snapshots, to: keychainItem, access: access)
      } catch let rollbackError as ControllerIdentityAccessAuthorizationError {
        throw rollbackError
      } catch {
        throw error
      }
      throw error
    }

    do {
      try authorizeControllerAuthorizationStore(currentApplication: currentApplication)
    } catch {
      guard !snapshots.isEmpty else { throw error }
      do {
        try restore(snapshots, to: keychainItem, access: access)
      } catch let rollbackError as ControllerIdentityAccessAuthorizationError {
        throw rollbackError
      } catch {
        throw error
      }
      throw error
    }
  }

  private func authorizeControllerAuthorizationStore(
    currentApplication: SecTrustedApplication
  ) throws {
    var item: SecKeychainItem?
    let status = Self.controllerAuthorizationService.withCString { service in
      Self.controllerAuthorizationAccount.withCString { account in
        SecKeychainFindGenericPassword(
          nil,
          UInt32(strlen(service)), service,
          UInt32(strlen(account)), account,
          nil, nil, &item
        )
      }
    }
    if status == errSecItemNotFound { return }
    guard status == errSecSuccess, let item else {
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    try authorizeCurrentApplication(
      for: item,
      currentApplication: currentApplication
    )
  }

  private func authorizeCurrentApplication(
    for item: SecKeychainItem,
    currentApplication: SecTrustedApplication
  ) throws {
    let access = try copyAccess(for: item)
    let currentApplicationData = try trustedApplicationData(currentApplication)
    var snapshots: [ACLSnapshot] = []
    var matchedUsageACL = false
    do {
      for authorization in [kSecACLAuthorizationDecrypt] {
        for accessControlList in copyMatchingACLs(access, authorization: authorization) {
          matchedUsageACL = true
          let contents = try copyContents(of: accessControlList)
          guard let trustedApplications = contents.trustedApplications else {
            throw ControllerIdentityAccessAuthorizationError.unsafeAllowAllACL
          }
          let alreadyTrusted = try trustedApplications.contains {
            try trustedApplicationData($0) == currentApplicationData
          }
          guard !alreadyTrusted else { continue }
          let status = SecACLSetContents(
            accessControlList,
            (trustedApplications + [currentApplication]) as CFArray,
            contents.description,
            contents.promptSelector
          )
          guard status == errSecSuccess else {
            throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
          }
          snapshots.append(ACLSnapshot(accessControlList: accessControlList, contents: contents))
        }
      }
      guard matchedUsageACL else {
        throw ControllerIdentityAccessAuthorizationError.missingUsageACL
      }
      guard !snapshots.isEmpty else { return }
      let status = SecKeychainItemSetAccess(item, access)
      guard status == errSecSuccess else {
        throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
      }
    } catch {
      guard !snapshots.isEmpty else { throw error }
      do {
        try restore(snapshots, to: item, access: access)
      } catch let rollbackError as ControllerIdentityAccessAuthorizationError {
        throw rollbackError
      } catch {
        throw error
      }
      throw error
    }
  }

  private func restore(
    _ snapshots: [ACLSnapshot],
    to item: SecKeychainItem,
    access: SecAccess
  ) throws {
    for snapshot in snapshots {
      guard let trustedApplications = snapshot.contents.trustedApplications else {
        throw ControllerIdentityAccessAuthorizationError.rollbackFailed(errSecDecode)
      }
      let status = SecACLSetContents(
        snapshot.accessControlList,
        trustedApplications as CFArray,
        snapshot.contents.description,
        snapshot.contents.promptSelector
      )
      guard status == errSecSuccess else {
        throw ControllerIdentityAccessAuthorizationError.rollbackFailed(status)
      }
    }
    let status = SecKeychainItemSetAccess(item, access)
    guard status == errSecSuccess else {
      throw ControllerIdentityAccessAuthorizationError.rollbackFailed(status)
    }
  }

  private func copyPrivateKey(from identity: SecIdentity) throws -> SecKey {
    var privateKey: SecKey?
    let status = SecIdentityCopyPrivateKey(identity, &privateKey)
    guard status == errSecSuccess, let privateKey else {
      if status == errSecSuccess {
        throw ControllerIdentityAccessAuthorizationError.missingPrivateKey
      }
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    return privateKey
  }

  private func copyAccess(for item: SecKeychainItem) throws -> SecAccess {
    var access: SecAccess?
    let status = SecKeychainItemCopyAccess(item, &access)
    guard status == errSecSuccess, let access else {
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    return access
  }

  private func makeCurrentTrustedApplication() throws -> SecTrustedApplication {
    var application: SecTrustedApplication?
    let status = SecTrustedApplicationCreateFromPath(nil, &application)
    guard status == errSecSuccess, let application else {
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    return application
  }

  private func trustedApplicationData(
    _ application: SecTrustedApplication
  ) throws -> Data {
    var data: CFData?
    let status = SecTrustedApplicationCopyData(application, &data)
    guard status == errSecSuccess, let data else {
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    return data as Data
  }

  private func copyContents(of accessControlList: SecACL) throws -> ACLContents {
    var applicationList: CFArray?
    var description: CFString?
    var promptSelector = SecKeychainPromptSelector()
    let status = SecACLCopyContents(
      accessControlList,
      &applicationList,
      &description,
      &promptSelector
    )
    guard status == errSecSuccess, let description else {
      throw ControllerIdentityAccessAuthorizationError.unexpectedStatus(status)
    }
    let trustedApplications: [SecTrustedApplication]?
    if let applicationList {
      var applications: [SecTrustedApplication] = []
      for index in 0..<CFArrayGetCount(applicationList) {
        let value = CFArrayGetValueAtIndex(applicationList, index)
        applications.append(unsafeBitCast(value, to: SecTrustedApplication.self))
      }
      trustedApplications = applications
    } else {
      trustedApplications = nil
    }
    return ACLContents(
      trustedApplications: trustedApplications,
      description: description,
      promptSelector: promptSelector
    )
  }

  private func copyMatchingACLs(
    _ access: SecAccess,
    authorization: CFString
  ) -> [SecACL] {
    guard let list = SecAccessCopyMatchingACLList(access, authorization) else { return [] }
    return (0..<CFArrayGetCount(list)).map { index in
      unsafeBitCast(CFArrayGetValueAtIndex(list, index), to: SecACL.self)
    }
  }

  private func verifySigningAccess(_ privateKey: SecKey) throws {
    var error: Unmanaged<CFError>?
    let payload = Data("pinshift-controller-key-access".utf8)
    let signature = SecKeyCreateSignature(
      privateKey,
      .rsaSignatureMessagePKCS1v15SHA256,
      payload as CFData,
      &error
    )
    guard signature != nil else {
      throw ControllerIdentityAccessAuthorizationError.signatureVerificationFailed
    }
  }
}

private struct ACLContents {
  let trustedApplications: [SecTrustedApplication]?
  let description: CFString
  let promptSelector: SecKeychainPromptSelector
}

private struct ACLSnapshot {
  let accessControlList: SecACL
  let contents: ACLContents
}
