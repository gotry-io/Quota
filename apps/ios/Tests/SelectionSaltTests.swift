import Foundation
import QuotaAccount
import QuotaKeychain
import QuotaPresentation
import Security
import Testing

@testable import Quota

struct SelectionSaltTests {
  /// A widget's `selection_id` is what a deep link must parse — twelve lowercase hex characters —
  /// and a new salt (logout clears it) renames every subscription so old links fall back.
  @Test
  func aSelectionIDIsTwelveLowercaseHexAndANewSaltRenamesIt() {
    let selector = SubscriptionSelector.make(
      provider: "codex",
      fingerprint: "fp_codex_01",
      fingerprintScope: "global",
      sourceID: nil
    )
    let first = SelectionIDs.make(selector: selector, salt: Data(repeating: 0x11, count: 32))
    let rotated = SelectionIDs.make(selector: selector, salt: Data(repeating: 0x22, count: 32))
    let hex = CharacterSet(charactersIn: "0123456789abcdef")
    #expect(first.count == 12)
    #expect(first.unicodeScalars.allSatisfy { hex.contains($0) })
    #expect(first != rotated)
    #expect(first != selector)
    #expect(rotated != selector)
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

    // The racing store read before the first one wrote, so it reaches the add and loses it.
    let racing = KeychainSelectionSaltStore(
      service: "io.gotry.quota.test-selection-salt",
      account: "selection-salt",
      keychain: keychain,
      generateSalt: { Data(repeating: 0x22, count: 32) }
    )
    keychain.missNextRead = true
    #expect(try racing.loadOrCreate() == Data(repeating: 0x11, count: 32))
    #expect(keychain.calls == ["add", "add"])
  }
}

final class SelectionSaltFakeKeychain: KeychainOperating, @unchecked Sendable {
  var items: [String: Data] = [:]
  var calls: [String] = []
  var deleteCount = 0
  var lastAddAccessible: String?
  /// Answers the next read as empty, the way a store that read before another one wrote sees it.
  var missNextRead = false

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
    if missNextRead {
      missNextRead = false
      return (errSecItemNotFound, nil)
    }
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
