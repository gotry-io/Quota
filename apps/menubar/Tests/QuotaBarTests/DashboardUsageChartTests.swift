import QuotaWire
import Testing

@testable import QuotaBar

struct DashboardUsageChartTests {
  @Test
  func anEmptyDayIsATickAndAnUnpricedDayIsNotZero() {
    let empty = LocalUsageDay(
      date: "2026-08-14",
      totals: totals(0),
      cost: priced("0")
    )
    let unpriced = LocalUsageDay(
      date: "2026-08-15",
      totals: totals(40),
      cost: unpricedCost()
    )
    let pricedDay = LocalUsageDay(
      date: "2026-08-16",
      totals: totals(100),
      cost: priced("2500000")
    )

    #expect(dashboardUsageDayKind(empty) == .empty)
    #expect(dashboardUsageDayKind(unpriced) == .unpriced)
    #expect(dashboardUsageDayKind(pricedDay) == .cost(2.5))
  }
}

private func totals(_ tokens: Int) -> UsageSummaryTotals {
  UsageSummaryTotals(
    totalTokens: tokens,
    inputTokens: tokens,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheWriteInputTokens: 0,
    reasoningTokens: 0,
    messages: tokens == 0 ? 0 : 1
  )
}

private func priced(_ amountMicrousd: String) -> UsageCostOutcome {
  let hasAmount = amountMicrousd != "0"
  return UsageCostOutcome(
    mode: .calculate,
    basis: hasAmount ? .calculated : .none,
    status: .complete,
    amountMicrousd: hasAmount ? amountMicrousd : nil,
    catalogRevision: hasAmount ? "pricing_1" : nil,
    calculatedRows: hasAmount ? 1 : 0,
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
        billingChannel: .unknown,
        model: "unknown",
        reason: .unknownModel,
        rows: 1
      )
    ]
  )
}
