import QuotaPresentation
import Testing

struct UsageCostFormatTests {
  @Test
  func completeCostUsesTwoDecimalsWithoutDetailCopy() {
    let value = UsageCostFormat.compact(status: .complete, amountMicrousd: "50239770")
    #expect(value.contains("50.24"))
    #expect(!value.contains("estimated"))
    #expect(!value.hasPrefix("≥"))
  }

  @Test
  func partialCostPrefixesInequality() {
    let value = UsageCostFormat.compact(status: .partial, amountMicrousd: "50239770")
    #expect(value.hasPrefix("≥ "))
    #expect(value.contains("50.24"))
  }

  @Test
  func unavailableCostIsUnpriced() {
    #expect(UsageCostFormat.compact(status: .unavailable, amountMicrousd: nil) == "— unpriced")
    #expect(
      UsageCostFormat.compact(status: .unavailable, amountMicrousd: "50239770") == "— unpriced"
    )
  }

  @Test
  func completeWithoutAmountFallsBackToZeroDollars() {
    let value = UsageCostFormat.compact(status: .complete, amountMicrousd: nil)
    #expect(value.contains("0.00"))
  }

  @Test
  func accessibilityIncludesCoverageWords() {
    #expect(
      UsageCostFormat.accessible(status: .complete, amountMicrousd: "3138").contains("complete")
    )
    #expect(
      UsageCostFormat.accessible(status: .partial, amountMicrousd: "3138").contains("partial")
    )
    #expect(UsageCostFormat.accessible(status: .unavailable, amountMicrousd: nil) == "unpriced")
  }

  @Test
  func savedWithNoAmountIsNil() {
    #expect(UsageCostFormat.saved(status: .complete, amountMicrousd: nil) == nil)
    #expect(UsageCostFormat.saved(status: .partial, amountMicrousd: nil) == nil)
    #expect(UsageCostFormat.saved(status: .unavailable, amountMicrousd: nil) == nil)
  }

  @Test
  func savedCompletePrefixesTheCompactAmount() {
    let value = UsageCostFormat.saved(status: .complete, amountMicrousd: "50239770")
    #expect(value?.hasPrefix("saved ") == true)
    #expect(value?.contains("50.24") == true)
    #expect(value?.contains("≥") == false)
  }

  @Test
  func savedPartialPrefixesInequality() {
    let value = UsageCostFormat.saved(status: .partial, amountMicrousd: "50239770")
    #expect(value?.hasPrefix("saved ≥ ") == true)
    #expect(value?.contains("50.24") == true)
  }
}
