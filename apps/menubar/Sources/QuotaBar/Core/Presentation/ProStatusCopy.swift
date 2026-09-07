import Foundation
import QuotaPresentation

/// Every sentence QuotaBar says about Quota Pro.
///
/// Quota Pro is the one thing an account pays for, so the Account page states it where the
/// account is managed rather than interrupting the panel with a banner. The words are the ones
/// the website uses for the same entitlement, so a person reading both is told the same thing
/// twice, not two things once.
enum ProStatusCopy {
  static let title = "Quota Pro"
  static let notSubscribed = "Not active"
  static let grace = "Grace period · update payment"
  /// Before this Mac has read the account once there is nothing to state yet.
  static let unknown = "Checking…"
  static let subscribe = "Get Quota Pro…"
  static let manage = "Manage…"
  static let redeem = "Redeem a code…"
  static let lifetime = "Lifetime"
  /// Why the Sync Usage switch cannot be turned on.
  static let uploadNeedsSubscription = "Needs Quota Pro"

  /// The status line under **Quota Pro**, which is one line in a 320pt panel.
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
    return "\(name(entitlement)) · checked \(FreshnessCopy.age(since: checkedAt, now: now))"
  }

  /// The state on its own, for a line that has to spend its width on something else.
  private static func name(_ entitlement: LocalServiceEntitlement) -> String {
    switch entitlement.status {
    case .active: entitlement.expiresAt == nil ? lifetime : "Active"
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
      guard let expiresAt = entitlement.expiresAt else { return lifetime }
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
