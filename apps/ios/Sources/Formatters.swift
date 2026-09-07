import Foundation
import QuotaPresentation
import QuotaWire

enum QuotaFormat {
  static func remaining(_ window: QuotaWindow) -> String {
    RemainingQuotaFormat.remaining(
      remainingPercent: window.remainingPercent,
      remainingValue: window.remainingValue,
      limitValue: window.limitValue,
      hasLimit: window.limitValue != nil,
      unit: window.remainingUnit
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

  /// The saving beside a cache hit rate, or `nil` when nothing behind it could be priced.
  static func cacheSaved(_ saved: UsageCacheSaved) -> String? {
    guard saved.amountMicrousd != nil else { return nil }
    return "saved \(UsageCostFormat.compact(status: UsageCostCoverage(saved.status), amountMicrousd: saved.amountMicrousd))"
  }

  /// One part of a whole as whole percent. A whole of nothing has no share to state.
  static func share(_ part: Int, of whole: Int) -> String? {
    guard whole > 0 else { return nil }
    return "\((part * 200 + whole) / (whole * 2))%"
  }

  /// How many of this period's rows the catalog priced, matching the website coverage line.
  static func costPriced(_ outcome: UsageCostOutcome) -> String {
    let priced = outcome.calculatedRows + outcome.reportedRows
    let total = priced + outcome.unpricedRows
    return "Priced \(priced) of \(total) rows"
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
    FreshnessCopy.resetCopy(
      resetsAt: date,
      now: now,
      timeZone: timeZone,
      calendar: calendar,
      style: .relative
    )
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

