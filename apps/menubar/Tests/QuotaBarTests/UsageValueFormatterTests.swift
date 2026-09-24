import QuotaWire
import Testing

@testable import QuotaBar

struct UsageValueFormatterTests {
  @Test
  func compactCountsUseIndustrySuffixesAndKeepSmallValuesReadable() {
    #expect(!UsageValueFormatter.count(999).hasSuffix("k"))
    #expect(UsageValueFormatter.count(1_234).hasSuffix("k"))
    #expect(UsageValueFormatter.count(999_500).hasSuffix("M"))
    #expect(UsageValueFormatter.count(1_234_567).hasSuffix("M"))
    #expect(UsageValueFormatter.count(1_234_567_890).hasSuffix("B"))
  }

  @Test
  func anUnpricedAmountIsNeverPrintedAsACost() {
    let summary = UsageValueFormatter.todaySummary(tokens: 1_234_567, cost: cost(nil))

    #expect(summary?.text == "Today · 1.23M tokens")
    #expect(summary?.text.contains("unpriced") == false)
    #expect(UsageValueFormatter.tokensAndCost(1_234_567, cost(nil)) == "1.23M")
  }

  @Test
  func usageOrderingPrefersComparableCostThenFallsBackToTokens() {
    #expect(
      UsageValueFormatter.precedes(
        cost: cost("10000000"), tokens: 10, name: "expensive",
        before: cost("9000000"), tokens: 1_000, name: "large"
      )
    )
    #expect(
      !UsageValueFormatter.precedes(
        cost: cost(nil), tokens: 1_000, name: "unpriced",
        before: cost("9000000"), tokens: 10, name: "priced"
      )
    )
  }

  @Test
  func todaySummaryDisappearsWhenThereAreNoTokens() {
    #expect(UsageValueFormatter.todaySummary(tokens: 0, cost: cost("12340000")) == nil)
    #expect(UsageValueFormatter.todaySummary(tokens: 0, cost: cost(nil)) == nil)
  }

  private func cost(_ amountMicrousd: String?) -> UsageCostOutcome {
    UsageCostOutcome(
      mode: .calculate,
      basis: amountMicrousd == nil ? .none : .calculated,
      status: amountMicrousd == nil ? .unavailable : .complete,
      amountMicrousd: amountMicrousd,
      catalogRevision: amountMicrousd == nil ? nil : "pricing_1",
      calculatedRows: amountMicrousd == nil ? 0 : 1,
      reportedRows: 0,
      unpricedRows: amountMicrousd == nil ? 1 : 0,
      assumptions: [],
      unpriced: amountMicrousd == nil
        ? [
          UsageUnpricedItem(
            billingChannel: .unknown,
            model: "unknown",
            reason: .unknownModel,
            rows: 1
          )
        ] : []
    )
  }
}
