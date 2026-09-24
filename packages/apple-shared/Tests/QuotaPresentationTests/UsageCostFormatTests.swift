import QuotaPresentation
import Testing

struct UsageCostFormatTests {
  /// A partial price is a lower bound and says so, an unpriced one names no amount even when one
  /// arrived, and only a complete one is stated flat — on screen, to VoiceOver, and as a saving.
  @Test
  func aCostIsNeverShownAsSurerThanItsCoverage() {
    let complete = UsageCostFormat.compact(status: .complete, amountMicrousd: "50239770")
    #expect(complete.contains("50.24"))
    #expect(!complete.hasPrefix("≥"))
    let partial = UsageCostFormat.compact(status: .partial, amountMicrousd: "50239770")
    #expect(partial.hasPrefix("≥ "))
    #expect(partial.contains("50.24"))
    #expect(
      UsageCostFormat.compact(status: .unavailable, amountMicrousd: "50239770") == "— unpriced"
    )
    #expect(
      UsageCostFormat.accessible(status: .partial, amountMicrousd: "3138").contains("partial")
    )
    #expect(UsageCostFormat.accessible(status: .unavailable, amountMicrousd: nil) == "unpriced")
    #expect(
      UsageCostFormat.saved(status: .complete, amountMicrousd: "50239770")?.contains("≥") == false
    )
    #expect(
      UsageCostFormat.saved(status: .partial, amountMicrousd: "50239770")?.hasPrefix("saved ≥ ")
        == true
    )
  }

  @Test
  func savedWithNoAmountIsNil() {
    #expect(UsageCostFormat.saved(status: .complete, amountMicrousd: nil) == nil)
    #expect(UsageCostFormat.saved(status: .partial, amountMicrousd: nil) == nil)
    #expect(UsageCostFormat.saved(status: .unavailable, amountMicrousd: nil) == nil)
  }
}
