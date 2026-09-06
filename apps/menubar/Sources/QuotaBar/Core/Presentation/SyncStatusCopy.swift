import Foundation
import QuotaPresentation

/// Every sentence QuotaBar says about the paid sync subscription.
///
/// Sync is the one capability an account pays for, so the Account page states it where the
/// account is managed rather than interrupting the panel with a banner. The words are the ones
/// the website uses for the same entitlement, so a person reading both is told the same thing
/// twice, not two things once.
enum SyncStatusCopy {
  static let title = "Sync"
  static let notSubscribed = "Not subscribed"
  static let grace = "Grace period · update payment"
  /// Before this Mac has read the account once there is nothing to state yet.
  static let unknown = "Checking…"
  static let subscribe = "Subscribe…"
  static let manage = "Manage…"
  /// Why the Sync Usage switch cannot be turned on.
  static let uploadNeedsSubscription = "Needs a subscription"

  /// The status line under **Sync**, which is one line in a 320pt panel.
  ///
  /// A stale answer says when Relay last managed to check instead of the date it would renew:
  /// the values are that old, so the age is the fact worth the width, and an answer nobody
  /// could refresh has not earned a date a reader would act on.
  static func status(
    _ entitlement: LocalServiceEntitlement?,
    now: Date = Date(),
    timeZone: TimeZone = .current
  ) -> String {
    guard let entitlement else { return unknown }
    guard entitlement.stale, let checkedAt = entitlement.checkedAt else {
      return state(entitlement, timeZone: timeZone)
    }
    return "\(name(entitlement.status)) · checked \(FreshnessCopy.age(since: checkedAt, now: now))"
  }

  /// The state on its own, for a line that has to spend its width on something else.
  private static func name(_ status: LocalServiceEntitlementStatus) -> String {
    switch status {
    case .active: "Active"
    case .grace: "Grace period"
    case .expired, .none, .unknown: notSubscribed
    }
  }

  /// What the trailing button offers: buying it, or managing the one that exists.
  static func action(_ entitlement: LocalServiceEntitlement?) -> String {
    entitlement?.allowsSync == true ? manage : subscribe
  }

  private static func state(_ entitlement: LocalServiceEntitlement, timeZone: TimeZone) -> String {
    switch entitlement.status {
    case .grace:
      return grace
    case .active:
      guard let expiresAt = entitlement.expiresAt else { return "Active" }
      let verb = entitlement.willRenew ? "renews" : "ends"
      return "Active · \(verb) \(date(expiresAt, timeZone: timeZone))"
    case .expired, .none, .unknown:
      return notSubscribed
    }
  }

  private static func date(_ date: Date, timeZone: TimeZone) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "MMM d"
    return formatter.string(from: date)
  }
}
