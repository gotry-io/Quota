import Foundation
import Observation

/// What the paywall buys with, and what the store has said since.
///
/// It never decides whether sync is on: `AppModel` reads that from the Relay `entitlement`. What
/// this model contributes is the plans to buy, the purchase and restore calls, and one nudge to
/// re-read Relay when the store changes its mind — the same purchase reaches Relay through a
/// RevenueCat webhook, which may land a few seconds later.
@MainActor
@Observable
final class SubscriptionModel {
  enum OffersPhase: Equatable {
    case idle
    case loading
    case loaded([SubscriptionOffer])
    case failed
  }

  /// Where a purchase got to, as the paywall reports it.
  enum PurchaseState: Equatable {
    case idle
    case purchasing
    /// Bought, and waiting for Relay to say so.
    case confirming
    case pending
    case failed(String)
  }

  private let purchases: any PurchasesFacade
  private var changeWatcher: Task<Void, Never>?
  private var identifiedAccountID: String?

  var offers: OffersPhase = .idle
  var purchase: PurchaseState = .idle
  var restoreMessage: String?

  var isAvailable: Bool { purchases.isConfigured }

  /// Re-read Relay. `AppModel` owns this model and sets it, because the entitlement a purchase
  /// produces is Relay's to report, not the store's.
  @ObservationIgnored var onStoreChange: @MainActor () async -> Void = {}

  init(purchases: any PurchasesFacade = UnconfiguredPurchases()) {
    self.purchases = purchases
  }

  /// Bind purchases to the signed-in Quota Account and start listening for store changes.
  /// Called with the same id every refresh; only a change does any work.
  func identify(accountID: String) async {
    guard purchases.isConfigured, identifiedAccountID != accountID else { return }
    identifiedAccountID = accountID
    await purchases.logIn(accountID: accountID)
    startWatchingStore()
  }

  /// Signing out of Quota ends the store identity with it, so the next Account on this device
  /// does not inherit the last one's purchases.
  func signOut() async {
    changeWatcher?.cancel()
    changeWatcher = nil
    offers = .idle
    purchase = .idle
    restoreMessage = nil
    guard purchases.isConfigured, identifiedAccountID != nil else { return }
    identifiedAccountID = nil
    await purchases.logOut()
  }

  func loadOffers(force: Bool = false) async {
    guard purchases.isConfigured else {
      offers = .loaded([])
      return
    }
    if !force, case .loading = offers { return }
    if !force, case .loaded = offers { return }
    offers = .loading
    do {
      offers = .loaded(try await purchases.offers())
    } catch {
      offers = .failed
    }
  }

  func buy(_ offer: SubscriptionOffer) async {
    guard purchases.isConfigured else {
      purchase = .failed(SyncCopy.unavailable)
      return
    }
    purchase = .purchasing
    restoreMessage = nil
    do {
      switch try await purchases.purchase(offer) {
      case .purchased:
        purchase = .confirming
        await onStoreChange()
      case .pending:
        purchase = .pending
      case .cancelled:
        purchase = .idle
      }
    } catch {
      purchase = .failed(SyncCopy.purchaseFailed)
    }
  }

  func restore() async {
    guard purchases.isConfigured else {
      restoreMessage = SyncCopy.unavailable
      return
    }
    purchase = .purchasing
    restoreMessage = nil
    do {
      try await purchases.restorePurchases()
      purchase = .confirming
      await onStoreChange()
    } catch {
      purchase = .idle
      restoreMessage = SyncCopy.restoreFailed
    }
  }

  /// Relay has confirmed the entitlement; the paywall has nothing left to say.
  func entitlementConfirmed() {
    purchase = .idle
    restoreMessage = nil
  }

  private func startWatchingStore() {
    changeWatcher?.cancel()
    let stream = purchases.customerChanges()
    changeWatcher = Task { [weak self] in
      for await _ in stream {
        guard let self else { return }
        await self.onStoreChange()
      }
    }
  }
}
