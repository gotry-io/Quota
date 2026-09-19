import Foundation
import QuotaWire
import Testing

@testable import Quota

/// Fixture bodies decode into the totals, cost, and coverage copy the Usage page prints.
struct UsagePeriodRenderTests {
  @Test
  func fixtureBodyRendersTotalsCostAndCoverage() throws {
    let totals = UsageSummaryTotals(
      totalTokens: 2_400,
      inputTokens: 2_000,
      outputTokens: 400,
      cacheReadInputTokens: 200,
      cacheWriteInputTokens: 0,
      reasoningTokens: 50,
      messages: 6
    )
    let cost = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .complete,
      amountMicrousd: "1230000",
      catalogRevision: "pricing_1",
      calculatedRows: 1,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [.agentDefaultChannel],
      unpriced: []
    )
    let period = UsagePeriod(
      totals: totals,
      cost: cost,
      cacheSaved: UsageCacheSaved(amountMicrousd: "190", status: .complete, unpricedRows: 0),
      partial: true,
      agents: []
    )
    let headline = UsageHeadlineSection(period: period, truncatedByRetention: true)
    #expect(QuotaFormat.compactCount(period.totals.totalTokens) == "2.4k")
    #expect(QuotaFormat.cost(period.cost) == "$1.23")
    #expect(headline.partial)
    #expect(headline.truncatedByRetention)
    #expect(headline.partialCopy == "Some hours in this period were scanned incompletely.")
    #expect(headline.truncatedCopy == "This range goes past what Quota still keeps.")
  }
}
