import Foundation
import QuotaAccount
import QuotaKeychain
import QuotaWire
import Security
import Testing

struct KeychainStoreTests {
  @Test
  func saveAddsMissingItemWithoutDeleting() throws {
    let keychain = FakeKeychain()
    let store = KeychainAccountSessionStore(
      service: "io.gotry.quota.test-session",
      account: "account-session",
      keychain: keychain
    )
    try store.save(Fixtures.session())
    #expect(keychain.calls == ["add"])
    #expect(keychain.items.count == 1)
    #expect(keychain.lastAddAccessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    #expect(try store.load()?.accountID == "account_01")
  }

  @Test
  func saveUpdatesExistingItemWithoutDeleting() throws {
    let keychain = FakeKeychain()
    let store = KeychainAccountSessionStore(
      service: "io.gotry.quota.test-session",
      account: "account-session",
      keychain: keychain
    )
    try store.save(Fixtures.session())
    let rotated = Fixtures.session(access: Fixtures.rotatedAccess, refresh: Fixtures.rotatedRefresh)
    try store.save(rotated)
    #expect(keychain.calls == ["add", "add", "update"])
    #expect(keychain.deleteCount == 0)
    #expect(keychain.items.count == 1)
    #expect(keychain.lastUpdateAccessible == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
    #expect(try store.load()?.accessToken == Fixtures.rotatedAccess)
  }

  @Test
  func failedUpdateLeavesTheExistingSession() throws {
    let keychain = FakeKeychain()
    let store = KeychainAccountSessionStore(
      service: "io.gotry.quota.test-session",
      account: "account-session",
      keychain: keychain
    )
    let prior = Fixtures.session()
    try store.save(prior)
    keychain.updateStatus = errSecNotAvailable
    #expect(throws: AccountStoreError.unwritable) {
      try store.save(
        Fixtures.session(access: Fixtures.rotatedAccess, refresh: Fixtures.rotatedRefresh)
      )
    }
    #expect(keychain.deleteCount == 0)
    #expect(try store.load() == prior)
  }

  @Test
  func failedAddOnMissingItemDoesNotDelete() throws {
    let keychain = FakeKeychain()
    keychain.addStatus = errSecNotAvailable
    let store = KeychainAccountSessionStore(
      service: "io.gotry.quota.test-session",
      account: "account-session",
      keychain: keychain
    )
    #expect(throws: AccountStoreError.unwritable) {
      try store.save(Fixtures.session())
    }
    #expect(keychain.calls == ["add"])
    #expect(keychain.deleteCount == 0)
    #expect(try store.load() == nil)
  }
}

final class FakeKeychain: KeychainOperating, @unchecked Sendable {
  var items: [String: Data] = [:]
  var calls: [String] = []
  var deleteCount = 0
  var addStatus: OSStatus?
  var updateStatus: OSStatus = errSecSuccess
  var lastAddAccessible: String?
  var lastUpdateAccessible: String?

  func add(_ attributes: [String: Any]) -> OSStatus {
    calls.append("add")
    lastAddAccessible = accessibility(attributes)
    if let addStatus {
      return addStatus
    }
    let key = identity(attributes)
    if items[key] != nil {
      return errSecDuplicateItem
    }
    items[key] = attributes[kSecValueData as String] as? Data
    return errSecSuccess
  }

  func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
    calls.append("update")
    lastUpdateAccessible = accessibility(attributes)
    let key = identity(query)
    guard items[key] != nil else { return errSecItemNotFound }
    guard updateStatus == errSecSuccess else { return updateStatus }
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
    let service = query[kSecAttrService as String] as? String ?? ""
    let matches = items.filter { $0.key.hasPrefix("\(service)|") }
    guard !matches.isEmpty else { return (errSecItemNotFound, []) }
    return (errSecSuccess, matches.values.map { [kSecValueData as String: $0] })
  }

  func delete(_ query: [String: Any]) -> OSStatus {
    calls.append("delete")
    deleteCount += 1
    items[identity(query)] = nil
    return errSecSuccess
  }

  private func identity(_ query: [String: Any]) -> String {
    let service = query[kSecAttrService as String] as? String ?? ""
    let account = query[kSecAttrAccount as String] as? String ?? ""
    return "\(service)|\(account)"
  }

  private func accessibility(_ attributes: [String: Any]) -> String? {
    attributes[kSecAttrAccessible as String] as? String
  }
}
