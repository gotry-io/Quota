import Foundation
import QuotaWire
import Testing

@testable import Quota

struct UsageDailyBarTests {
  @Test
  func anEmptyDayIsATickAndNotAQuantitativeBar() {
    let empty = row(date: "2026-08-10", tokens: 0, cost: UsageActivityChart.emptyCost())
    #expect(UsageDailyFold.barKind(empty, metric: .tokens) == .empty)
    #expect(UsageDailyFold.barKind(empty, metric: .cost) == .empty)
    #expect(UsageDailyFold.quantitativeMaximum([empty], metric: .tokens) == 0)
  }

  @Test
  func anUnpricedCostDayIsDistinctFromZero() {
    let unpriced = row(date: "2026-08-11", tokens: 40, cost: unpricedCost())
    #expect(UsageDailyFold.barKind(unpriced, metric: .tokens) == .amount(40))
    #expect(UsageDailyFold.barKind(unpriced, metric: .cost) == .unpriced)
    #expect(UsageDailyFold.quantitativeMaximum([unpriced], metric: .cost) == 0)
  }

  @Test
  func aPricedDayIsABarAndDoesNotTurnUnavailableIntoZero() {
    let priced = row(date: "2026-08-12", tokens: 100, cost: pricedCost("2500000"))
    let unpriced = row(date: "2026-08-13", tokens: 20, cost: unpricedCost())
    let empty = row(date: "2026-08-14", tokens: 0, cost: UsageActivityChart.emptyCost())
    #expect(UsageDailyFold.barKind(priced, metric: .cost) == .amount(2_500_000))
    #expect(
      UsageDailyFold.quantitativeMaximum([priced, unpriced, empty], metric: .cost) == 2_500_000
    )
  }

  @Test
  func aMissingDayInTheRangeIsAGapNotAZeroBar() {
    let reported = [
      row(date: "2026-09-01", tokens: 10, cost: pricedCost("1000000")),
      row(date: "2026-09-03", tokens: 20, cost: pricedCost("2000000")),
    ].map {
      UsageActivityDay(date: $0.date, totals: $0.totals, cost: $0.cost, partial: false, agents: nil)
    }
    // 7-day range; the 4th local date (index 3, Sep 4) is absent from days[] as a genuine gap.
    let rows = UsageDailyFold.rows(
      reported: reported,
      from: "2026-09-01",
      to: "2026-09-07"
    )
    #expect(rows.count == 7)
    #expect(rows.map(\.date) == [
      "2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04", "2026-09-05", "2026-09-06",
      "2026-09-07",
    ])
    #expect(UsageDailyFold.barKind(rows[0], metric: .tokens) == .amount(10))
    #expect(UsageDailyFold.barKind(rows[1], metric: .tokens) == .empty)
    #expect(UsageDailyFold.barKind(rows[2], metric: .tokens) == .amount(20))
    #expect(UsageDailyFold.barKind(rows[3], metric: .tokens) == .empty)
    #expect(UsageDailyFold.barKind(rows[3], metric: .tokens) != .amount(0))
    #expect(UsageDailyFold.quantitativeMaximum(rows, metric: .tokens) == 20)
  }

  @Test
  func valueTicksAreTwoOrThreeAndIncludeZero() {
    #expect(UsageDailyAxis.valueTicks(maximum: 100) == [0, 50, 100])
    let millions = UsageDailyAxis.valueTicks(maximum: 11_400_000)
    #expect(millions.first == 0)
    #expect(millions.count == 2 || millions.count == 3)
    #expect(millions.last ?? 0 >= 11_400_000)
  }

  @Test
  func theYAxisCeilingIsTheTightNiceStepAtOrAboveTheMax() {
    #expect(UsageDailyAxis.niceCeiling(240_000) == 250_000)
    #expect(UsageDailyAxis.valueTicks(maximum: 240_000) == [0, 125_000, 250_000])
    #expect(UsageDailyAxis.niceCeiling(1_100_000) == 1_200_000)
    #expect(UsageDailyAxis.valueTicks(maximum: 1_100_000) == [0, 600_000, 1_200_000])
    let emptyCeiling = UsageDailyAxis.niceCeiling(0)
    #expect(emptyCeiling > 0)
    let emptyTicks = UsageDailyAxis.valueTicks(maximum: 0)
    #expect(emptyTicks.first == 0)
    #expect(emptyTicks.last == emptyCeiling)
    #expect(emptyTicks.count == 2 || emptyTicks.count == 3)
  }

  @Test
  func dateTicksKeepEndsAndDoNotLabelEveryDay() {
    let week = (1...7).map { String(format: "2026-09-%02d", $0) }
    #expect(UsageDailyAxis.dateTicks(dates: week) == ["2026-09-01", "2026-09-04", "2026-09-07"])
    let month = (1...30).map { String(format: "2026-09-%02d", $0) }
    let ticks = UsageDailyAxis.dateTicks(dates: month)
    #expect(ticks.count == 4)
    #expect(ticks.first == "2026-09-01")
    #expect(ticks.last == "2026-09-30")
    #expect(UsageDailyAxis.dateTicks(dates: ["2026-09-19"]) == ["2026-09-19"])
  }

  @Test
  func theLastDateTickLabelIsTheFullMonthAndDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.locale = Locale(identifier: "en_US")
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let month = (1...30).map { String(format: "2026-09-%02d", $0) }
    let ticks = UsageDailyAxis.dateTicks(dates: month)
    #expect(ticks.last == "2026-09-30")
    #expect(UsageDailyAxis.dateLabel(ticks.last!, calendar: calendar) == "Sep 30")
    #expect(UsageDailyAxis.dateLabel("2026-09-20", calendar: calendar) == "Sep 20")
    #expect(
      UsageDailyAxis.dateTickAnchor(index: ticks.count - 1, count: ticks.count) == .trailing
    )
    #expect(UsageDailyAxis.dateTickAnchor(index: 0, count: ticks.count) == .leading)
  }

  @Test
  func chartAccessibilityFollowsTheActiveMode() {
    let priced = row(date: "2026-08-12", tokens: 100, cost: pricedCost("2500000"))
    let unpriced = row(date: "2026-08-13", tokens: 20, cost: unpricedCost())
    let empty = row(date: "2026-08-14", tokens: 0, cost: UsageActivityChart.emptyCost())
    let rows = [priced, unpriced, empty]
    let tokens = UsageDailyFold.chartAccessibilityValue(rows, metric: .tokens)
    #expect(tokens.contains("3 days"))
    #expect(tokens.contains("tokens"))
    #expect(!tokens.contains("unpriced"))
    let cost = UsageDailyFold.chartAccessibilityValue(rows, metric: .cost)
    #expect(cost.contains("3 days"))
    #expect(cost.contains("unpriced"))
    #expect(!cost.contains("$0"))
  }
}

private func row(date: String, tokens: Int, cost: UsageCostOutcome) -> UsageDailyFold.Row {
  UsageDailyFold.Row(
    date: date,
    totals: UsageSummaryTotals(
      totalTokens: tokens,
      inputTokens: tokens,
      outputTokens: 0,
      cacheReadInputTokens: 0,
      cacheWriteInputTokens: 0,
      reasoningTokens: 0,
      messages: tokens == 0 ? 0 : 1
    ),
    cost: cost
  )
}

private func pricedCost(_ amountMicrousd: String) -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .calculate,
    basis: .calculated,
    status: .complete,
    amountMicrousd: amountMicrousd,
    catalogRevision: "pricing_1",
    calculatedRows: 1,
    reportedRows: 0,
    unpricedRows: 0,
    assumptions: [],
    unpriced: []
  )
}

private func unpricedCost() -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .calculate,
    basis: .none,
    status: .unavailable,
    amountMicrousd: nil,
    catalogRevision: nil,
    calculatedRows: 0,
    reportedRows: 0,
    unpricedRows: 1,
    assumptions: [],
    unpriced: [
      UsageUnpricedItem(
        billingChannel: .openaiDirect,
        model: "other",
        reason: .unknownModel,
        rows: 1
      )
    ]
  )
}
