import Foundation

private let quotaJSONSafeIntegerMaximum = 9_007_199_254_740_991

// ProviderID lives in ProviderID.generated.swift (from packages/provider/catalog.json via
// `pnpm generate:provider-catalog`). Do not redefine provider cases here.

enum QuotaStatus: String, Codable, Sendable {
  case available
  case stale
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

enum FingerprintScope: String, Codable, Sendable {
  case global
  case source
}

struct QuotaAccount: Codable, Equatable, Sendable {
  let fingerprint: String
  let label: String?
  let plan: String?
  let fingerprintScope: FingerprintScope

  private enum CodingKeys: String, CodingKey {
    case fingerprint
    case label
    case plan
    case fingerprintScope
  }

}

extension QuotaAccount {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["fingerprint", "label", "plan", "fingerprintScope"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fingerprint = try container.decode(String.self, forKey: .fingerprint)
    label = try container.decodeIfPresent(String.self, forKey: .label)
    plan = try container.decodeIfPresent(String.self, forKey: .plan)
    fingerprintScope = try container.decode(FingerprintScope.self, forKey: .fingerprintScope)
  }
}

enum QuotaValueUnit: String, Codable, Equatable, Sendable {
  case usd
  case credits
  case count
}

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let usedPercent: Double
  let resetsAt: Date?
  let durationSeconds: Int?
  /// Absolute remaining when known (e.g. USD). Optional; meter still uses usedPercent.
  let remainingValue: Double?
  let limitValue: Double?
  let valueUnit: QuotaValueUnit?

  private enum CodingKeys: String, CodingKey {
    case id
    case title
    case usedPercent
    case resetsAt
    case durationSeconds
    case remainingValue
    case limitValue
    case valueUnit
  }

  init(
    id: String,
    title: String,
    usedPercent: Double,
    resetsAt: Date? = nil,
    durationSeconds: Int? = nil,
    remainingValue: Double? = nil,
    limitValue: Double? = nil,
    valueUnit: QuotaValueUnit? = nil
  ) {
    self.id = id
    self.title = title
    self.usedPercent = usedPercent
    self.resetsAt = resetsAt
    self.durationSeconds = durationSeconds
    self.remainingValue = remainingValue
    self.limitValue = limitValue
    self.valueUnit = valueUnit
  }

  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "id", "title", "usedPercent", "resetsAt", "durationSeconds", "remainingValue", "limitValue",
      "valueUnit",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    usedPercent = try container.decode(Double.self, forKey: .usedPercent)
    resetsAt = try container.decodeIfPresent(Date.self, forKey: .resetsAt)
    durationSeconds = try container.decodeIfPresent(Int.self, forKey: .durationSeconds)
    remainingValue = try container.decodeIfPresent(Double.self, forKey: .remainingValue)
    limitValue = try container.decodeIfPresent(Double.self, forKey: .limitValue)
    valueUnit = try container.decodeIfPresent(QuotaValueUnit.self, forKey: .valueUnit)
  }
}

struct QuotaSnapshot: Codable, Equatable, Sendable {
  let provider: ProviderID
  let account: QuotaAccount
  let windows: [QuotaWindow]
  let source: String
  let status: QuotaStatus
  let observedAt: Date
  let validUntil: Date?
}

extension QuotaSnapshot {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "provider", "account", "windows", "source", "status", "observedAt", "validUntil",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    account = try container.decode(QuotaAccount.self, forKey: .account)
    windows = try container.decode([QuotaWindow].self, forKey: .windows)
    source = try container.decode(String.self, forKey: .source)
    status = try container.decode(QuotaStatus.self, forKey: .status)
    observedAt = try container.decode(Date.self, forKey: .observedAt)
    validUntil = try container.decodeIfPresent(Date.self, forKey: .validUntil)
    guard isValidWireSnapshot else {
      throw DecodingError.dataCorruptedError(
        forKey: .account,
        in: container,
        debugDescription: "Invalid quota snapshot."
      )
    }
  }

  var isValidWireSnapshot: Bool {
    isQuotaOpaqueID(account.fingerprint)
      && (account.label.map({ isQuotaTrimmedText($0, maximum: 128) }) ?? true)
      && (account.plan.map({ isQuotaTrimmedText($0, maximum: 64) }) ?? true)
      && isQuotaBillingDimension(source, maximum: 64)
      && windows.count <= 16
      && windows.allSatisfy { window in
        isQuotaBillingDimension(window.id, maximum: 64)
          && isQuotaTrimmedText(window.title, maximum: 128)
          && window.usedPercent.isFinite
          && (0...100).contains(window.usedPercent)
          && (window.durationSeconds.map {
            (0...quotaJSONSafeIntegerMaximum).contains($0)
          } ?? true)
          && (window.remainingValue?.isFinite ?? true)
          && (window.limitValue.map { $0.isFinite && $0 >= 0 } ?? true)
      }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case account
    case windows
    case source
    case status
    case observedAt
    case validUntil
  }
}

struct QuotaSnapshotEnvelope: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let deviceID: String
  let generation: Int
  let sequence: Int
  let capturedAt: Date
  let snapshots: [QuotaSnapshot]

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case deviceID = "deviceId"
    case generation
    case sequence
    case capturedAt
    case snapshots
  }
}

extension QuotaSnapshotEnvelope {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys([
      "protocolVersion", "deviceId", "generation", "sequence", "capturedAt", "snapshots",
    ])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    generation = try container.decode(Int.self, forKey: .generation)
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    snapshots = try container.decode([QuotaSnapshot].self, forKey: .snapshots)
    guard protocolVersion == 3,
      isQuotaOpaqueID(deviceID),
      (1...quotaJSONSafeIntegerMaximum).contains(generation),
      (0...quotaJSONSafeIntegerMaximum).contains(sequence),
      snapshots.count <= 32,
      snapshots.allSatisfy({ $0.provider.syncsToAccount(protocolVersion: protocolVersion) })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Invalid quota snapshot envelope."
      )
    }
  }
}

private func isQuotaOpaqueID(_ value: String) -> Bool {
  isQuotaWireIdentifier(value, maximum: 128, includesPlus: false)
}

private func isQuotaBillingDimension(_ value: String, maximum: Int) -> Bool {
  isQuotaWireIdentifier(value, maximum: maximum, includesPlus: true)
}

private func isQuotaWireIdentifier(_ value: String, maximum: Int, includesPlus: Bool) -> Bool {
  guard let first = value.utf8.first, !value.isEmpty, value.count <= maximum,
    isQuotaASCIIAlphaNumeric(first)
  else { return false }
  return value.utf8.allSatisfy { byte in
    isQuotaASCIIAlphaNumeric(byte) || byte == 46 || byte == 58 || byte == 95 || byte == 45
      || (includesPlus && byte == 43)
  }
}

private func isQuotaASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
  (48...57).contains(byte) || (65...90).contains(byte) || (97...122).contains(byte)
}

private func isQuotaTrimmedText(_ value: String, maximum: Int) -> Bool {
  !value.isEmpty && value.count <= maximum
    && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
}

enum QuotaWireCodec {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .custom { decoder in
      let container = try decoder.singleValueContainer()
      let value = try container.decode(String.self)

      let fractionalFormatter = ISO8601DateFormatter()
      fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      if let date = fractionalFormatter.date(from: value) {
        return date
      }

      let formatter = ISO8601DateFormatter()
      formatter.formatOptions = [.withInternetDateTime]
      if let date = formatter.date(from: value) {
        return date
      }

      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Expected an ISO 8601 date-time."
      )
    }
    return decoder
  }

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
