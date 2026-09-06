import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct SubscriptionTests {
  @Test
  func syncStatusIsSpokenFromTheRelayEntitlement() {
    let expires = Fixtures.date("2026-09-14T12:00:00Z")
    #expect(
      SyncCopy.status(entitlement(.active, expiresAt: expires, willRenew: true))
        == "Active · renews \(SyncCopy.date(expires))")
    #expect(
      SyncCopy.status(entitlement(.active, expiresAt: expires, willRenew: false))
        == "Expires \(SyncCopy.date(expires))")
    #expect(SyncCopy.status(entitlement(.active, expiresAt: nil, willRenew: true)) == "Active")
    #expect(SyncCopy.status(entitlement(.grace, expiresAt: expires, willRenew: true)) == "Grace period")
    // Nothing bought, and a status this build cannot name, both offer the paywall instead.
    #expect(SyncCopy.status(.unsubscribed) == nil)
    #expect(SyncCopy.status(entitlement(.expired, expiresAt: expires, willRenew: false)) == nil)
    #expect(SyncCopy.status(entitlement(.unknown, expiresAt: nil, willRenew: false)) == nil)
  }

  @Test
  func onlyActiveAndGraceAllowSync() {
    #expect(EntitlementStatus.active.allowsSync)
    #expect(EntitlementStatus.grace.allowsSync)
    #expect(EntitlementStatus.expired.allowsSync == false)
    #expect(EntitlementStatus.none.allowsSync == false)
    #expect(EntitlementStatus.unknown.allowsSync == false)
  }

  @Test
  func offerDetailNamesTheTrialBeforeThePrice() {
    #expect(
      SyncCopy.offerDetail(offer(.monthly, trialDays: 7)) == "7 days free, then $2.99")
    #expect(SyncCopy.offerDetail(offer(.monthly, trialDays: nil)) == "$2.99")
  }

  @Test
  func aSignedInAccountWithoutSyncGetsTheOverviewBanner() async throws {
    let model = try await signedInModel(status: "none")
    #expect(model.isSyncOn == false)
    #expect(model.syncBanner == SyncCopy.offBanner)
  }

  @Test
  func graceIsStillSyncOnAndShowsNoBanner() async throws {
    let model = try await signedInModel(status: "grace")
    #expect(model.isSyncOn)
    #expect(model.syncBanner == nil)
  }

  @Test
  func aSignedOutModelHasNoSyncBanner() async {
    let model = AppModel(
      account: client(exchanges: []),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled))
    )
    await model.logout()
    #expect(model.entitlement.status == .none)
    #expect(model.syncBanner == nil)
  }

  @Test
  func aBuildWithoutAnAPIKeyOffersNothingAndRefusesToBuy() async {
    let model = SubscriptionModel(purchases: UnconfiguredPurchases())
    #expect(model.isAvailable == false)
    await model.loadOffers()
    #expect(model.offers == .loaded([]))
    await model.buy(offer(.monthly, trialDays: 7))
    #expect(model.purchase == .failed(SyncCopy.unavailable))
    await model.restore()
    #expect(model.restoreMessage == SyncCopy.unavailable)
  }

  @Test
  func aSuccessfulPurchaseWaitsForRelayRatherThanTheStore() async {
    let store = FakePurchases()
    let model = SubscriptionModel(purchases: store)
    var refreshes = 0
    model.onStoreChange = { refreshes += 1 }

    await model.loadOffers()
    #expect(model.offers == .loaded(store.catalog))

    await model.buy(store.catalog[0])
    // The store said yes; the entitlement is still Relay's to report, so the paywall waits.
    #expect(model.purchase == .confirming)
    #expect(refreshes == 1)

    model.entitlementConfirmed()
    #expect(model.purchase == .idle)
  }

  @Test
  func cancellingLeavesThePaywallAsItWas() async {
    let store = FakePurchases()
    store.outcome = .cancelled
    let model = SubscriptionModel(purchases: store)
    await model.buy(offer(.monthly, trialDays: 7))
    #expect(model.purchase == .idle)
  }

  @Test
  func aStoreFailureIsSaidInWords() async {
    let store = FakePurchases()
    store.purchaseFails = true
    let model = SubscriptionModel(purchases: store)
    await model.buy(offer(.monthly, trialDays: 7))
    #expect(model.purchase == .failed(SyncCopy.purchaseFailed))

    store.restoreFails = true
    await model.restore()
    #expect(model.restoreMessage == SyncCopy.restoreFailed)
    #expect(model.purchase == .idle)
  }

  @Test
  func offersThatCannotBeReadFailAndCanBeRetried() async {
    let store = FakePurchases()
    store.offersFail = true
    let model = SubscriptionModel(purchases: store)
    await model.loadOffers()
    #expect(model.offers == .failed)

    store.offersFail = false
    await model.loadOffers(force: true)
    #expect(model.offers == .loaded(store.catalog))
  }

  @Test
  func identifyingBindsPurchasesToTheAccountOnce() async {
    let store = FakePurchases()
    let model = SubscriptionModel(purchases: store)
    await model.identify(accountID: "account_01")
    await model.identify(accountID: "account_01")
    #expect(store.loggedIn == ["account_01"])

    await model.signOut()
    #expect(store.logOutCount == 1)
    await model.identify(accountID: "account_01")
    #expect(store.loggedIn == ["account_01", "account_01"])
  }

  private func signedInModel(status: String) async throws -> AppModel {
    let model = AppModel(
      account: client(
        exchanges: [
          .init(
            status: 200,
            body: try Fixtures.accountSummaryJSON(
              entitlement: Fixtures.entitlement(status: status)
            )
          )
        ]
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled))
    )
    await model.restore()
    #expect(model.phase == .signedIn)
    return model
  }

  private func client(exchanges: [ScriptedHTTPTransport.Exchange]) -> AccountClient {
    AccountClient(
      relay: RelayClient(transport: ScriptedHTTPTransport(exchanges)),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
  }

  private func entitlement(
    _ status: EntitlementStatus,
    expiresAt: Date?,
    willRenew: Bool
  ) -> AccountEntitlement {
    AccountEntitlement(
      status: status,
      expiresAt: expiresAt,
      willRenew: willRenew,
      productID: "quota_sync_monthly",
      store: "app_store",
      stale: false
    )
  }

  private func offer(_ term: SubscriptionTerm, trialDays: Int?) -> SubscriptionOffer {
    SubscriptionOffer(
      term: term,
      productID: term.productID,
      displayPrice: "$2.99",
      freeTrialDays: trialDays
    )
  }
}

/// A store that answers without RevenueCat, an App Store account, or a network.
private final class FakePurchases: PurchasesFacade, @unchecked Sendable {
  let isConfigured = true
  let catalog = [
    SubscriptionOffer(
      term: .monthly,
      productID: SubscriptionTerm.monthly.productID,
      displayPrice: "$2.99",
      freeTrialDays: 7
    ),
    SubscriptionOffer(
      term: .yearly,
      productID: SubscriptionTerm.yearly.productID,
      displayPrice: "$29.99",
      freeTrialDays: 7
    ),
  ]

  var outcome: SubscriptionPurchaseOutcome = .purchased
  var offersFail = false
  var purchaseFails = false
  var restoreFails = false
  private(set) var loggedIn: [String] = []
  private(set) var logOutCount = 0

  func logIn(accountID: String) async {
    loggedIn.append(accountID)
  }

  func logOut() async {
    logOutCount += 1
  }

  func offers() async throws -> [SubscriptionOffer] {
    if offersFail { throw SubscriptionError.offerUnavailable }
    return catalog
  }

  func purchase(_ offer: SubscriptionOffer) async throws -> SubscriptionPurchaseOutcome {
    if purchaseFails { throw SubscriptionError.storeFailure("no") }
    return outcome
  }

  func restorePurchases() async throws {
    if restoreFails { throw SubscriptionError.storeFailure("no") }
  }

  func customerChanges() -> AsyncStream<Void> {
    AsyncStream { $0.finish() }
  }
}
