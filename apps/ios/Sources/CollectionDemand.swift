import Foundation
import QuotaWire

/// When this phone asks the Account's Macs for a fresh reading, and when it stops waiting.
///
/// Someone opening the app is the demand
/// ([ADR 0063](../../../docs/decisions/0063-collection-follows-demand-and-activity.md)): on a cold
/// launch, a return to the foreground, or a pull to refresh, a subscription whose newest Mac
/// reading is older than ``staleAfter(_:)`` is worth one request. Only a Mac answers one, so only a
/// Mac's reading is judged, and never this phone's own. The phone then re-reads the summary
/// every 20 seconds for up to three minutes, and stops as soon as every subscription it asked
/// about has a Mac reading at or after the instant Relay stored.
struct CollectionDemand: Equatable, Sendable {
  /// Two minutes, or the provider's catalog floor when that is longer: a Mac does not ask a
  /// provider again inside its floor, so a younger reading is as fresh as a request could make it.
  static func staleAfter(_ provider: ProviderID) -> TimeInterval {
    max(2 * 60, provider.minCollectionInterval)
  }
  static let followUpInterval: Duration = .seconds(20)
  /// Three minutes of 20-second reads.
  static let followUpReads = 9

  /// The subscriptions whose newest Mac reading was stale when the request went out.
  let subscriptionKeys: Set<String>
  /// How many Macs those readings came from, which is what the subtitle names.
  let macCount: Int
  /// The instant Relay stored, which a Mac's reading has to reach.
  var requestedAt: Date?

  /// What is worth asking for in `summary` at `now`, or nil when every Mac reading is fresh.
  static func stale(
    in summary: AccountSummary,
    selfDeviceID: String?,
    now: Date
  ) -> CollectionDemand? {
    let macs = Set(summary.devices.filter { $0.platform == .macos }.map(\.id))
    var keys = Set<String>()
    var devices = Set<String>()
    for subscription in summary.subscriptions {
      guard let newest = newestMacSource(subscription, macs: macs, selfDeviceID: selfDeviceID),
        now.timeIntervalSince(newest.observedAt) > staleAfter(subscription.provider)
      else { continue }
      keys.insert(subscription.key)
      devices.insert(newest.deviceID)
    }
    guard !keys.isEmpty else { return nil }
    return CollectionDemand(subscriptionKeys: keys, macCount: devices.count, requestedAt: nil)
  }

  /// Whether every subscription asked about has a Mac reading at or after `requestedAt`. One
  /// that has left the Account has nothing left to wait for.
  func isAnswered(by summary: AccountSummary, selfDeviceID: String?) -> Bool {
    guard let requestedAt else { return false }
    let macs = Set(summary.devices.filter { $0.platform == .macos }.map(\.id))
    return summary.subscriptions.allSatisfy { subscription in
      guard subscriptionKeys.contains(subscription.key) else { return true }
      guard
        let newest = Self.newestMacSource(subscription, macs: macs, selfDeviceID: selfDeviceID)
      else { return true }
      return newest.observedAt >= requestedAt
    }
  }

  private static func newestMacSource(
    _ subscription: QuotaSubscription,
    macs: Set<String>,
    selfDeviceID: String?
  ) -> QuotaSubscriptionSource? {
    subscription.sources
      .filter { $0.deviceID != selfDeviceID && macs.contains($0.deviceID) }
      .max { $0.observedAt < $1.observedAt }
  }
}
