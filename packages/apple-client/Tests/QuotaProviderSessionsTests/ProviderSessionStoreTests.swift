import Foundation
import QuotaKeychain
import QuotaProviderSessions
import QuotaWire
import Security
import Testing

struct ProviderSessionStoreTests {
  static let stored = Date(timeIntervalSince1970: 1_786_723_200)

  static func session(
    provider: ProviderID = .codex,
    fingerprint: String = "fingerprint_codex",
    header: String = "__Secure-next-auth.session-token=abc",
    label: String? = "k•••@example.com",
    validatedAt: Date = stored
  ) -> StoredProviderSession {
    StoredProviderSession(
      provider: provider,
      accountFingerprint: fingerprint,
      cookieHeader: header,
      accountLabel: label,
      storedAt: stored,
      lastValidatedAt: validatedAt
    )
  }

  @Test
  func upsertKeepsOneItemPerProviderAndAccount() throws {
    let keychain = ProviderSessionFakeKeychain()
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: keychain)

    try store.upsert(Self.session())
    try store.upsert(Self.session(provider: .claude, fingerprint: "fingerprint_claude"))
    #expect(try store.list().count == 2)

    let later = Self.stored.addingTimeInterval(3_600)
    try store.upsert(
      Self.session(header: "__Secure-next-auth.session-token=def", validatedAt: later))
    let sessions = try store.list()
    #expect(sessions.count == 2)
    let codex = try #require(sessions.first { $0.provider == .codex })
    #expect(codex.cookieHeader == "__Secure-next-auth.session-token=def")
    #expect(codex.lastValidatedAt == later)
    #expect(codex.storedAt == Self.stored)
    #expect(keychain.calls == ["add", "add", "add", "update"])
  }

  @Test
  func twoAccountsOfOneProviderAreTwoSessions() throws {
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: ProviderSessionFakeKeychain())
    try store.upsert(Self.session(fingerprint: "one", label: "a•••@example.com"))
    try store.upsert(Self.session(fingerprint: "two", label: "b•••@example.com"))

    let sessions = try store.list()
    #expect(sessions.map(\.accountFingerprint) == ["one", "two"])
    #expect(sessions.allSatisfy { $0.provider == .codex })
  }

  /// A cookie is a credential, and this one is this device's: it survives a locked phone so a
  /// background refresh can read it, and iCloud never carries it to another device.
  @Test
  func everyItemIsDeviceOnlyAfterFirstUnlockAndNotSynchronized() throws {
    let keychain = ProviderSessionFakeKeychain()
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: keychain)
    try store.upsert(Self.session())

    #expect(
      keychain.lastAddAccessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    #expect(keychain.lastAddSynchronizable == false)
  }

  @Test
  func removeDeletesOnlyThatAccount() throws {
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: ProviderSessionFakeKeychain())
    try store.upsert(Self.session(fingerprint: "one"))
    try store.upsert(Self.session(provider: .grok, fingerprint: "two"))

    try store.remove(provider: .codex, accountFingerprint: "one")
    #expect(try store.list().map(\.provider) == [.grok])

    // Removing what is already gone is what a second tap does, and it is not a failure.
    try store.remove(provider: .codex, accountFingerprint: "one")
    #expect(try store.list().count == 1)
  }

  @Test
  func anEmptyKeychainListsNothing() throws {
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: ProviderSessionFakeKeychain())
    #expect(try store.list().isEmpty)
  }

  @Test
  func aRefusedReadIsNotAnEmptyList() {
    let keychain = ProviderSessionFakeKeychain()
    keychain.listStatus = errSecInteractionNotAllowed
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: keychain)
    #expect(throws: ProviderSessionStoreError.unreadable) { try store.list() }
  }

  /// An item written by a build this one cannot read is left where it is; the sessions beside it
  /// still answer.
  @Test
  func anUnreadableItemDoesNotHideTheOthers() throws {
    let keychain = ProviderSessionFakeKeychain()
    let store = KeychainProviderSessionStore(
      service: "io.gotry.quota.test-provider-session", keychain: keychain)
    try store.upsert(Self.session())
    keychain.items["io.gotry.quota.test-provider-session|claude:broken"] = Data("{".utf8)

    #expect(try store.list().map(\.provider) == [.codex])
  }

  @Test
  func theMemoryStoreAnswersTheSameWay() throws {
    let store = MemoryProviderSessionStore(sessions: [Self.session()])
    try store.upsert(Self.session(provider: .claude, fingerprint: "fingerprint_claude"))
    #expect(try store.list().map(\.provider) == [.claude, .codex])

    try store.remove(provider: .claude, accountFingerprint: "fingerprint_claude")
    #expect(try store.list().map(\.provider) == [.codex])
  }
}

final class ProviderSessionFakeKeychain: KeychainOperating, @unchecked Sendable {
  var items: [String: Data] = [:]
  var calls: [String] = []
  var listStatus: OSStatus = errSecSuccess
  var lastAddAccessible: String?
  var lastAddSynchronizable: Bool?

  func add(_ attributes: [String: Any]) -> OSStatus {
    calls.append("add")
    lastAddAccessible = attributes[kSecAttrAccessible as String] as? String
    lastAddSynchronizable = attributes[kSecAttrSynchronizable as String] as? Bool
    let key = identity(attributes)
    if items[key] != nil {
      return errSecDuplicateItem
    }
    items[key] = attributes[kSecValueData as String] as? Data
    return errSecSuccess
  }

  func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
    calls.append("update")
    let key = identity(query)
    guard items[key] != nil else { return errSecItemNotFound }
    if let data = attributes[kSecValueData as String] as? Data {
      items[key] = data
    }
    return errSecSuccess
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
    let key = identity(query)
    guard let data = items[key] else { return (errSecItemNotFound, nil) }
    return (errSecSuccess, data)
  }

  func copyAllMatching(_ query: [String: Any]) -> (OSStatus, [[String: Any]]) {
    guard listStatus == errSecSuccess else { return (listStatus, []) }
    let service = query[kSecAttrService as String] as? String ?? ""
    let matches = items.filter { $0.key.hasPrefix("\(service)|") }
    guard !matches.isEmpty else { return (errSecItemNotFound, []) }
    return (errSecSuccess, matches.values.map { [kSecValueData as String: $0] })
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    calls.append("delete")
    let key = identity(query)
    guard items[key] != nil else { return errSecItemNotFound }
    items[key] = nil
    return errSecSuccess
  }

  private func identity(_ query: [String: Any]) -> String {
    let service = query[kSecAttrService as String] as? String ?? ""
    let account = query[kSecAttrAccount as String] as? String ?? ""
    return "\(service)|\(account)"
  }
}
