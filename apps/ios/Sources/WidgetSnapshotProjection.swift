import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire

enum WidgetSnapshotProjection {
  static func make(summary: AccountSummary, fetchedAt: Date) -> WidgetSnapshot {
    let items = projectItems(from: summary.quota)
    let today = WidgetTodayUsage(
      inputTokens: summary.usage.totals.inputTokens,
      outputTokens: summary.usage.totals.outputTokens,
      cost: mapCost(summary.usage.cost)
    )
    return WidgetSnapshot(fetchedAt: fetchedAt, items: items, today: today)
  }

  static func projectItems(from observations: [AccountQuotaObservation]) -> [WidgetQuotaItem] {
    var newest: [String: WidgetSnapshotCandidate] = [:]
    for observation in observations {
      let provider = observation.snapshot.provider
      let fingerprint = observation.snapshot.account.fingerprint
      for window in observation.snapshot.windows {
        let key = "\(provider.rawValue)\u{1f}\(fingerprint)\u{1f}\(window.id)"
        if let existing = newest[key], existing.observation.updatedAt >= observation.updatedAt {
          continue
        }
        newest[key] = WidgetSnapshotCandidate(
          observation: observation,
          window: window,
          providerID: provider.rawValue,
          fingerprint: fingerprint,
          windowID: window.id
        )
      }
    }

    // Sort fully in memory (including fingerprint / window id tie-breaks) before mapping so
    // Dictionary iteration order cannot leak into the published snapshot.
    let candidates = Array(newest.values)
    let percentage = candidates.filter { !$0.isBalanceOnly }.sorted(by: percentageSort)
    let balanceOnly = candidates.filter(\.isBalanceOnly).sorted(by: balanceOnlySort)
    return Array((percentage + balanceOnly).prefix(WidgetSnapshot.maximumItemCount)).map(\.item)
  }

  private static func percentageSort(
    _ lhs: WidgetSnapshotCandidate,
    _ rhs: WidgetSnapshotCandidate
  ) -> Bool {
    if lhs.remainingPercent != rhs.remainingPercent {
      return lhs.remainingPercent < rhs.remainingPercent
    }
    let leftOrder = providerSortOrder(lhs.providerID)
    let rightOrder = providerSortOrder(rhs.providerID)
    if leftOrder != rightOrder {
      return leftOrder < rightOrder
    }
    if lhs.windowTitle != rhs.windowTitle {
      return lhs.windowTitle < rhs.windowTitle
    }
    if lhs.providerID != rhs.providerID {
      return lhs.providerID < rhs.providerID
    }
    if lhs.fingerprint != rhs.fingerprint {
      return lhs.fingerprint < rhs.fingerprint
    }
    return lhs.windowID < rhs.windowID
  }

  private static func balanceOnlySort(
    _ lhs: WidgetSnapshotCandidate,
    _ rhs: WidgetSnapshotCandidate
  ) -> Bool {
    let leftOrder = providerSortOrder(lhs.providerID)
    let rightOrder = providerSortOrder(rhs.providerID)
    if leftOrder != rightOrder {
      return leftOrder < rightOrder
    }
    if lhs.windowTitle != rhs.windowTitle {
      return lhs.windowTitle < rhs.windowTitle
    }
    if lhs.providerID != rhs.providerID {
      return lhs.providerID < rhs.providerID
    }
    if lhs.fingerprint != rhs.fingerprint {
      return lhs.fingerprint < rhs.fingerprint
    }
    return lhs.windowID < rhs.windowID
  }

  private static func providerSortOrder(_ providerID: String) -> Int {
    ProviderID(rawValue: providerID)?.sortOrder ?? Int.max
  }

  private static func mapCost(_ cost: UsageCostOutcome) -> WidgetCost {
    switch cost.status {
    case .complete:
      return WidgetCost(status: .complete, amountMicrousd: cost.amountMicrousd)
    case .partial:
      return WidgetCost(status: .partial, amountMicrousd: cost.amountMicrousd)
    case .unavailable:
      return WidgetCost(status: .unavailable, amountMicrousd: nil)
    }
  }
}

/// Hidden ranking carrier. Fingerprint and window id exist only for deterministic sort and are never
/// written into `WidgetQuotaItem` / App Group storage.
private struct WidgetSnapshotCandidate {
  var observation: AccountQuotaObservation
  var window: QuotaWindow
  var providerID: String
  var fingerprint: String
  var windowID: String

  var isBalanceOnly: Bool {
    RemainingQuotaFormat.isBalanceOnly(
      remainingValue: window.remainingValue,
      hasLimit: window.limitValue != nil
    )
  }

  var remainingPercent: Double {
    RemainingQuotaFormat.remainingPercent(usedPercent: window.usedPercent)
  }

  var windowTitle: String {
    RemainingQuotaFormat.windowTitle(window.title, isBalanceOnly: isBalanceOnly)
  }

  var item: WidgetQuotaItem {
    let hasLimit = window.limitValue != nil
    let provider = observation.snapshot.provider
    return WidgetQuotaItem(
      providerID: provider.rawValue,
      providerDisplayName: provider.displayName,
      windowTitle: windowTitle,
      remainingPercent: remainingPercent,
      remainingValue: window.remainingValue,
      unit: window.valueUnit.map(mapUnit),
      hasLimit: hasLimit,
      resetsAt: window.resetsAt,
      isAvailable: observation.snapshot.isAvailable,
      validUntil: observation.snapshot.validUntil
    )
  }

  private func mapUnit(_ unit: QuotaValueUnit) -> WidgetQuotaUnit {
    switch unit {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    }
  }
}
