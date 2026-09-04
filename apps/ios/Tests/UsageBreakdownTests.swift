import QuotaWire
import Testing

@testable import Quota

struct UsageBreakdownTests {
  @Test
  func groupsAgentProviderThenModelAndFoldsPastFive() {
    let period = UsagePeriod(
      totals: totals(input: 70, output: 14, messages: 7),
      cost: completeCost(microusd: "7000", rows: 7),
      partial: true,
      agents: [
        UsageAgentUsage(
          agent: .codex,
          providers: [
            UsageProviderUsage(
              provider: .openai,
              models: (1...7).map { index in
                model("gpt-\(index)", input: 10, output: 2, messages: 1, microusd: "1000")
              }
            )
          ]
        ),
        UsageAgentUsage(
          agent: .claudeCode,
          providers: [
            UsageProviderUsage(
              provider: .anthropic,
              models: [model("other", input: 10, output: 2, messages: 1, microusd: "500")]
            )
          ]
        ),
      ]
    )

    let sections = UsageBreakdown.sections(in: period)
    #expect(sections.map(\.displayName) == ["Codex", "Claude Code"])
    #expect(sections.count == 2)
    #expect(sections[0].providers.count == 1)
    #expect(sections[0].providers[0].displayName == "OpenAI")
    #expect(sections[0].providers[0].models.count == 7)
    #expect(sections[0].providers[0].visibleModels(expanded: false).count == 5)
    #expect(sections[0].providers[0].hiddenCount(expanded: false) == 2)
    #expect(sections[0].providers[0].hiddenCount(expanded: true) == 0)
    #expect(sections[1].providers[0].models[0].displayName == "Other")
  }

  @Test
  func emptyAgentsYieldNoSections() {
    let period = UsagePeriod(
      totals: totals(input: 0, output: 0, messages: 0),
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
    #expect(UsageBreakdown.sections(in: period).isEmpty)
  }
}

private func model(
  _ name: String,
  input: Int,
  output: Int,
  messages: Int,
  microusd: String
) -> UsageModelUsage {
  UsageModelUsage(
    model: name,
    totals: totals(input: input, output: output, messages: messages),
    cost: completeCost(microusd: microusd, rows: messages)
  )
}

private func totals(input: Int, output: Int, messages: Int) -> UsageSummaryTotals {
  UsageSummaryTotals(
    totalTokens: input + output,
    inputTokens: input,
    outputTokens: output,
    cacheReadInputTokens: 0,
    cacheWriteInputTokens: 0,
    reasoningTokens: 0,
    messages: messages
  )
}

private func completeCost(microusd: String, rows: Int) -> UsageCostOutcome {
  UsageCostOutcome(
    mode: .calculate,
    basis: .calculated,
    status: .complete,
    amountMicrousd: microusd,
    catalogRevision: "pricing_visual_fixture",
    calculatedRows: rows,
    reportedRows: 0,
    unpricedRows: 0,
    assumptions: [.agentDefaultChannel],
    unpriced: []
  )
}
