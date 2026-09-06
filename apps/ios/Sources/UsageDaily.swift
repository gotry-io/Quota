import QuotaWire

/// The UTC days a period's table shows, oldest first, including the ones that reported nothing.
///
/// The activity read answers UTC dates — 400 local days would cut 400 UTC days, which is the
/// history the rollup exists to keep closed (ADR 0024) — so this table is UTC too, and says so.
/// `all` has no table: two years of rows is what the Activity chart beside it already answers.
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

  /// How many UTC days each period covers, or `nil` for the period that has no table.
  static func span(_ period: SelectedUsagePeriod) -> Int? {
    switch period {
    case .today: 1
    case .last7Days: 7
    case .last30Days: 30
    case .all: nil
    }
  }

  static func rows(
    reported: [UsageActivityDay],
    period: SelectedUsagePeriod,
    lastDate: String
  ) -> [Row] {
    guard let span = span(period) else { return [] }
    let byDate = Dictionary(reported.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    return (0..<span).reversed().map { offset in
      let date = UsageActivityCalendar.addDays(-offset, to: lastDate)
      let day = byDate[date]
      return Row(
        date: date,
        totals: day?.totals ?? emptyTotals,
        cost: day?.cost ?? UsageActivityChart.emptyCost()
      )
    }
  }

  static func hasUsage(_ rows: [Row]) -> Bool {
    rows.contains { $0.totals.totalTokens > 0 }
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
