import Foundation
import QuotaPresentation
import QuotaWire

/// One line of today's Usage, with the spoken form of the same numbers.
struct UsageTodaySummary: Equatable, Sendable {
  let text: String
  let accessibilityLabel: String
}

enum UsageValueFormatter {
  static func count(_ value: Int) -> String {
    CompactCountFormat.compact(value)
  }

  static func accessibleCount(_ value: Int) -> String {
    CompactCountFormat.accessible(value)
  }

  static func compactCost(_ outcome: UsageCostOutcome) -> String {
    UsageCostFormat.compact(
      status: UsageCostCoverage(outcome.status),
      amountMicrousd: outcome.amountMicrousd
    )
  }

  /// Overview's footer line: `Today · $12.34 · 1.2M tokens`.
  ///
  /// Cost leads because it is the number a person is spending, but it is only reported when
  /// it is known; an unpriced day still shows its tokens. A day with no tokens has nothing
  /// to report, so the line does not appear at all.
  static func todaySummary(tokens: Int, cost: UsageCostOutcome) -> UsageTodaySummary? {
    guard tokens > 0 else { return nil }
    let priced = cost.status != .unavailable && cost.amountMicrousd != nil
    var parts = ["Today"]
    var spoken = ["Today"]
    if priced {
      parts.append(compactCost(cost))
      spoken.append(
        UsageCostFormat.accessible(
          status: UsageCostCoverage(cost.status),
          amountMicrousd: cost.amountMicrousd
        )
      )
    }
    parts.append("\(count(tokens)) tokens")
    spoken.append("\(accessibleCount(tokens)) tokens")
    return UsageTodaySummary(
      text: parts.joined(separator: " · "),
      accessibilityLabel: spoken.joined(separator: ", ")
    )
  }

  static func tokensAndCost(_ tokens: Int, _ cost: UsageCostOutcome) -> String {
    let tokens = count(tokens)
    guard cost.status != .unavailable, cost.amountMicrousd != nil else { return tokens }
    return "\(tokens) · \(compactCost(cost))"
  }

  static func precedes(
    cost leftCost: UsageCostOutcome,
    tokens leftTokens: Int,
    name leftName: String,
    before rightCost: UsageCostOutcome,
    tokens rightTokens: Int,
    name rightName: String
  ) -> Bool {
    let left = normalizedMicrousd(leftCost.amountMicrousd)
    let right = normalizedMicrousd(rightCost.amountMicrousd)
    if (left != nil) != (right != nil) { return left != nil }
    if let left, let right, left != right {
      return left.count == right.count ? left > right : left.count > right.count
    }
    if leftTokens != rightTokens { return leftTokens > rightTokens }
    return leftName.localizedStandardCompare(rightName) == .orderedAscending
  }

  static func agent(_ agent: BillingAgent) -> String {
    switch agent {
    case .codex: "Codex"
    case .claudeCode: "Claude Code"
    case .grok: "Grok"
    case .opencode: "OpenCode"
    case .pi: "Pi"
    case .cursor: "Cursor"
    // An agent this build has never heard of is named as what it is.
    case .unknown: "Unknown"
    }
  }

  private static func normalizedMicrousd(_ value: String?) -> String? {
    guard let value else { return nil }
    let normalized = value.drop(while: { $0 == "0" })
    return normalized.isEmpty ? "0" : String(normalized)
  }
}

extension UsageCostCoverage {
  fileprivate init(_ status: UsageCostStatus) {
    switch status {
    case .complete: self = .complete
    case .partial: self = .partial
    case .unavailable: self = .unavailable
    }
  }
}
