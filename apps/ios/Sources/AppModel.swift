import Foundation
import Observation
import QuotaAccount
import QuotaPresentation
import QuotaRelay
import QuotaWidgetData
import QuotaWire

@MainActor
@Observable
final class AppModel {
  enum Phase: Equatable {
    case launching
    case signedOut
    case connecting
    case signedIn
  }

  enum BannerKind: Equatable {
    case connecting
    case offlineCached
    case refreshFailed
    case expired
  }

  struct Banner: Equatable {
    var kind: BannerKind
    var text: String
    var symbolName: String
  }

  private let account: AccountClient
  private let authenticator: any BrowserSessionAuthenticating
  private let makeAuthorizationAttempt: @Sendable () throws -> AuthorizationAttempt
  private let widgetPublisher: any WidgetSnapshotPublishing
  private let selectionSaltStore: any SelectionSaltStore
  private let backgroundRefresh: any BackgroundRefreshScheduling

  var phase: Phase = .launching
  var summary: AccountSummary?
  var fetchedAt: Date?
  var fromCache = false
  var isRefreshing = false
  var banner: Banner?
  var expiredMessage: String?

  #if DEBUG
    /// When true, `QuotaApp` skips `restore()` so visual fixtures stay offline and deterministic.
    var skipsRestore = false
  #endif

  init(
    account: AccountClient,
    authenticator: any BrowserSessionAuthenticating,
    widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
    selectionSaltStore: any SelectionSaltStore = InMemorySelectionSaltStore(),
    backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler(),
    makeAuthorizationAttempt: @escaping @Sendable () throws -> AuthorizationAttempt = {
      try AuthorizationRequest.make()
    }
  ) {
    self.account = account
    self.authenticator = authenticator
    self.widgetPublisher = widgetPublisher
    self.selectionSaltStore = selectionSaltStore
    self.backgroundRefresh = backgroundRefresh
    self.makeAuthorizationAttempt = makeAuthorizationAttempt
  }

  convenience init(backgroundRefresh: any BackgroundRefreshScheduling) {
    self.init(
      account: AccountClient(
        sessionStore: KeychainAccountSessionStore(),
        summaryStore: (try? ProtectedFileAccountSummaryStore.applicationSupport())
          ?? MemoryAccountSummaryStore()
      ),
      authenticator: SystemBrowserAuthenticator(),
      widgetPublisher: AppGroupWidgetSnapshotPublisher.make(),
      selectionSaltStore: KeychainSelectionSaltStore(),
      backgroundRefresh: backgroundRefresh
    )
  }

  var accountLabel: String {
    PlanDisplay.accountLabel(summary?.account.displayLabel) ?? "Account"
  }

  /// One card per provider, and inside it one row per subscription rather than per
  /// reporting device: an account collected on three Macs is one subscription, not three,
  /// and Relay has already resolved it that way.
  var providerCards: [ProviderQuotaCardModel] {
    guard let summary else { return [] }
    let grouped = Dictionary(grouping: summary.subscriptions) { $0.snapshot.provider }
    return ProviderID.allCases.compactMap { provider in
      guard let subscriptions = grouped[provider], !subscriptions.isEmpty else { return nil }
      return ProviderQuotaCardModel(provider: provider, subscriptions: subscriptions)
    }
  }

  func restore() async {
    let cached = try? await account.loadCachedSummary()
    summary = cached?.summary
    fetchedAt = cached?.fetchedAt
    fromCache = cached != nil
    if (try? await account.hasSession()) == true {
      phase = .signedIn
      if let cached {
        publishWidget(summary: cached.summary, fetchedAt: cached.fetchedAt)
      }
      await refresh()
    } else {
      applySignedOut()
    }
  }

  func connectAccount() async {
    guard phase != .connecting else { return }
    phase = .connecting
    banner = Banner(
      kind: .connecting,
      text: "Continue in the browser.",
      symbolName: "safari"
    )
    do {
      let attempt = try makeAuthorizationAttempt()
      let callback = try await authenticator.authenticate(
        url: attempt.authorizationURL,
        callbackScheme: QuotaIOSOAuth.callbackScheme
      )
      _ = try await account.completeLogin(callback: callback, expected: attempt)
      expiredMessage = nil
      phase = .signedIn
      banner = nil
      await refresh()
    } catch is CancellationError {
      phase = .signedOut
      banner = nil
    } catch AuthorizationError.cancelled, AccountClientError.cancelled {
      phase = .signedOut
      banner = nil
    } catch AccountClientError.sessionExpired {
      applyExpired()
    } catch {
      phase = .signedOut
      banner = Banner(
        kind: .refreshFailed,
        text: "Could not connect this account. Try again.",
        symbolName: "exclamationmark.triangle"
      )
    }
  }

  /// The one refresh the pull-to-refresh gesture and a background app refresh both run: read
  /// the account summary, apply it, republish the widget snapshot from the result, and ask for
  /// the next background window. Reports whether the read reached Relay, which is the success
  /// a `BGAppRefreshTask` completes with.
  ///
  /// The next window is only worth asking for while a session exists to read with. A read that
  /// ends signed out — no session, or one Relay would not renew — leaves without asking, and
  /// has already withdrawn the standing ask on its way through `applySignedOut`.
  @discardableResult
  func refresh() async -> Bool {
    guard !isRefreshing else { return false }
    isRefreshing = true
    defer { isRefreshing = false }
    let result = await account.fetchTodaySummary()
    apply(result)
    if phase == .signedIn {
      backgroundRefresh.scheduleNextRefresh()
    }
    return result.error == nil
  }

  func logout() async {
    await account.logout()
    applySignedOut()
  }

  private func apply(_ result: AccountRefreshResult) {
    summary = result.summary
    fetchedAt = result.fetchedAt
    fromCache = result.fromCache
    switch result.error {
    case .none:
      banner = nil
      expiredMessage = nil
      phase = .signedIn
      if let summary = result.summary, let fetchedAt = result.fetchedAt {
        publishWidget(summary: summary, fetchedAt: fetchedAt)
      } else {
        clearWidget()
      }
    case .sessionExpired:
      applyExpired()
    case .notSignedIn:
      // Signing out, or never having signed in, is not an expiry. Saying a session expired to
      // someone who deliberately logged out invents a failure that did not happen.
      applySignedOut()
    case .relay(.unavailable), .relay(.timeout):
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: true)
      syncWidgetAfterFailure(hasTrustedSummary: result.summary != nil)
    case .some:
      phase = .signedIn
      banner = failureBanner(hasCachedSummary: result.summary != nil, offline: false)
      syncWidgetAfterFailure(hasTrustedSummary: result.summary != nil)
    }
  }

  private func syncWidgetAfterFailure(hasTrustedSummary: Bool) {
    // Trusted cached summary stays published; absence of a trusted summary clears.
    if !hasTrustedSummary {
      clearWidget()
    }
  }

  private func failureBanner(hasCachedSummary: Bool, offline: Bool) -> Banner {
    if hasCachedSummary {
      return Banner(
        kind: offline ? .offlineCached : .refreshFailed,
        text: "Showing saved account data. Could not refresh.",
        symbolName: offline ? "icloud.slash" : "exclamationmark.triangle"
      )
    }
    return Banner(
      kind: .refreshFailed,
      text: "Could not refresh account data. Pull to try again.",
      symbolName: "exclamationmark.triangle"
    )
  }

  private func applyExpired() {
    applySignedOut()
    expiredMessage = "Session expired. Connect Account to continue."
  }

  /// Connect Account with nothing said about why: no session, or one the person ended. There is
  /// no account left to read, so the standing background-refresh ask goes with it.
  private func applySignedOut() {
    summary = nil
    fetchedAt = nil
    fromCache = false
    banner = nil
    expiredMessage = nil
    phase = .signedOut
    backgroundRefresh.cancelPendingRefresh()
    try? selectionSaltStore.clear()
    clearWidget()
  }

  private func publishWidget(summary: AccountSummary, fetchedAt: Date) {
    guard let salt = try? selectionSaltStore.loadOrCreate() else { return }
    let snapshot = WidgetSnapshotProjection.make(
      summary: summary,
      fetchedAt: fetchedAt,
      salt: salt
    )
    try? widgetPublisher.publish(snapshot)
  }

  private func clearWidget() {
    try? widgetPublisher.clear()
  }
}

struct ProviderQuotaCardModel: Identifiable, Equatable {
  var id: ProviderID { provider }
  let provider: ProviderID
  let subscriptions: [QuotaSubscription]
}
