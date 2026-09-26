import Foundation
import QuotaPresentation

// The wire's Usage trees read as the shared model-usage vocabulary in QuotaPresentation, so
// `ModelColorAssignment`, `ModelLedger`, and a series legend name a model the same way.
//
// Public API:
// - `InferenceProvider.modelFamily`, `UsageModelSeriesEntry.modelFamily`
// - `UsageSummaryTotals.modelUsageTotals`, `UsageCostOutcome.modelUsageCost`
// - `[UsageAgentUsage].modelLeaves` (Account period or summary tree)
// - `[LocalUsageAgentSummary].modelLeaves` (this Mac's tree)

extension InferenceProvider {
  /// The colour family of this provider's models. The two vocabularies are one for one.
  public var modelFamily: ModelFamily { ModelFamily(rawValue: rawValue) ?? .unknown }
}

extension UsageModelSeriesEntry {
  /// Nil only for the folded `other` series, which spans providers.
  public var modelFamily: ModelFamily? { provider?.modelFamily }
}

extension UsageSummaryTotals {
  public var modelUsageTotals: ModelUsageTotals {
    ModelUsageTotals(
      totalTokens: totalTokens,
      inputTokens: inputTokens,
      outputTokens: outputTokens,
      cacheReadInputTokens: cacheReadInputTokens,
      cacheWriteInputTokens: cacheWriteInputTokens,
      messages: messages
    )
  }
}

extension UsageCostOutcome {
  public var modelUsageCost: ModelUsageCost {
    ModelUsageCost(coverage: UsageCostCoverage(status), amountMicrousd: amountMicrousd)
  }
}

extension Array where Element == UsageAgentUsage {
  /// Every (agent, provider, model) leaf of an Account tree, in tree order.
  public var modelLeaves: [ModelUsageLeaf<BillingAgent>] {
    flatMap { agent in
      agent.providers.flatMap { provider in
        provider.models.map { model in
          ModelUsageLeaf(
            agent: agent.agent,
            key: ModelKey(family: provider.provider.modelFamily, model: model.model),
            totals: model.totals.modelUsageTotals,
            cost: model.cost.modelUsageCost
          )
        }
      }
    }
  }
}

extension Array where Element == LocalUsageAgentSummary {
  /// Every (agent, provider, model) leaf of this Mac's tree, in tree order.
  public var modelLeaves: [ModelUsageLeaf<BillingAgent>] {
    flatMap { agent in
      agent.providers.flatMap { provider in
        provider.models.map { model in
          ModelUsageLeaf(
            agent: agent.agent,
            key: ModelKey(family: provider.provider.modelFamily, model: model.model),
            totals: model.totals.modelUsageTotals,
            cost: model.cost.modelUsageCost
          )
        }
      }
    }
  }
}

/// A window names its reset, so the shared next-resets grouping reads it directly.
extension QuotaWindow: ResettingQuotaWindow {}
