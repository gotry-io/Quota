import Foundation
import QuotaWire
import Security

public protocol AccountSessionStore: Sendable {
  func load() throws -> AccountSession?
  func save(_ session: AccountSession) throws
  func clear() throws
}

public enum AccountStoreError: Error, Equatable, Sendable {
  case unreadable
  case unwritable
  case invalidSession
}

public protocol KeychainOperating: Sendable {
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
  func delete(_ query: [String: Any]) -> OSStatus
}

public struct SecurityKeychain: KeychainOperating {
  public init() {}

  public func add(_ attributes: [String: Any]) -> OSStatus {
    SecItemAdd(attributes as CFDictionary, nil)
  }

  public func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
    SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
  }

  public func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    return (status, item as? Data)
  }

  public func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}

public final class MemoryAccountSessionStore: AccountSessionStore, @unchecked Sendable {
  private let lock = NSLock()
  private var session: AccountSession?

  public init(session: AccountSession? = nil) {
    self.session = session
  }

  public func load() throws -> AccountSession? {
    lock.lock()
    defer { lock.unlock() }
    return session
  }

  public func save(_ session: AccountSession) throws {
    guard session.isValid else { throw AccountStoreError.invalidSession }
    lock.lock()
    self.session = session
    lock.unlock()
  }

  public func clear() throws {
    lock.lock()
    session = nil
    lock.unlock()
  }
}

public struct KeychainAccountSessionStore: AccountSessionStore, Sendable {
  public let service: String
  public let account: String
  private let keychain: any KeychainOperating

  public init(
    service: String = "io.gotry.quota.account-session",
    account: String = "account-session",
    keychain: any KeychainOperating = SecurityKeychain()
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
  }

  public func load() throws -> AccountSession? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    let (status, data) = keychain.copyMatching(query)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data else {
      throw AccountStoreError.unreadable
    }
    do {
      let session = try WireCodec.decode(AccountSession.self, from: data)
      guard session.isValid else { throw AccountStoreError.invalidSession }
      return session
    } catch {
      throw AccountStoreError.unreadable
    }
  }

  public func save(_ session: AccountSession) throws {
    guard session.isValid else { throw AccountStoreError.invalidSession }
    let data = try WireCodec.encode(session)
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let addAttributes: [String: Any] = identity.merging(
      [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
    ) { _, new in new }
    let added = keychain.add(addAttributes)
    if added == errSecSuccess {
      return
    }
    guard added == errSecDuplicateItem else {
      throw AccountStoreError.unwritable
    }
    let updated = keychain.update(
      query: identity,
      attributes: [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
      ]
    )
    guard updated == errSecSuccess else {
      throw AccountStoreError.unwritable
    }
  }

  public func clear() throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    let status = keychain.delete(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw AccountStoreError.unwritable
    }
  }
}
