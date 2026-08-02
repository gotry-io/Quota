import Foundation

enum ProviderID: String, Codable, CaseIterable, Identifiable, Sendable {
  case codex
  case claude
  case grok

  var id: String { rawValue }

  var displayName: String {
    switch self {
    case .codex: "Codex"
    case .claude: "Claude Code"
    case .grok: "Grok"
    }
  }
}

enum QuotaStatus: String, Codable, Sendable {
  case available
  case stale
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

struct QuotaAccount: Codable, Equatable, Sendable {
  let fingerprint: String
  let label: String?
  let plan: String?
}

struct QuotaWindow: Codable, Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let usedPercent: Double
  let resetsAt: Date?
  let durationSeconds: Int?
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

enum QuotaWireCodec {
  static func makeDecoder() -> JSONDecoder {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return decoder
  }

  static func makeEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.keyEncodingStrategy = .convertToSnakeCase
    encoder.dateEncodingStrategy = .iso8601
    return encoder
  }
}
