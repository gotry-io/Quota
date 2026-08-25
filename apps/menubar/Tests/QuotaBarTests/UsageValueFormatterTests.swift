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
  func accessibilityCountsDoNotUseCompactNotation() {
    #expect(!UsageValueFormatter.accessibleCount(1_234_567).contains("M"))
  }

  @Test
  func compactCostUsesTwoDecimalsWithoutDetailCopy() {
    let outcome = cost("50239770")
    let value = UsageValueFormatter.compactCost(outcome)
    #expect(value.contains("50.24"))
    #expect(!value.contains("estimated"))
  }

  @Test
  func compactModelSummaryKeepsTokensBeforeCost() {
    let value = UsageValueFormatter.tokensAndCost(1_234_567, cost("50239770"))
    #expect(value.hasPrefix("1.23M · "))
    #expect(value.contains("50.24"))
  }

  @Test
  func compactModelSummaryOmitsUnavailableCost() {
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
  func todaySummaryLeadsWithCostAndNamesTheTokens() {
    let summary = UsageValueFormatter.todaySummary(tokens: 1_234_567, cost: cost("12340000"))

    #expect(summary?.text.hasPrefix("Today · ") == true)
    #expect(summary?.text.contains("12.34") == true)
    #expect(summary?.text.hasSuffix(" · 1.23M tokens") == true)
    #expect(summary?.accessibilityLabel.contains("1,234,567 tokens") == true)
  }

  @Test
  func todaySummaryKeepsTokensWhenTheDayIsUnpriced() {
    let summary = UsageValueFormatter.todaySummary(tokens: 1_234_567, cost: cost(nil))

    #expect(summary?.text == "Today · 1.23M tokens")
    #expect(summary?.text.contains("unpriced") == false)
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
