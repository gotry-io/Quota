import Foundation
import Security
import Testing

@testable import QuotaBar

@Test
func addsControllerCredentialWithThisDeviceOnlyAccessibility() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let store = RelayControllerCredentialStore(operations: operations)
  let reference = RelayControllerCredentialStore.reference(
    for: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
  )

  try store.save("controller_synthetic_secret", reference: reference)

  let operation = try #require(operations.operations.first)
  guard case .add(let item) = operation else {
    Issue.record("Expected a Keychain add operation.")
    return
  }
  #expect(item.query.service == "io.gotry.quotabar.relay-controller")
  #expect(item.query.account == reference)
  #expect(!item.query.returnsData)
  #expect(!item.query.matchesOne)
  #expect(item.value == Data("controller_synthetic_secret".utf8))
  #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
}

@Test
func scopesControllerCredentialQueriesToTheConfiguredService() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let service = "io.gotry.quotabar.relay-controller.e2e.synthetic"
  let store = RelayControllerCredentialStore(operations: operations, service: service)

  try store.save("controller_synthetic_secret", reference: "relay-controller:profile")

  guard case .add(let item) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain add operation.")
    return
  }
  #expect(item.query.service == service)
}

@Test
func updatesExistingControllerCredentialWithThisDeviceOnlyAccessibility() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecDuplicateItem, data: nil),
    RelayKeychainResult(status: errSecSuccess, data: nil),
  ])
  let store = RelayControllerCredentialStore(operations: operations)

  try store.save("replacement_secret", reference: "relay-controller:profile")

  #expect(operations.operations.count == 2)
  guard case .update(let item) = operations.operations[1] else {
    Issue.record("Expected a Keychain update operation.")
    return
  }
  #expect(item.value == Data("replacement_secret".utf8))
  #expect(item.accessibility == .afterFirstUnlockThisDeviceOnly)
}

@Test
func loadsControllerCredentialWithAnExactSingleItemQuery() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: Data("controller_synthetic_secret".utf8))
  ])
  let store = RelayControllerCredentialStore(operations: operations)

  let controllerBearer = try store.load(reference: "relay-controller:profile")

  #expect(controllerBearer == "controller_synthetic_secret")
  guard case .load(let query) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain load operation.")
    return
  }
  #expect(query.service == "io.gotry.quotabar.relay-controller")
  #expect(query.account == "relay-controller:profile")
  #expect(query.returnsData)
  #expect(query.matchesOne)
}

@Test
func deletesOnlyTheReferencedControllerCredential() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])
  let store = RelayControllerCredentialStore(operations: operations)

  try store.delete(reference: "relay-controller:profile")

  guard case .delete(let query) = try #require(operations.operations.first) else {
    Issue.record("Expected a Keychain delete operation.")
    return
  }
  #expect(query.service == "io.gotry.quotabar.relay-controller")
  #expect(query.account == "relay-controller:profile")
  #expect(!query.returnsData)
  #expect(!query.matchesOne)
}

@Test
func reconcilesControllerCredentialsByDeletingOnlyOrphanedAccounts() throws {
  let kept = "relay-controller:kept"
  let orphan = "relay-controller:orphan"
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil, accounts: [kept, orphan]),
    RelayKeychainResult(status: errSecSuccess, data: nil),
  ])

  try RelayControllerCredentialStore(operations: operations).reconcile(retaining: [kept])

  #expect(operations.operations.count == 2)
  #expect(operations.operations[0] == .listAccounts(service: RelayControllerCredentialStore.service))
  guard case .delete(let query) = operations.operations[1] else {
    Issue.record("Expected the orphaned Keychain item to be deleted.")
    return
  }
  #expect(query.account == orphan)
}

@Test
func deletesAllControllerCredentialsWithinTheQuotaBarService() throws {
  let operations = FakeRelayKeychainOperations([
    RelayKeychainResult(status: errSecSuccess, data: nil)
  ])

  try RelayControllerCredentialStore(operations: operations).deleteAll()

  #expect(operations.operations == [
    .deleteAll(service: RelayControllerCredentialStore.service)
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

  #expect(throws: RelayControllerCredentialStoreError.missingCredential) {
    try RelayControllerCredentialStore(operations: missingOperations).load(reference: "relay-controller:p")
  }
  #expect(throws: RelayControllerCredentialStoreError.corruptCredential) {
    try RelayControllerCredentialStore(operations: corruptOperations).load(reference: "relay-controller:p")
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

  #expect(throws: RelayControllerCredentialStoreError.couldNotStore) {
    try RelayControllerCredentialStore(operations: addFailure).save(
      "controller_synthetic_secret",
      reference: "relay-controller:profile"
    )
  }
  #expect(throws: RelayControllerCredentialStoreError.couldNotStore) {
    try RelayControllerCredentialStore(operations: updateFailure).save(
      "controller_synthetic_secret",
      reference: "relay-controller:profile"
    )
  }
  #expect(throws: RelayControllerCredentialStoreError.couldNotRead) {
    try RelayControllerCredentialStore(operations: readFailure).load(reference: "relay-controller:profile")
  }
  #expect(throws: RelayControllerCredentialStoreError.couldNotDelete) {
    try RelayControllerCredentialStore(operations: deleteFailure).delete(reference: "relay-controller:profile")
  }
}

@Test
func rejectsCredentialsWithSurroundingWhitespace() {
  let operations = FakeRelayKeychainOperations([])

  #expect(throws: RelayControllerCredentialStoreError.invalidCredential) {
    try RelayControllerCredentialStore(operations: operations).save(
      " controller_synthetic_secret",
      reference: "relay-controller:p"
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
