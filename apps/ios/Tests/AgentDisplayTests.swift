import QuotaWire
import Testing

@testable import Quota

struct AgentDisplayTests {
  @Test
  func mapsEachKnownAgent() {
    #expect(AgentDisplay.name(.codex) == "Codex")
    #expect(AgentDisplay.name(.claudeCode) == "Claude Code")
    #expect(AgentDisplay.name(.grok) == "Grok")
    #expect(AgentDisplay.name(.opencode) == "OpenCode")
    #expect(AgentDisplay.name(.pi) == "Pi")
    #expect(AgentDisplay.name(.cursor) == "Cursor")
    #expect(AgentDisplay.name(.unknown) == "Unknown")
  }

  @Test
  func namesEveryBillingAgent() {
    for agent in BillingAgent.allCases {
      #expect(!AgentDisplay.name(agent).isEmpty)
    }
  }

  @Test
  func otherModelIsTitleCased() {
    #expect(ModelDisplay.name("other") == "Other")
    #expect(ModelDisplay.name("gpt-5") == "gpt-5")
  }

  @Test
  func costBasisMatchesTheWebsiteLine() {
    let complete = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .complete,
      amountMicrousd: "1230000",
      catalogRevision: nil,
      calculatedRows: 1,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [],
      unpriced: []
    )
    #expect(QuotaFormat.costBasis(complete) == "estimated · complete")
    let unpriced = UsageCostOutcome(
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
          billingChannel: .openaiDirect, model: "other", reason: .unknownModel, rows: 1)
      ]
    )
    #expect(QuotaFormat.costBasis(unpriced) == "Unpriced")
  }
}

struct SelectedUsagePeriodTests {
  @Test
  func segmentedTitlesFitTheControl() {
    #expect(SelectedUsagePeriod.today.segmentTitle == "Today")
    #expect(SelectedUsagePeriod.last7Days.segmentTitle == "7 Days")
    #expect(SelectedUsagePeriod.last30Days.segmentTitle == "30 Days")
    #expect(SelectedUsagePeriod.all.segmentTitle == "2 Years")
    #expect(SelectedUsagePeriod.all.accessibilityTitle == "Up to 2 years")
  }

  @Test
  func readsTheMatchingPeriodFromAccountUsage() {
    let usage = AccountUsage(
      today: emptyPeriod(),
      last7Days: emptyPeriod(),
      last30Days: emptyPeriod(),
      all: emptyPeriod()
    )
    #expect(SelectedUsagePeriod.today.period(in: usage).totals.messages == 0)
    #expect(SelectedUsagePeriod.last30Days.period(in: usage).agents.isEmpty)
  }
}

private func emptyPeriod() -> UsagePeriod {
  UsagePeriod(
    totals: UsageSummaryTotals(
      totalTokens: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheReadInputTokens: 0,
      cacheWriteInputTokens: 0,
      reasoningTokens: 0,
      messages: 0
    ),
    cost: UsageCostOutcome(
      mode: .calculate,
      basis: .none,
      status: .complete,
      amountMicrousd: nil,
      catalogRevision: nil,
      calculatedRows: 0,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [],
      unpriced: []
    ),
    partial: false,
    agents: []
  )
}
