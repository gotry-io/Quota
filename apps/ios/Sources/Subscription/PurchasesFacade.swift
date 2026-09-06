import Foundation

/// How often a Sync subscription bills. The paywall shows one row per term.
enum SubscriptionTerm: String, CaseIterable, Sendable {
  case monthly
  case yearly

  var title: String {
    switch self {
    case .monthly: "Monthly"
    case .yearly: "Yearly"
    }
  }

  /// The store product id this term is sold as. Also what `Quota.storekit` declares locally and
  /// what the RevenueCat Offering is built from.
  var productID: String {
    switch self {
    case .monthly: "quota_sync_monthly"
    case .yearly: "quota_sync_yearly"
    }
  }
}

/// One purchasable Sync plan, already localized by the store.
///
/// Prices are strings because the store formats them for the customer's storefront; the app
/// never composes a currency amount of its own.
struct SubscriptionOffer: Equatable, Identifiable, Sendable {
  let term: SubscriptionTerm
  let productID: String
  let displayPrice: String
  /// Days of free introductory access this customer is eligible for, when the store offers any.
  let freeTrialDays: Int?

  var id: String { productID }
}

/// What a purchase attempt ended as. A failure throws instead.
enum SubscriptionPurchaseOutcome: Equatable, Sendable {
  case purchased
  case pending
  case cancelled
}

/// The slice of the store SDK Quota uses.
///
/// It exists so views and tests never reach RevenueCat directly, and so a build without an API
/// key has something honest to be: `isConfigured` is false and every call refuses. Relay remains
/// the authority on what the Account is entitled to; this protocol only buys and restores.
protocol PurchasesFacade: Sendable {
  /// False when this build has no RevenueCat API key, which is every build that was not given one.
  var isConfigured: Bool { get }
  /// Binds purchases made from here to a Quota Account id.
  func logIn(accountID: String) async
  func logOut() async
  func offers() async throws -> [SubscriptionOffer]
  func purchase(_ offer: SubscriptionOffer) async throws -> SubscriptionPurchaseOutcome
  func restorePurchases() async throws
  /// One element each time the store's own view of this customer changes. Quota uses it only as
  /// a nudge to re-read Relay, which learns the same purchase from a RevenueCat webhook.
  func customerChanges() -> AsyncStream<Void>
}

/// The facade a build with no RevenueCat API key gets.
struct UnconfiguredPurchases: PurchasesFacade {
  let isConfigured = false

  func logIn(accountID: String) async {}
  func logOut() async {}

  func offers() async throws -> [SubscriptionOffer] { [] }

  func purchase(_ offer: SubscriptionOffer) async throws -> SubscriptionPurchaseOutcome {
    throw SubscriptionError.purchasesUnavailable
  }

  func restorePurchases() async throws {
    throw SubscriptionError.purchasesUnavailable
  }

  func customerChanges() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}

enum SubscriptionError: Error, Equatable {
  case purchasesUnavailable
  case offerUnavailable
  case storeFailure(String)
}
