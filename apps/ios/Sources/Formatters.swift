import Foundation
import QuotaPresentation
import QuotaWire

enum QuotaFormat {
  static func remaining(_ window: QuotaWindow) -> String {
    RemainingQuotaFormat.remaining(
      remainingPercent: window.remainingPercent,
      remainingValue: window.remainingValue,
      hasLimit: window.limitValue != nil,
      unit: window.valueUnit.flatMap(\.remainingUnit)
    )
  }

  static func remainingAccessibility(_ window: QuotaWindow) -> String {
    RemainingQuotaFormat.remainingAccessibility(
      windowTitle: windowTitle(window),
      remainingLabel: remaining(window),
      isBalanceOnly: window.isBalanceOnly
    )
  }

  static func windowTitle(_ window: QuotaWindow) -> String {
    RemainingQuotaFormat.windowTitle(window.title, isBalanceOnly: window.isBalanceOnly)
  }

  static func compactCount(_ value: Int) -> String {
    CompactCountFormat.compact(value)
  }

  static func accessibleCount(_ value: Int) -> String {
    CompactCountFormat.accessible(value)
  }

  static func cost(_ outcome: UsageCostOutcome) -> String {
    UsageCostFormat.compact(
      status: UsageCostCoverage(outcome.status),
      amountMicrousd: outcome.amountMicrousd
    )
  }

  static func costAccessibility(_ outcome: UsageCostOutcome) -> String {
    UsageCostFormat.accessible(
      status: UsageCostCoverage(outcome.status),
      amountMicrousd: outcome.amountMicrousd
    )
  }

  /// How the cost was arrived at, matching the website's basis line.
  static func costBasis(_ outcome: UsageCostOutcome) -> String {
    if outcome.status == .unavailable { return "Unpriced" }
    let basis: String
    switch outcome.basis {
    case .calculated: basis = "estimated"
    case .reported: basis = "reported"
    case .mixed: basis = "mixed"
    case .none: basis = "none"
    }
    switch outcome.status {
    case .complete: return "\(basis) · complete"
    case .partial: return "\(basis) · priced subset only"
    case .unavailable: return "Unpriced"
    }
  }

  static func utcLongDate(_ value: String) -> String {
    UsageActivityCalendar.longDate(value)
  }

  /// How old the account summary on screen is, in the words every Quota client uses.
  static func updated(_ date: Date, now: Date = Date()) -> String {
    FreshnessCopy.updated(since: date, now: now)
  }

  static func resetTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  static func planBadge(_ raw: String?) -> String? {
    PlanDisplay.planBadge(raw)
  }
}

