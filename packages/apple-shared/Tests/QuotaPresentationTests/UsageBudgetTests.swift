import Foundation
import QuotaPresentation
import Testing

struct UsageBudgetTests {
  @Test func anAmountOutsideTheBoundsIsNoBudgetAtAll() {
    #expect(UsageBudget(amountUSD: 50, alerts: true).amountUSD == 50)
    #expect(UsageBudget(amountUSD: 0, alerts: true).amountUSD == nil)
    #expect(UsageBudget(amountUSD: -1, alerts: true).amountUSD == nil)
    #expect(UsageBudget(amountUSD: 2_000_000, alerts: true).amountUSD == nil)
    #expect(!UsageBudget.none.isSet)
  }

  @Test func roundsThePercentDownAndClampsTheBar() {
    #expect(UsageBudgetProgress(spentUSD: 5.39, budgetUSD: 50, partial: false).percent == 10)
    #expect(UsageBudgetProgress(spentUSD: 49.999, budgetUSD: 50, partial: false).percent == 99)
    #expect(UsageBudgetProgress(spentUSD: 75, budgetUSD: 50, partial: false).fraction == 1)
    #expect(UsageBudgetProgress(spentUSD: 0, budgetUSD: 50, partial: false).percent == 0)
  }

  @Test func namesTheThresholdsAMonthHasReached() {
    #expect(UsageBudgetProgress(spentUSD: 20, budgetUSD: 50, partial: false).crossedThresholds == [])
    #expect(
      UsageBudgetProgress(spentUSD: 40, budgetUSD: 50, partial: false).crossedThresholds == [80])
    #expect(
      UsageBudgetProgress(spentUSD: 60, budgetUSD: 50, partial: false).crossedThresholds
        == [80, 100]
    )
  }

  @Test func readsAnAmountOutOfTheMicrodollarsEveryCostCarries() {
    #expect(UsageBudgetProgress.dollars(microusd: "5390000") == 5.39)
    #expect(UsageBudgetProgress.dollars(microusd: nil) == nil)
    #expect(UsageBudgetProgress.dollars(microusd: "not a number") == nil)
  }

  @Test func writesTheProgressLineTheThreeClientsShare() {
    let progress = UsageBudgetProgress(spentUSD: 5.39, budgetUSD: 50, partial: false)
    #expect(progress.text.contains("5.39"))
    #expect(progress.text.hasSuffix("· 10%"))
    #expect(UsageBudgetProgress(spentUSD: 5.39, budgetUSD: 50, partial: true).text.hasPrefix("≥ "))
  }
}
