import Foundation
import Security

enum RelayKeychainAccessibility: Equatable, Sendable {
  case afterFirstUnlockThisDeviceOnly
}

struct RelayKeychainQuery: Equatable, Sendable {
  let service: String
  let account: String
  let returnsData: Bool
  let matchesOne: Bool
}

struct RelayKeychainItem: Equatable, Sendable {
  let query: RelayKeychainQuery
  let value: Data
  let accessibility: RelayKeychainAccessibility
}

enum RelayKeychainOperation: Equatable, Sendable {
  case add(RelayKeychainItem)
  case load(RelayKeychainQuery)
  case update(RelayKeychainItem)
  case delete(RelayKeychainQuery)
}

struct RelayKeychainResult: Equatable, Sendable {
  let status: OSStatus
  let data: Data?
}

protocol RelayKeychainOperating: Sendable {
  func perform(_ operation: RelayKeychainOperation) -> RelayKeychainResult
}

struct SystemRelayKeychainOperations: RelayKeychainOperating {
  func perform(_ operation: RelayKeychainOperation) -> RelayKeychainResult {
    switch operation {
    case .add(let item):
      var attributes = baseQuery(item.query)
      attributes[kSecValueData] = item.value
      attributes[kSecAttrAccessible] = accessibility(item.accessibility)
      return RelayKeychainResult(status: SecItemAdd(attributes as CFDictionary, nil), data: nil)

    case .load(let query):
      var attributes = baseQuery(query)
      attributes[kSecReturnData] = query.returnsData
      if query.matchesOne {
        attributes[kSecMatchLimit] = kSecMatchLimitOne
      }
      var result: CFTypeRef?
      let status = SecItemCopyMatching(attributes as CFDictionary, &result)
      return RelayKeychainResult(status: status, data: result as? Data)

    case .update(let item):
      let attributes: [CFString: Any] = [
        kSecValueData: item.value,
        kSecAttrAccessible: accessibility(item.accessibility),
      ]
      let status = SecItemUpdate(
        baseQuery(item.query) as CFDictionary,
        attributes as CFDictionary
      )
      return RelayKeychainResult(status: status, data: nil)

    case .delete(let query):
      return RelayKeychainResult(
        status: SecItemDelete(baseQuery(query) as CFDictionary),
        data: nil
      )
    }
  }

  private func baseQuery(_ query: RelayKeychainQuery) -> [CFString: Any] {
    [
      kSecClass: kSecClassGenericPassword,
      kSecAttrService: query.service,
      kSecAttrAccount: query.account,
    ]
  }

  private func accessibility(_ value: RelayKeychainAccessibility) -> CFString {
    switch value {
    case .afterFirstUnlockThisDeviceOnly:
      kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    }
  }
}

enum RelayOwnerCredentialStoreError: LocalizedError, Equatable, Sendable {
  case invalidCredential
  case missingCredential
  case corruptCredential
  case couldNotRead
  case couldNotStore
  case couldNotDelete

  var errorDescription: String? {
    switch self {
    case .invalidCredential:
      "The Relay owner credential is invalid."
    case .missingCredential:
      "The Relay owner credential is missing."
    case .corruptCredential:
      "The saved Relay owner credential is invalid."
    case .couldNotRead:
      "QuotaBar could not read the Relay owner credential."
    case .couldNotStore:
      "QuotaBar could not save the Relay owner credential."
    case .couldNotDelete:
      "QuotaBar could not delete the Relay owner credential."
    }
  }
}

struct RelayOwnerCredentialStore: Sendable {
  static let service = "io.gotry.quotabar.relay-owner"

  private let operations: any RelayKeychainOperating
  private let service: String

  init(
    operations: any RelayKeychainOperating = SystemRelayKeychainOperations(),
    service: String = RelayOwnerCredentialStore.service
  ) {
    self.operations = operations
    self.service = service
  }

  static func reference(for profileID: UUID) -> String {
    RelayProfile.credentialReference(for: profileID)
  }

  func save(_ ownerBearer: String, reference: String) throws {
    guard isValid(ownerBearer), !reference.isEmpty else {
      throw RelayOwnerCredentialStoreError.invalidCredential
    }
    let item = RelayKeychainItem(
      query: query(reference: reference),
      value: Data(ownerBearer.utf8),
      accessibility: .afterFirstUnlockThisDeviceOnly
    )
    let added = operations.perform(.add(item))
    if added.status == errSecSuccess {
      return
    }
    guard added.status == errSecDuplicateItem else {
      throw RelayOwnerCredentialStoreError.couldNotStore
    }
    guard operations.perform(.update(item)).status == errSecSuccess else {
      throw RelayOwnerCredentialStoreError.couldNotStore
    }
  }

  func load(reference: String) throws -> String {
    guard !reference.isEmpty else {
      throw RelayOwnerCredentialStoreError.missingCredential
    }
    let result = operations.perform(.load(query(reference: reference, forLoad: true)))
    if result.status == errSecItemNotFound {
      throw RelayOwnerCredentialStoreError.missingCredential
    }
    guard result.status == errSecSuccess else {
      throw RelayOwnerCredentialStoreError.couldNotRead
    }
    guard let data = result.data,
      let ownerBearer = String(data: data, encoding: .utf8),
      isValid(ownerBearer)
    else {
      throw RelayOwnerCredentialStoreError.corruptCredential
    }
    return ownerBearer
  }

  func delete(reference: String) throws {
    guard !reference.isEmpty else {
      throw RelayOwnerCredentialStoreError.missingCredential
    }
    let status = operations.perform(.delete(query(reference: reference))).status
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw RelayOwnerCredentialStoreError.couldNotDelete
    }
  }

  private func query(reference: String, forLoad: Bool = false) -> RelayKeychainQuery {
    RelayKeychainQuery(
      service: service,
      account: reference,
      returnsData: forLoad,
      matchesOne: forLoad
    )
  }

  private func isValid(_ ownerBearer: String) -> Bool {
    !ownerBearer.isEmpty
      && ownerBearer == ownerBearer.trimmingCharacters(in: .whitespacesAndNewlines)
      && ownerBearer.unicodeScalars.allSatisfy { $0.value >= 0x20 && $0.value != 0x7f }
  }
}
