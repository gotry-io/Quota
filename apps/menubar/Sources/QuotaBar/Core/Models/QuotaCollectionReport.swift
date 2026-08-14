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

  /// Absolute remaining when `value_unit`/`remaining_value` are present.
  /// Balance-only rows without a unit (e.g. DeepSeek CNY) still show the number.
  var absoluteRemainingLabel: String? {
    guard let remainingValue else { return nil }
    if let valueUnit {
      switch valueUnit {
      case .usd:
        return String(format: "$%.2f", remainingValue)
      case .credits:
        return String(format: "%.2f credits", remainingValue)
      case .count:
        return String(format: "%.0f", remainingValue)
      }
    }
    if isBalanceOnly {
      return String(format: "%.2f", remainingValue)
    }
    return nil
  }

  /// Overview remaining copy. No "left" suffix; the value is remaining by product rule.
  /// Budget windows with an amount show `71% · $3.75`.
  var remainingDisplayLabel: String {
    let percent = formattedRemainingPercent
    guard let absolute = absoluteRemainingLabel else { return percent }
    if isBalanceOnly || !showsPercentMeter {
      return absolute
    }
    return "\(percent) · \(absolute)"
  }

  /// Compact Overview copy. Cursor's Other Models percentage and included-usage dollars are
  /// different provider meters, so retain the dollars for a future detail surface without
  /// presenting them as one value here.
  func overviewRemainingDisplayLabel(provider: ProviderID) -> String {
    if provider == .cursor, id == "other_models" {
      return formattedRemainingPercent
    }
    return remainingDisplayLabel
  }

  var formattedRemainingPercent: String {
    Self.formattedPercent(remainingPercent)
  }

  static func formattedPercent(_ value: Double) -> String {
    if abs(value.rounded() - value) < 0.05 {
      return "\(Int(value.rounded()))%"
    }
    return String(format: "%.1f%%", value)
  }
}
