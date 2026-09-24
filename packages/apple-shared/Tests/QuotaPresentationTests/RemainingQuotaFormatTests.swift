import QuotaPresentation
import Testing

struct RemainingQuotaFormatTests {
  @Test
  func nearIntegerPercentRoundsToWholeNumber() {
    #expect(RemainingQuotaFormat.percent(74.96) == "75%")
    #expect(RemainingQuotaFormat.percent(0) == "0%")
    #expect(RemainingQuotaFormat.percent(100) == "100%")
  }

  @Test
  func clampsUsedAndRemainingPercent() {
    #expect(RemainingQuotaFormat.remainingPercent(usedPercent: -4) == 100)
    #expect(RemainingQuotaFormat.remainingPercent(usedPercent: 140) == 0)
    #expect(RemainingQuotaFormat.percent(-4) == "0%")
    #expect(RemainingQuotaFormat.percent(140) == "100%")
  }

  /// An amount with no unit is printed only when it is the whole reading (a wallet); beside a
  /// limit it would be a bare number nobody can read, so the window keeps its percent.
  @Test
  func aUnitlessAmountPrintsOnlyAsAWallet() {
    #expect(
      RemainingQuotaFormat.absolute(remainingValue: 12.5, hasLimit: false, unit: nil) == "12.50"
    )
    #expect(
      RemainingQuotaFormat.absolute(remainingValue: 12.5, hasLimit: true, unit: nil) == nil
    )
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: 75,
        remainingValue: 12.5,
        hasLimit: true,
        unit: nil
      ) == "75%"
    )
  }
}
