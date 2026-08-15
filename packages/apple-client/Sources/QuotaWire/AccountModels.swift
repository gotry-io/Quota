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

public enum AccountDeviceHealthClientProduct: String, Codable, Sendable {
  case quotaBar = "quotabar"
  case quotaCLI = "quotacli"
}

public enum AccountDeviceHealthOperation: String, Codable, Sendable {
  case healthy
  case degraded
  case blocked
}

public enum AccountDeviceHealthDataState: String, Codable, Sendable {
  case current
  case stale
  case partial
  case empty
  case unknown
}

public enum AccountDeviceHealthAttention: String, Codable, Sendable {
  case none
  case automatic
  case optional
  case required
}

public enum AccountDeviceHealthCode: String, Codable, Sendable {
  case refreshFailed = "refresh_failed"
  case quotaCollectionFailed = "quota_collection_failed"
  case usageScanPartial = "usage_scan_partial"
  case usageUploadFailed = "usage_upload_failed"
  case accountSyncFailed = "account_sync_failed"
  case pricingRefreshFailed = "pricing_refresh_failed"
  case processInterrupted = "process_interrupted"
  case localStateInvalid = "local_state_invalid"
}

public struct AccountDeviceHealthSummary: Codable, Equatable, Sendable {
  public let operation: AccountDeviceHealthOperation
  public let data: AccountDeviceHealthDataState
  public let attention: AccountDeviceHealthAttention

  public init(
    operation: AccountDeviceHealthOperation,
    data: AccountDeviceHealthDataState,
    attention: AccountDeviceHealthAttention
  ) {
    self.operation = operation
    self.data = data
    self.attention = attention
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["operation", "data", "attention"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    operation = try container.decode(AccountDeviceHealthOperation.self, forKey: .operation)
    data = try container.decode(AccountDeviceHealthDataState.self, forKey: .data)
    attention = try container.decode(AccountDeviceHealthAttention.self, forKey: .attention)
  }

  private enum CodingKeys: String, CodingKey {
    case operation
    case data
    case attention
  }
}

public struct AccountDeviceHealth: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let clientProduct: AccountDeviceHealthClientProduct
  public let clientVersion: String
  public let platform: AccountDevicePlatform
  public let observedAt: Date
  public let refreshRevision: Int
  public let lastCompletedRefreshAt: Date?
  public let lastSuccessfulAccountSyncAt: Date?
  public let summary: AccountDeviceHealthSummary
  public let topCode: AccountDeviceHealthCode?
  public let consecutiveFailures: Int
  public let usageUploadEnabled: Bool
  public let receivedAt: Date
  public let freshUntil: Date

  public init(
    schemaVersion: Int = 1,
    clientProduct: AccountDeviceHealthClientProduct,
    clientVersion: String,
    platform: AccountDevicePlatform,
    observedAt: Date,
    refreshRevision: Int,
    lastCompletedRefreshAt: Date?,
    lastSuccessfulAccountSyncAt: Date?,
    summary: AccountDeviceHealthSummary,
    topCode: AccountDeviceHealthCode?,
    consecutiveFailures: Int,
    usageUploadEnabled: Bool,
    receivedAt: Date,
    freshUntil: Date
  ) {
    self.schemaVersion = schemaVersion
    self.clientProduct = clientProduct
    self.clientVersion = clientVersion
    self.platform = platform
    self.observedAt = observedAt
    self.refreshRevision = refreshRevision
    self.lastCompletedRefreshAt = lastCompletedRefreshAt
    self.lastSuccessfulAccountSyncAt = lastSuccessfulAccountSyncAt
    self.summary = summary
    self.topCode = topCode
    self.consecutiveFailures = consecutiveFailures
    self.usageUploadEnabled = usageUploadEnabled
    self.receivedAt = receivedAt
    self.freshUntil = freshUntil
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "schemaVersion", "clientProduct", "clientVersion", "platform", "observedAt",
      "refreshRevision", "lastCompletedRefreshAt", "lastSuccessfulAccountSyncAt", "summary",
      "topCode", "consecutiveFailures", "usageUploadEnabled", "receivedAt", "freshUntil",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    clientProduct = try container.decode(AccountDeviceHealthClientProduct.self, forKey: .clientProduct)
    clientVersion = try container.decode(String.self, forKey: .clientVersion)
    platform = try container.decode(AccountDevicePlatform.self, forKey: .platform)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    refreshRevision = try container.decode(Int.self, forKey: .refreshRevision)
    lastCompletedRefreshAt = try container.decode(Date?.self, forKey: .lastCompletedRefreshAt)
    lastSuccessfulAccountSyncAt = try container.decode(Date?.self, forKey: .lastSuccessfulAccountSyncAt)
    summary = try container.decode(AccountDeviceHealthSummary.self, forKey: .summary)
    topCode = try container.decode(AccountDeviceHealthCode?.self, forKey: .topCode)
    consecutiveFailures = try container.decode(Int.self, forKey: .consecutiveFailures)
    usageUploadEnabled = try container.decode(Bool.self, forKey: .usageUploadEnabled)
    receivedAt = try container.decode(Date.self, forKey: .receivedAt)
    freshUntil = try container.decode(Date.self, forKey: .freshUntil)
    let versionValid = !clientVersion.isEmpty && clientVersion.count <= 32
      && clientVersion.enumerated().allSatisfy { index, character in
        character.isASCII && (character.isLetter || character.isNumber
          || (index > 0 && ".+_-".contains(character)))
      }
    guard schemaVersion == 1, versionValid,
      WireValidation.isSafeNonnegative(refreshRevision),
      (0 ... 1_000).contains(consecutiveFailures), freshUntil >= receivedAt,
      lastCompletedRefreshAt.map({ $0 <= observedAt.addingTimeInterval(300) }) ?? true,
      lastSuccessfulAccountSyncAt.map({ $0 <= observedAt.addingTimeInterval(300) }) ?? true
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion, in: container, debugDescription: "Invalid device health.")
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case clientProduct
    case clientVersion
    case platform
    case observedAt
    case refreshRevision
    case lastCompletedRefreshAt
    case lastSuccessfulAccountSyncAt
    case summary
    case topCode
    case consecutiveFailures
    case usageUploadEnabled
    case receivedAt
    case freshUntil
  }
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
  public let health: AccountDeviceHealth?

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
    signedOutAt: Date?,
    health: AccountDeviceHealth? = nil
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
    self.health = health
  }

  public init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "deviceId", "displayName", "platform", "deviceGeneration", "status", "createdAt",
      "lastLoginAt", "lastSeenAt", "signedOutAt", "health",
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
    health = try container.decode(AccountDeviceHealth?.self, forKey: .health)
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
    try container.encode(health, forKey: .health)
  }

  var isValid: Bool {
    WireValidation.isOpaqueID(deviceID)
      && WireValidation.isTrimmedText(displayName, maximum: 128)
      && WireValidation.isSafePositive(deviceGeneration)
      && (status == .signedOut) == (signedOutAt != nil)
      && (health.map { $0.platform == platform } ?? true)
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
    case health
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
