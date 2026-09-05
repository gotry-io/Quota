import Foundation
import Security

/// The generic-password Keychain, as the four calls this repository makes.
///
/// It is a protocol so a test can answer without a Keychain — a signed test host is not always
/// there, and the stores above it are worth testing on their own terms. Nothing here interprets
/// what it stores: the store that owns an item decides its class, its accessibility, and what its
/// data means.
public protocol KeychainOperating: Sendable {
  func add(_ attributes: [String: Any]) -> OSStatus
  func update(query: [String: Any], attributes: [String: Any]) -> OSStatus
  func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?)
  /// Every item a query matches, each as its attribute dictionary. A store that keeps one item
  /// per account reads its whole list with this.
  func copyAllMatching(_ query: [String: Any]) -> (OSStatus, [[String: Any]])
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

  public func copyAllMatching(_ query: [String: Any]) -> (OSStatus, [[String: Any]]) {
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    return (status, item as? [[String: Any]] ?? [])
  }

  public func delete(_ query: [String: Any]) -> OSStatus {
    SecItemDelete(query as CFDictionary)
  }
}
