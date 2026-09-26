import Foundation
import QuotaPresentation
import Testing

struct ModelUsageTests {
  private static func leaf(
    _ agent: String,
    _ family: ModelFamily,
    _ model: String,
    tokens: Int,
    cacheRead: Int = 0,
    cost: ModelUsageCost = ModelUsageCost(coverage: .complete, amountMicrousd: "0")
  ) -> ModelUsageLeaf<String> {
    ModelUsageLeaf(
      agent: agent,
      key: ModelKey(family: family, model: model),
      totals: ModelUsageTotals(
        totalTokens: tokens,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadInputTokens: cacheRead,
        cacheWriteInputTokens: 0,
        messages: 1
      ),
      cost: cost
    )
  }

  /// Rank is inside a provider, over `all`, after agents merge: `opus` is split across two
  /// agents and still outranks `sonnet`, and a large OpenAI model does not push Anthropic's
  /// fifth model into a shade.
  @Test func aShadeIsTheRankInsideItsProviderOverAllAndTheFifthIsOther() {
    let colors = ModelColorAssignment(all: [
      Self.leaf("claude_code", .anthropic, "sonnet", tokens: 500),
      Self.leaf("claude_code", .anthropic, "opus", tokens: 300),
      Self.leaf("opencode", .anthropic, "opus", tokens: 300),
      Self.leaf("claude_code", .anthropic, "haiku", tokens: 200),
      Self.leaf("claude_code", .anthropic, "claude-3", tokens: 100),
      Self.leaf("claude_code", .anthropic, "claude-2", tokens: 50),
      Self.leaf("codex", .openai, "gpt-5", tokens: 10_000),
      Self.leaf("pi", .unknown, "mystery", tokens: 1),
    ])
    func swatch(_ family: ModelFamily, _ model: String) -> ModelSwatch {
      colors.swatch(for: ModelKey(family: family, model: model))
    }
    #expect(swatch(.anthropic, "opus") == .shade(.anthropic, 1))
    #expect(swatch(.anthropic, "sonnet") == .shade(.anthropic, 2))
    #expect(swatch(.anthropic, "claude-3") == .shade(.anthropic, 4))
    #expect(swatch(.anthropic, "claude-2") == .other)
    #expect(swatch(.openai, "gpt-5") == .shade(.openai, 1))
    #expect(swatch(.unknown, "mystery") == .shade(.unknown, 1))
    #expect(swatch(.openai, "never-in-all") == .other)
    #expect(colors.swatch(family: nil, model: "other") == .other)
  }

  /// One model used by two agents is one row: tokens and cache add, the cost is partial when one
  /// agent's share could not be priced, and the agent that sent more is named first.
  @Test func aModelUsedByTwoAgentsIsOneRow() {
    let rows = ModelLedger.rows([
      Self.leaf(
        "claude_code", .anthropic, "opus", tokens: 100, cacheRead: 50,
        cost: ModelUsageCost(coverage: .complete, amountMicrousd: "1500")),
      Self.leaf("codex", .openai, "gpt-5", tokens: 200),
      Self.leaf(
        "opencode", .anthropic, "opus", tokens: 300, cacheRead: 0,
        cost: ModelUsageCost(coverage: .unavailable, amountMicrousd: nil)),
    ])
    #expect(rows.map(\.key.model) == ["opus", "gpt-5"])
    let opus = rows[0]
    #expect(opus.totals.totalTokens == 400)
    #expect(opus.share == 400.0 / 600.0)
    #expect(opus.cacheHitBasisPoints == 1_250)
    #expect(opus.cost == ModelUsageCost(coverage: .partial, amountMicrousd: "1500"))
    #expect(opus.agents == ["opencode", "claude_code"])
    #expect(opus.shareChange == nil)
  }

  @Test func shareChangeIsPointsAgainstThePreviousPeriodOrNewForAModelItLacked() {
    let previous = [
      Self.leaf("codex", .openai, "gpt-5", tokens: 900),
      Self.leaf("claude_code", .anthropic, "opus", tokens: 100),
    ]
    let rows = ModelLedger.rows(
      [
        Self.leaf("codex", .openai, "gpt-5", tokens: 500),
        Self.leaf("claude_code", .anthropic, "opus", tokens: 300),
        Self.leaf("claude_code", .anthropic, "haiku", tokens: 200),
      ],
      previous: previous
    )
    #expect(rows.map(\.shareChange) == [.points(-40), .points(20), .new])
    // A previous period with no Usage at all compares nothing rather than calling it all new.
    let fromNothing = ModelLedger.rows(
      [Self.leaf("codex", .openai, "gpt-5", tokens: 500)],
      previous: []
    )
    #expect(fromNothing.map(\.shareChange) == [nil])
  }
}
