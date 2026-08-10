import Foundation

enum CLIAccountSyncStatus: String, Codable, Sendable {
  case synced
  case signedOut = "signed_out"
  case logoutPending = "logout_pending"
  case accountUnavailable = "account_unavailable"
}

enum CLIAccountSyncReason: String, Codable, Sendable {
  case deviceDeleted = "device_deleted"
  case staleGeneration = "stale_generation"
  case unauthorized
}

/// The stable JSON envelope emitted by `quotacli sync --format json`.
struct CLIAccountSyncOutput: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let status: CLIAccountSyncStatus
  let reason: CLIAccountSyncReason?
  let localReport: QuotaCollectionReport
  let localUsage: LocalUsageReport
  let accountSummary: AccountSummary?

  init(
    schemaVersion: Int = 2,
    status: CLIAccountSyncStatus,
    reason: CLIAccountSyncReason? = nil,
    localReport: QuotaCollectionReport,
    localUsage: LocalUsageReport,
    accountSummary: AccountSummary?
  ) {
    self.schemaVersion = schemaVersion
    self.status = status
    self.reason = reason
    self.localReport = localReport
    self.localUsage = localUsage
    self.accountSummary = accountSummary
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    status = try container.decode(CLIAccountSyncStatus.self, forKey: .status)
    reason = try container.decodeIfPresent(CLIAccountSyncReason.self, forKey: .reason)
    localReport = try container.decode(QuotaCollectionReport.self, forKey: .localReport)
    localUsage = try container.decode(LocalUsageReport.self, forKey: .localUsage)
    accountSummary = try container.decodeIfPresent(AccountSummary.self, forKey: .accountSummary)

    let hasValidPayload =
      switch status {
      case .synced:
        accountSummary != nil && reason == nil
      case .signedOut:
        accountSummary == nil
      case .logoutPending:
        accountSummary == nil && reason == nil
      case .accountUnavailable:
        accountSummary == nil && reason == nil
      }
    guard schemaVersion == 2, hasValidPayload else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid QuotaCLI sync outcome."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case status
    case reason
    case localReport
    case localUsage
    case accountSummary
  }
}

enum CLIAccountAuthStatus: String, Codable, Sendable {
  case signedIn = "signed_in"
  case signedOut = "signed_out"
}

/// The credential-free result emitted by QuotaCLI login and logout commands.
struct CLIAccountAuthOutput: Decodable, Equatable, Sendable {
  let schemaVersion: Int
  let status: CLIAccountAuthStatus
  let accountID: String?
  let deviceID: String?
  let deviceGeneration: Int?

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    status = try container.decode(CLIAccountAuthStatus.self, forKey: .status)
    accountID = try container.decodeIfPresent(String.self, forKey: .accountID)
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    deviceGeneration = try container.decodeIfPresent(Int.self, forKey: .deviceGeneration)

    let isValid =
      switch status {
      case .signedIn:
        accountID.map(isOpaqueID) == true
          && deviceID.map(isOpaqueID) == true
          && deviceGeneration.map { $0 > 0 } == true
      case .signedOut:
        accountID == nil && deviceID == nil && deviceGeneration == nil
      }
    guard schemaVersion == 1, isValid else {
      throw DecodingError.dataCorruptedError(
        forKey: .status,
        in: container,
        debugDescription: "Invalid QuotaCLI account result."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case status
    case accountID = "accountId"
    case deviceID = "deviceId"
    case deviceGeneration
  }
}

func isOpaqueID(_ value: String) -> Bool {
  guard let first = value.utf8.first, value.count <= 128, first.isASCIIAlphaNumeric else {
    return false
  }
  return value.utf8.allSatisfy { byte in
    byte.isASCIIAlphaNumeric || byte == 46 || byte == 58 || byte == 95 || byte == 45
  }
}

extension UInt8 {
  fileprivate var isASCIIAlphaNumeric: Bool {
    (48...57).contains(self) || (65...90).contains(self) || (97...122).contains(self)
  }
}
