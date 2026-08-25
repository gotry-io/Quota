import Foundation

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

public enum AccountDeviceStatus: String, Codable, Sendable, TolerantWireEnum {
  case active
  case offline
  case signedOut = "signed_out"
  case unknown
}

public enum AccountDevicePlatform: String, Codable, Sendable, TolerantWireEnum {
  case macos
  case linux
  case windows
  case unknown
}

public struct AccountDevice: Codable, Equatable, Identifiable, Sendable {
  public let deviceID: String
  public let displayName: String
  public let platform: AccountDevicePlatform
  public let deviceGeneration: Int
  public let status: AccountDeviceStatus
  public let createdAt: Date
  public let lastLoginAt: Date
  public let lastSeenAt: Date?
  public let signedOutAt: Date?

  public var id: String { deviceID }

  public init(
    deviceID: String,
    displayName: String,
    platform: AccountDevicePlatform,
    deviceGeneration: Int,
    status: AccountDeviceStatus,
    createdAt: Date,
    lastLoginAt: Date,
    lastSeenAt: Date?,
    signedOutAt: Date?
  ) {
    self.deviceID = deviceID
    self.displayName = displayName
    self.platform = platform
    self.deviceGeneration = deviceGeneration
    self.status = status
    self.createdAt = createdAt
    self.lastLoginAt = lastLoginAt
    self.lastSeenAt = lastSeenAt
    self.signedOutAt = signedOutAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    displayName = try container.decode(String.self, forKey: .displayName)
    platform = try container.decode(AccountDevicePlatform.self, forKey: .platform)
    deviceGeneration = try container.decode(Int.self, forKey: .deviceGeneration)
    status = try container.decode(AccountDeviceStatus.self, forKey: .status)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    lastLoginAt = try container.decode(Date.self, forKey: .lastLoginAt)
    lastSeenAt = try container.decode(Date?.self, forKey: .lastSeenAt)
    signedOutAt = try container.decode(Date?.self, forKey: .signedOutAt)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid account device."
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(deviceID, forKey: .deviceID)
    try container.encode(displayName, forKey: .displayName)
    try container.encode(platform, forKey: .platform)
    try container.encode(deviceGeneration, forKey: .deviceGeneration)
    try container.encode(status, forKey: .status)
    try container.encode(createdAt, forKey: .createdAt)
    try container.encode(lastLoginAt, forKey: .lastLoginAt)
    try container.encode(lastSeenAt, forKey: .lastSeenAt)
    try container.encode(signedOutAt, forKey: .signedOutAt)
  }

  public var isValid: Bool {
    WireValidation.isOpaqueID(deviceID)
      && WireValidation.isTrimmedText(displayName, maximum: 128)
      && WireValidation.isSafePositive(deviceGeneration)
      && (status == .signedOut) == (signedOutAt != nil)
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case displayName
    case platform
    case deviceGeneration
    case status
    case createdAt
    case lastLoginAt
    case lastSeenAt
    case signedOutAt
  }
}

public struct AccountQuotaObservation: Codable, Equatable, Sendable {
  public let deviceID: String
  public let snapshot: QuotaSnapshot

  public init(deviceID: String, snapshot: QuotaSnapshot) {
    self.deviceID = deviceID
    self.snapshot = snapshot
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    guard isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID, in: container, debugDescription: "Invalid quota observation.")
    }
  }

  /// A managed observation names a device. The provider is carried by `ProviderID`, whose
  /// cases are exactly the providers this Account accepts.
  public var isValid: Bool { WireValidation.isOpaqueID(deviceID) }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case snapshot
  }
}

public struct AccountSummary: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let account: QuotaUserAccount
  public let devices: [AccountDevice]
  public let quota: [AccountQuotaObservation]
  public let usage: AccountUsageSummary

  public init(
    account: QuotaUserAccount,
    devices: [AccountDevice],
    quota: [AccountQuotaObservation],
    usage: AccountUsageSummary
  ) {
    protocolVersion = WireCodec.managedDataProtocolVersion
    self.account = account
    self.devices = devices
    self.quota = quota
    self.usage = usage
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    account = try container.decode(QuotaUserAccount.self, forKey: .account)
    devices = try container.decode([AccountDevice].self, forKey: .devices)
    quota = try container.decode([AccountQuotaObservation].self, forKey: .quota)
    usage = try container.decode(AccountUsageSummary.self, forKey: .usage)
    guard protocolVersion == WireCodec.managedDataProtocolVersion,
      account.isValid,
      devices.count <= 256,
      devices.allSatisfy(\.isValid),
      quota.count <= 8_192,
      usage.isValid
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
    case quota
    case usage
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
  case sequenceConflict = "sequence_conflict"
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
