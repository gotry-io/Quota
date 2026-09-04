import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire

enum WidgetSnapshotProjection {
  static func make(summary: AccountSummary, fetchedAt: Date, salt: Data) -> WidgetSnapshot {
    let items = projectItems(from: summary.subscriptions, salt: salt)
    let today = WidgetTodayUsage(
      inputTokens: summary.usage.today.totals.inputTokens,
      outputTokens: summary.usage.today.totals.outputTokens,
      cost: mapCost(summary.usage.today.cost)
    )
    return WidgetSnapshot(fetchedAt: fetchedAt, items: items, today: today)
  }

  /// Relay resolves an account's readings into one row per subscription, so the widget ranks
  /// those rows rather than one card per reporting device.
  static func projectItems(from subscriptions: [QuotaSubscription], salt: Data) -> [WidgetQuotaItem]
  {
    let candidates = subscriptions.flatMap { subscription in
      let selectionID = selectionID(for: subscription, salt: salt)
      return subscription.snapshot.windows.map { window in
        WidgetSnapshotCandidate(
          snapshot: subscription.snapshot,
          window: window,
          providerID: subscription.snapshot.provider.rawValue,
          fingerprint: subscription.snapshot.account.fingerprint,
          sourceID: subscription.key,
          windowID: window.id,
          selectionID: selectionID
        )
      }
    }

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
    if lhs.sourceID != rhs.sourceID {
      return lhs.sourceID < rhs.sourceID
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
    if lhs.sourceID != rhs.sourceID {
      return lhs.sourceID < rhs.sourceID
    }
    return lhs.windowID < rhs.windowID
  }

  private static func providerSortOrder(_ providerID: String) -> Int {
    ProviderID(rawValue: providerID)?.sortOrder ?? Int.max
  }

  /// `SHA-256(selector ‖ "|" ‖ salt)` truncated to twelve lowercase hex characters.
  static func selectionID(for subscription: QuotaSubscription, salt: Data) -> String {
    SelectionIDs.make(selector: selector(for: subscription), salt: salt)
  }

  static func selector(for subscription: QuotaSubscription) -> String {
    SubscriptionSelector.make(
      provider: subscription.snapshot.provider.rawValue,
      fingerprint: subscription.snapshot.account.fingerprint,
      fingerprintScope: subscription.snapshot.account.fingerprintScope.rawValue,
      sourceID: selectorSourceID(from: subscription)
    )
  }

  /// The resolved key is `provider|fingerprint|scope|source_id`; none of the four parts
  /// contain `|`. Global subscriptions carry an empty source id.
  private static func selectorSourceID(from subscription: QuotaSubscription) -> String? {
    guard subscription.snapshot.account.fingerprintScope == .source else { return nil }
    let parts = subscription.key.split(
      separator: "|",
      maxSplits: 3,
      omittingEmptySubsequences: false
    )
    guard parts.count == 4 else { return nil }
    let value = String(parts[3])
    return value.isEmpty ? nil : value
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

/// Hidden ranking carrier. Fingerprint, source id, and window id exist only for deterministic sort
/// and are never written into `WidgetQuotaItem` / App Group storage.
private struct WidgetSnapshotCandidate {
  var snapshot: QuotaSnapshot
  var window: QuotaWindow
  var providerID: String
  var fingerprint: String
  var sourceID: String
  var windowID: String
  var selectionID: String

  var isBalanceOnly: Bool {
    RemainingQuotaFormat.isBalanceOnly(
      remainingValue: window.remainingValue,
      hasLimit: window.limitValue != nil
    )
  }

  var remainingPercent: Double {
    window.remainingPercent
  }

  var windowTitle: String {
    RemainingQuotaFormat.windowTitle(window.title, isBalanceOnly: isBalanceOnly)
  }

  var item: WidgetQuotaItem {
    let hasLimit = window.limitValue != nil
    let provider = snapshot.provider
    return WidgetQuotaItem(
      selectionID: selectionID,
      providerID: provider.rawValue,
      providerDisplayName: provider.displayName,
      windowTitle: windowTitle,
      remainingPercent: remainingPercent,
      remainingValue: window.remainingValue,
      unit: window.valueUnit.flatMap(mapUnit),
      hasLimit: hasLimit,
      resetsAt: window.resetsAt,
      state: WidgetQuotaState(snapshot.reportedState),
      validUntil: snapshot.validUntil
    )
  }

  /// `nil` for a unit this build cannot name; the widget then shows the number without one.
  private func mapUnit(_ unit: QuotaValueUnit) -> WidgetQuotaUnit? {
    switch unit {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    case .unknown: nil
    }
  }
}
