import Foundation
import QuotaPresentation
import QuotaWire
import Testing

@testable import Quota

struct UsageModelRiverTests {
  private let colors = ModelColorAssignment(tokensByModel: [
    ModelKey(family: .anthropic, model: "claude-opus"): 900,
    ModelKey(family: .openai, model: "gpt-5"): 500,
  ])

  /// Every asked date keeps its slot: a date the series does not name is an empty day whose
  /// stack meets the baseline, and a model without a cell on a date is zero there — neither is
  /// dropped from the axis or carried over from a neighbour.
  @Test
  func aDateTheSeriesDoesNotNameIsAnEmptyDayInItsSlot() {
    let series = UsageModelSeries(
      models: [entry("claude-opus", .anthropic), entry("gpt-5", .openai)],
      days: [
        day("2026-09-01", [cell("claude-opus", tokens: 30), cell("gpt-5", tokens: 10)]),
        day("2026-09-03", [cell("gpt-5", tokens: 20)]),
      ]
    )
    let river = UsageModelRiver.make(
      series: series, from: "2026-09-01", to: "2026-09-04", today: "2026-09-04",
      metric: .tokens, colors: colors)

    #expect(river.days.map(\.date) == ["2026-09-01", "2026-09-02", "2026-09-03", "2026-09-04"])
    #expect(river.days.map(\.kind) == [.amount(40), .empty, .amount(20), .empty])
    #expect(river.points.filter { $0.date == "2026-09-02" }.map(\.value) == [0, 0])
    #expect(river.points.filter { $0.date == "2026-09-03" }.map(\.value) == [0, 20])
    #expect(river.days.last?.isToday == true)
    #expect(river.maximum == 40)
  }

  /// A cell Relay could not price is left out of a Cost stack, never drawn as $0 of it, and a
  /// day with nothing priced is its own mark rather than an empty one.
  @Test
  func anUnpricedCellIsNotACostOfZero() {
    let series = UsageModelSeries(
      models: [entry("claude-opus", .anthropic), entry("gpt-5", .openai)],
      days: [
        day("2026-09-01", [
          cell("claude-opus", tokens: 30, micro: "2500000"), cell("gpt-5", tokens: 10, micro: nil),
        ]),
        day("2026-09-02", [cell("gpt-5", tokens: 10, micro: nil)]),
      ]
    )
    let river = UsageModelRiver.make(
      series: series, from: "2026-09-01", to: "2026-09-02", today: "2026-09-30",
      metric: .cost, colors: colors)

    #expect(river.days.map(\.kind) == [.amount(2.5), .unpriced])
    #expect(river.days.map(\.unpricedCells) == [1, 1])
  }

  /// The folded rest of a top-N series spans providers, so it is `other`; a named model takes its
  /// provider's shade from the `all` assignment, not from its place in this period's legend.
  @Test
  func theFoldedRestIsOtherAndANamedModelKeepsItsAllTimeShade() {
    let series = UsageModelSeries(
      models: [entry("gpt-5", .openai), entry("claude-opus", .anthropic), entry("other", nil)],
      days: [day("2026-09-01", [cell("gpt-5", tokens: 90), cell("other", tokens: 5)])]
    )
    let river = UsageModelRiver.make(
      series: series, from: "2026-09-01", to: "2026-09-01", today: "2026-09-01",
      metric: .tokens, colors: colors)

    #expect(river.series.map(\.swatch) == [.shade(.openai, 1), .shade(.anthropic, 1), .other])
  }

  @Test
  func theYAxisCeilingIsTheTightNiceStepAtOrAboveTheMax() {
    #expect(UsageDailyAxis.niceCeiling(240_000) == 250_000)
    #expect(UsageDailyAxis.valueTicks(maximum: 240_000) == [0, 125_000, 250_000])
    #expect(UsageDailyAxis.niceCeiling(1_100_000) == 1_200_000)
    #expect(UsageDailyAxis.valueTicks(maximum: 1_100_000) == [0, 600_000, 1_200_000])
    #expect(UsageDailyAxis.valueTicks(maximum: 100) == [0, 50, 100])
    let millions = UsageDailyAxis.valueTicks(maximum: 11_400_000)
    #expect(millions.first == 0)
    #expect(millions.count == 2 || millions.count == 3)
    #expect(millions.last ?? 0 >= 11_400_000)
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
    // The end labels anchor inward so neither is clipped at the plot's edge.
    #expect(UsageDailyAxis.dateTickAnchor(index: ticks.count - 1, count: ticks.count) == .trailing)
    #expect(UsageDailyAxis.dateTickAnchor(index: 0, count: ticks.count) == .leading)
  }

  @Test
  func theLedgerListsSixThenNamesTheRest() {
    let rows = ModelLedger.rows(
      (1...7).map { index in
        ModelUsageLeaf(
          agent: BillingAgent.codex,
          key: ModelKey(family: .openai, model: "m\(index)"),
          totals: ModelUsageTotals(
            totalTokens: index * 10, inputTokens: index * 10, outputTokens: 0,
            cacheReadInputTokens: 0, cacheWriteInputTokens: 0, messages: 1),
          cost: ModelUsageCost(coverage: .complete, amountMicrousd: "1")
        )
      })
    let six = UsageLedgerFold.split(Array(rows.prefix(6)))
    #expect(six.visible.count == 6)
    #expect(six.rest == nil)

    let seven = UsageLedgerFold.split(rows)
    #expect(seven.visible.count == 6)
    #expect(seven.rest?.count == 1)
    #expect(seven.rest?.tokens == 10, "the smallest model is the one folded away")
  }
}

private func entry(_ model: String, _ provider: InferenceProvider?) -> UsageModelSeriesEntry {
  UsageModelSeriesEntry(model: model, provider: provider)
}

private func day(_ date: String, _ cells: [UsageModelSeriesCell]) -> UsageModelSeriesDay {
  UsageModelSeriesDay(date: date, partial: false, models: cells)
}

private func cell(_ model: String, tokens: Int, micro: String? = "1000") -> UsageModelSeriesCell {
  UsageModelSeriesCell(
    model: model,
    totalTokens: tokens,
    inputTokens: tokens,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheWriteInputTokens: 0,
    costMicrousd: micro
  )
}
