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
