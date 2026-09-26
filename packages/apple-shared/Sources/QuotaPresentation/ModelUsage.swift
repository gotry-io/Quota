import Foundation

// The model-usage vocabulary the analysis surfaces share (ADR 0064): one leaf of a period's
// agent tree, flattened, so the colour assignment and the ledger fold read one shape whether the
// tree came from Relay or from this Mac's service.
//
// Public API:
// - `ModelFamily` — the inference provider a model's colour family is named for.
// - `ModelKey` — a model as every chart and ledger names it: provider family plus model name.
// - `ModelUsageTotals` — token and message counts of one leaf or one merged row.
// - `ModelUsageCost` — a cost outcome reduced to what a merge and a ledger cell need.
// - `ModelUsageLeaf<Agent>` — one (agent, provider, model) leaf of a period tree.

/// The inference provider a model's colour family is named for. Its members are the wire's
/// `InferenceProvider` members one for one; a provider this build does not know is `unknown`.
public typealias ModelFamily = DesignTokens.ModelFamily

/// A model as every chart and ledger names it: the same name under two providers is two models.
public struct ModelKey: Hashable, Sendable {
  public let family: ModelFamily
  public let model: String

  public init(family: ModelFamily, model: String) {
    self.family = family
    self.model = model
  }
}

/// Token and message counts of one leaf, or of a row merged from several.
public struct ModelUsageTotals: Equatable, Sendable {
  public var totalTokens: Int
  public var inputTokens: Int
  public var outputTokens: Int
  public var cacheReadInputTokens: Int
  public var cacheWriteInputTokens: Int
  public var messages: Int

  public init(
    totalTokens: Int,
    inputTokens: Int,
    outputTokens: Int,
    cacheReadInputTokens: Int,
    cacheWriteInputTokens: Int,
    messages: Int
  ) {
    self.totalTokens = totalTokens
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.cacheReadInputTokens = cacheReadInputTokens
    self.cacheWriteInputTokens = cacheWriteInputTokens
    self.messages = messages
  }

  public static let zero = ModelUsageTotals(
    totalTokens: 0,
    inputTokens: 0,
    outputTokens: 0,
    cacheReadInputTokens: 0,
    cacheWriteInputTokens: 0,
    messages: 0
  )

  public static func + (lhs: Self, rhs: Self) -> Self {
    ModelUsageTotals(
      totalTokens: lhs.totalTokens + rhs.totalTokens,
      inputTokens: lhs.inputTokens + rhs.inputTokens,
      outputTokens: lhs.outputTokens + rhs.outputTokens,
      cacheReadInputTokens: lhs.cacheReadInputTokens + rhs.cacheReadInputTokens,
      cacheWriteInputTokens: lhs.cacheWriteInputTokens + rhs.cacheWriteInputTokens,
      messages: lhs.messages + rhs.messages
    )
  }

  /// Input that did not come from a cache: `inputTokens` less both cache subsets.
  public var freshInputTokens: Int {
    max(inputTokens - cacheReadInputTokens - cacheWriteInputTokens, 0)
  }

  /// Cache read over input, in basis points, by the shared ``UsageMetrics`` rule.
  public var cacheHitBasisPoints: Int? {
    UsageMetrics.cacheHitBasisPoints(
      cacheReadInputTokens: cacheReadInputTokens,
      inputTokens: inputTokens
    )
  }
}

/// A cost outcome as a ledger cell reads it: how much of it was priced, and the priced amount.
///
/// `amountMicrousd` is nil exactly when nothing was priced (`unavailable`).
public struct ModelUsageCost: Equatable, Sendable {
  public let coverage: UsageCostCoverage
  public let amountMicrousd: String?

  public init(coverage: UsageCostCoverage, amountMicrousd: String?) {
    self.coverage = coverage
    self.amountMicrousd = coverage == .unavailable ? nil : amountMicrousd
  }

  /// Two outcomes of one model merged: amounts add; the result is complete only when both are,
  /// unavailable only when both are, and partial otherwise — the wire's own status rule.
  public static func + (lhs: Self, rhs: Self) -> Self {
    let coverage: UsageCostCoverage =
      switch (lhs.coverage, rhs.coverage) {
      case (.complete, .complete): .complete
      case (.unavailable, .unavailable): .unavailable
      default: .partial
      }
    guard coverage != .unavailable else {
      return ModelUsageCost(coverage: .unavailable, amountMicrousd: nil)
    }
    let sum = decimal(lhs.amountMicrousd) + decimal(rhs.amountMicrousd)
    return ModelUsageCost(
      coverage: coverage,
      amountMicrousd: NSDecimalNumber(decimal: sum).stringValue
    )
  }

  private static func decimal(_ microusd: String?) -> Decimal {
    microusd.flatMap { Decimal(string: $0, locale: Locale(identifier: "en_US_POSIX")) } ?? 0
  }
}

/// One leaf of a period's agent tree: what one agent sent to one model of one provider.
public struct ModelUsageLeaf<Agent: Hashable & Sendable>: Equatable, Sendable {
  public let agent: Agent
  public let key: ModelKey
  public let totals: ModelUsageTotals
  public let cost: ModelUsageCost

  public init(agent: Agent, key: ModelKey, totals: ModelUsageTotals, cost: ModelUsageCost) {
    self.agent = agent
    self.key = key
    self.totals = totals
    self.cost = cost
  }
}
