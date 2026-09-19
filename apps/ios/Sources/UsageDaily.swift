import Foundation
import QuotaPresentation
import QuotaWire

/// What the daily bars measure.
enum UsageDailyMetric: Equatable, Sendable {
  case tokens
  case cost
}

/// How one UTC day is drawn: a quantitative bar, a baseline tick, or an unpriced mark.
enum UsageDailyBarKind: Equatable, Sendable {
  /// Height is `amount` against the chart maximum.
  case amount(Int)
  /// The day exists and has no height.
  case empty
  /// Cost mode, and the catalog could not price this day.
  case unpriced
}

/// The UTC days a period's table shows, oldest first, including the ones that reported nothing.
///
/// The activity read answers UTC dates — 400 local days would cut 400 UTC days, which is the
/// history the rollup exists to keep closed (ADR 0024) — so this table is UTC too, and says so.
/// `all` has no first day, so it has no table: two years of rows is what the Activity chart
/// beside it already answers.
enum UsageDailyFold {
  struct Row: Identifiable, Equatable, Sendable {
    let date: String
    let totals: UsageSummaryTotals
    let cost: UsageCostOutcome

    var id: String { date }

    /// The three shares that add up to `totals.totalTokens`, in the order they stack.
    var freshInputTokens: Int { totals.inputTokens - totals.cacheReadInputTokens }
    var cachedInputTokens: Int { totals.cacheReadInputTokens }
    var outputTokens: Int { totals.outputTokens }
  }

  static func rows(reported: [UsageActivityDay], from: String, to: String) -> [Row] {
    guard from <= to else { return [] }
    let byDate = Dictionary(reported.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    var rows: [Row] = []
    var date = from
    while date <= to {
      let day = byDate[date]
      rows.append(
        Row(
          date: date,
          totals: day?.totals ?? emptyTotals,
          cost: day?.cost ?? UsageActivityChart.emptyCost()
        )
      )
      date = UsageActivityCalendar.addDays(1, to: date)
    }
    return rows
  }

  static func hasUsage(_ rows: [Row]) -> Bool {
    rows.contains { $0.totals.totalTokens > 0 }
  }

  static func barKind(_ row: Row, metric: UsageDailyMetric) -> UsageDailyBarKind {
    switch metric {
    case .tokens:
      return row.totals.totalTokens > 0 ? .amount(row.totals.totalTokens) : .empty
    case .cost:
      if row.totals.totalTokens == 0 { return .empty }
      if row.cost.status == .unavailable { return .unpriced }
      let amount = Int(row.cost.amountMicrousd ?? "0") ?? 0
      return amount > 0 ? .amount(amount) : .empty
    }
  }

  static func quantitativeMaximum(_ rows: [Row], metric: UsageDailyMetric) -> Int {
    rows.reduce(0) { maximum, row in
      if case .amount(let value) = barKind(row, metric: metric) {
        return max(maximum, value)
      }
      return maximum
    }
  }

  /// The plotted height: tokens as a count, cost as dollars. Gaps and unpriced days are 0.
  static func plotValue(_ row: Row, metric: UsageDailyMetric) -> Double {
    switch barKind(row, metric: metric) {
    case .amount(let amount):
      return metric == .cost ? Double(amount) / 1_000_000 : Double(amount)
    case .empty, .unpriced:
      return 0
    }
  }

  static func chartAccessibilityValue(_ rows: [Row], metric: UsageDailyMetric) -> String {
    switch metric {
    case .tokens:
      let total = rows.reduce(0) { $0 + $1.totals.totalTokens }
      return "\(rows.count) days, \(CompactCountFormat.accessible(total)) tokens in total"
    case .cost:
      let unpriced = rows.filter { barKind($0, metric: .cost) == .unpriced }.count
      var microusd = 0 as Decimal
      var priced = false
      for row in rows {
        guard case .amount = barKind(row, metric: .cost),
          let text = row.cost.amountMicrousd,
          let amount = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
        else { continue }
        microusd += amount
        priced = true
      }
      if !priced {
        return unpriced > 0
          ? "\(rows.count) days, \(unpriced) unpriced"
          : "\(rows.count) days, no cost"
      }
      let costText = UsageCostFormat.accessible(
        status: .complete,
        amountMicrousd: NSDecimalNumber(decimal: microusd).stringValue
      )
      if unpriced == 0 {
        return "\(rows.count) days, \(costText) in total"
      }
      return "\(rows.count) days, \(costText) in total, \(unpriced) unpriced"
    }
  }

  private static let emptyTotals = UsageSummaryTotals(
    totalTokens: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheWriteInputTokens: 0,
    reasoningTokens: 0,
    messages: 0
  )
}

/// Y-axis values (2–3, including zero) and the date labels the daily chart marks.
enum UsageDailyAxis {
  /// Where a date tick's label sits relative to its tick, so the first and last stay in full.
  enum DateTickAnchor: Equatable, Sendable {
    case leading
    case center
    case trailing
  }

  /// Inclusive nice ticks from 0 to a ceiling of `maximum`. An empty plot still gets a
  /// non-zero ceiling so the axis is readable.
  static func valueTicks(maximum: Double) -> [Double] {
    let top = niceCeiling(maximum)
    let half = top / 2
    if half == 0 || half == top { return [0, top] }
    return [0, half, top]
  }

  /// Dates to label. One to three days stay themselves; a week keeps the ends and the middle;
  /// a longer range keeps four evenly spaced dates, including both ends.
  static func dateTicks(dates: [String]) -> [String] {
    guard !dates.isEmpty else { return [] }
    if dates.count <= 3 { return dates }
    if dates.count <= 7 {
      return uniqued([dates[0], dates[dates.count / 2], dates[dates.count - 1]])
    }
    let last = dates.count - 1
    return uniqued([
      dates[0],
      dates[last / 3],
      dates[(2 * last) / 3],
      dates[last],
    ])
  }

  static func dateTickAnchor(index: Int, count: Int) -> DateTickAnchor {
    if count <= 1 { return .center }
    if index == 0 { return .leading }
    if index == count - 1 { return .trailing }
    return .center
  }

  /// `Sep 20` — the full month-and-day, never a clipped first letter.
  static func dateLabel(_ date: String, calendar: Calendar = .current) -> String {
    guard let value = UsageDateText.date(from: date, calendar) else { return date }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate("MMMd")
    return formatter.string(from: value)
  }

  /// Smallest of `{1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10} × 10^n` that is ≥ `value`.
  static func niceCeiling(_ value: Double) -> Double {
    let steps: [Double] = [1, 1.2, 1.5, 2, 2.5, 3, 4, 5, 6, 8, 10]
    guard value > 0 else { return 1 }
    let exponent = floor(log10(value))
    let magnitude = pow(10, exponent)
    let fraction = value / magnitude
    let step = steps.first { fraction <= $0 } ?? 10
    let raw = step * magnitude
    return raw >= 1 ? raw.rounded() : raw
  }

  private static func uniqued(_ dates: [String]) -> [String] {
    var seen: Set<String> = []
    return dates.filter { seen.insert($0).inserted }
  }
}
