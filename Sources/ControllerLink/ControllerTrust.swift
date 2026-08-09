import Foundation
import Security

public enum ControllerTrustDisposition: Equatable, Sendable {
  case pairingRequired
  case trusted
  case identityMismatch
}

public protocol ControllerTrustStore: Sendable {
  func load() async throws -> ControllerIdentity?
  func save(_ identity: ControllerIdentity) async throws
  func remove() async throws
}

public struct ControllerTrust: Sendable {
  private let store: any ControllerTrustStore

  public init(store: any ControllerTrustStore) {
    self.store = store
  }

  public func evaluate(_ presentedIdentity: ControllerIdentity) async throws
    -> ControllerTrustDisposition
  {
    guard let trustedIdentity = try await store.load() else {
      return .pairingRequired
    }
    return trustedIdentity == presentedIdentity ? .trusted : .identityMismatch
  }

  public func trustedIdentity() async throws -> ControllerIdentity? {
    try await store.load()
  }

  public func remember(_ identity: ControllerIdentity) async throws {
    try await store.save(identity)
  }

  public func forget() async throws {
    try await store.remove()
  }
}

public actor InMemoryControllerTrustStore: ControllerTrustStore {
  private var identity: ControllerIdentity?

  public init(identity: ControllerIdentity? = nil) {
    self.identity = identity
  }

  public func load() -> ControllerIdentity? {
    identity
  }

  public func save(_ identity: ControllerIdentity) {
    self.identity = identity
  }

  public func remove() {
    identity = nil
  }
}

public enum KeychainControllerTrustStoreError: Error, Equatable, Sendable {
  case unexpectedStatus(OSStatus)
  case invalidStoredIdentity
}

public actor KeychainControllerTrustStore: ControllerTrustStore {
  private let service: String
  private let account: String

  public init(
    service: String = "dev.sayori.pinshift.controller-trust",
    account: String = "trusted-controller-identity"
  ) {
    self.service = service
    self.account = account
  }

  public func load() throws -> ControllerIdentity? {
    var query = baseQuery
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw KeychainControllerTrustStoreError.unexpectedStatus(status)
    }
    guard let data = result as? Data else {
      throw KeychainControllerTrustStoreError.invalidStoredIdentity
    }
    do {
      return try ControllerIdentity(fingerprint: data)
    } catch {
      throw KeychainControllerTrustStoreError.invalidStoredIdentity
    }
  }

  public func save(_ identity: ControllerIdentity) throws {
    let attributes: [CFString: Any] = [
      kSecValueData: identity.fingerprint,
      kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    ]
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainControllerTrustStoreError.unexpectedStatus(updateStatus)
    }

    var item = baseQuery
    for (key, value) in attributes {
      item[key] = value
    }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainControllerTrustStoreError.unexpectedStatus(addStatus)
    }
  }

  public func remove() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainControllerTrustStoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
      kSecUseDataProtectionKeychain: true,
    ]
  }
}
