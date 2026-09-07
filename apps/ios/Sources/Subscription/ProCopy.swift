import Foundation
import QuotaAccount
import QuotaWire

/// Every word the Quota Pro Settings group and the paywall say.
///
/// Status copy is derived from the Relay `entitlement`, never from the store SDK: the boundary
/// that refuses a Device's write is the one this device quotes.
enum ProCopy {
  static let section = "Quota Pro"
  static let subscribeRow = "Get Quota Pro"
  static let manage = "Manage"
  static let restore = "Restore Purchases"
  static let redeemOfferCode = "Redeem Offer Code"
  static let lifetime = "Lifetime"
  static let terms = "Terms"
  static let privacy = "Privacy"
  static let paywallTitle = "Quota Pro"
  static let paywallSubtitle =
    "Quota Pro carries what your Macs collect to this iPhone, the website, and your widgets."
  static let benefits = [
    "Every Mac you run QuotaBar on reports into one Account.",
    "The website and your Home Screen widgets read that same account.",
    "Usage history and a year of Activity are kept for you.",
  ]
  static let unavailable = "Purchases unavailable in this build."
  static let offersFailed = "Couldn't load subscription options."
  static let retry = "Retry"
  static let purchaseFailed = "Couldn't complete the purchase. Try again."
  static let restoreFailed = "Couldn't restore purchases. Try again."
  static let pending = "Waiting for the App Store to confirm this purchase."
  /// Shown while Relay has not yet seen the webhook the purchase triggers.
  static let confirming = "Purchase complete. Turning sync on…"
  /// The same sentence Relay's own 402 is spoken as, so the banner and a refused write agree.
  static let offBanner = AccountClientError.subscriptionRequiredMessage
  static let sectionFooter =
    "Quota Pro is billed through the App Store and managed in your Apple Account."

  /// The Quota Pro status line for an entitlement Relay answered with, or nil when there is
  /// nothing bought yet and the group should offer the paywall instead.
  static func status(_ entitlement: AccountEntitlement) -> String? {
    switch entitlement.status {
    case .active:
      guard let expiresAt = entitlement.expiresAt else { return lifetime }
      return entitlement.willRenew
        ? "Active · renews \(date(expiresAt))"
        : "Expires \(date(expiresAt))"
    case .grace:
      return "Grace period"
    case .expired, .none, .unknown:
      return nil
    }
  }

  /// The button line for one plan: its price, and the trial that comes before it.
  static func offerDetail(_ offer: SubscriptionOffer) -> String {
    guard let days = offer.freeTrialDays else { return offer.displayPrice }
    return "\(days) days free, then \(offer.displayPrice)"
  }

  static func date(_ value: Date) -> String {
    value.formatted(.dateTime.year().month(.abbreviated).day())
  }
}
