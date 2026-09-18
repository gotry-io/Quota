import QuotaWire
import Testing

@testable import Quota

struct AgentDisplayTests {
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

  @Test
  func costPricedMatchesTheWebsiteLine() {
    let complete = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .complete,
      amountMicrousd: "1230000",
      catalogRevision: nil,
      calculatedRows: 12,
      reportedRows: 0,
      unpricedRows: 0,
      assumptions: [],
      unpriced: []
    )
    #expect(QuotaFormat.costPriced(complete) == "Priced 12 of 12 rows")
    let partial = UsageCostOutcome(
      mode: .calculate,
      basis: .calculated,
      status: .partial,
      amountMicrousd: "1000000",
      catalogRevision: nil,
      calculatedRows: 9,
      reportedRows: 1,
      unpricedRows: 2,
      assumptions: [],
      unpriced: [
        UsageUnpricedItem(
          billingChannel: .openaiDirect, model: "other", reason: .unknownModel, rows: 2)
      ]
    )
    #expect(QuotaFormat.costPriced(partial) == "Priced 10 of 12 rows")
  }

  @Test
  func agentSystemImagesAreSymbolsNotProviderMarks() {
    #expect(BillingAgent.codex.systemImage == "terminal")
    #expect(BillingAgent.claudeCode.systemImage == "sparkles")
    #expect(BillingAgent.grok.systemImage == "bolt")
    #expect(BillingAgent.cursor.systemImage == "cursorarrow")
    #expect(BillingAgent.gemini.systemImage == "star.circle")
    #expect(BillingAgent.copilot.systemImage == "airplane")
    #expect(BillingAgent.opencode.systemImage == "chevron.left.forwardslash.chevron.right")
    #expect(BillingAgent.pi.systemImage == BillingAgent.opencode.systemImage)
    #expect(BillingAgent.kilo.systemImage == BillingAgent.opencode.systemImage)
    #expect(BillingAgent.antigravity.systemImage == BillingAgent.opencode.systemImage)
    #expect(BillingAgent.unknown.systemImage == BillingAgent.opencode.systemImage)
  }
}
