import Foundation
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWire

/// Quota's side of the shared projection: it names each Account subscription with this
/// installation's salted `selection_id`, and the shared rule in `QuotaWidgetProjection` ranks
/// and words the readings the same way QuotaBar does.
extension WidgetSnapshotProjection {
  static func make(
    subscriptions: [QuotaSubscription],
    today: UsagePeriod?,
    fetchedAt: Date,
    salt: Data
  ) -> WidgetSnapshot {
    make(
      subscriptions: subscriptions.map { projection(for: $0, salt: salt) },
      today: today.map { todayUsage(totals: $0.totals, cost: $0.cost) },
      fetchedAt: fetchedAt
    )
  }

  static func projectItems(
    from subscriptions: [QuotaSubscription],
    salt: Data,
    now: Date
  ) -> [WidgetQuotaItem] {
    projectItems(from: subscriptions.map { projection(for: $0, salt: salt) }, now: now)
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

  private static func projection(
    for subscription: QuotaSubscription,
    salt: Data
  ) -> WidgetProjectionSubscription {
    WidgetProjectionSubscription(
      snapshot: subscription.snapshot,
      selectionID: selectionID(for: subscription, salt: salt),
      sourceKey: subscription.key
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
}
