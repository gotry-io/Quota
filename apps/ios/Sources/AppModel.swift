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
    makeAuthorizationAttempt: @escaping @Sendable () throws -> AuthorizationAttempt = {
      try AuthorizationRequest.make()
    }
  ) {
    self.account = account
    self.authenticator = authenticator
    self.widgetPublisher = widgetPublisher
    self.makeAuthorizationAttempt = makeAuthorizationAttempt
  }

  convenience init() {
    self.init(
      account: AccountClient(
        sessionStore: KeychainAccountSessionStore(),
        summaryStore: (try? ProtectedFileAccountSummaryStore.applicationSupport())
          ?? MemoryAccountSummaryStore()
      ),
      authenticator: SystemBrowserAuthenticator(),
      widgetPublisher: AppGroupWidgetSnapshotPublisher.make()
    )
  }

  var accountLabel: String {
    PlanDisplay.accountLabel(summary?.account.displayLabel) ?? "Account"
  }

  var providerCards: [ProviderQuotaCardModel] {
    guard let summary else { return [] }
    let grouped = Dictionary(grouping: summary.quota, by: \.snapshot.provider)
    return ProviderID.allCases.compactMap { provider in
      guard let observations = grouped[provider], !observations.isEmpty else { return nil }
      return ProviderQuotaCardModel(provider: provider, observations: observations)
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
      phase = .signedOut
      clearWidget()
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

  func refresh() async {
    guard !isRefreshing else { return }
    isRefreshing = true
    defer { isRefreshing = false }
    let result = await account.fetchTodaySummary()
    apply(result)
  }

  func logout() async {
    await account.logout()
    summary = nil
    fetchedAt = nil
    fromCache = false
    banner = nil
    expiredMessage = nil
    phase = .signedOut
    clearWidget()
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
    case .sessionExpired, .notSignedIn:
      applyExpired()
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
    summary = nil
    fetchedAt = nil
    fromCache = false
    banner = nil
    expiredMessage = "Session expired. Connect Account to continue."
    phase = .signedOut
    clearWidget()
  }

  private func publishWidget(summary: AccountSummary, fetchedAt: Date) {
    let snapshot = WidgetSnapshotProjection.make(summary: summary, fetchedAt: fetchedAt)
    try? widgetPublisher.publish(snapshot)
  }

  private func clearWidget() {
    try? widgetPublisher.clear()
  }
}

struct ProviderQuotaCardModel: Identifiable, Equatable {
  var id: ProviderID { provider }
  let provider: ProviderID
  let observations: [AccountQuotaObservation]
}
