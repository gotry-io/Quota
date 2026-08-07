import Foundation

// ProviderID lives in ProviderID.generated.swift (from packages/provider/src/catalog.ts via
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

  init(
    fingerprint: String,
    label: String?,
    plan: String?,
    fingerprintScope: FingerprintScope
  ) {
    self.fingerprint = fingerprint
    self.label = label
    self.plan = plan
    self.fingerprintScope = fingerprintScope
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

struct QuotaSnapshotEnvelope: Codable, Equatable, Sendable {
  let schemaVersion: Int
  let deviceID: String
  let sequence: Int
  let capturedAt: Date
  let snapshots: [QuotaSnapshot]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion
    case deviceID = "deviceId"
    case sequence
    case capturedAt
    case snapshots
  }
}

extension QuotaSnapshotEnvelope {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    deviceID = try container.decode(String.self, forKey: .deviceID)
    sequence = try container.decode(Int.self, forKey: .sequence)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    snapshots = try container.decode([QuotaSnapshot].self, forKey: .snapshots)
    guard schemaVersion == 1, !deviceID.isEmpty, sequence >= 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Invalid quota snapshot envelope."
      )
    }
  }
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
