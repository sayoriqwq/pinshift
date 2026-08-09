import Foundation
import Security

public enum ControllerAuthorizationError: Error, Equatable, Sendable {
  case invalidLength
  case randomGenerationFailed(OSStatus)
}

public struct ControllerAuthorization: Codable, Equatable, Sendable, CustomStringConvertible {
  public static let pairedAppKeychainAccount = "paired-pinshift-app"

  private let bytes: Data

  public init(bytes: Data) throws {
    guard bytes.count == 32 else {
      throw ControllerAuthorizationError.invalidLength
    }
    self.bytes = bytes
  }

  public static func generate() throws -> ControllerAuthorization {
    var bytes = Data(count: 32)
    let status = bytes.withUnsafeMutableBytes { buffer in
      SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
    }
    guard status == errSecSuccess else {
      throw ControllerAuthorizationError.randomGenerationFailed(status)
    }
    return try ControllerAuthorization(bytes: bytes)
  }

  public var description: String {
    "<redacted controller authorization>"
  }

  fileprivate var keychainData: Data {
    bytes
  }

  func securelyMatches(_ other: ControllerAuthorization) -> Bool {
    let lhs = [UInt8](bytes)
    let rhs = [UInt8](other.bytes)
    var difference = UInt8(truncatingIfNeeded: lhs.count ^ rhs.count)
    for index in lhs.indices {
      difference |= lhs[index] ^ (index < rhs.count ? rhs[index] : 0)
    }
    return difference == 0
  }
}

public protocol ControllerAuthorizationStore: Sendable {
  func load() async throws -> ControllerAuthorization?
  func save(_ authorization: ControllerAuthorization) async throws
  func remove() async throws
}

public actor InMemoryControllerAuthorizationStore: ControllerAuthorizationStore {
  private var authorization: ControllerAuthorization?

  public init(authorization: ControllerAuthorization? = nil) {
    self.authorization = authorization
  }

  public func load() -> ControllerAuthorization? {
    authorization
  }

  public func save(_ authorization: ControllerAuthorization) {
    self.authorization = authorization
  }

  public func remove() {
    authorization = nil
  }
}

public enum KeychainControllerAuthorizationStoreError: Error, Equatable, Sendable {
  case unexpectedStatus(OSStatus)
  case invalidStoredAuthorization
}

public actor KeychainControllerAuthorizationStore: ControllerAuthorizationStore {
  private let service: String
  private let account: String

  public init(
    service: String = "dev.sayori.remotelocation.controller-authorization",
    account: String = "trusted-controller-authorization"
  ) {
    self.service = service
    self.account = account
  }

  public func load() throws -> ControllerAuthorization? {
    var query = baseQuery
    query[kSecMatchLimit] = kSecMatchLimitOne
    query[kSecReturnData] = true
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data = result as? Data else {
      if status == errSecSuccess {
        throw KeychainControllerAuthorizationStoreError.invalidStoredAuthorization
      }
      throw KeychainControllerAuthorizationStoreError.unexpectedStatus(status)
    }
    do {
      return try ControllerAuthorization(bytes: data)
    } catch {
      throw KeychainControllerAuthorizationStoreError.invalidStoredAuthorization
    }
  }

  public func save(_ authorization: ControllerAuthorization) throws {
    var attributes: [CFString: Any] = [
      kSecValueData: authorization.keychainData
    ]
    #if !os(macOS)
      attributes[kSecAttrAccessible] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    #endif
    let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw KeychainControllerAuthorizationStoreError.unexpectedStatus(updateStatus)
    }
    var item = baseQuery
    for (key, value) in attributes {
      item[key] = value
    }
    let addStatus = SecItemAdd(item as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw KeychainControllerAuthorizationStoreError.unexpectedStatus(addStatus)
    }
  }

  public func remove() throws {
    let status = SecItemDelete(baseQuery as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainControllerAuthorizationStoreError.unexpectedStatus(status)
    }
  }

  private var baseQuery: [CFString: Any] {
    var query: [CFString: Any] = [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: service,
      kSecAttrAccount: account,
      kSecAttrSynchronizable: false,
    ]
    #if !os(macOS)
      query[kSecUseDataProtectionKeychain] = true
    #endif
    return query
  }
}
