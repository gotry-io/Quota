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
  let schemaVersion: Int
  let capturedAt: Date
  let results: [QuotaCollectionResult]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion = "protocolVersion"
    case capturedAt
    case results
  }
}

extension QuotaCollectionReport {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    results = try container.decode([QuotaCollectionResult].self, forKey: .results)
    guard schemaVersion == 2, results.count <= ProviderID.allCases.count else {
      throw DecodingError.dataCorruptedError(
        forKey: .schemaVersion,
        in: container,
        debugDescription: "Unsupported quota report schema version."
      )
    }
  }
}

extension QuotaWindow {
  var remainingPercent: Double {
    min(max(100 - usedPercent, 0), 100)
  }

  /// Wallet-style window: absolute remaining only, no budget/limit ratio.
  var isBalanceOnly: Bool {
    remainingValue != nil && limitValue == nil
  }

  /// Rate-limit / budget meters need a percent bar. Balance-only wallets do not.
  var showsPercentMeter: Bool {
    !isBalanceOnly
  }

  /// e.g. "$4.61 left" when value_unit/remaining_value are present.
  /// Balance-only rows without a unit (e.g. DeepSeek CNY) still show the absolute remaining.
  var absoluteRemainingLabel: String? {
    guard let remainingValue else { return nil }
    if let valueUnit {
      switch valueUnit {
      case .usd:
        return String(format: "$%.2f left", remainingValue)
      case .credits:
        return String(format: "%.2f credits left", remainingValue)
      case .count:
        return String(format: "%.0f left", remainingValue)
      }
    }
    if isBalanceOnly {
      return String(format: "%.2f left", remainingValue)
    }
    return nil
  }
}
