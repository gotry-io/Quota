import Testing

@testable import QuotaBar

struct QuotaWindowRemainingLabelTests {
  @Test
  func percentOnlyOmitsLeftSuffix() {
    let window = QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 25)
    #expect(window.remainingDisplayLabel == "75%")
  }

  @Test
  func fractionalPercentKeepsOneDecimal() {
    let window = QuotaWindow(id: "other_models", title: "Other Models", usedPercent: 29.204)
    #expect(window.remainingDisplayLabel == "70.8%")
  }

  @Test
  func balanceOnlyIsAmountWithoutLeft() {
    let window = QuotaWindow(
      id: "credits",
      title: "Balance (USD)",
      usedPercent: 0,
      remainingValue: 60,
      valueUnit: .usd
    )
    #expect(window.remainingDisplayLabel == "$60.00")
    #expect(window.absoluteRemainingLabel == "$60.00")
  }

  @Test
  func budgetShowsPercentThenRemainingAmount() {
    let window = QuotaWindow(
      id: "on_demand",
      title: "On-demand",
      usedPercent: 29.204,
      remainingValue: 3.75,
      limitValue: 5,
      valueUnit: .usd
    )
    #expect(window.remainingDisplayLabel == "70.8% · $3.75")
  }

  @Test
  func countBudgetShowsPercentThenCount() {
    let window = QuotaWindow(
      id: "weekly",
      title: "Weekly",
      usedPercent: 25,
      remainingValue: 75,
      limitValue: 100,
      valueUnit: .count
    )
    #expect(window.remainingDisplayLabel == "75% · 75")
  }
}
