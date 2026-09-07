import Foundation
import QuotaPresentation
import QuotaWidgetData

/// Pure widget read/format helpers shared by the extension and app tests.
/// No network, Keychain, Security, or account types.
public enum OverviewWidgetContent {
  /// The scheme the app on this platform answers: Quota's is `io.gotry.quota:`, QuotaBar's is
  /// `quotabar:`. The paths behind them are the same two.
  #if os(macOS)
    public static let urlScheme = "quotabar"
  #else
    public static let urlScheme = "io.gotry.quota"
  #endif
  public static let overviewURL = URL(string: "\(urlScheme):/overview")!
  public static let refreshInterval: TimeInterval = 15 * 60
  public static let smallWindowLimit = 2
  public static let mediumProviderLimit = 3
  public static let largeProviderLimit = 3
  public static let largeWindowsPerProvider = 2
  /// Live `Text(timerInterval:)` is only for a refill still under a day away.
  public static let liveResetCountdownLimit: TimeInterval = 86_400

  /// Per-item deep link. The widget as a whole (medium/large with several items) still
  /// opens `overviewURL`.
  public static func subscriptionURL(for item: WidgetQuotaItem) -> URL {
    URL(string: "\(urlScheme):/subscriptions/\(item.selectionID)")!
  }

  /// One subscription (possibly several of its windows) opens that subscription;
  /// several subscriptions keep Overview.
  public static func widgetURL(for items: [WidgetQuotaItem]) -> URL {
    let ids = Set(items.map(\.selectionID))
    if ids.count == 1, let item = items.first {
      return subscriptionURL(for: item)
    }
    return overviewURL
  }

  public static func loadSnapshot(
    containerURL: URL? = WidgetAppGroup.containerURL()
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

  public static func nextRefreshDate(from now: Date = Date()) -> Date {
    now.addingTimeInterval(refreshInterval)
  }

  /// Automatic (`nil` or an id the snapshot no longer carries) keeps the ranked list.
  /// A known `selection_id` keeps every window of that subscription.
  public static func select(
    items: [WidgetQuotaItem],
    configuredSelectionID: String?
  ) -> [WidgetQuotaItem] {
    guard let configuredSelectionID else { return items }
    let matches = items.filter { $0.selectionID == configuredSelectionID }
    return matches.isEmpty ? items : matches
  }

  public static func primaryItem(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> WidgetQuotaItem? {
    select(items: snapshot?.items ?? [], configuredSelectionID: configuredSelectionID).first
  }

  /// One subscription, shortest cadence first, up to two windows.
  public static func smallItems(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetQuotaItem] {
    let selected = select(
      items: snapshot?.items ?? [],
      configuredSelectionID: configuredSelectionID
    )
    guard let first = selected.first else { return [] }
    let sameSubscription = selected.filter { $0.selectionID == first.selectionID }
    return Array(sortedWindows(sameSubscription).prefix(smallWindowLimit))
  }

  /// Automatic: one row per provider, most constrained window, up to three.
  /// A configured subscription: that subscription's windows, shortest first.
  public static func mediumItems(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetQuotaItem] {
    let selected = select(
      items: snapshot?.items ?? [],
      configuredSelectionID: configuredSelectionID
    )
    if let configuredSelectionID,
      selected.contains(where: { $0.selectionID == configuredSelectionID })
    {
      return Array(sortedWindows(selected).prefix(smallWindowLimit))
    }
    return uniqueProviderHeads(selected, limit: mediumProviderLimit)
  }

  public static func largeProviderGroups(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetProviderGroup] {
    let selected = select(
      items: snapshot?.items ?? [],
      configuredSelectionID: configuredSelectionID
    )
    var order: [String] = []
    var buckets: [String: [WidgetQuotaItem]] = [:]
    for item in selected {
      if buckets[item.providerID] == nil {
        order.append(item.providerID)
      }
      buckets[item.providerID, default: []].append(item)
    }
    return order.prefix(largeProviderLimit).compactMap { providerID in
      let items = Array(
        sortedWindows(buckets[providerID] ?? []).prefix(largeWindowsPerProvider)
      )
      guard let head = items.first else { return nil }
      return WidgetProviderGroup(
        providerID: providerID,
        providerDisplayName: head.providerDisplayName,
        items: items
      )
    }
  }

  public static func largeItems(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> [WidgetQuotaItem] {
    largeProviderGroups(
      from: snapshot,
      configuredSelectionID: configuredSelectionID
    ).flatMap(\.items)
  }

  /// Weekly window of the focused subscription; otherwise that subscription's first window.
  public static func lockScreenWeeklyItem(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> WidgetQuotaItem? {
    let windows = smallItems(
      from: snapshot,
      configuredSelectionID: configuredSelectionID
    )
    return windows.first(where: { isWeeklyWindow($0) }) ?? windows.first
  }

  /// The other window of the same subscription, for the Lock Screen rectangular family.
  public static func lockScreenSecondItem(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> WidgetQuotaItem? {
    let weekly = lockScreenWeeklyItem(
      from: snapshot,
      configuredSelectionID: configuredSelectionID
    )
    let windows = smallItems(
      from: snapshot,
      configuredSelectionID: configuredSelectionID
    )
    return windows.first(where: { $0.windowTitle != weekly?.windowTitle })
  }

  /// The Lock Screen families are one tap target: the focused subscription, or Overview.
  public static func lockScreenURL(
    from snapshot: WidgetSnapshot?,
    configuredSelectionID: String? = nil
  ) -> URL {
    lockScreenWeeklyItem(
      from: snapshot,
      configuredSelectionID: configuredSelectionID
    ).map(subscriptionURL(for:)) ?? overviewURL
  }

  public static func remainingLabel(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.remaining(
      remainingPercent: item.remainingPercent,
      remainingValue: item.remainingValue,
      limitValue: item.limitValue,
      hasLimit: item.hasLimit == true,
      unit: remainingUnit(item.unit)
    )
  }

  public static func remainingAccessibility(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.remainingAccessibility(
      windowTitle: item.windowTitle,
      remainingLabel: remainingLabel(for: item),
      isBalanceOnly: isBalanceOnly(item)
    )
  }

  public static func isBalanceOnly(_ item: WidgetQuotaItem) -> Bool {
    RemainingQuotaFormat.isBalanceOnly(
      remainingValue: item.remainingValue,
      hasLimit: item.hasLimit == true
    )
  }

  public static func showsPercentMeter(_ item: WidgetQuotaItem) -> Bool {
    RemainingQuotaFormat.showsPercentMeter(
      remainingPercent: item.remainingPercent,
      remainingValue: item.remainingValue,
      limitValue: item.limitValue,
      hasLimit: item.hasLimit == true,
      unit: remainingUnit(item.unit)
    )
  }

  public static func percentLabel(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.percent(item.remainingPercent)
  }

  public static func usedPercentLabel(for item: WidgetQuotaItem) -> String {
    RemainingQuotaFormat.percent(item.usedPercent)
  }

  /// Lock Screen inline: `Weekly 29%` plus a static reset when the refill is a day or more away.
  public static func inlineLabel(for item: WidgetQuotaItem, now: Date = Date()) -> String {
    var parts = ["\(item.windowTitle) \(usedPercentLabel(for: item))"]
    if let resetsAt = item.resetsAt,
      !usesLiveResetCountdown(resetsAt: resetsAt, now: now),
      let reset = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now)
    {
      parts.append(reset)
    }
    return parts.joined(separator: " · ")
  }

  public static func usedAccessibility(for item: WidgetQuotaItem) -> String {
    "\(item.windowTitle), \(usedPercentLabel(for: item)) used"
  }

  public static func paceRunsOut(_ item: WidgetQuotaItem) -> Bool {
    item.pace?.isRunsOut == true
  }

  public static func isWeeklyWindow(_ item: WidgetQuotaItem) -> Bool {
    item.windowTitle.caseInsensitiveCompare("Weekly") == .orderedSame
  }

  /// The whole phrase, so a widget says how old its reading is exactly the way the app does.
  public static func updated(fetchedAt: Date, now: Date = Date()) -> String {
    FreshnessCopy.updated(since: fetchedAt, now: now)
  }

  /// System-ticking countdown when the refill is still under a day away.
  public static func usesLiveResetCountdown(resetsAt: Date, now: Date) -> Bool {
    let seconds = resetsAt.timeIntervalSince(now)
    return seconds > 0 && seconds < liveResetCountdownLimit
  }

  public static func todayTokensLabel(input: Int, output: Int) -> String {
    "\(CompactCountFormat.compact(input)) in · \(CompactCountFormat.compact(output)) out"
  }

  public static func todayTokensAccessibility(input: Int, output: Int) -> String {
    "\(CompactCountFormat.accessible(input)) input tokens, \(CompactCountFormat.accessible(output)) output tokens"
  }

  public static func costLabel(for cost: WidgetCost) -> String {
    UsageCostFormat.compact(
      status: coverage(cost.status),
      amountMicrousd: cost.amountMicrousd
    )
  }

  public static func costAccessibility(for cost: WidgetCost) -> String {
    UsageCostFormat.accessible(
      status: coverage(cost.status),
      amountMicrousd: cost.amountMicrousd
    )
  }

  public static func itemAccessibility(
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

  public static func sortedWindows(_ items: [WidgetQuotaItem]) -> [WidgetQuotaItem] {
    items.sorted { lhs, rhs in
      switch (cadenceKind(for: lhs.windowTitle), cadenceKind(for: rhs.windowTitle)) {
      case (let left?, let right?) where left != right:
        return left < right
      case (_?, nil):
        return true
      case (nil, _?):
        return false
      default:
        if lhs.remainingPercent != rhs.remainingPercent {
          return lhs.remainingPercent < rhs.remainingPercent
        }
        return lhs.windowTitle < rhs.windowTitle
      }
    }
  }

  private static func uniqueProviderHeads(
    _ items: [WidgetQuotaItem],
    limit: Int
  ) -> [WidgetQuotaItem] {
    var seen = Set<String>()
    var result: [WidgetQuotaItem] = []
    for item in items {
      if seen.insert(item.providerID).inserted {
        result.append(item)
      }
      if result.count == limit { break }
    }
    return result
  }

  private static func cadenceKind(for title: String) -> PrimaryCadenceKind? {
    switch title.lowercased() {
    case "5 hours", "5 hour", "5h": .fiveHour
    case "weekly": .weekly
    case "monthly": .monthly
    default: nil
    }
  }
}

public struct WidgetProviderGroup: Equatable, Sendable {
  public var providerID: String
  public var providerDisplayName: String
  public var items: [WidgetQuotaItem]

  public init(providerID: String, providerDisplayName: String, items: [WidgetQuotaItem]) {
    self.providerID = providerID
    self.providerDisplayName = providerDisplayName
    self.items = items
  }
}
