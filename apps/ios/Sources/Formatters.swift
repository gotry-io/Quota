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

  /// How old the account summary on screen is, in the words every Quota client uses.
  static func updated(_ date: Date, now: Date = Date()) -> String {
    FreshnessCopy.updated(since: date, now: now)
  }

  /// The shared observation line: Updated age, or why the reading is not current.
  static func observation(_ snapshot: QuotaSnapshot, now: Date = Date()) -> String {
    FreshnessCopy.observation(
      state: snapshot.observedState(now: now),
      observedAt: snapshot.observedAt,
      now: now
    )
  }

  static func resetTime(
    _ date: Date,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String? {
    FreshnessCopy.resetCopy(resetsAt: date, now: now, timeZone: timeZone, calendar: calendar)
  }

  /// Live countdown under a day; shared reset copy at a day or more; `nil` once the instant has passed.
  static func countdown(
    resetsAt: Date?,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> QuotaResetCountdown? {
    guard let resetsAt else { return nil }
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return nil }
    if seconds < 86_400 {
      return .live(end: resetsAt)
    }
    return resetTime(resetsAt, now: now, timeZone: timeZone, calendar: calendar).map { .copy($0) }
  }

  static func planBadge(_ raw: String?) -> String? {
    PlanDisplay.planBadge(raw)
  }
}

enum QuotaResetCountdown: Equatable, Sendable {
  case live(end: Date)
  case copy(String)
}

