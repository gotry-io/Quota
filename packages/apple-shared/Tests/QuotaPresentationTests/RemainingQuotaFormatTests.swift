import QuotaPresentation
import Testing

struct RemainingQuotaFormatTests {
  @Test
  func percentOnlyOmitsLeftSuffix() {
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: 75,
        remainingValue: nil,
        hasLimit: false,
        unit: nil
      ) == "75%"
    )
  }

  @Test
  func fractionalPercentKeepsOneDecimal() {
    #expect(RemainingQuotaFormat.percent(70.796) == "70.8%")
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: RemainingQuotaFormat.remainingPercent(usedPercent: 29.204),
        remainingValue: nil,
        hasLimit: false,
        unit: nil
      ) == "70.8%"
    )
  }

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

  @Test
  func balanceOnlyIsAmountWithoutLeft() {
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: 100,
        remainingValue: 60,
        hasLimit: false,
        unit: .usd
      ) == "$60.00"
    )
    #expect(
      RemainingQuotaFormat.absolute(remainingValue: 60, hasLimit: false, unit: .usd) == "$60.00"
    )
    #expect(
      RemainingQuotaFormat.windowTitle("Balance (USD)", isBalanceOnly: true) == "Balance"
    )
  }

  @Test
  func unitlessBalanceShowsBareAmount() {
    #expect(
      RemainingQuotaFormat.absolute(remainingValue: 12.5, hasLimit: false, unit: nil) == "12.50"
    )
  }

  @Test
  func unitlessBudgetOmitsAbsoluteAmount() {
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

  @Test
  func budgetShowsPercentThenRemainingAmount() {
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: 70.796,
        remainingValue: 3.75,
        hasLimit: true,
        unit: .usd
      ) == "70.8% · $3.75"
    )
  }

  @Test
  func countBudgetShowsPercentThenCount() {
    #expect(
      RemainingQuotaFormat.remaining(
        remainingPercent: 75,
        remainingValue: 75,
        hasLimit: true,
        unit: .count
      ) == "75% · 75"
    )
  }

  @Test
  func creditsKeepTwoDecimals() {
    #expect(
      RemainingQuotaFormat.absolute(remainingValue: 1.5, hasLimit: false, unit: .credits)
        == "1.50 credits"
    )
  }

  @Test
  func remainingAccessibilityAddsRemainingExceptBalance() {
    #expect(
      RemainingQuotaFormat.remainingAccessibility(
        windowTitle: "Weekly",
        remainingLabel: "75%",
        isBalanceOnly: false
      ) == "Weekly, 75% remaining"
    )
    #expect(
      RemainingQuotaFormat.remainingAccessibility(
        windowTitle: "Balance",
        remainingLabel: "$60.00",
        isBalanceOnly: true
      ) == "Balance, $60.00"
    )
  }

  @Test
  func meterIsHiddenOnlyForBalanceWindows() {
    #expect(
      RemainingQuotaFormat.showsPercentMeter(remainingValue: 60, hasLimit: false) == false
    )
    #expect(
      RemainingQuotaFormat.showsPercentMeter(remainingValue: 3.75, hasLimit: true) == true
    )
    #expect(
      RemainingQuotaFormat.showsPercentMeter(remainingValue: nil, hasLimit: false) == true
    )
  }
}
