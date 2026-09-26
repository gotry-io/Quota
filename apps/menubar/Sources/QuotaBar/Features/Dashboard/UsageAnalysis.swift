import Foundation
import QuotaPresentation
import QuotaWire

/// What the Usage page measures its chart and ledger in (`docs/design.md` Model river).
enum UsageMetric: String, CaseIterable, Identifiable, Sendable {
  case tokens
  case cost
  case messages

  var id: Self { self }

  var title: String {
    switch self {
    case .tokens: "Tokens"
    case .cost: "API-equivalent cost"
    case .messages: "Messages"
    }
  }

  /// The period's value, as the switch prints it beside the title.
  func periodValue(_ totals: UsageSummaryTotals, cost: UsageCostOutcome) -> String {
    switch self {
    case .tokens: UsageValueFormatter.count(totals.totalTokens)
    case .cost: UsageValueFormatter.compactCost(cost)
    case .messages: UsageValueFormatter.count(totals.messages)
    }
  }
}

/// Whether the river stacks amounts or each day's shares.
enum UsageRiverScale: String, CaseIterable, Identifiable, Sendable {
  case amount
  case share

  var id: Self { self }

  var title: String {
    switch self {
    case .amount: "Amount"
    case .share: "Share"
    }
  }
}

/// The sentence header of an analysis page: one sentence from the reader's own numbers, as runs
/// whose numbers are set in ink and the rest in body colour.
enum UsageSentence {
  struct Run: Equatable {
    let text: String
    let emphasized: Bool
  }

  /// How a sentence names the selected period.
  static func periodPhrase(for selection: UsagePeriodSelection, title: String) -> String {
    switch selection {
    case .day(0): "today"
    case .day(1): "yesterday"
    case .day: "on \(title)"
    case .week(0): "this week"
    case .month(0): "this month"
    case .week, .month, .custom: "in \(title)"
    case .last7Days: "in the last 7 days"
    case .last30Days: "in the last 30 days"
    case .all: "in everything Quota keeps"
    }
  }

  /// **You ran 1.72B tokens through 9 models in the last 30 days. claude-opus-5-5 carried 31% of
  /// it.** The second sentence only when more than one model shares the period.
  static func runs(
    totals: UsageSummaryTotals,
    ledger: [ModelLedgerRow<BillingAgent>],
    periodPhrase: String
  ) -> [Run] {
    guard totals.totalTokens > 0 else {
      return [Run(text: "No usage \(periodPhrase).", emphasized: false)]
    }
    var runs = [
      Run(text: "You ran ", emphasized: false),
      Run(text: "\(UsageValueFormatter.count(totals.totalTokens)) tokens", emphasized: true),
    ]
    if !ledger.isEmpty {
      runs.append(Run(text: " through ", emphasized: false))
      runs.append(
        Run(text: ledger.count == 1 ? "1 model" : "\(ledger.count) models", emphasized: true))
    }
    runs.append(Run(text: " \(periodPhrase).", emphasized: false))
    if ledger.count > 1, let top = ledger.first,
      let share = UsageValueFormatter.share(top.totals.totalTokens, of: totals.totalTokens)
    {
      runs.append(Run(text: " ", emphasized: false))
      runs.append(Run(text: top.key.model, emphasized: true))
      runs.append(Run(text: " carried ", emphasized: false))
      runs.append(Run(text: share, emphasized: true))
      runs.append(Run(text: " of it.", emphasized: false))
    }
    return runs
  }

  /// The meta line under the sentence: cost, cache share, active days, and the change against
  /// the previous period, each only when the period states it.
  static func meta(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome,
    cacheHitBasisPoints: Int?,
    days: [LocalUsageDay]?,
    previous: UsageSummaryTotals?
  ) -> String {
    var parts: [String] = []
    if cost.status != .unavailable {
      parts.append("\(UsageValueFormatter.compactCost(cost)) API-equivalent")
    }
    if let hit = UsageMetrics.cacheHitPercentLabel(basisPoints: cacheHitBasisPoints) {
      parts.append("\(hit) from cache")
    }
    if let days {
      let active = days.filter { $0.totals.totalTokens > 0 }.count
      parts.append(active == 1 ? "1 active day" : "\(active) active days")
    }
    if let previous, previous.totalTokens > 0 {
      let change = Double(totals.totalTokens - previous.totalTokens) / Double(previous.totalTokens)
      let percent = Int((abs(change) * 100).rounded())
      parts.append(
        percent == 0
          ? "same as the previous period"
          : "\(change > 0 ? "↑" : "↓") \(percent)% on the previous period")
    }
    return parts.joined(separator: " · ")
  }
}

/// A ledger cell's change of share, as the design contract prints it.
enum UsageShareChangeCopy {
  static func text(_ change: ModelShareChange?) -> String {
    switch change {
    case .none: "—"
    case .new: "New"
    case .points(0): "—"
    case .points(let points): "\(points > 0 ? "↑" : "↓") \(abs(points)) pts"
    }
  }
}

/// One model of the river's legend, bottom of the stack first.
struct UsageRiverSeries: Equatable, Identifiable {
  let name: String
  let swatch: ModelSwatch?
  var id: String { name }
}

/// One stacked band of one series on one local day.
struct UsageRiverBand: Equatable, Identifiable {
  let series: String
  /// The series name, plus the run of days it belongs to when the river breaks over an empty
  /// day (Share), so Swift Charts draws each run as its own area.
  let segmentKey: String
  let date: Date
  let low: Double
  let high: Double
  var id: String { "\(segmentKey)|\(date.timeIntervalSince1970)" }
}

/// A day the river draws as a baseline tick rather than a stack.
enum UsageRiverTick: Equatable {
  case empty
  case unpriced
}

/// The model river (`docs/design.md` Model river): a stacked area by model per local day, the
/// largest model at the bottom, over every date of the period — a day with no usage keeps its
/// place on the axis.
struct UsageRiver: Equatable {
  let series: [UsageRiverSeries]
  let dates: [Date]
  let bands: [UsageRiverBand]
  /// Totals per day in the metric, for the spoken summary and the selected-day detail.
  let dayTotals: [Date: Double]
  let ticks: [Date: UsageRiverTick]
  /// The reader's current day, drawn as in progress, when the period reaches it.
  let inProgress: Date?
  let metric: UsageMetric
  let scale: UsageRiverScale

  /// Nil when the period is a single day or names no dates (`all`): a river needs a run of days.
  /// Messages are counted per day but not per model, so they draw one stream from `days`.
  static func make(
    range: UsageDateRange,
    series: UsageModelSeries?,
    days: [LocalUsageDay]?,
    metric: UsageMetric,
    scale: UsageRiverScale,
    colors: ModelColorAssignment,
    today: String,
    calendar: Calendar = .current
  ) -> UsageRiver? {
    guard let count = UsageDateText.days(from: range.from, to: range.to, calendar), count > 1,
      let first = UsageDateText.date(from: range.from, calendar)
    else { return nil }
    let dateTexts = (0..<count).compactMap { offset in
      calendar.date(byAdding: .day, value: offset, to: first).map {
        UsageDateText.date($0, calendar)
      }
    }

    var legend: [UsageRiverSeries]
    var values: [String: [String: Double]] = [:]
    var unpricedDates: Set<String> = []
    if metric == .messages {
      guard let days else { return nil }
      legend = [UsageRiverSeries(name: UsageMetric.messages.title, swatch: nil)]
      for day in days {
        values[day.date] = [UsageMetric.messages.title: Double(day.totals.messages)]
      }
    } else {
      guard let series, !series.models.isEmpty else { return nil }
      legend = series.models.map {
        UsageRiverSeries(
          name: $0.model,
          swatch: colors.swatch(family: $0.modelFamily, model: $0.model)
        )
      }
      for day in series.days {
        var cells: [String: Double] = [:]
        var priced = false
        for cell in day.models {
          switch metric {
          case .tokens:
            cells[cell.model] = Double(cell.totalTokens)
          case .cost:
            if let amount = cell.costMicrousd.flatMap(Double.init) {
              cells[cell.model] = amount / 1_000_000
              priced = true
            }
          case .messages:
            break
          }
        }
        if metric == .cost, !priced, day.models.contains(where: { $0.totalTokens > 0 }) {
          unpricedDates.insert(day.date)
        }
        values[day.date] = cells
      }
    }

    var dates: [Date] = []
    var bands: [UsageRiverBand] = []
    var dayTotals: [Date: Double] = [:]
    var ticks: [Date: UsageRiverTick] = [:]
    var segment = 0
    var previousWasEmpty = false
    for text in dateTexts {
      guard let date = UsageDateText.date(from: text, calendar) else { continue }
      dates.append(date)
      let cells = values[text] ?? [:]
      let total = cells.values.reduce(0, +)
      dayTotals[date] = total
      if total <= 0 {
        ticks[date] = unpricedDates.contains(text) ? .unpriced : .empty
        previousWasEmpty = true
        // In Share the areas break over an empty day rather than dipping to 0 %.
        if scale == .share { continue }
      } else if previousWasEmpty {
        segment += 1
        previousWasEmpty = false
      }
      var low = 0.0
      for entry in legend {
        let value = cells[entry.name] ?? 0
        let height = scale == .share && total > 0 ? value / total : value
        bands.append(
          UsageRiverBand(
            series: entry.name,
            segmentKey: scale == .share ? "\(entry.name)#\(segment)" : entry.name,
            date: date,
            low: low,
            high: low + height
          )
        )
        low += height
      }
    }
    return UsageRiver(
      series: legend,
      dates: dates,
      bands: bands,
      dayTotals: dayTotals,
      ticks: ticks,
      inProgress: dateTexts.contains(today) ? UsageDateText.date(from: today, calendar) : nil,
      metric: metric,
      scale: scale
    )
  }

  /// Every segment key a series draws under, so each maps to the series' colour.
  var segmentKeys: [(key: String, series: String)] {
    var seen: Set<String> = []
    return bands.compactMap { band in
      seen.insert(band.segmentKey).inserted ? (band.segmentKey, band.series) : nil
    }
  }
}

/// The token mix (`docs/design.md` Token mix): cache read, cache write, fresh input, and output,
/// adding up to the period's tokens.
struct UsageTokenMix: Equatable {
  enum Part: String, CaseIterable, Identifiable {
    case cacheRead
    case cacheWrite
    case freshInput
    case output

    var id: Self { self }

    var title: String {
      switch self {
      case .cacheRead: "Cache read"
      case .cacheWrite: "Cache write"
      case .freshInput: "Fresh input"
      case .output: "Output"
      }
    }
  }

  let tokens: [Part: Int]
  let total: Int
  let reasoningTokens: Int

  init(_ totals: UsageSummaryTotals) {
    let fresh = max(
      totals.inputTokens - totals.cacheReadInputTokens - totals.cacheWriteInputTokens, 0)
    tokens = [
      .cacheRead: totals.cacheReadInputTokens,
      .cacheWrite: totals.cacheWriteInputTokens,
      .freshInput: fresh,
      .output: totals.outputTokens,
    ]
    total = totals.totalTokens
    reasoningTokens = totals.reasoningTokens
  }

  /// The parts the period has, in stacking order. Cache write is left out when nothing wrote.
  var parts: [Part] {
    Part.allCases.filter { $0 != .cacheWrite || (tokens[$0] ?? 0) > 0 }
  }

  func fraction(_ part: Part) -> Double {
    total > 0 ? Double(tokens[part] ?? 0) / Double(total) : 0
  }
}
