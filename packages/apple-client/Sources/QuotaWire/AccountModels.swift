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
    try decoder.rejectUnknownWireKeys(["accountId", "displayLabel", "createdAt"])
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

  var isValid: Bool {
    WireValidation.isOpaqueID(accountID)
      && (displayLabel.map { WireValidation.isTrimmedText($0, maximum: 128) } ?? true)
  }

  private enum CodingKeys: String, CodingKey {
    case accountID = "accountId"
    case displayLabel
    case createdAt
  }
}

public enum AccountDeviceStatus: String, Codable, Sendable {
  case active
  case offline
  case signedOut = "signed_out"
}

public enum AccountDevicePlatform: String, Codable, Sendable {
  case macos
  case linux
  case windows
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
    try decoder.rejectUnknownWireKeys([
      "deviceId", "displayName", "platform", "deviceGeneration", "status", "createdAt",
      "lastLoginAt", "lastSeenAt", "signedOutAt",
    ])
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

  var isValid: Bool {
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
  public let sequence: Int
  public let capturedAt: Date
  public let snapshot: QuotaSnapshot
  public let updatedAt: Date

  public init(
    deviceID: String,
    sequence: Int,
    capturedAt: Date,
    snapshot: QuotaSnapshot,
    updatedAt: Date
  ) {
    self.deviceID = deviceID
    self.sequence = sequence
    self.capturedAt = capturedAt
    self.snapshot = snapshot
    self.updatedAt = updatedAt
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "deviceId", "sequence", "capturedAt", "snapshot", "updatedAt",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    snapshot = try container.decode(QuotaSnapshot.self, forKey: .snapshot)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    guard WireValidation.isOpaqueID(deviceID), WireValidation.isSafeNonnegative(sequence) else {
      throw DecodingError.dataCorruptedError(
        forKey: .deviceID,
        in: container,
        debugDescription: "Invalid quota observation."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case deviceID = "deviceId"
    case sequence
    case capturedAt
    case snapshot
    case updatedAt
  }
}

public struct AccountSummary: Codable, Equatable, Sendable {
  public let protocolVersion: Int
  public let generatedAt: Date
  public let account: QuotaUserAccount
  public let devices: [AccountDevice]
  public let quota: [AccountQuotaObservation]
  public let usage: AccountUsageSummary

  public init(
    generatedAt: Date,
    account: QuotaUserAccount,
    devices: [AccountDevice],
    quota: [AccountQuotaObservation],
    usage: AccountUsageSummary
  ) {
    protocolVersion = WireCodec.managedDataProtocolVersion
    self.generatedAt = generatedAt
    self.account = account
    self.devices = devices
    self.quota = quota
    self.usage = usage
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "generatedAt", "account", "devices", "quota", "usage",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    generatedAt = try container.decode(Date.self, forKey: .generatedAt)
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
    case generatedAt
    case account
    case devices
    case quota
    case usage
  }
}

public struct CachedAccountSummary: Codable, Equatable, Sendable {
  public let summary: AccountSummary
  public let fetchedAt: Date

  public init(summary: AccountSummary, fetchedAt: Date) {
    self.summary = summary
    self.fetchedAt = fetchedAt
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["summary", "fetchedAt"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    summary = try container.decode(AccountSummary.self, forKey: .summary)
    fetchedAt = try container.decode(Date.self, forKey: .fetchedAt)
  }

  private enum CodingKeys: String, CodingKey {
    case summary
    case fetchedAt
  }
}

public enum RelayErrorCode: String, Codable, Sendable {
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
}

public struct RelayErrorEnvelope: Decodable, Equatable, Sendable {
  public let code: RelayErrorCode
  public let message: String

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["error"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let error = try container.decode(ErrorBody.self, forKey: .error)
    code = error.code
    message = error.message
  }

  private struct ErrorBody: Decodable {
    let code: RelayErrorCode
    let message: String

    init(from decoder: Decoder) throws {
      try decoder.rejectUnknownWireKeys(["code", "message"])
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
