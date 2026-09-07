import Foundation
import RevenueCat

/// The RevenueCat-backed store. The only file in Quota that imports the SDK.
///
/// The SDK is configured once, here, from the key this build was given. Purchases are bound to
/// the Quota Account id with `logIn`, so the `app_user_id` RevenueCat reports to Relay's webhook
/// is the same `accounts.id` Relay gates writes on. See
/// [ADR 0033](../../../../docs/decisions/0033-entitlement-is-read-from-revenuecat.md).
actor RevenueCatPurchases: PurchasesFacade {
  nonisolated let isConfigured = true

  /// Packages by store product id, kept from the last `offers()` so a purchase buys the package
  /// RevenueCat priced rather than a product looked up a second way.
  private var packages: [String: Package] = [:]

  /// The API key comes from `REVENUECAT_IOS_API_KEY` in the Info dictionary, which
  /// `Local.xcconfig` fills locally and the release workflow fills from a repository secret.
  /// A build without one gets `UnconfiguredPurchases` instead, so this initializer is only
  /// reached when there is a key to configure with.
  init(apiKey: String) {
    _ = Purchases.configure(withAPIKey: apiKey)
  }

  static func apiKey(bundle: Bundle = .main) -> String? {
    guard let value = bundle.object(forInfoDictionaryKey: "REVENUECAT_IOS_API_KEY") as? String
    else {
      return nil
    }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }

  func logIn(accountID: String) async {
    _ = try? await Purchases.shared.logIn(accountID)
  }

  func logOut() async {
    _ = try? await Purchases.shared.logOut()
  }

  func offers() async throws -> [SubscriptionOffer] {
    let offerings: Offerings
    do {
      offerings = try await Purchases.shared.offerings()
    } catch {
      throw SubscriptionError.storeFailure(error.localizedDescription)
    }
    guard let current = offerings.current else {
      throw SubscriptionError.offerUnavailable
    }
    var found: [String: Package] = [:]
    for package in current.availablePackages {
      found[package.storeProduct.productIdentifier] = package
    }
    packages = found
    let offers = SubscriptionTerm.allCases.compactMap { term in
      found[term.productID].map { Self.offer(term: term, product: $0.storeProduct) }
    }
    guard !offers.isEmpty else {
      throw SubscriptionError.offerUnavailable
    }
    return offers
  }

  func purchase(_ offer: SubscriptionOffer) async throws -> SubscriptionPurchaseOutcome {
    guard let package = packages[offer.productID] else {
      throw SubscriptionError.offerUnavailable
    }
    do {
      let result = try await Purchases.shared.purchase(package: package)
      if result.userCancelled { return .cancelled }
      return result.customerInfo.entitlements[Self.entitlementID]?.isActive == true
        ? .purchased
        : .pending
    } catch {
      throw SubscriptionError.storeFailure(error.localizedDescription)
    }
  }

  func restorePurchases() async throws {
    do {
      _ = try await Purchases.shared.restorePurchases()
    } catch {
      throw SubscriptionError.storeFailure(error.localizedDescription)
    }
  }

  func presentOfferCodeRedemption() async {
    await MainActor.run {
      Purchases.shared.presentCodeRedemptionSheet()
    }
  }

  nonisolated func customerChanges() -> AsyncStream<Void> {
    AsyncStream { continuation in
      let task = Task {
        for await _ in Purchases.shared.customerInfoStream {
          continuation.yield(())
        }
        continuation.finish()
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }

  /// The RevenueCat entitlement Quota Pro is sold as. Relay reads the same id.
  static let entitlementID = "pro"

  private static func offer(term: SubscriptionTerm, product: StoreProduct) -> SubscriptionOffer {
    SubscriptionOffer(
      term: term,
      productID: product.productIdentifier,
      displayPrice: product.localizedPriceString,
      freeTrialDays: freeTrialDays(product.introductoryDiscount)
    )
  }

  private static func freeTrialDays(_ discount: StoreProductDiscount?) -> Int? {
    guard let discount, discount.paymentMode == .freeTrial else { return nil }
    let period = discount.subscriptionPeriod
    let perUnit: Int
    switch period.unit {
    case .day: perUnit = 1
    case .week: perUnit = 7
    case .month: perUnit = 30
    case .year: perUnit = 365
    }
    return period.value * perUnit
  }
}
