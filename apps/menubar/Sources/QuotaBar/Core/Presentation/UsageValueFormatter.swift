import Foundation
import QuotaPresentation

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
