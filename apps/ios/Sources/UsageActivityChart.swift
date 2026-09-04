import Foundation
import QuotaPresentation
import QuotaWire

/// UTC calendar dates and the 365-day window the Activity chart asks for.
enum UsageActivityCalendar {
  static let dayCount = 365
  static let weekdayLabels = ["", "Mon", "", "Wed", "", "Fri", ""]
  static let monthAbbreviations = [
    "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
  ]

  fileprivate static let monthLabelMinWeeks = 2

  static var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  static func utcDay(from date: Date) -> String {
    let parts = utc.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
  }

  static func date(from utcDay: String) -> Date {
    let parts = utcDay.split(separator: "-")
    var components = DateComponents()
    components.year = Int(parts[0])
    components.month = Int(parts[1])
    components.day = Int(parts[2])
    return utc.date(from: components)!
  }

  static func addDays(_ delta: Int, to utcDay: String) -> String {
    let shifted = utc.date(byAdding: .day, value: delta, to: date(from: utcDay))!
    return self.utcDay(from: shifted)
  }

  /// Inclusive range of `dayCount` UTC days ending on `today`.
  static func range(endingOn today: String) -> (from: String, to: String) {
    (from: addDays(-(dayCount - 1), to: today), to: today)
  }

  /// Sunday-first padding around an inclusive UTC range, matching the website chart.
  static func sundayAlignedDates(from: String, to: String) -> [String] {
    let first = date(from: from)
    let last = date(from: to)
    let leading = utc.component(.weekday, from: first) - 1
    let trailing = 7 - utc.component(.weekday, from: last)
    let alignedFirst = utc.date(byAdding: .day, value: -leading, to: first)!
    let alignedLast = utc.date(byAdding: .day, value: trailing, to: last)!
    var dates: [String] = []
    var cursor = alignedFirst
    while cursor <= alignedLast {
      dates.append(utcDay(from: cursor))
      cursor = utc.date(byAdding: .day, value: 1, to: cursor)!
    }
    return dates
  }

  static func monthAbbreviation(for utcDay: String) -> String {
    let month = utc.component(.month, from: date(from: utcDay))
    return monthAbbreviations[month - 1]
  }

  /// `en-US` UTC long date, the same words the website tooltip uses.
  static func longDate(_ utcDay: String) -> String {
    let formatter = DateFormatter()
    formatter.calendar = utc
    formatter.locale = Locale(identifier: "en_US")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateStyle = .long
    formatter.timeStyle = .none
    return formatter.string(from: date(from: utcDay))
  }
}

/// Heatmap layout: Sunday-first columns, five fill levels, month labels on week columns.
struct UsageActivityChart: Equatable, Sendable {
  struct Day: Equatable, Identifiable, Sendable {
    var id: String { date }
    var date: String
    var outside: Bool
    var today: Bool
    var level: Int
    var tokens: Int
    var cost: UsageCostOutcome?
    var partial: Bool

    /// VoiceOver value for the selected day: date, tokens, cost.
    var accessibilityValue: String {
      let tokens = CompactCountFormat.accessible(tokens)
      let costText: String
      if let cost {
        costText = UsageCostFormat.accessible(
          status: UsageCostCoverage(cost.status),
          amountMicrousd: cost.amountMicrousd
        )
      } else {
        costText = UsageCostFormat.accessible(status: .unavailable, amountMicrousd: nil)
      }
      return "\(UsageActivityCalendar.longDate(date)), \(tokens) tokens, \(costText)"
    }
  }

  struct MonthLabel: Equatable, Identifiable, Sendable {
    var id: Int { weekIndex }
    var weekIndex: Int
    var label: String
    var span: Int
  }

  var days: [Day]
  var weeks: [[Day]]
  var monthLabels: [MonthLabel]

  var selectableDays: [Day] { days.filter { !$0.outside } }

  /// Today when it is in range, otherwise the last in-range day.
  var defaultSelectedDate: String {
    days.first { $0.today && !$0.outside }?.date ?? selectableDays.last?.date ?? ""
  }

  /// Any reported day with tokens. An empty or all-zero range must not draw 365 empty cells.
  static func hasReportedActivity(_ days: [UsageActivityDay]) -> Bool {
    days.contains { $0.totals.totalTokens > 0 }
  }

  func selectableDay(on date: String) -> Day? {
    selectableDays.first { $0.date == date }
  }

  /// Next or previous in-range day. Stays put at the range ends. Unknown dates resolve to the
  /// last in-range day so VoiceOver has somewhere to land.
  func adjacentSelectableDay(from date: String, increment: Bool) -> Day? {
    let selectable = selectableDays
    guard let index = selectable.firstIndex(where: { $0.date == date }) else {
      return selectable.last
    }
    if increment {
      return index + 1 < selectable.count ? selectable[index + 1] : selectable[index]
    }
    return index > 0 ? selectable[index - 1] : selectable[index]
  }

  /// Nearest in-range day to a point in the week-grid coordinate space (origin at the first
  /// Sunday cell, columns are weeks, rows are weekdays). Outside padding cells are skipped.
  func nearestSelectableDay(
    atX x: Double,
    atY y: Double,
    cellSize: Double,
    cellGap: Double
  ) -> Day? {
    let stride = cellSize + cellGap
    var best: Day?
    var bestDistance = Double.greatestFiniteMagnitude
    for (weekIndex, week) in weeks.enumerated() {
      for (dayIndex, day) in week.enumerated() {
        guard !day.outside else { continue }
        let dx = x - (Double(weekIndex) * stride + cellSize / 2)
        let dy = y - (Double(dayIndex) * stride + cellSize / 2)
        let distance = dx * dx + dy * dy
        if distance < bestDistance {
          bestDistance = distance
          best = day
        }
      }
    }
    return best
  }

  static func build(
    reported: [UsageActivityDay],
    range: (from: String, to: String),
    today: String
  ) -> UsageActivityChart {
    let byDate = Dictionary(uniqueKeysWithValues: reported.map { ($0.date, $0) })
    let maxTokens = reported.map(\.totals.totalTokens).max() ?? 0
    let days: [Day] = UsageActivityCalendar.sundayAlignedDates(from: range.from, to: range.to)
      .map { date in
        let value = byDate[date]
        let outside = date < range.from || date > range.to
        let tokens = value?.totals.totalTokens ?? 0
        return Day(
          date: date,
          outside: outside,
          today: !outside && date == today,
          level: activityLevel(tokens, maximum: maxTokens),
          tokens: tokens,
          cost: value?.cost,
          partial: value?.partial ?? false
        )
      }
    let weeks = chunkWeeks(days)
    return UsageActivityChart(
      days: days,
      weeks: weeks,
      monthLabels: monthLabels(for: weeks)
    )
  }

  /// Zero tokens, or a zero scale, is empty. Otherwise four equal bands of the busiest day.
  static func activityLevel(_ value: Int, maximum: Int) -> Int {
    guard value > 0, maximum > 0 else { return 0 }
    return min(4, Int(ceil(Double(value) / Double(maximum) * 4)))
  }

  static func emptyTotals() -> UsageSummaryTotals {
    UsageSummaryTotals(
      totalTokens: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadInputTokens: 0,
      cacheWriteInputTokens: 0,
      reasoningTokens: 0,
      messages: 0
    )
  }

  static func emptyCost() -> UsageCostOutcome {
    UsageCostOutcome(
      mode: .calculate,
      basis: .none,
      status: .complete,
      amountMicrousd: nil,
      catalogRevision: nil,
      calculatedRows: 0,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [],
      unpriced: []
    )
  }

  static func emptyDay(date: String) -> UsageActivityDay {
    UsageActivityDay(
      date: date,
      totals: emptyTotals(),
      cost: emptyCost(),
      partial: false,
      agents: nil
    )
  }

  private static func chunkWeeks(_ days: [Day]) -> [[Day]] {
    stride(from: 0, to: days.count, by: 7).map { index in
      Array(days[index..<min(index + 7, days.count)])
    }
  }

  private static func monthLabels(for weeks: [[Day]]) -> [MonthLabel] {
    var starts: [(weekIndex: Int, label: String)] = []
    var seen: Set<String> = []
    for (weekIndex, week) in weeks.enumerated() {
      for day in week where !day.outside {
        let month = String(day.date.prefix(7))
        guard !seen.contains(month) else { continue }
        seen.insert(month)
        starts.append((weekIndex, UsageActivityCalendar.monthAbbreviation(for: day.date)))
      }
    }
    var placed: [(weekIndex: Int, label: String)] = []
    for start in starts {
      if let previous = placed.last,
        start.weekIndex - previous.weekIndex < UsageActivityCalendar.monthLabelMinWeeks
      {
        continue
      }
      placed.append(start)
    }
    return placed.enumerated().map { index, item in
      let next = index + 1 < placed.count ? placed[index + 1].weekIndex : weeks.count
      return MonthLabel(weekIndex: item.weekIndex, label: item.label, span: next - item.weekIndex)
    }
  }
}
