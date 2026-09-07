import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWire

/// One subscription a client is willing to publish, already named by its locally salted
/// `selection_id`. `sourceKey` never leaves this file: it only breaks ranking ties.
public struct WidgetProjectionSubscription: Sendable {
  public var snapshot: QuotaSnapshot
  public var selectionID: String
  public var sourceKey: String

  public init(snapshot: QuotaSnapshot, selectionID: String, sourceKey: String) {
    self.snapshot = snapshot
    self.selectionID = selectionID
    self.sourceKey = sourceKey
  }
}

/// The one rule that turns resolved subscriptions into the App Group `WidgetSnapshot`, shared by
/// Quota on iOS and QuotaBar on macOS so both platforms rank and word the same readings the same
/// way. It lives beside the wire types rather than in `QuotaWidgetData` because it speaks
/// `QuotaSnapshot`, and the widget extensions must not link `QuotaWire`
/// ([ADR 0014](../../../../docs/decisions/0014-nonsecret-ios-widget-snapshot.md)).
public enum WidgetSnapshotProjection {
  /// The widget draws the merged readings, without distinguishing which device took them: a
  /// subscription this iPhone read for itself ranks beside one a Mac reported.
  ///
  /// Today Usage is what the publishing client can account for, so a client with none shows no
  /// usage rather than a zero it did not measure.
  public static func make(
    subscriptions: [WidgetProjectionSubscription],
    today: WidgetTodayUsage?,
    fetchedAt: Date
  ) -> WidgetSnapshot {
    WidgetSnapshot(
      fetchedAt: fetchedAt,
      items: projectItems(from: subscriptions, now: fetchedAt),
      today: today
        ?? WidgetTodayUsage(
          inputTokens: 0,
          outputTokens: 0,
          cost: WidgetCost(status: .unavailable, amountMicrousd: nil)
        )
    )
  }

  /// Every subscription reaches the widget as one row per window with its readings already
  /// resolved, so the widget ranks those rows rather than one card per reporting device.
  ///
  /// `now` is the instant the readings were fetched: pace is a rate read against the window
  /// elapsed at that moment, so the snapshot states the pace of what it carries rather than one
  /// the widget would have to recompute against its own clock.
  public static func projectItems(
    from subscriptions: [WidgetProjectionSubscription],
    now: Date
  ) -> [WidgetQuotaItem] {
    let candidates = subscriptions.flatMap { subscription in
      subscription.snapshot.windows.map { window in
        WidgetSnapshotCandidate(
          snapshot: subscription.snapshot,
          window: window,
          providerID: subscription.snapshot.provider.rawValue,
          fingerprint: subscription.snapshot.account.fingerprint,
          sourceID: subscription.sourceKey,
          windowID: window.id,
          selectionID: subscription.selectionID,
          now: now
        )
      }
    }

    let percentage = candidates.filter { !$0.isBalanceOnly }.sorted(by: percentageSort)
    let balanceOnly = candidates.filter(\.isBalanceOnly).sorted(by: balanceOnlySort)
    return Array((percentage + balanceOnly).prefix(WidgetSnapshot.maximumItemCount)).map(\.item)
  }

  /// The Today fold both clients publish, from the totals and cost they already hold.
  public static func todayUsage(
    totals: UsageSummaryTotals,
    cost: UsageCostOutcome
  ) -> WidgetTodayUsage {
    WidgetTodayUsage(
      inputTokens: totals.inputTokens,
      outputTokens: totals.outputTokens,
      cost: mapCost(cost)
    )
  }

  private static func percentageSort(
    _ lhs: WidgetSnapshotCandidate,
    _ rhs: WidgetSnapshotCandidate
  ) -> Bool {
    if lhs.remainingPercent != rhs.remainingPercent {
      return lhs.remainingPercent < rhs.remainingPercent
    }
    return tieBreak(lhs, rhs)
  }

  private static func balanceOnlySort(
    _ lhs: WidgetSnapshotCandidate,
    _ rhs: WidgetSnapshotCandidate
  ) -> Bool {
    tieBreak(lhs, rhs)
  }

  private static func tieBreak(
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
  var now: Date

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
      limitValue: window.limitValue,
      unit: window.valueUnit.flatMap(mapUnit),
      hasLimit: hasLimit,
      resetsAt: window.resetsAt,
      state: WidgetQuotaState(snapshot.reportedState),
      validUntil: snapshot.validUntil,
      pace: QuotaPace.evaluate(window.paceReading, now: now)
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
