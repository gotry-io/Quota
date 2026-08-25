import Foundation
import QuotaPresentation

/// The subscriptions behind an Account's quota observations.
///
/// Relay keeps one observation per reporting device, so an account that runs on three Macs
/// answers with three readings of one subscription. Every reader resolves them the same
/// way — ``QuotaSubscriptionMerge`` states the rule — and this is where the managed wire
/// type meets it, so no client restates the mapping.
public enum AccountQuotaSubscriptions {
  public static func resolve(
    _ observations: [AccountQuotaObservation],
    now: Date = Date()
  ) -> [QuotaSubscription<QuotaSnapshot>] {
    QuotaSubscriptionMerge.resolve(
      observations.map { observation in
        QuotaSubscriptionObservation(
          deviceID: observation.deviceID,
          provider: observation.snapshot.provider.rawValue,
          fingerprint: observation.snapshot.account.fingerprint,
          isSourceScoped: observation.snapshot.account.fingerprintScope == .source,
          observedAt: observation.snapshot.observedAt,
          reading: observation.snapshot
        )
      },
      now: now
    )
  }
}
