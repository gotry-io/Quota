import Foundation

enum CollectionOutcome: String, Codable, Sendable {
  case success
  case authRequired = "auth_required"
  case unavailable
  case unsupported
  case error
}

struct QuotaCollectionResult: Codable, Equatable, Sendable {
  let provider: ProviderID
  let outcome: CollectionOutcome
  let snapshots: [QuotaSnapshot]
  let source: String?
  let message: String?
}

extension QuotaCollectionResult {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["provider", "outcome", "snapshots", "source", "message"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    provider = try container.decode(ProviderID.self, forKey: .provider)
    outcome = try container.decode(CollectionOutcome.self, forKey: .outcome)
    snapshots = try container.decode([QuotaSnapshot].self, forKey: .snapshots)
    source = try container.decodeIfPresent(String.self, forKey: .source)
    message = try container.decodeIfPresent(String.self, forKey: .message)
    let isSuccess = outcome == .success
    guard isSuccess == !snapshots.isEmpty,
      snapshots.count <= 32,
      snapshots.allSatisfy({ $0.provider == provider })
    else {
      throw DecodingError.dataCorruptedError(
        forKey: .snapshots,
        in: container,
        debugDescription: "Invalid quota collection result."
      )
    }
  }

  private enum CodingKeys: String, CodingKey {
    case provider
    case outcome
    case snapshots
    case source
    case message
  }
}

struct QuotaCollectionReport: Codable, Equatable, Sendable {
  let protocolVersion: Int
  let capturedAt: Date
  let results: [QuotaCollectionResult]

  private enum CodingKeys: String, CodingKey {
    case protocolVersion
    case capturedAt
    case results
  }
}

extension QuotaCollectionReport {
  init(from decoder: Decoder) throws {
    try decoder.rejectUnknownWireKeys(["protocolVersion", "capturedAt", "results"])
    let container = try decoder.container(keyedBy: CodingKeys.self)
    protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    results = try container.decode([QuotaCollectionResult].self, forKey: .results)
    guard protocolVersion == 2, results.count <= ProviderID.allCases.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .protocolVersion,
        in: container,
        debugDescription: "Unsupported quota report schema version."
      )
    }
  }
}
