import Foundation
import QuotaPresentation
import QuotaWire

enum QuotaFormat {
  static func remaining(_ window: QuotaWindow) -> String {
    RemainingQuotaFormat.remaining(
      remainingPercent: window.remainingPercent,
      remainingValue: window.remainingValue,
      hasLimit: window.limitValue != nil,
      unit: window.valueUnit?.remainingUnit
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

  static func fetchedTime(_ date: Date) -> String {
    date.formatted(date: .omitted, time: .shortened)
  }

  static func refreshedAge(_ date: Date, now: Date = Date()) -> String {
    CompactAgeFormat.string(since: date, now: now)
  }

  static func resetTime(_ date: Date) -> String {
    date.formatted(date: .abbreviated, time: .shortened)
  }

  static func planBadge(_ raw: String?) -> String? {
    PlanDisplay.planBadge(raw)
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

