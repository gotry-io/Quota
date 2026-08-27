import Foundation
import QuotaPresentation

public struct QuotaUserAccount: Codable, Equatable, Sendable {
  public let accountID: String
  public let displayLabel: String?
  public let createdAt: Date

  public init(accountID: String, displayLabel: String?, createdAt: Date) {
    self.accountID = accountID
    self.displayLabel = displayLabel
    self.createdAt = createdAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    accountID = try container.decode(String.self, forKey: .accountID)
    displayLabel = try container.decode(String?.self, forKey: .displayLabel)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .accountID,
        in: container,
        debugDescription: "Invalid account metadata."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(accountID, forKey: .accountID)
    try container.encode(displayLabel, forKey: .displayLabel)
    try container.encode(createdAt, forKey: .createdAt)
  }

  public var isValid: Bool {
    WireValidation.isOpaqueID(accountID)
      && (displayLabel.map { WireValidation.isTrimmedText($0, maximum: 128) } ?? true)
  }

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case displayLabel
    case createdAt
  }
}

/// What a Device runs. QuotaBar is the only client that registers one, so there is one member
/// besides the one every tolerant read keeps for a value this build cannot name.
public enum AccountDevicePlatform: String, Codable, Sendable, TolerantWireEnum {
  case macos
  case unknown
}

/// A device as an Account reads it: the two instants Relay witnessed.
///
/// `lastSeenAt` is when the device last called; `lastObservedAt` is when the newest reading it
/// sent was taken. How recently a device spoke is derived from those by whoever reads them, so
/// nothing here is a status one device asserted about another.
public struct AccountDevice: Codable, Equatable, Identifiable, Sendable {
  public let id: String
  public let displayName: String
  public let platform: AccountDevicePlatform
  public let lastSeenAt: Date?
  public let lastObservedAt: Date?

  public init(
    id: String,
    displayName: String,
    platform: AccountDevicePlatform,
    lastSeenAt: Date?,
    lastObservedAt: Date?
  ) {
    self.id = id
    self.displayName = displayName
    self.platform = platform
    self.lastSeenAt = lastSeenAt
    self.lastObservedAt = lastObservedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    platform = try container.decode(AccountDevicePlatform.self, forKey: .platform)
    lastSeenAt = try container.decode(Date?.self, forKey: .lastSeenAt)
    lastObservedAt = try container.decode(Date?.self, forKey: .lastObservedAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .id,
        in: container,
        debugDescription: "Invalid account device."
      )
    }
  }

  public var isValid: Bool {
    WireValidation.isOpaqueID(id) && WireValidation.isTrimmedText(displayName, maximum: 128)
  }

  /// How recently this device spoke, in the words every Quota client uses.
  public func activity(now: Date) -> DeviceActivity {
    DeviceActivity.make(lastSeenAt: lastSeenAt, lastObservedAt: lastObservedAt, now: now)
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case displayName
    case lastSeenAt
    case lastObservedAt
    case platform
  }
}

/// One device that reported a subscription, kept whether or not its reading is the one shown.
public struct QuotaSubscriptionSource: Codable, Equatable, Sendable {
  public let deviceID: String
  public let observedAt: Date

  public init(deviceID: String, observedAt: Date) {
    self.deviceID = deviceID
    self.observedAt = observedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    guard WireValidation.isOpaqueID(deviceID) else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid subscription source."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case observedAt
  }
}

/// One subscription, already resolved.
///
/// Relay keeps one observation per reporting device and resolves them once, so an account
/// collected on three Macs reaches every reader as one row with three sources rather than as
/// three cards each client had to collapse for itself.
public struct QuotaSubscription: Codable, Equatable, Identifiable, Sendable {
  public let key: String
  public let provider: ProviderID
  public let snapshot: QuotaSnapshot
  public let sources: [QuotaSubscriptionSource]

  public var id: String { key }

  public init(
    key: String,
    provider: ProviderID,
    snapshot: QuotaSnapshot,
    sources: [QuotaSubscriptionSource]
  ) {
    self.key = key
    self.provider = provider
    self.snapshot = snapshot
    self.sources = sources
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    key = try container.decode(String.self, forKey: .key)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    sources = try container.decode([QuotaSubscriptionSource].self, forKey: .sources)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .key,
        in: container,
        debugDescription: "Invalid subscription."
      )
    }
  }

  public var isValid: Bool {
    !key.isEmpty && key.utf8.count <= 512 && sources.count <= 256
  }

  private enum CodingKeys: String, CodingKey {
    case key
    case provider
    case snapshot
    case sources
  }
}

/// What an Account read answers: who the account is, what reported to it, what it is using,
/// and the catalog revisions the numbers were priced against.
public struct AccountSummary: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let account: QuotaUserAccount
  public let devices: [AccountDevice]
  public let subscriptions: [QuotaSubscription]
  public let usage: AccountUsage
  public let pricingRevision: String
  public let modelCatalogRevision: String

  public init(
    account: QuotaUserAccount,
    devices: [AccountDevice],
    subscriptions: [QuotaSubscription],
    usage: AccountUsage,
    pricingRevision: String,
    modelCatalogRevision: String
  ) {
    protocolVersion = WireCodec.managedDataProtocolVersion
    self.account = account
    self.devices = devices
    self.subscriptions = subscriptions
    self.usage = usage
    self.pricingRevision = pricingRevision
    self.modelCatalogRevision = modelCatalogRevision
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    account = try container.decode(QuotaUserAccount.self, forKey: .account)
    devices = try container.decode([AccountDevice].self, forKey: .devices)
    subscriptions = try container.decode([QuotaSubscription].self, forKey: .subscriptions)
    usage = try container.decode(AccountUsage.self, forKey: .usage)
    pricingRevision = try container.decode(String.self, forKey: .pricingRevision)
    modelCatalogRevision = try container.decode(String.self, forKey: .modelCatalogRevision)
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      account.isValid,
      devices.count <= 256,
      devices.allSatisfy(\.isValid),
      subscriptions.count <= 1_024,
      subscriptions.allSatisfy(\.isValid),
      usage.isValid,
      WireValidation.isOpaqueID(pricingRevision),
      WireValidation.isOpaqueID(modelCatalogRevision)
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid account summary."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case account
    case devices
    case subscriptions
    case usage
    case pricingRevision
    case modelCatalogRevision
  }
}

public struct CachedAccountSummary: Codable, Equatable, Sendable {
  public let summary: AccountSummary
  public let fetchedAt: Date
  /// The validator this body is current at, when the read that produced it carried one.
  /// Offering it back is what lets an unchanged account answer 304 instead of resending.
  public let etag: String?

  public init(summary: AccountSummary, fetchedAt: Date, etag: String? = nil) {
    self.summary = summary
    self.fetchedAt = fetchedAt
    self.etag = etag
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(AccountSummary.self, forKey: .summary)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
    etag = try container.decodeIfPresent(String.self, forKey: .etag)
  }

  private enum CodingKeys: String, CodingKey {
    case summary
    case fetchedAt
    case etag
  }
}

public enum RelayErrorCode: String, Codable, Sendable, TolerantWireEnum {
  case invalidRequest = "invalid_request"
  case unauthorized
  case forbidden
  case notFound = "not_found"
  case authorizationPending = "authorization_pending"
  case slowDown = "slow_down"
  case accessDenied = "access_denied"
  case expiredToken = "expired_token"
  case invalidGrant = "invalid_grant"
  case rateLimited = "rate_limited"
  case staleGeneration = "stale_generation"
  case deviceDeleted = "device_deleted"
  case clientUpgradeRequired = "client_upgrade_required"
  case conflict
  case internalError = "internal_error"
  case unknown
}

public struct RelayErrorEnvelope: Decodable, Equatable, Sendable {
  public let code: RelayErrorCode
  public let message: String

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let error = try container.decode(ErrorBody.self, forKey: .error)
    code = error.code
    message = error.message
  }

  private struct ErrorBody: Decodable {
    let code: RelayErrorCode
    let message: String

    init(from decoder: Decoder) throws {
      let container = try decoder.container(keyedBy: CodingKeys.self)
      code = try container.decode(RelayErrorCode.self, forKey: .code)
      message = try container.decode(String.self, forKey: .message)
      guard WireValidation.isTrimmedText(message, maximum: 512) else {
        throw DecodingError.dataCorruptedError(
          forKey: .message,
          in: container,
          debugDescription: "Invalid relay error message."
        )
      }
    }

    private enum CodingKeys: String, CodingKey {
      case code
      case message
    }
  }

  private enum CodingKeys: String, CodingKey {
    case error
  }
}
