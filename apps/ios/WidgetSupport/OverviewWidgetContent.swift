import Foundation
import QuotaPresentation
import QuotaWidgetData

/// Pure widget read/format helpers shared by the extension and app tests.
/// No network, Keychain, Security, or account types.
enum OverviewWidgetContent {
  static let appGroupIdentifier = "group.io.gotry.quota"
  static let widgetKind = "io.gotry.quota.overview"
  static let overviewURL = URL(string: "io.gotry.quota:/overview")!
  static let refreshInterval: TimeInterval = 15 * 60
  static let mediumItemLimit = 2
  static let largeItemLimit = 6
  /// Live `Text(timerInterval:)` is only for a refill still under a day away.
  static let liveResetCountdownLimit: TimeInterval = 86_400

  /// Per-item deep link. The widget as a whole (medium/large with several items) still
  /// opens `overviewURL`.
  static func subscriptionURL(for item: WidgetQuotaItem) -> URL {
    URL(string: "io.gotry.quota:/subscriptions/\(item.selectionID)")!
  }

  /// A single visible item opens its subscription; several items keep Overview.
  static func widgetURL(for items: [WidgetQuotaItem]) -> URL {
    if items.count == 1, let item = items.first {
      return subscriptionURL(for: item)
    }
    return overviewURL
  }

  static func loadSnapshot(
    containerURL: URL? = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdentifier
    )
  ) -> WidgetSnapshot? {
    guard let containerURL else { return nil }
    let store = ProtectedFileWidgetSnapshotStore(directory: containerURL)
    do {
      return try store.load()
    } catch {
      // Corrupt, oversize, or unreadable snapshots degrade to no-data.
      return nil
    }
  }

  static func nextRefreshDate(from now: Date = Date()) -> Date {
    now.addingTimeInterval(refreshInterval)
  }

  /// Automatic (`nil` or an id the snapshot no longer carries) keeps the ranked list.
  /// A known `selection_id` keeps every window of that subscription.
  static func select(
    items: [WidgetQuotaItem],
    configuredSelectionID: String?
  ) -> [WidgetQuotaItem] {
    guard let configuredSelectionID else { return items }
    let matches = items.filter { $0.selectionID == configuredSelectionID }
    return matches.isEmpty ? items : matches
  }

  static func primaryItem(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> WidgetQuotaItem? {
    select(items: snapshot?.items ?? [], configuredSelectionID: configuredSelectionID).first
  }

  static func mediumItems(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetQuotaItem] {
    Array(
      select(items: snapshot?.items ?? [], configuredSelectionID: configuredSelectionID)
        .prefix(mediumItemLimit)
    )
  }

  static func largeItems(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetQuotaItem] {
    Array(
      select(items: snapshot?.items ?? [], configuredSelectionID: configuredSelectionID)
        .prefix(largeItemLimit)
    )
  }

  static func remainingLabel(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.remaining(
      remainingPercent: item.remainingPercent,
      remainingValue: item.remainingValue,
      hasLimit: item.hasLimit == true,
      unit: remainingUnit(item.unit)
    )
  }

  static func remainingAccessibility(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.remainingAccessibility(
      windowTitle: item.windowTitle,
      remainingLabel: remainingLabel(for: item),
      isBalanceOnly: isBalanceOnly(item)
    )
  }

  static func isBalanceOnly(_ item: WidgetQuotaItem) -> Bool {
    RemainingQuotaFormat.isBalanceOnly(
      remainingValue: item.remainingValue,
      hasLimit: item.hasLimit == true
    )
  }

  static func percentLabel(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.percent(item.remainingPercent)
  }

  /// Lock Screen inline: `<Provider> <remaining>%`.
  static func inlineLabel(for item: WidgetQuotaItem) -> String {
    "\(item.providerDisplayName) \(percentLabel(for: item))"
  }

  /// The whole phrase, so a widget says how old its reading is exactly the way the app does.
  static func updated(fetchedAt: Date, now: Date = Date()) -> String {
    FreshnessCopy.updated(since: fetchedAt, now: now)
  }

  /// System-ticking countdown when the refill is still under a day away.
  static func usesLiveResetCountdown(resetsAt: Date, now: Date) -> Bool {
    let seconds = resetsAt.timeIntervalSince(now)
    return seconds > 0 && seconds < liveResetCountdownLimit
  }

  static func todayTokensLabel(input: Int, output: Int) -> String {
    "\(CompactCountFormat.compact(input)) in · \(CompactCountFormat.compact(output)) out"
  }

  static func todayTokensAccessibility(input: Int, output: Int) -> String {
    "\(CompactCountFormat.accessible(input)) input tokens, \(CompactCountFormat.accessible(output)) output tokens"
  }

  static func costLabel(for cost: WidgetCost) -> String {
    UsageCostFormat.compact(
      status: coverage(cost.status),
      amountMicrousd: cost.amountMicrousd
    )
  }

  static func costAccessibility(for cost: WidgetCost) -> String {
    UsageCostFormat.accessible(
      status: coverage(cost.status),
      amountMicrousd: cost.amountMicrousd
    )
  }

  static func itemAccessibility(
    item: WidgetQuotaItem,
    fetchedAt: Date?,
    now: Date = Date()
  ) -> String {
    var parts = [
      item.providerDisplayName,
      remainingAccessibility(for: item),
    ]
    if let state = item.stateLabel(now: now) {
      parts.append(state)
    }
    if let resetsAt = item.resetsAt,
      let reset = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now)
    {
      parts.append(reset)
    }
    if let fetchedAt {
      parts.append(updated(fetchedAt: fetchedAt, now: now))
    }
    return parts.joined(separator: ", ")
  }

  private static func remainingUnit(_ unit: WidgetQuotaUnit?) -> RemainingQuotaUnit? {
    switch unit {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    case nil: nil
    }
  }

  private static func coverage(_ status: WidgetCostStatus) -> UsageCostCoverage {
    switch status {
    case .complete: .complete
    case .partial: .partial
    case .unavailable: .unavailable
    }
  }
}
