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

  /// Copy used when a reset instant is at or before `now` (avoids a misleading "0s").
  static let resetDueCopy = "now"

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

  static func primaryItem(from snapshot: WidgetSnapshot?) -> WidgetQuotaItem? {
    snapshot?.items.first
  }

  static func mediumItems(from snapshot: WidgetSnapshot?) -> [WidgetQuotaItem] {
    Array((snapshot?.items ?? []).prefix(2))
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

  static func updatedAge(fetchedAt: Date, now: Date = Date()) -> String {
    CompactAgeFormat.string(since: fetchedAt, now: now)
  }

  /// Relative time until reset, or `resetDueCopy` once the reset instant has passed.
  static func resetAge(resetsAt: Date, now: Date = Date()) -> String {
    if resetsAt <= now {
      return resetDueCopy
    }
    return CompactAgeFormat.string(since: now, now: resetsAt)
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
    if let resetsAt = item.resetsAt {
      parts.append("Resets \(resetAge(resetsAt: resetsAt, now: now))")
    }
    if item.isStale == true {
      parts.append("Stale")
    }
    if let fetchedAt {
      parts.append("Updated \(updatedAge(fetchedAt: fetchedAt, now: now))")
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
