import Foundation
import QuotaKeychain
import QuotaWire
import Security

/// One provider web session this device signed in to, as it is kept.
///
/// The cookie header is the whole credential, so it is stored the way a credential is: in the
/// Keychain, on this device only, and never in a file, a preference, a log, or an upload. The two
/// dates are what the Providers list says out loud — when this device took the session, and when
/// the provider last answered for it.
public struct StoredProviderSession: Equatable, Sendable, Codable {
  public let provider: ProviderID
  public let accountFingerprint: String
  public let cookieHeader: String
  public let accountLabel: String?
  public let storedAt: Date
  public let lastValidatedAt: Date

  public init(
    provider: ProviderID,
    accountFingerprint: String,
    cookieHeader: String,
    accountLabel: String?,
    storedAt: Date,
    lastValidatedAt: Date
  ) {
    self.provider = provider
    self.accountFingerprint = accountFingerprint
    self.cookieHeader = cookieHeader
    self.accountLabel = accountLabel
    self.storedAt = storedAt
    self.lastValidatedAt = lastValidatedAt
  }

  /// One session per provider per account: signing in again as the same account replaces it
  /// rather than listing it twice.
  public var key: String { "\(provider.rawValue):\(accountFingerprint)" }
}

public enum ProviderSessionStoreError: Error, Equatable, Sendable {
  case unreadable
  case unwritable
}

public protocol ProviderSessionStoring: Sendable {
  func list() throws -> [StoredProviderSession]
  func upsert(_ session: StoredProviderSession) throws
  func remove(provider: ProviderID, accountFingerprint: String) throws
}

/// The provider sessions of a device, in the Keychain.
///
/// Every item is `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and
/// `kSecAttrSynchronizable: false`: a background refresh has to be able to read it while the
/// phone is locked, and no iCloud Keychain copies it to another device — a session this reader
/// signed in on this phone is this phone's.
public struct KeychainProviderSessionStore: ProviderSessionStoring, Sendable {
  public let service: String
  private let keychain: any KeychainOperating

  public init(
    service: String = "io.gotry.quota.provider-session",
    keychain: any KeychainOperating = SecurityKeychain()
  ) {
    self.service = service
    self.keychain = keychain
  }

  public func list() throws -> [StoredProviderSession] {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrSynchronizable as String: false,
      kSecReturnData as String: true,
      kSecReturnAttributes as String: true,
      kSecMatchLimit as String: kSecMatchLimitAll,
    ]
    let (status, items) = keychain.copyAllMatching(query)
    if status == errSecItemNotFound {
      return []
    }
    guard status == errSecSuccess else {
      throw ProviderSessionStoreError.unreadable
    }
    // An item this build cannot read is not an error the reader can do anything about, and
    // refusing the whole list would hide every session beside it. It is left where it is.
    let sessions = items.compactMap { item -> StoredProviderSession? in
      guard let data = item[kSecValueData as String] as? Data else { return nil }
      return try? WireCodec.decode(StoredProviderSession.self, from: data)
    }
    return sessions.sorted { ($0.key, $0.storedAt) < ($1.key, $1.storedAt) }
  }

  public func upsert(_ session: StoredProviderSession) throws {
    let data: Data
    do {
      data = try WireCodec.encode(session)
    } catch {
      throw ProviderSessionStoreError.unwritable
    }
    let identity: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: session.key,
      kSecAttrSynchronizable as String: false,
    ]
    let added = keychain.add(
      identity.merging([
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]) { _, new in new })
    if added == errSecSuccess {
      return
    }
    guard added == errSecDuplicateItem else {
      throw ProviderSessionStoreError.unwritable
    }
    let updated = keychain.update(
      query: identity,
      attributes: [
        kSecValueData as String: data,
        kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      ]
    )
    guard updated == errSecSuccess else {
      throw ProviderSessionStoreError.unwritable
    }
  }

  public func remove(provider: ProviderID, accountFingerprint: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: "\(provider.rawValue):\(accountFingerprint)",
      kSecAttrSynchronizable as String: false,
    ]
    let status = keychain.delete(query)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw ProviderSessionStoreError.unwritable
    }
  }
}

/// The same store without a Keychain, for tests and DEBUG visual fixtures.
public final class MemoryProviderSessionStore: ProviderSessionStoring, @unchecked Sendable {
  private let lock = NSLock()
  private var sessions: [String: StoredProviderSession]

  public init(sessions: [StoredProviderSession] = []) {
    self.sessions = Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, $0) })
  }

  public func list() throws -> [StoredProviderSession] {
    lock.lock()
    defer { lock.unlock() }
    return sessions.values.sorted { ($0.key, $0.storedAt) < ($1.key, $1.storedAt) }
  }

  public func upsert(_ session: StoredProviderSession) throws {
    lock.lock()
    sessions[session.key] = session
    lock.unlock()
  }

  public func remove(provider: ProviderID, accountFingerprint: String) throws {
    lock.lock()
    sessions["\(provider.rawValue):\(accountFingerprint)"] = nil
    lock.unlock()
  }
}
