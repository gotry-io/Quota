import Foundation

// The model ledger (`docs/design.md` Model ledger): a period's agent tree folded into one row per
// model, names merged across agents, largest first, with each row's change of share against the
// previous period.
//
// Public API:
// - `ModelShareChange` — `.points(n)` or `.new`.
// - `ModelLedgerRow<Agent>` — one model's merged totals, share, cache hit, cost, agents, change.
// - `ModelLedger.rows(_:previous:)` — the fold.

/// How a model's share of the period moved against the previous period.
public enum ModelShareChange: Equatable, Sendable {
  /// Percentage points of the period's tokens, rounded half away from zero: `+4` prints
  /// **↑ 4 pts**. Zero is a stated no-change.
  case points(Int)
  /// The previous period had Usage, but none on this model.
  case new
}

/// One model of a period, merged across the agents that used it.
public struct ModelLedgerRow<Agent: Hashable & Sendable>: Equatable, Sendable {
  public let key: ModelKey
  public let totals: ModelUsageTotals
  public let cost: ModelUsageCost
  /// This model's tokens over the period's, 0…1; 0 when the period has no tokens.
  public let share: Double
  /// Cache read over input, in basis points; nil when the model had no input.
  public let cacheHitBasisPoints: Int?
  /// The agents that sent this model tokens, most tokens first.
  public let agents: [Agent]
  /// Nil when there is nothing to compare against: no previous period was given, or it had no
  /// Usage at all (every model would otherwise read as new).
  public let shareChange: ModelShareChange?

  public init(
    key: ModelKey,
    totals: ModelUsageTotals,
    cost: ModelUsageCost,
    share: Double,
    cacheHitBasisPoints: Int?,
    agents: [Agent],
    shareChange: ModelShareChange?
  ) {
    self.key = key
    self.totals = totals
    self.cost = cost
    self.share = share
    self.cacheHitBasisPoints = cacheHitBasisPoints
    self.agents = agents
    self.shareChange = shareChange
  }
}

public enum ModelLedger {
  /// Folds a period's leaves into one row per ``ModelKey``, sorted by total tokens (ties by model
  /// name, then family), and states each row's share change against `previous`, the previous
  /// period's leaves of the same length.
  public static func rows<Agent>(
    _ leaves: [ModelUsageLeaf<Agent>],
    previous: [ModelUsageLeaf<Agent>]? = nil
  ) -> [ModelLedgerRow<Agent>] {
    let current = merge(leaves)
    let total = current.values.reduce(0) { $0 + $1.totals.totalTokens }
    let before = previous.map(merge)
    let beforeTotal = before?.values.reduce(0) { $0 + $1.totals.totalTokens } ?? 0

    let rows = current.map { key, merged in
      let share = total > 0 ? Double(merged.totals.totalTokens) / Double(total) : 0
      var change: ModelShareChange?
      if let before, beforeTotal > 0 {
        let tokensBefore = before[key]?.totals.totalTokens ?? 0
        change =
          tokensBefore == 0
          ? .new
          : .points(Int(((share - Double(tokensBefore) / Double(beforeTotal)) * 100).rounded()))
      }
      return ModelLedgerRow(
        key: key,
        totals: merged.totals,
        cost: merged.cost,
        share: share,
        cacheHitBasisPoints: merged.totals.cacheHitBasisPoints,
        agents: merged.agentTokens.sorted { $0.value > $1.value }.map(\.key),
        shareChange: change
      )
    }
    return rows.sorted { left, right in
      if left.totals.totalTokens != right.totals.totalTokens {
        return left.totals.totalTokens > right.totals.totalTokens
      }
      if left.key.model != right.key.model { return left.key.model < right.key.model }
      return left.key.family.rawValue < right.key.family.rawValue
    }
  }

  private struct Merged<Agent: Hashable> {
    var totals: ModelUsageTotals
    var cost: ModelUsageCost
    var agentTokens: [(key: Agent, value: Int)]
  }

  private static func merge<Agent>(_ leaves: [ModelUsageLeaf<Agent>]) -> [ModelKey: Merged<Agent>] {
    var merged: [ModelKey: Merged<Agent>] = [:]
    for leaf in leaves {
      guard var row = merged[leaf.key] else {
        merged[leaf.key] = Merged(
          totals: leaf.totals,
          cost: leaf.cost,
          agentTokens: [(leaf.agent, leaf.totals.totalTokens)]
        )
        continue
      }
      row.totals = row.totals + leaf.totals
      row.cost = row.cost + leaf.cost
      if let index = row.agentTokens.firstIndex(where: { $0.key == leaf.agent }) {
        row.agentTokens[index].value += leaf.totals.totalTokens
      } else {
        row.agentTokens.append((leaf.agent, leaf.totals.totalTokens))
      }
      merged[leaf.key] = row
    }
    return merged
  }
}
