import Foundation
import Security
import Testing

@testable import QuotaBar

@Test
func addsOwnerCredentialWithThisDeviceOnlyAccessibility() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let store = RelayOwnerCredentialStore(operations: operations)
  let reference = RelayOwnerCredentialStore.reference(
    for: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  )

  try store.save("owner_synthetic_secret", reference: reference)

  let operation = try #require(operations.operations.first)
  guard case .add(let item) = operation else {
    Issue.record("Expected a Keychain add operation.")
    return
  }
  #expect(item.query.service == "io.gotry.quotabar.relay-owner")
  #expect(item.query.account == reference)
  #expect(!item.query.returnsData)
  #expect(!item.query.matchesOne)
  #expect(item.value == Data("owner_synthetic_secret".utf8))
  #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
}

@Test
func scopesOwnerCredentialQueriesToTheConfiguredService() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let service = "io.gotry.quotabar.relay-owner.e2e.synthetic"
  let store = RelayOwnerCredentialStore(operations: operations, service: service)

  try store.save("owner_synthetic_secret", reference: "relay-owner:profile")

  guard case .add(let item) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain add operation.")
    return
  }
  #expect(item.query.service == service)
}

@Test
func updatesExistingOwnerCredentialWithThisDeviceOnlyAccessibility() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecDuplicateItem, data: nil),
    RelayKeychainResult(status: errSecSuccess, data: nil),
  ])
  let store = RelayOwnerCredentialStore(operations: operations)

  try store.save("replacement_secret", reference: "relay-owner:profile")

  #expect(operations.operations.count == 2)
  guard case .update(let item) = operations.operations[1] else {
    Issue.record("Expected a Keychain update operation.")
    return
  }
  #expect(item.value == Data("replacement_secret".utf8))
  #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
}

@Test
func loadsOwnerCredentialWithAnExactSingleItemQuery() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: Data("owner_synthetic_secret".utf8))
  ])
  let store = RelayOwnerCredentialStore(operations: operations)

  let ownerBearer = try store.load(reference: "relay-owner:profile")

  #expect(ownerBearer == "owner_synthetic_secret")
  guard case .load(let query) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain load operation.")
    return
  }
  #expect(query.service == "io.gotry.quotabar.relay-owner")
  #expect(query.account == "relay-owner:profile")
  #expect(query.returnsData)
  #expect(query.matchesOne)
}

@Test
func deletesOnlyTheReferencedOwnerCredential() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let store = RelayOwnerCredentialStore(operations: operations)

  try store.delete(reference: "relay-owner:profile")

  guard case .delete(let query) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain delete operation.")
    return
  }
  #expect(query.service == "io.gotry.quotabar.relay-owner")
  #expect(query.account == "relay-owner:profile")
  #expect(!query.returnsData)
  #expect(!query.matchesOne)
}

@Test
func reconcilesOwnerCredentialsByDeletingOnlyOrphanedAccounts() throws {
  let kept = "relay-owner:kept"
  let orphan = "relay-owner:orphan"
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil, accounts: [kept, orphan]),
    RelayKeychainResult(status: errSecSuccess, data: nil),
  ])

  try RelayOwnerCredentialStore(operations: operations).reconcile(retaining: [kept])

  #expect(operations.operations.count == 2)
  #expect(operations.operations[0] == .listAccounts(service: RelayOwnerCredentialStore.service))
  guard case .delete(let query) = operations.operations[1] else {
    Issue.record("Expected the orphaned Keychain item to be deleted.")
    return
  }
  #expect(query.account == orphan)
}

@Test
func deletesAllOwnerCredentialsWithinTheQuotaBarService() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])

  try RelayOwnerCredentialStore(operations: operations).deleteAll()

  #expect(operations.operations == [
    .deleteAll(service: RelayOwnerCredentialStore.service)
  ])
}

@Test
func reportsFixedMissingAndCorruptCredentialErrors() throws {
  let missingOperations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecItemNotFound, data: nil)
  ])
  let corruptOperations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: Data([0xff]))
  ])

  #expect(throws: RelayOwnerCredentialStoreError.missingCredential) {
    try RelayOwnerCredentialStore(operations: missingOperations).load(reference: "relay-owner:p")
  }
  #expect(throws: RelayOwnerCredentialStoreError.corruptCredential) {
    try RelayOwnerCredentialStore(operations: corruptOperations).load(reference: "relay-owner:p")
  }
}

@Test
func mapsKeychainFailuresToFixedErrors() {
  let addFailure = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecInteractionNotAllowed, data: nil)
  ])
  let updateFailure = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecDuplicateItem, data: nil),
    RelayKeychainResult(status: errSecInteractionNotAllowed, data: nil),
  ])
  let readFailure = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecInteractionNotAllowed, data: nil)
  ])
  let deleteFailure = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecInteractionNotAllowed, data: nil)
  ])

  #expect(throws: RelayOwnerCredentialStoreError.couldNotStore) {
    try RelayOwnerCredentialStore(operations: addFailure).save(
      "owner_synthetic_secret",
      reference: "relay-owner:profile"
    )
  }
  #expect(throws: RelayOwnerCredentialStoreError.couldNotStore) {
    try RelayOwnerCredentialStore(operations: updateFailure).save(
      "owner_synthetic_secret",
      reference: "relay-owner:profile"
    )
  }
  #expect(throws: RelayOwnerCredentialStoreError.couldNotRead) {
    try RelayOwnerCredentialStore(operations: readFailure).load(reference: "relay-owner:profile")
  }
  #expect(throws: RelayOwnerCredentialStoreError.couldNotDelete) {
    try RelayOwnerCredentialStore(operations: deleteFailure).delete(reference: "relay-owner:profile")
  }
}

@Test
func rejectsCredentialsWithSurroundingWhitespace() {
  let operations = FakeRelayKeychainOperations([])

  #expect(throws: RelayOwnerCredentialStoreError.invalidCredential) {
    try RelayOwnerCredentialStore(operations: operations).save(
      " owner_synthetic_secret",
      reference: "relay-owner:p"
    )
  }
  #expect(operations.operations.isEmpty)
}

private final class FakeRelayKeychainOperations: RelayKeychainOperating, @unchecked Sendable {
  private let lock = NSLock()
  private var results: [RelayKeychainResult]
  private(set) var operations: [RelayKeychainOperation] = []

  init(_ results: [RelayKeychainResult]) {
    self.results = results
  }

  func perform(_ operation: RelayKeychainOperation) -> RelayKeychainResult {
    lock.withLock {
      operations.append(operation)
      guard !results.isEmpty else {
        return RelayKeychainResult(status: errSecParam, data: nil)
      }
      return results.removeFirst()
    }
  }
}
