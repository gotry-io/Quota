import Foundation
import QuotaAccount
import QuotaKeychain
import QuotaPresentation
import Security
import Testing

@testable import Quota

struct SelectionSaltTests {
  @Test
  func makeReturnsTwelveLowercaseHexCharacters() {
    let salt = Data(repeating: 0x5a, count: 32)
    let id = SelectionIDs.make(selector: "ccfc96629357", salt: salt)
    #expect(id.count == 12)
    #expect(id == id.lowercased())
    let hex = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(id.unicodeScalars.allSatisfy { hex.contains($0) })
  }

  @Test
  func makeIsStableForTheSameSelectorAndSalt() {
    let salt = Data(repeating: 0x5a, count: 32)
    let first = SelectionIDs.make(selector: "ccfc96629357", salt: salt)
    let again = SelectionIDs.make(selector: "ccfc96629357", salt: salt)
    #expect(first == again)
  }

  @Test
  func makeChangesWhenTheSaltChanges() {
    let selector = SubscriptionSelector.make(
      provider: "codex",
      fingerprint: "fp_codex_01",
      fingerprintScope: "global",
      sourceID: nil
    )
    let first = SelectionIDs.make(selector: selector, salt: Data(repeating: 0x11, count: 32))
    let rotated = SelectionIDs.make(selector: selector, salt: Data(repeating: 0x22, count: 32))
    #expect(first != rotated)
    #expect(first != selector)
    #expect(rotated != selector)
  }

  @Test
  func inMemoryLoadOrCreateReusesTheSameSaltUntilCleared() throws {
    let generation = SaltGenerationCounter()
    let store = InMemorySelectionSaltStore {
      generation.count += 1
      return Data(repeating: UInt8(generation.count), count: 32)
    }
    let first = try store.loadOrCreate()
    let again = try store.loadOrCreate()
    #expect(first == again)
    #expect(generation.count == 1)

    try store.clear()
    let rotated = try store.loadOrCreate()
    #expect(rotated != first)
    #expect(generation.count == 2)
  }

  @Test
  func keychainLoadOrCreateWritesAfterFirstUnlockThisDeviceOnly() throws {
    let keychain = SelectionSaltFakeKeychain()
    let store = KeychainSelectionSaltStore(
      service: "io.gotry.quota.test-selection-salt",
      account: "selection-salt",
      keychain: keychain,
      generateSalt: { Data(repeating: 0xab, count: 32) }
    )
    let first = try store.loadOrCreate()
    #expect(first == Data(repeating: 0xab, count: 32))
    #expect(keychain.calls == ["add"])
    #expect(keychain.lastAddAccessible == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)

    let again = try store.loadOrCreate()
    #expect(again == first)
    #expect(keychain.calls == ["add"])

    try store.clear()
    #expect(keychain.deleteCount == 1)
    let rotated = try store.loadOrCreate()
    #expect(rotated == first)
    #expect(keychain.calls == ["add", "delete", "add"])
  }

  @Test
  func keychainLoadOrCreateKeepsTheExistingSaltOnADuplicateAdd() throws {
    let keychain = SelectionSaltFakeKeychain()
    let firstStore = KeychainSelectionSaltStore(
      service: "io.gotry.quota.test-selection-salt",
      account: "selection-salt",
      keychain: keychain,
      generateSalt: { Data(repeating: 0x11, count: 32) }
    )
    #expect(try firstStore.loadOrCreate() == Data(repeating: 0x11, count: 32))

    let racing = KeychainSelectionSaltStore(
      service: "io.gotry.quota.test-selection-salt",
      account: "selection-salt",
      keychain: keychain,
      generateSalt: { Data(repeating: 0x22, count: 32) }
    )
    #expect(try racing.loadOrCreate() == Data(repeating: 0x11, count: 32))
  }
}

final class SaltGenerationCounter: @unchecked Sendable {
  var count = 0
}

final class SelectionSaltFakeKeychain: KeychainOperating, @unchecked Sendable {
  var items: [String: Data] = [:]
  var calls: [String] = []
  var deleteCount = 0
  var lastAddAccessible: String?

  func add(_ attributes: [String: Any]) -> OSStatus {
    calls.append("add")
    lastAddAccessible = attributes[kSecAttrAccessible as String] as? String
    let key = identity(attributes)
    if items[key] != nil {
      return errSecDuplicateItem
    }
    items[key] = attributes[kSecValueData as String] as? Data
    return errSecSuccess
  }

  func update(query: [String: Any], attributes: [String: Any]) -> OSStatus {
    calls.append("update")
    return errSecSuccess
  }

  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
    let key = identity(query)
    guard let data = items[key] else { return (errSecItemNotFound, nil) }
    return (errSecSuccess, data)
  }

  func copyAllMatching(_ query: [String: Any]) -> (OSStatus, [[String: Any]]) {
    (errSecItemNotFound, [])
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
}
