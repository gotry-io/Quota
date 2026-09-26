import Foundation
import QuotaPresentation
import QuotaWire

/// What the Usage page's metric tabs, and so the river under them, measure. The series carries
/// tokens and cost per model and day; messages it does not, so they are not a metric here.
enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
  case tokens
  case cost

  var id: Self { self }
}

/// The period's `model_series` read as the model river (docs/design.md, Model river): one stack
/// per asked local date, largest model at the bottom, the legend's models plus `other`.
///
/// Every asked date keeps its slot. A date the series does not name reported nothing, so its
/// stack meets the baseline and it is drawn as a tick, never dropped from the axis. A model with
/// no cell on a date is zero there. In Cost, a cell Relay could not price is left out of the
/// stack rather than drawn as $0, and a day with nothing priced is its own mark.
enum UsageModelRiver {
  struct Series: Identifiable, Equatable, Sendable {
    /// The legend's model name; `other` is the folded rest.
    let id: String
    let swatch: ModelSwatch

    var name: String { ModelDisplay.name(id) }
  }

  enum DayKind: Equatable, Sendable {
    /// Height is the day's stacked total.
    case amount(Double)
    /// The day reported nothing: a baseline tick.
    case empty
    /// Cost, and nothing reported that day could be priced.
    case unpriced
  }

  struct Day: Identifiable, Equatable, Sendable {
    let date: String
    let kind: DayKind
    /// The local date the reader is in: still being written, drawn as in progress.
    let isToday: Bool
    /// Cells left out of a Cost stack because Relay could not price them.
    let unpricedCells: Int

    var id: String { date }
  }

  struct Point: Identifiable, Equatable, Sendable {
    let date: String
    let seriesID: String
    let value: Double

    var id: String { "\(date)|\(seriesID)" }
  }

  struct River: Equatable, Sendable {
    /// Legend order: largest first, which is the bottom of the stack.
    let series: [Series]
    let days: [Day]
    /// Every series on every day, dates ascending and legend order inside a date.
    let points: [Point]

    var maximum: Double {
      days.reduce(0) { top, day in
        if case .amount(let value) = day.kind { return max(top, value) }
        return top
      }
    }

    var hasUsage: Bool { days.contains { $0.kind != .empty } }
  }

  static func make(
    series: UsageModelSeries,
    from: String,
    to: String,
    today: String,
    metric: UsageMetric,
    colors: ModelColorAssignment
  ) -> River {
    let legend = series.models.map { entry in
      Series(id: entry.model, swatch: colors.swatch(family: entry.modelFamily, model: entry.model))
    }
    let byDate = Dictionary(series.days.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    var days: [Day] = []
    var points: [Point] = []
    var date = from
    while from <= to, date <= to {
      let cells = Dictionary(
        (byDate[date]?.models ?? []).map { ($0.model, $0) }, uniquingKeysWith: { first, _ in first })
      var total = 0.0
      var unpriced = 0
      for entry in legend {
        var value = 0.0
        if let cell = cells[entry.id] {
          switch metric {
          case .tokens:
            value = Double(cell.totalTokens)
          case .cost:
            if let micro = cell.costMicrousd.flatMap(Double.init) {
              value = micro / 1_000_000
            } else {
              unpriced += 1
            }
          }
        }
        total += value
        points.append(Point(date: date, seriesID: entry.id, value: value))
      }
      let kind: DayKind =
        if total > 0 { .amount(total) } else if unpriced > 0 { .unpriced } else { .empty }
      days.append(Day(date: date, kind: kind, isToday: date == today, unpricedCells: unpriced))
      date = UsageActivityCalendar.addDays(1, to: date)
    }
    return River(series: legend, days: days, points: points)
  }
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
