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
