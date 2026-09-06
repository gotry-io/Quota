import Foundation

/// One subscription, addressed the way [ADR 0003](../../../../docs/decisions/0003-observation-preserving-subscription-merge.md)
/// addresses it.
///
/// A `global` fingerprint identifies the same account wherever it was observed, so every source
/// that reported it resolves to one subscription. A `source` fingerprint means nothing outside the
/// source that produced it and therefore carries that source's identity.
public struct QuotaSubscriptionIdentity: Hashable, Sendable {
  public let provider: String
  public let fingerprint: String
  public let scope: String
  public let sourceID: String?

  public init(provider: String, fingerprint: String, scope: String, sourceID: String?) {
    self.provider = provider
    self.fingerprint = fingerprint
    self.scope = scope
    self.sourceID = sourceID
  }

  /// The stable name of this subscription.
  ///
  /// Relay sends this to every reader, so it is printable text rather than a delimiter nothing
  /// outside one process would accept. None of the four parts can contain `|`: a provider and a
  /// scope are enum members, and a fingerprint and a source identity are opaque ids.
  public var key: String {
    [provider, fingerprint, scope, sourceID ?? ""].joined(separator: "|")
  }

  /// The order every reader lists subscriptions in.
  static func isOrderedBefore(
    _ left: QuotaSubscriptionIdentity,
    _ right: QuotaSubscriptionIdentity
  ) -> Bool {
    if left.provider != right.provider { return left.provider < right.provider }
    if left.fingerprint != right.fingerprint { return left.fingerprint < right.fingerprint }
    if left.scope != right.scope { return left.scope < right.scope }
    return (left.sourceID ?? "") < (right.sourceID ?? "")
  }
}
