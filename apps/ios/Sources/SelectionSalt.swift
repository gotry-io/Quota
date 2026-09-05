import CryptoKit
import Foundation
import QuotaAccount
import QuotaKeychain
import Security

/// The 32-byte installation salt mixed into every widget `selection_id`.
///
/// Lives in the app-private Keychain, never in the App Group. Logout deletes it so
/// prior deep links and widget Intent configuration fall back to Overview.
protocol SelectionSaltStore: Sendable {
  /// The 32-byte salt, created on first use.
  func loadOrCreate() throws -> Data
  func clear() throws
}

enum SelectionSaltStoreError: Error, Equatable, Sendable {
  case unreadable
  case unwritable
}

enum SelectionIDs {
  /// `SHA-256(selector ‖ "|" ‖ salt)` truncated to twelve lowercase hex characters.
  static func make(selector: String, salt: Data) -> String {
    var preimage = Data(selector.utf8)
    preimage.append(contentsOf: Data("|".utf8))
    preimage.append(salt)
    let digest = SHA256.hash(data: preimage)
    let hex = digest.map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(12))
  }
}

final class InMemorySelectionSaltStore: SelectionSaltStore, @unchecked Sendable {
  private let lock = NSLock()
  private var salt: Data?
  private let generateSalt: @Sendable () throws -> Data

  init(
    salt: Data? = nil,
    generateSalt: @escaping @Sendable () throws -> Data = {
      try KeychainSelectionSaltStore.randomSalt()
    }
  ) {
    self.salt = salt
    self.generateSalt = generateSalt
  }

  func loadOrCreate() throws -> Data {
    lock.lock()
    defer { lock.unlock() }
    if let salt {
      return salt
    }
    let created = try generateSalt()
    salt = created
    return created
  }

  func clear() throws {
    lock.lock()
    salt = nil
    lock.unlock()
  }
}

struct KeychainSelectionSaltStore: SelectionSaltStore, Sendable {
  static let saltByteCount = 32

  let service: String
  let account: String
  private let keychain: any KeychainOperating
  private let generateSalt: @Sendable () throws -> Data

  init(
    service: String = "io.gotry.quota.selection-salt",
    account: String = "selection-salt",
    keychain: any KeychainOperating = SecurityKeychain(),
    generateSalt: @escaping @Sendable () throws -> Data = {
      try KeychainSelectionSaltStore.randomSalt()
    }
  ) {
    self.service = service
    self.account = account
    self.keychain = keychain
    self.generateSalt = generateSalt
  }

  func loadOrCreate() throws -> Data {
    if let existing = try load() {
      return existing
    }
    let generated = try generateSalt()
    let added = keychain.add(addAttributes(value: generated))
    if added == errSecSuccess {
      return generated
    }
    guard added == errSecDuplicateItem, let existing = try load() else {
      throw SelectionSaltStoreError.unwritable
    }
    return existing
  }

  func clear() throws {
    let status = keychain.delete(identity)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw SelectionSaltStoreError.unwritable
    }
  }

  static func randomSalt() throws -> Data {
    var bytes = [UInt8](repeating: 0, count: saltByteCount)
    let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
    guard status == errSecSuccess else {
      throw SelectionSaltStoreError.unwritable
    }
    return Data(bytes)
  }

  private func load() throws -> Data? {
    var query = identity
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne
    let (status, data) = keychain.copyMatching(query)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess, let data else {
      throw SelectionSaltStoreError.unreadable
    }
    return data
  }

  private var identity: [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }

  private func addAttributes(value: Data) -> [String: Any] {
    identity.merging(
      [
        kSecValueData as String: value,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
    ) { _, new in new }
  }
}
