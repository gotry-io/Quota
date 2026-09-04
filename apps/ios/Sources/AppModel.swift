import Foundation
import Observation
import QuotaAccount
import QuotaAlerts
import QuotaPresentation
import QuotaRelay
import QuotaWidgetData
import QuotaWire

@MainActor
@Observable
final class AppModel {
  enum Phase: Equatable, Hashable {
    case launching
    case signedOut
    case connecting
    case confirmingAccount(label: String)
    case pendingRefreshFailed
    case signedIn
  }

  enum BannerKind: Equatable {
    case offlineCached
    case refreshFailed
  }

  struct Banner: Equatable {
    var kind: BannerKind
    var text: String
    var symbolName: String

    static let cachedText = "Showing saved data. Couldn't refresh."
    static let failedText = "Couldn't refresh. Pull to try again."
  }

  private let account: AccountClient
  private let authenticator: any BrowserSessionAuthenticating
  private let makeAuthorizationAttempt: @Sendable () throws -> AuthorizationAttempt
  private let widgetPublisher: any WidgetSnapshotPublishing
  private let selectionSaltStore: any SelectionSaltStore
  private let backgroundRefresh: any BackgroundRefreshScheduling
  private let alertCoordinator: AlertCoordinator
  private let iosAlertSink: IOSAlertSink?
  private let resetScheduler: IOSResetReminderScheduler
  private let activity: any ActivityLoading
  private let now: @Sendable () -> Date

  var phase: Phase = .launching
  var summary: AccountSummary?
  var fetchedAt: Date?
  var fromCache = false
  var isRefreshing = false
  var banner: Banner?
  var expiredMessage: String?
  var selectedTab: AppTab = .overview
  var selectedUsagePeriod: SelectedUsagePeriod = .last30Days
  /// Selection id from a subscription deep link, held until a summary can name it.
  var pendingSubscriptionSelection: String?
  /// Subscription keys on the Overview stack. A matching deep link replaces this with one key.
  var overviewPath: [String] = []
  /// Last 365 UTC days. Memory only; a failed read stays here and does not block the period list.
  var activityChart: ActivityChartPhase = .idle
  /// Presented day sheet, if any.
  var activityDaySheet: ActivityDaySheetState?
  private var sessionActivation: AccountSessionActivation?

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
    alertCoordinator: AlertCoordinator? = nil,
    alertRulesStore: IOSAlertRulesStore? = nil,
    alertStateStore: (any IOSAlertStateStore)? = nil,
    notificationCenter: (any NotificationCentering)? = nil,
    makeAuthorizationAttempt: @escaping @Sendable () throws -> AuthorizationAttempt = {
      try AuthorizationRequest.make()
    },
    activity: (any ActivityLoading)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.account = account
    self.authenticator = authenticator
    self.widgetPublisher = widgetPublisher
    self.selectionSaltStore = selectionSaltStore
    self.backgroundRefresh = backgroundRefresh
    self.now = now
    self.makeAuthorizationAttempt = makeAuthorizationAttempt
    let center = notificationCenter ?? NoOpNotificationCenter()
    let sink = IOSAlertSink(center: center)
    self.resetScheduler = IOSResetReminderScheduler(center: center)
    if let alertCoordinator {
      self.alertCoordinator = alertCoordinator
      self.iosAlertSink = nil
    } else {
      self.iosAlertSink = sink
      self.alertCoordinator = AlertCoordinator(
        rulesStore: alertRulesStore ?? IOSAlertRulesStore(),
        stateStore: alertStateStore ?? InMemoryIOSAlertStateStore(),
        sink: sink,
        now: now
      )
    }
    self.activity = activity ?? AccountClientActivityLoading(client: account)
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
      backgroundRefresh: backgroundRefresh,
      alertStateStore: FileIOSAlertStateStore.applicationSupport(),
      notificationCenter: IOSNotificationCenter()
    )
  }

  var accountLabel: String {
    PlanDisplay.accountLabel(summary?.account.displayLabel) ?? "Account"
  }

  /// One group per provider, and inside it one Overview row per subscription rather than per
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
    let session = try? await account.loadSession()
    sessionActivation = session?.activation
    summary = cached?.summary
    fetchedAt = cached?.fetchedAt
    fromCache = cached != nil
    switch session?.activation {
    case .active:
      phase = .signedIn
      if let cached {
        publishWidget(summary: cached.summary, fetchedAt: cached.fetchedAt)
      }
      resolvePendingSubscriptionSelection()
      await refresh()
    case .pending:
      if let label = PlanDisplay.accountLabel(cached?.summary.account.displayLabel) {
        phase = .confirmingAccount(label: label)
      } else {
        await refresh()
        if phase == .launching {
          presentPendingRefreshFailure(
            message: AuthorizationError.genericConnectFailureMessage
          )
        }
      }
    case nil:
      applySignedOut()
    }
  }

  func connectAccount(switchingAccount: Bool = false) async {
    if !switchingAccount {
      guard phase != .connecting else { return }
    }
    phase = .connecting
    banner = nil
    expiredMessage = nil
    do {
      let attempt = try makeAuthorizationAttempt()
      let callback = try await authenticator.authenticate(
        url: attempt.authorizationURL,
        callbackScheme: QuotaIOSOAuth.callbackScheme,
        prefersEphemeralWebBrowserSession: switchingAccount
      )
      let session = try await account.completeLogin(callback: callback, expected: attempt)
      sessionActivation = session.activation
      expiredMessage = nil
      banner = nil
      await refresh()
    } catch is CancellationError {
      applySignedOut()
    } catch AuthorizationError.cancelled, AccountClientError.cancelled {
      applySignedOut()
    } catch AccountClientError.sessionExpired {
      applyExpired()
    } catch let error as AccountClientError {
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: error.userFacingMessage,
        symbolName: "exclamationmark.triangle"
      )
    } catch let error as AuthorizationError {
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: error.userFacingMessage,
        symbolName: "exclamationmark.triangle"
      )
    } catch {
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: AuthorizationError.genericConnectFailureMessage,
        symbolName: "exclamationmark.triangle"
      )
    }
  }

  /// Keep the session this device just opened. Continue is the only promotion to `active`.
  func confirmAccount() async {
    guard case .confirmingAccount = phase else { return }
    do {
      try await account.activateSession()
    } catch {
      banner = Banner(
        kind: .refreshFailed,
        text: AuthorizationError.genericConnectFailureMessage,
        symbolName: "exclamationmark.triangle"
      )
      return
    }
    sessionActivation = .active
    expiredMessage = nil
    phase = .signedIn
    if let summary, let fetchedAt {
      banner = nil
      publishWidget(summary: summary, fetchedAt: fetchedAt)
      evaluateAlerts(summary: summary)
    } else {
      banner = failureBanner(hasCachedSummary: false, offline: false)
      clearWidget()
    }
    backgroundRefresh.scheduleNextRefresh()
    resolvePendingSubscriptionSelection()
    pruneOverviewPath()
  }

  /// Retry the identifying Account read while the session stays pending.
  func retryPendingIdentification() async {
    guard phase == .pendingRefreshFailed else { return }
    banner = nil
    expiredMessage = nil
    await refresh()
  }

  /// Revoke the session just opened and sign in again in an ephemeral browser session so GitHub
  /// cannot reuse the Safari account.
  func useDifferentAccount() async {
    switch phase {
    case .confirmingAccount, .pendingRefreshFailed: break
    default: return
    }
    phase = .connecting
    banner = nil
    expiredMessage = nil
    await account.logout()
    sessionActivation = nil
    summary = nil
    fetchedAt = nil
    fromCache = false
    clearWidget()
    await connectAccount(switchingAccount: true)
  }

  /// The one refresh the pull-to-refresh gesture and a background app refresh both run: read
  /// the account summary, apply it, republish the widget snapshot from the result, evaluate
  /// local remaining-quota alerts, rebuild reset reminders, and ask for the next background
  /// window. Reports whether the read reached Relay, which is the success a `BGAppRefreshTask`
  /// completes with.
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
    await apply(result)
    if phase == .signedIn {
      backgroundRefresh.scheduleNextRefresh()
    }
    return result.error == nil
  }

  func logout() async {
    await account.logout()
    applySignedOut()
  }

  /// Opens the website Delete Account flow in `ASWebAuthenticationSession` with shared cookies.
  /// The sheet ending — including cancel — returns here so Settings can prompt to sign out.
  func presentDeleteAccount() async {
    try? await authenticator.present(
      url: QuotaWebLinks.deleteAccountStart,
      callbackScheme: nil,
      prefersEphemeralWebBrowserSession: false
    )
  }

  func openDeepLink(_ url: URL) {
    selectedTab = .overview
    if case .subscription(let id) = DeepLink.parse(url) {
      pendingSubscriptionSelection = id
      resolvePendingSubscriptionSelection()
    } else {
      pendingSubscriptionSelection = nil
      overviewPath = []
    }
  }

  /// When a summary exists, match `pendingSubscriptionSelection` against each subscription's
  /// salted selection id. A hit pushes that row; a miss stays on Overview and clears pending.
  /// No summary yet keeps the pending id so a later restore or refresh can answer it.
  func resolvePendingSubscriptionSelection() {
    guard let pending = pendingSubscriptionSelection else { return }
    guard let summary else { return }
    guard let salt = try? selectionSaltStore.loadOrCreate() else { return }
    pendingSubscriptionSelection = nil
    if let match = summary.subscriptions.first(where: {
      WidgetSnapshotProjection.selectionID(for: $0, salt: salt) == pending
    }) {
      overviewPath = [match.key]
    } else {
      overviewPath = []
    }
  }

  func subscription(forKey key: String) -> QuotaSubscription? {
    summary?.subscriptions.first { $0.key == key }
  }

  var activityToday: String {
    UsageActivityCalendar.utcDay(from: now())
  }

  var activityDateRange: (from: String, to: String) {
    UsageActivityCalendar.range(endingOn: activityToday)
  }

  /// First visit to Usage asks once. Retry is explicit. The answer stays in memory.
  func loadActivity(force: Bool = false) async {
    guard phase == .signedIn else { return }
    if !force {
      switch activityChart {
      case .idle: break
      case .loading, .loaded, .failed: return
      }
    } else if case .loading = activityChart {
      return
    }
    activityChart = .loading
    let range = activityDateRange
    let result = await activity.fetchUsageActivity(from: range.from, to: range.to, detail: nil)
    guard phase == .signedIn else { return }
    applyActivity(result)
  }

  func retryActivity() async {
    await loadActivity(force: true)
  }

  func openActivityDay(date: String) async {
    guard phase == .signedIn else { return }
    presentActivityDay(date: date)
    await loadActivityDayAgents()
  }

  func presentActivityDay(date: String) {
    activityDaySheet = ActivityDaySheetState(
      date: date,
      headline: reportedDay(on: date),
      agents: .loading
    )
  }

  func retryActivityDay() async {
    guard activityDaySheet != nil else { return }
    updateDaySheet { $0.agents = .loading }
    await loadActivityDayAgents()
  }

  private func loadActivityDayAgents() async {
    guard let current = activityDaySheet else { return }
    let result = await activity.fetchUsageActivity(
      from: current.date,
      to: current.date,
      detail: .agents
    )
    guard phase == .signedIn, activityDaySheet?.date == current.date else { return }
    switch result {
    case .activity(let response):
      applyDayDetail(response, onto: current.date)
    case .failure(.sessionExpired):
      applyExpired()
    case .failure(.notSignedIn):
      applySignedOut()
    case .failure:
      updateDaySheet { $0.agents = .failed }
    }
  }

  private func applyActivity(_ result: AccountActivityResult) {
    switch result {
    case .activity(let response):
      activityChart = .loaded(response.days)
    case .failure(.sessionExpired):
      applyExpired()
    case .failure(.notSignedIn):
      applySignedOut()
    case .failure:
      activityChart = .failed
    }
  }

  private func applyDayDetail(_ response: AccountUsageActivityResponse, onto date: String) {
    updateDaySheet { sheet in
      if let day = response.days.first(where: { $0.date == date }) ?? response.days.first {
        sheet.headline = day
        let agents = day.agents ?? []
        sheet.agents = agents.isEmpty ? .empty : .loaded(agents)
      } else {
        sheet.agents = .empty
      }
    }
  }

  private func reportedDay(on date: String) -> UsageActivityDay {
    if case .loaded(let days) = activityChart, let day = days.first(where: { $0.date == date }) {
      return day
    }
    return UsageActivityChart.emptyDay(date: date)
  }

  private func updateDaySheet(_ mutate: (inout ActivityDaySheetState) -> Void) {
    guard var sheet = activityDaySheet else { return }
    mutate(&sheet)
    activityDaySheet = sheet
  }

  private var isPendingSession: Bool {
    sessionActivation == .pending
  }

  private func apply(_ result: AccountRefreshResult) async {
    summary = result.summary
    fetchedAt = result.fetchedAt
    fromCache = result.fromCache
    if isPendingSession {
      await applyPending(result)
      return
    }
    switch result.error {
    case .none:
      banner = nil
      expiredMessage = nil
      phase = .signedIn
      if let summary = result.summary, let fetchedAt = result.fetchedAt {
        publishWidget(summary: summary, fetchedAt: fetchedAt)
        evaluateAlerts(summary: summary)
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
    if phase == .signedIn {
      resolvePendingSubscriptionSelection()
      pruneOverviewPath()
    }
  }

  private func applyPending(_ result: AccountRefreshResult) async {
    switch result.error {
    case .none:
      if let label = PlanDisplay.accountLabel(result.summary?.account.displayLabel) {
        banner = nil
        expiredMessage = nil
        phase = .confirmingAccount(label: label)
      } else {
        presentPendingRefreshFailure(message: AuthorizationError.genericConnectFailureMessage)
      }
    case .sessionExpired:
      await revokePendingSession()
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: AuthorizationError.expiredSignInMessage,
        symbolName: "exclamationmark.triangle"
      )
    case .notSignedIn:
      sessionActivation = nil
      applySignedOut()
    case .some(let error) where isExpiredConnectError(error):
      await revokePendingSession()
      applySignedOut()
      banner = Banner(
        kind: .refreshFailed,
        text: error.userFacingMessage,
        symbolName: "exclamationmark.triangle"
      )
    case .some(let error):
      presentPendingRefreshFailure(message: error.userFacingMessage)
    }
  }

  private func isExpiredConnectError(_ error: AccountClientError) -> Bool {
    error.userFacingMessage == AuthorizationError.expiredSignInMessage
  }

  private func revokePendingSession() async {
    await account.logout()
    sessionActivation = nil
  }

  private func presentPendingRefreshFailure(message: String) {
    banner = Banner(
      kind: .refreshFailed,
      text: message,
      symbolName: "exclamationmark.triangle"
    )
    expiredMessage = nil
    phase = .pendingRefreshFailed
  }

  private func pruneOverviewPath() {
    guard let summary else {
      overviewPath = []
      return
    }
    overviewPath.removeAll { key in
      !summary.subscriptions.contains { $0.key == key }
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
        text: Banner.cachedText,
        symbolName: offline ? "icloud.slash" : "exclamationmark.triangle"
      )
    }
    return Banner(
      kind: .refreshFailed,
      text: Banner.failedText,
      symbolName: "exclamationmark.triangle"
    )
  }

  private func applyExpired() {
    applySignedOut()
    expiredMessage = "Session expired. Connect again."
  }

  /// Connect with GitHub with nothing said about why: no session, or one the person ended. There is
  /// no account left to read, so the standing background-refresh ask goes with it.
  private func applySignedOut() {
    summary = nil
    fetchedAt = nil
    fromCache = false
    banner = nil
    expiredMessage = nil
    sessionActivation = nil
    phase = .signedOut
    selectedTab = .overview
    selectedUsagePeriod = .last30Days
    pendingSubscriptionSelection = nil
    overviewPath = []
    activityChart = .idle
    activityDaySheet = nil
    backgroundRefresh.cancelPendingRefresh()
    try? selectionSaltStore.clear()
    clearWidget()
    alertCoordinator.clearState()
    resetScheduler.removeAll()
  }

  /// Compare the latest Account readings against the last available ones, hand events to the
  /// sink, and rebuild reset reminders. A `windowReset` whose selector and window already have
  /// a scheduled reminder is left to that reminder.
  private func evaluateAlerts(summary: AccountSummary) {
    let instant = now()
    let catalog = AlertCoordinator.catalog(from: summary.subscriptions)
    if let iosAlertSink {
      iosAlertSink.catalog = catalog
      iosAlertSink.scheduledResetKeys = resetScheduler.scheduledResetKeys
      iosAlertSink.now = instant
    }
    alertCoordinator.evaluate(summary: summary)
    resetScheduler.reschedule(
      rules: alertCoordinator.currentRules(),
      subscriptions: AlertCoordinator.readings(from: summary.subscriptions),
      catalog: catalog,
      now: instant
    )
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

enum ActivityChartPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded([UsageActivityDay])
  case failed
}

enum ActivityDayAgentsPhase: Equatable, Sendable {
  case loading
  case loaded([UsageAgentUsage])
  case empty
  case failed
}

struct ActivityDaySheetState: Identifiable, Equatable, Sendable {
  var id: String { date }
  var date: String
  var headline: UsageActivityDay
  var agents: ActivityDayAgentsPhase
}
