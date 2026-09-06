import Foundation

/// What paid sync is worth to this Account right now, as Relay last read it.
///
/// `grace` is still access: the store is retrying a payment and Apple has not withdrawn the
/// subscription yet. `none` is a member of the contract, not the absence of one, so the tolerant
/// `unknown` still stands for a status a newer Relay names that this build cannot.
public enum EntitlementStatus: String, Codable, Sendable, TolerantWireEnum {
  case active
  case grace
  case expired
  case none
  case unknown

  /// Whether Relay would let this Account's Devices write. The two members that answer yes are
  /// the same two the write routes gate on, so the app never disagrees with the boundary.
  public var allowsSync: Bool {
    switch self {
    case .active, .grace: true
    case .expired, .none, .unknown: false
    }
  }
}

/// The paid-sync entitlement carried by an Account read.
///
/// `stale` says Relay answered from what it had stored because RevenueCat could not be reached.
/// The values are still the last ones observed, so a reader shows them rather than nothing.
/// See [ADR 0033](../../../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md).
public struct AccountEntitlement: Codable, Equatable, Sendable {
  public let status: EntitlementStatus
  public let expiresAt: Date?
  public let willRenew: Bool
  public let productID: String?
  public let store: String?
  public let stale: Bool

  public init(
    status: EntitlementStatus,
    expiresAt: Date?,
    willRenew: Bool,
    productID: String?,
    store: String?,
    stale: Bool
  ) {
    self.status = status
    self.expiresAt = expiresAt
    self.willRenew = willRenew
    self.productID = productID
    self.store = store
    self.stale = stale
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    status = try container.decode(EntitlementStatus.self, forKey: .status)
    expiresAt = try container.decode(Date?.self, forKey: .expiresAt)
    willRenew = try container.decode(Bool.self, forKey: .willRenew)
    productID = try container.decode(String?.self, forKey: .productID)
    store = try container.decode(String?.self, forKey: .store)
    stale = try container.decode(Bool.self, forKey: .stale)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid entitlement."
      )
    }
  }

  public var isValid: Bool {
    (productID.map { WireValidation.isTrimmedText($0, maximum: 256) } ?? true)
      && (store.map { WireValidation.isTrimmedText($0, maximum: 64) } ?? true)
  }

  /// The entitlement an Account has before any purchase reaches it. Named for what it is rather
  /// than after its `none` status, so it is never read as `Optional.none` where the expected type
  /// is an optional entitlement.
  public static let unsubscribed = AccountEntitlement(
    status: .none,
    expiresAt: nil,
    willRenew: false,
    productID: nil,
    store: nil,
    stale: false
  )

  private enum CodingKeys: String, CodingKey {
    case status
    case expiresAt
    case willRenew
    case productID = "productId"
    case store
    case stale
  }
}
