import AppKit
import Foundation
import Observation
import QuotaPresentation
import QuotaWire
import SweetCookieKit

enum QuotaOverviewState: Equatable {
  case loading
  case unavailable(message: String)
  case empty(refreshWarning: String?)
  case content(providers: [ProviderQuotaPresentation], refreshWarning: String?)
}

struct ProviderQuotaPresentation: Equatable, Identifiable {
  let provider: ProviderID
  let accounts: [AccountQuotaPresentation]
  let status: ProviderStatusCopy?

  var id: ProviderID { provider }

  init(
    provider: ProviderID,
    accounts: [AccountQuotaPresentation],
    status: ProviderStatusCopy? = nil
  ) {
    self.provider = provider
    self.accounts = accounts
    self.status = status
  }
}

struct AccountQuotaPresentation: Equatable, Identifiable {
  let identity: QuotaSubscriptionIdentity
  let snapshot: QuotaSnapshot
  /// What the row says about this reading: the source's own report, or aged out by the
  /// service's verdict. Resolved once here so the view never re-derives it.
  let state: QuotaObservationState
  let selectedSourceDisplayName: String

  var id: QuotaSubscriptionIdentity { identity }

  /// An Overview row spends no line on which source answered or how old the reading is; a
  /// reading that no longer describes live quota says so in tone. Tone cannot be read aloud,
  /// so the sentence it replaced is what VoiceOver announces for the row.
  func accessibilityLabel(accountIndex: Int, now: Date) -> String {
    let account =
      PlanDisplay.accountLabel(snapshot.account.label).map { "Account: \($0)" }
      ?? "Account \(accountIndex + 1)"
    let freshness = FreshnessCopy.observation(
      state: state,
      observedAt: snapshot.observedAt,
      now: now
    )
    return "\(account). \(selectedSourceDisplayName). \(freshness)"
  }
}

private struct QuotaCollectionScanKey: Equatable {
  var updatedAt: Date?
}

/// Which browsers one scan opened and which it left shut, by display name.
struct BrowserScanCoverage: Equatable, Sendable {
  var read: [String] = []
  var skipped: [String] = []
  /// Sign-ins the scan found and sent to the service, whether or not it accepted them.
  var candidates = 0
}

enum ProviderBrowserSessionPopup: Equatable, Sendable {
  /// Asked before the first cookie is read after Scan browsers is turned on.
  case consent(provider: ProviderID)
}

enum AccountViewState: Equatable {
  case notChecked
  case signedOut
  case logoutPending
  case signedIn
}

enum AccountDisconnectReason: Equatable {
  case deviceDeleted
  case sessionEnded
}

#if DEBUG
  struct MenuBarVisualState {
    let report: QuotaCollectionReport
    let localUsage: LocalUsageReport
    let accountSummary: AccountSummary?
    let authStatus: LocalServiceAuthStatus
    let overview: [LocalServiceOverviewItem]
    var cache: LocalServiceCacheState = .settled
  }
#endif

@MainActor
@Observable
final class MenuBarViewModel: BrowserAccessGrantHandling {
  private(set) var report: QuotaCollectionReport?
  private(set) var localUsage: LocalUsageReport?
  private(set) var accountSummary: AccountSummary?
  /// The name the sign-in gave, held until an account read carries one of its own.
  private(set) var signInDisplayLabel: String?
  private(set) var usagePeriods: LocalServiceUsagePeriodCache?
  private(set) var errorMessage: String?
  private(set) var accountErrorMessage: String?
  private(set) var isRefreshing = false
  private(set) var usageRefreshing = false
  private(set) var accountRefreshing = false
  private(set) var isLoggingIn = false
  private(set) var isLoggingOut = false
  private(set) var isUpdatingUsageUpload = false
  private(set) var usageUploadEnabled = true
  private(set) var quotaRefreshIntervalSeconds = QuotaRefreshInterval.fallback.rawValue
  private(set) var isUpdatingQuotaRefreshInterval = false
  private(set) var accountDisconnectReason: AccountDisconnectReason?
  private(set) var lastCheckedAt: Date?
  private(set) var providerConfigurations: [ProviderID: LocalServiceProviderConfig] = [:]
  private(set) var providerBrowserSessions: [ProviderID: [LocalServiceProviderBrowserSession]] = [:]
  private(set) var browserScanEnabled: Set<ProviderID> = []
  private(set) var browserSessionPopup: ProviderBrowserSessionPopup?
  private(set) var browserSessionErrorMessages: [ProviderID: String] = [:]
  /// A read macOS refused, which is a different state from finding no session: it stands until
  /// the reader changes a permission, and the Diagnostics page carries it too.
  private(set) var browserSessionAccessDenials: [ProviderID: BrowserAccessDenial] = [:]
  private(set) var browserSessionWaitingProvider: ProviderID?
  private(set) var browserSessionActivityText: String?
  /// Every installed browser and the macOS grant it still needs, probed after Scan browsers is
  /// turned on. The Agent page summarises it in one row; the Browser Access window lists it.
  private(set) var browserAccessSnapshot = BrowserAccessSnapshot(
    statuses: [], awaitingRelaunch: false)
  /// The Chrome-family browser whose Keychain prompt is on screen right now.
  private(set) var keychainPromptBrowser: Browser?
  var browserAccessNeeds: [BrowserAccessNeed] { browserAccessSnapshot.needs }
  var browserAccessAwaitingRelaunch: Bool { browserAccessSnapshot.awaitingRelaunch }
  /// One line for the Agent page row, or nil when every installed browser is readable.
  var browserAccessSummary: String? {
    BrowserSessionCopy.accessSummary(
      needs: browserAccessNeeds, awaitingRelaunch: browserAccessAwaitingRelaunch)
  }
  /// Bumps after a browser-session replace finishes, so tests can wait on MainActor state.
  private(set) var browserSessionScanGeneration = 0
  /// What the last scan for each provider opened and skipped, so the Agent page can say
  /// where it looked.
  private(set) var browserScanCoverage: [ProviderID: BrowserScanCoverage] = [:]
  private var lastBrowserScanKey: [ProviderID: QuotaCollectionScanKey] = [:]
  private var lastBrowserScanFinishedAt: [ProviderID: Date] = [:]
  private var lastBrowserScanEnabled: Set<ProviderID> = []
  private var scanningProviders: Set<ProviderID> = []
  /// Set when this session sent the person to the Full Disk Access pane. The grant lands on
  /// the next launch, so from then on the window offers a relaunch.
  private var fullDiskAccessSettingsOpened = false

  private var authStatus: LocalServiceAuthStatus?
  private var overview: [LocalServiceOverviewItem] = []
  private var revision = 0
  private(set) var cache: LocalServiceCacheState = .settled

  /// The instant the menu-bar item is drawn for.
  ///
  /// The item's content is a function of time — the shared freshness rule retires a reading —
  /// but observation only re-reads it when something it read changed. Without a clock of its
  /// own the item would keep a percent that stopped describing live quota until the next
  /// service event, which for a Mac that has stopped collecting is never.
  private(set) var menuBarClock = Date()

  var accountState: AccountViewState {
    switch authStatus {
    case .signedIn: .signedIn
    case .logoutPending: .logoutPending
    case .loggingIn, .signedOut: .signedOut
    case nil: .notChecked
    }
  }

  /// What to call the account.
  ///
  /// The account read is the fuller answer, but it is not the first one: signing in already said
  /// what the account is called, so the name stands from that moment rather than from whenever
  /// the first read finishes.
  var accountDisplayLabel: String {
    PlanDisplay.accountLabel(accountSummary?.account.displayLabel)
      ?? PlanDisplay.accountLabel(signInDisplayLabel)
      ?? "Quota account"
  }

  var accountDeviceSummary: String {
    guard let devices = accountSummary?.devices else {
      return accountState == .signedIn ? "Unavailable" : "Sign in"
    }
    let now = Date()
    let active = devices.filter { $0.activity(now: now).status == .active }
      .count
    return active == devices.count ? "\(devices.count)" : "\(active)/\(devices.count) active"
  }

  @ObservationIgnored
  private let client: (any LocalServiceServing)?

  @ObservationIgnored
  private let initializationError: String?

  var showsCacheRebuildNotice: Bool {
    cache.rebuilding
  }

  @ObservationIgnored
  private var eventTask: Task<Void, Never>?

  @ObservationIgnored
  private var loginTask: Task<Void, Never>?

  @ObservationIgnored
  private var cancelLoginTask: Task<Void, Never>?

  @ObservationIgnored
  private var menuBarClockTask: Task<Void, Never>?

  /// Which readings were current the last time the clock was published.
  @ObservationIgnored
  private var menuBarCurrency: [Bool] = []

  @ObservationIgnored
  private let browserSessionImporter: any BrowserSessionImporting

  @ObservationIgnored
  private let loginURLOpener: any LoginURLOpening

  @ObservationIgnored
  private let accessProbe: any BrowserAccessProbing

  @ObservationIgnored
  private var grantPresenter: (any BrowserAccessGrantPresenting)?

  @ObservationIgnored
  private let relauncher: any QuotaBarRelaunching

  @ObservationIgnored
  private var fullDiskAccessPollTask: Task<Void, Never>?

  private(set) var accountActionErrorMessage: String?
  private(set) var loginAuthorizeURL: URL?
  private var browserOpenFailed = false

  var canCopyLoginLink: Bool { loginAuthorizeURL != nil }

  /// How long a quit waits for the service's goodbye before going ahead without it.
  nonisolated static let shutdownDeadline: Duration = .seconds(2)

  /// How often the menu-bar item is re-evaluated against the clock. The shared freshness rule's
  /// smallest unit is a minute — under one everything reads "just now" — so a minute is as fine
  /// as the item's answer can change.
  nonisolated static let menuBarClockInterval: Duration = .seconds(60)

  @ObservationIgnored
  private let shutdownDeadline: Duration

  init(
    client: (any LocalServiceServing)? = nil,
    browserSessionImporter: any BrowserSessionImporting = BrowserSessionImporter(),
    loginURLOpener: any LoginURLOpening = WorkspaceLoginURLOpener(),
    accessProbe: (any BrowserAccessProbing)? = nil,
    grantPresenter: (any BrowserAccessGrantPresenting)? = nil,
    relauncher: (any QuotaBarRelaunching)? = nil,
    shutdownDeadline: Duration = MenuBarViewModel.shutdownDeadline
  ) {
    let injectedClient = client != nil
    self.browserSessionImporter = browserSessionImporter
    self.loginURLOpener = loginURLOpener
    self.accessProbe = accessProbe ?? (injectedClient
      ? UnrestrictedBrowserAccessProbe()
      : SystemBrowserAccessProbe())
    self.relauncher = relauncher ?? (injectedClient
      ? NoOpQuotaBarRelauncher()
      : WorkspaceQuotaBarRelauncher())
    self.shutdownDeadline = shutdownDeadline
    if let client {
      self.client = client
      initializationError = nil
      self.grantPresenter = grantPresenter
    } else {
      do {
        self.client = try LocalServiceClient()
        initializationError = nil
      } catch {
        self.client = nil
        initializationError = Self.message(for: error)
      }
      if let grantPresenter {
        self.grantPresenter = grantPresenter
      } else {
        let panel = BrowserAccessWindowController()
        self.grantPresenter = panel
      }
    }
  }

  #if DEBUG
    init(
      visualTestState: MenuBarVisualState?,
      errorMessage: String?,
      lastCheckedAt: Date?
    ) {
      browserSessionImporter = BrowserSessionImporter()
      loginURLOpener = WorkspaceLoginURLOpener()
      accessProbe = UnrestrictedBrowserAccessProbe()
      relauncher = NoOpQuotaBarRelauncher()
      client = nil
      shutdownDeadline = MenuBarViewModel.shutdownDeadline
      initializationError = nil
      self.errorMessage = errorMessage
      self.lastCheckedAt = lastCheckedAt
      guard let visualTestState else { return }
      report = visualTestState.report
      localUsage = visualTestState.localUsage
      accountSummary = visualTestState.accountSummary
      if let usage = visualTestState.accountSummary?.usage {
        let values = LocalServiceUsagePeriodValues(
          today: Self.periodDetail(usage.today),
          last7Days: Self.periodDetail(usage.last7Days),
          last30Days: Self.periodDetail(usage.last30Days),
          all: Self.periodDetail(usage.all)
        )
        usagePeriods = LocalServiceUsagePeriodCache(local: values, account: values)
      }
      authStatus = visualTestState.authStatus
      overview = visualTestState.overview
      cache = visualTestState.cache
    }

    /// The managed period, in the shape the panel already reads. A managed tree states totals
    /// and cost only at the leaf, so what a fixture shows above them is folded here.
    private static func periodDetail(_ period: QuotaWire.UsagePeriod)
      -> LocalServiceUsageDetail
    {
      let agents = period.agents.map { agent in
        LocalUsageAgentSummary(
          agent: agent.agent,
          totals: period.totals,
          cost: period.cost,
          providers: agent.providers.map { provider in
            LocalUsageProviderSummary(
              provider: provider.provider,
              totals: period.totals,
              cost: period.cost,
              models: provider.models.map {
                LocalUsageModelSummary(model: $0.model, totals: $0.totals, cost: $0.cost)
              }
            )
          }
        )
      }
      return LocalServiceUsageDetail(
        range: UsageDateRange(from: "2026-08-10", to: "2026-08-10"),
        usage: LocalUsagePeriodSummary(
          totals: period.totals,
          cost: period.cost,
          agents: agents
        ),
        incomplete: period.partial,
        detailsTruncated: period.hasTruncatedDetails
      )
    }
  #endif

  deinit {
    eventTask?.cancel()
    loginTask?.cancel()
    cancelLoginTask?.cancel()
    menuBarClockTask?.cancel()
    fullDiskAccessPollTask?.cancel()
  }

  func start() {
    grantPresenter?.handler = self
    guard eventTask == nil, let client else {
      if self.client == nil { errorMessage = initializationError }
      return
    }
    eventTask = Task { @MainActor [weak self] in
      await self?.reloadState()
      for await event in client.events {
        guard !Task.isCancelled else { return }
        guard let self else { continue }
        guard event.revision > revision else { continue }
        await reloadState()
      }
    }
    let interval = Self.menuBarClockInterval
    menuBarClockTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        self?.advanceMenuBarClock(to: Date())
      }
    }
  }

  /// Publishes the instant the menu-bar item is drawn for.
  ///
  /// The item depends on time only through which readings still describe live quota, so a
  /// minute in which that set did not change is a minute in which the item cannot have changed
  /// either, and publishing would rebuild the status item for the same answer. New readings are
  /// the exception: the label is re-read for them anyway, and they have to be judged against the
  /// present rather than against whenever the clock last had reason to move.
  func advanceMenuBarClock(to now: Date, forNewReadings: Bool = false) {
    let currency = MenuBarLabelModel.currency(of: overview, now: now)
    guard forNewReadings || currency != menuBarCurrency else { return }
    menuBarCurrency = currency
    menuBarClock = now
  }

  /// QuotaBar's last word to its local service, and the last thing that can hold up a quit. The
  /// panel stops following the service, then the client asks the helper to exit and escalates to
  /// terminate and kill if it will not — but the wait for that answer is capped, because the
  /// person pressed Quit. A helper wedged badly enough to answer neither its `shutdown` nor a
  /// ping would otherwise hold the run loop AppKit is turning on our behalf; past the deadline
  /// the escalation finishes without an audience, and this process exiting closes the child's
  /// stdin, which says the same thing by a slower route.
  func shutdown() async {
    eventTask?.cancel()
    eventTask = nil
    fullDiskAccessPollTask?.cancel()
    fullDiskAccessPollTask = nil
    grantPresenter?.dismiss()
    guard let client else { return }
    // A race whose loser is abandoned rather than awaited: the deadline is the thing waited on,
    // and a goodbye that lands first cancels it so a healthy quit is not slowed to two seconds.
    let goodbye = Task { await client.shutdown() }
    let deadline = Task { try await Task.sleep(for: shutdownDeadline) }
    let arrival = Task {
      await goodbye.value
      deadline.cancel()
    }
    _ = await deadline.result
    arrival.cancel()
  }

  func refreshIfNeeded() async {
    if revision == 0 { await reloadState() }
  }

  func refresh() async {
    guard !isRefreshing, let client else {
      if self.client == nil { errorMessage = initializationError }
      return
    }
    isRefreshing = true
    do {
      _ = try await client.refresh()
      await reloadState()
    } catch is CancellationError {
      isRefreshing = false
      return
    } catch {
      errorMessage = Self.message(for: error)
      isRefreshing = false
    }
  }

  func diagnose() async throws -> LocalServiceDiagnosticReport {
    guard let client else {
      throw LocalServiceClientError.serviceMissing
    }
    let previous = try await client.diagnose()
    let refresh = try await client.recheckDiagnostics()
    guard refresh.accepted || refresh.pending else { return previous }
    // A running refresh keeps answering with the report it already had, so a different
    // evaluation time is the only proof that a newer one exists.
    let deadline = Date().addingTimeInterval(12)
    var latest = previous
    repeat {
      try await Task.sleep(for: .milliseconds(150))
      latest = try await client.diagnose()
      if latest.generatedAt != previous.generatedAt { return latest }
    } while Date() < deadline
    return latest
  }

  /// Deletes this Mac's derived cache and starts filling it in again. The session, the upload
  /// queue, and saved browser sessions live in a different file and are untouched.
  func resetLocalData() async {
    guard let client else { return }
    do {
      try await client.resetCache()
      await reloadState()
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func usageDetail(source: UsageSource, period: UsagePeriod) -> LocalServiceUsageDetail? {
    usagePeriods?.detail(source: source, period: period)
  }

  /// Account answers for Usage only while it can. Everywhere the selection is honored uses
  /// this, so Overview and the Usage page never disagree about which numbers are on screen.
  func effectiveUsageSource(_ selected: UsageSource) -> UsageSource {
    !usageUploadEnabled || accountSummary == nil ? .local : selected
  }

  /// The bottom bar's one line of today's spend, or `nil` when there is nothing to say.
  func todayUsageSummary(source: UsageSource) -> UsageTodaySummary? {
    guard let detail = usageDetail(source: effectiveUsageSource(source), period: .today) else {
      return nil
    }
    return UsageValueFormatter.todaySummary(
      tokens: detail.usage.totals.totalTokens,
      cost: detail.usage.cost
    )
  }

  /// The menu-bar item, drawn for `now` — which in the app is ``menuBarClock``, so reading the
  /// label subscribes the item to the clock as well as to the readings.
  func menuBarLabel(
    style: MenuBarStylePreference,
    provider: MenuBarProviderPreference = .automatic,
    arrangement: MenuBarArrangementPreference = .combined,
    now: Date
  ) -> MenuBarLabelModel {
    let layout = MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: ProviderDisplayOrder.enabledProviders()
    )
    return menuBarSpecs(style: style, layout: layout, now: now).first?.label ?? .empty
  }

  func menuBarSpecs(
    style: MenuBarStylePreference,
    layout: MenuBarLayout,
    now: Date
  ) -> [MenuBarStatusItemSpec] {
    MenuBarLabelModel.specs(overview: overview, style: style, layout: layout, now: now)
  }

  func isPreparingUsage(source: UsageSource) -> Bool {
    source == .local ? usageRefreshing : accountRefreshing
  }

  func startLogin() {
    guard loginTask == nil, let client else {
      if self.client == nil { accountErrorMessage = initializationError }
      return
    }
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    loginAuthorizeURL = nil
    browserOpenFailed = false
    isLoggingIn = true
    loginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        isLoggingIn = !Task.isCancelled && authStatus == .loggingIn
        loginTask = nil
      }
      do {
        let result = try await client.login()
        if let raw = result.authorizeURL, let url = URL(string: raw) {
          loginAuthorizeURL = url
          if !loginURLOpener.open(url) {
            browserOpenFailed = true
            let message =
              "QuotaBar could not open your browser. Copy the sign-in link and open it yourself."
            accountActionErrorMessage = message
            accountErrorMessage = message
          }
        }
        // The service stores logging_in before acknowledging this request. From here onward its
        // state/events, rather than the short-lived request task, are authoritative.
        loginTask = nil
        await reloadState()
      } catch is CancellationError {
        return
      } catch {
        accountActionErrorMessage = Self.message(for: error)
        accountErrorMessage = accountActionErrorMessage
        await reloadState()
      }
    }
  }

  /// Calls off a browser sign-in.
  ///
  /// The row keeps its Cancel until the service says the flow is over, so it is easy to press
  /// twice. A second press joins the request already in flight rather than sending the service a
  /// second `cancel_login` to race the first.
  func cancelLogin() {
    guard cancelLoginTask == nil, let client else { return }
    loginTask?.cancel()
    loginTask = nil
    isLoggingIn = false
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    loginAuthorizeURL = nil
    browserOpenFailed = false
    cancelLoginTask = Task { @MainActor [weak self] in
      defer { self?.cancelLoginTask = nil }
      do {
        try await client.cancelLogin()
      } catch {
        let message = Self.message(for: error)
        self?.accountActionErrorMessage = message
        self?.accountErrorMessage = message
        await self?.reloadState()
      }
    }
  }

  func copyLoginLink() {
    guard let url = loginAuthorizeURL else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(url.absoluteString, forType: .string)
  }

  func logout() async {
    guard !isLoggingOut, let client else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    do {
      _ = try await client.logout()
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      accountActionErrorMessage = Self.message(for: error)
      accountErrorMessage = accountActionErrorMessage
      await reloadState()
    }
  }

  func setUsageUploadEnabled(_ enabled: Bool) async {
    guard !isUpdatingUsageUpload, enabled != usageUploadEnabled, let client else { return }
    isUpdatingUsageUpload = true
    defer { isUpdatingUsageUpload = false }
    do {
      usageUploadEnabled = try await client.setUsageUpload(enabled: enabled).enabled
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func overviewItems(for provider: ProviderID) -> [LocalServiceOverviewItem] {
    overview.filter { $0.identity.provider == provider }
  }

  func overviewItem(provider: ProviderID, identityKey: String) -> LocalServiceOverviewItem? {
    overviewItems(for: provider).first { $0.pinIdentityKey == identityKey }
  }

  func setOverviewSourcePin(item: LocalServiceOverviewItem, pin: String?) async {
    guard let client else { return }
    do {
      _ = try await client.setOverviewSourcePin(
        provider: item.identity.provider,
        fingerprint: item.identity.fingerprint,
        scope: item.identity.scope.rawValue,
        identitySourceID: item.identity.sourceID,
        pin: pin
      )
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func setQuotaRefreshInterval(_ interval: QuotaRefreshInterval) async {
    guard !isUpdatingQuotaRefreshInterval, interval.rawValue != quotaRefreshIntervalSeconds,
      let client
    else { return }
    isUpdatingQuotaRefreshInterval = true
    defer { isUpdatingQuotaRefreshInterval = false }
    do {
      quotaRefreshIntervalSeconds =
        try await client.setQuotaRefreshInterval(seconds: interval.rawValue).intervalSeconds
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func setProviderConfig(
    _ provider: ProviderID,
    apiKey: String,
    baseURL: String?
  ) async throws {
    guard let client else {
      throw LocalServiceClientError.serviceMissing
    }
    let config = try await client.setProviderConfig(provider, apiKey: apiKey, baseURL: baseURL)
    providerConfigurations[provider] = config
    await reloadState()
  }

  func removeProviderConfig(_ provider: ProviderID) async throws {
    guard let client else {
      throw LocalServiceClientError.serviceMissing
    }
    let config = try await client.removeProviderConfig(provider)
    providerConfigurations[provider] = config
    await reloadState()
  }

  /// Turning Scan browsers on is the consent gate. Declining leaves every cookie store shut.
  func requestEnableBrowserScan(_ provider: ProviderID) {
    guard provider.browserSession != nil else { return }
    browserSessionErrorMessages[provider] = nil
    browserSessionAccessDenials[provider] = nil
    browserSessionPopup = .consent(provider: provider)
  }

  func confirmProviderBrowserSessionConsent() {
    guard case .consent(let provider) = browserSessionPopup else { return }
    browserSessionPopup = nil
    Task { await setBrowserScan(provider, enabled: true, scanImmediately: true) }
  }

  func setBrowserScanEnabled(_ provider: ProviderID, enabled: Bool) {
    if enabled {
      requestEnableBrowserScan(provider)
      return
    }
    Task { await setBrowserScan(provider, enabled: false, scanImmediately: false) }
  }

  func cancelProviderBrowserSessionFlow() {
    browserSessionPopup = nil
  }

  /// The Agent page row: re-probe, then bring the Browser Access window forward.
  func showBrowserAccessGrants() {
    refreshAccessSnapshot()
    presentBrowserAccessGrants()
  }

  func browserAccessGrantDidRequestFullDiskAccess() {
    fullDiskAccessSettingsOpened = true
    grantPresenter?.openFullDiskAccessSettings()
    refreshAccessSnapshot()
    startFullDiskAccessPolling()
  }

  func browserAccessGrantDidRequestKeychain(_ browser: Browser) {
    Task { await allowKeychain(browser) }
  }

  func browserAccessGrantDidRequestRelaunch() {
    relauncher.relaunch()
  }

  /// The icon landed in the Full Disk Access list. macOS applies that grant on the next
  /// launch, so this is the same place as having opened the pane: offer the relaunch and keep
  /// probing in case it lands sooner.
  func browserAccessGrantDidDropIntoFullDiskAccess() {
    fullDiskAccessSettingsOpened = true
    refreshAccessSnapshot()
    startFullDiskAccessPolling()
  }

  /// Closing the window changes nothing: Scan browsers stays on and the Agent page keeps the
  /// row until the grants arrive.
  func browserAccessGrantDidDismiss() {}

  func coversAccessDenial(_ denial: BrowserAccessDenial) -> Bool {
    switch denial.reason {
    case .fullDiskAccess:
      browserAccessNeeds.contains { $0.kind == .fullDiskAccess }
    case .keychainRefused:
      browserAccessNeeds.contains {
        $0.kind == .keychain && $0.browser.displayName == denial.browserName
      }
    case .storeUnreadable:
      false
    }
  }

  private func setBrowserScan(
    _ provider: ProviderID,
    enabled: Bool,
    scanImmediately: Bool
  ) async {
    guard let client else { return }
    browserSessionWaitingProvider = provider
    browserSessionActivityText = enabled ? "Checking access…" : "Turning off…"
    defer {
      if browserSessionWaitingProvider == provider {
        browserSessionWaitingProvider = nil
        browserSessionActivityText = nil
      }
    }
    do {
      _ = try await client.setProviderBrowserScan(provider, enabled: enabled)
      if enabled {
        browserScanEnabled.insert(provider)
        refreshAccessSnapshot()
        presentBrowserAccessGrants()
        if scanImmediately, !officialCredentialUsable(for: provider) {
          browserSessionActivityText = "Scanning browsers…"
          await scanAndReplaceBrowserSessions(provider)
        }
      } else {
        browserScanEnabled.remove(provider)
        providerBrowserSessions[provider] = []
        browserSessionAccessDenials[provider] = nil
        browserSessionErrorMessages[provider] = nil
        if browserScanEnabled.isEmpty {
          fullDiskAccessSettingsOpened = false
          fullDiskAccessPollTask?.cancel()
          fullDiskAccessPollTask = nil
          browserAccessSnapshot = BrowserAccessSnapshot(statuses: [], awaitingRelaunch: false)
          grantPresenter?.dismiss()
        } else {
          refreshAccessSnapshot()
        }
      }
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      browserSessionErrorMessages[provider] = Self.message(for: error)
    }
  }

  /// Reads every installed browser the current access snapshot allows and hands the service
  /// the whole result. A browser the snapshot says is closed is recorded as a refusal, not
  /// opened: a scheduled scan must never be the thing that shows a permission prompt.
  private func scanAndReplaceBrowserSessions(_ provider: ProviderID) async {
    guard let client, let spec = provider.browserSession else { return }
    guard scanningProviders.insert(provider).inserted else { return }
    defer {
      scanningProviders.remove(provider)
      lastBrowserScanFinishedAt[provider] = Date()
    }
    browserSessionWaitingProvider = provider
    browserSessionActivityText = "Scanning browsers…"
    defer {
      if browserSessionWaitingProvider == provider {
        browserSessionWaitingProvider = nil
        browserSessionActivityText = nil
      }
    }
    let access = browserAccessSnapshot
    var headers: [String] = []
    var seen = Set<String>()
    var denials: [BrowserAccessDenial] = []
    var coverage = BrowserScanCoverage()
    let deadline = Date().addingTimeInterval(30)
    for browser in BrowserSessionImporter.orderedBrowsers(for: spec) {
      guard !Task.isCancelled, Date() < deadline else { break }
      guard let status = access.status(for: browser) else { continue }
      switch status.state {
      case .readable:
        break
      case .needsFullDiskAccess, .needsKeychain:
        let denial = BrowserAccessDenial(
          browserName: browser.displayName,
          reason: status.state == .needsFullDiskAccess ? .fullDiskAccess : .keychainRefused
        )
        if !denials.contains(where: { $0.browserName == denial.browserName }) {
          denials.append(denial)
          browserSessionAccessDenials[provider] = denial
        }
        coverage.skipped.append(browser.displayName)
        continue
      case .unavailable:
        continue
      }
      let outcome = await browserSessionImporter.read(
        spec: spec, browser: browser, now: Date(), deadline: deadline)
      switch outcome {
      case .found(let candidates):
        coverage.read.append(browser.displayName)
        for candidate in candidates where seen.insert(candidate.headerFingerprint).inserted {
          headers.append(candidate.cookieHeader)
        }
      case .accessDenied(let denial):
        coverage.skipped.append(browser.displayName)
        if !denials.contains(where: { $0.browserName == denial.browserName }) {
          denials.append(denial)
        }
        browserSessionAccessDenials[provider] = denial
      case .noSession:
        coverage.read.append(browser.displayName)
      }
    }
    coverage.candidates = headers.count
    browserScanCoverage[provider] = coverage
    do {
      try await client.replaceProviderBrowserSessions(
        provider, cookieHeaders: headers, accessDenials: denials)
      browserSessionScanGeneration += 1
      if denials.isEmpty {
        browserSessionAccessDenials[provider] = nil
        browserSessionErrorMessages[provider] = nil
      } else if let denial = denials.first, !coversAccessDenial(denial) {
        browserSessionErrorMessages[provider] = denial.message
      } else {
        browserSessionErrorMessages[provider] = nil
      }
    } catch is CancellationError {
      return
    } catch {
      browserSessionErrorMessages[provider] = Self.message(for: error)
    }
  }

  private func officialCredentialUsable(for provider: ProviderID) -> Bool {
    guard let result = result(for: provider) else { return false }
    return result.sources.contains { source in
      source.outcome == .success && !Self.isBrowserSessionSource(source.sourceID)
    }
  }

  private static func isBrowserSessionSource(_ sourceID: String) -> Bool {
    SignInRungCatalog.isBrowserSource(sourceID)
  }

  /// A successful collection never re-reads a jar; auth-required is the only failure that does.
  private func shouldAutomaticallyScanBrowsers(for provider: ProviderID) -> Bool {
    let sessions = providerBrowserSessions[provider] ?? []
    guard let result = result(for: provider) else { return sessions.isEmpty }
    if result.outcome == .success { return false }
    return result.outcome == .authRequired
      || result.sources.contains { $0.category == .authRequired }
  }

  private func scheduleBrowserScans(quotaUpdatedAt: Date?, quotaRefreshing: Bool) {
    let enabledChanged = lastBrowserScanEnabled != browserScanEnabled
    lastBrowserScanEnabled = browserScanEnabled

    var providersToScan: [ProviderID] = []
    if !quotaRefreshing {
      let interval = TimeInterval(max(60, quotaRefreshIntervalSeconds))
      let now = Date()
      for provider in browserScanEnabled {
        guard shouldAutomaticallyScanBrowsers(for: provider) else { continue }
        if lastBrowserScanKey[provider] == QuotaCollectionScanKey(updatedAt: quotaUpdatedAt) {
          continue
        }
        if let finished = lastBrowserScanFinishedAt[provider],
          now.timeIntervalSince(finished) < interval
        {
          continue
        }
        providersToScan.append(provider)
      }
    }

    if (enabledChanged && !browserScanEnabled.isEmpty) || !providersToScan.isEmpty {
      refreshAccessSnapshot()
    }

    for provider in providersToScan {
      lastBrowserScanKey[provider] = QuotaCollectionScanKey(updatedAt: quotaUpdatedAt)
      Task { await scanAndReplaceBrowserSessions(provider) }
    }
  }

  private var grantSnapshot: BrowserAccessGrantSnapshot {
    BrowserAccessGrantSnapshot(
      statuses: browserAccessSnapshot.statuses,
      awaitingRelaunch: browserAccessSnapshot.awaitingRelaunch,
      keychainPromptBrowser: keychainPromptBrowser
    )
  }

  /// Probes every installed browser once and redraws the window if it is open. Closing it is
  /// the window's own decision, made when nothing is outstanding any more.
  private func refreshAccessSnapshot() {
    browserAccessSnapshot = accessProbe.snapshot(
      browsers: Browser.defaultImportOrder,
      fullDiskAccessSettingsOpened: fullDiskAccessSettingsOpened
    )
    grantPresenter?.update(grantSnapshot)
  }

  private func presentBrowserAccessGrants() {
    guard browserAccessSnapshot.hasOutstandingGrants else { return }
    grantPresenter?.present(grantSnapshot)
  }

  /// The one read that may show the Keychain prompt, because the person pressed Allow.
  private func allowKeychain(_ browser: Browser) async {
    guard keychainPromptBrowser == nil else { return }
    keychainPromptBrowser = browser
    grantPresenter?.update(grantSnapshot)
    let access = await accessProbe.requestKeychainAccess(for: browser)
    keychainPromptBrowser = nil
    refreshAccessSnapshot()
    if access == .allowed {
      await scanEnabledProvidersMissingOfficialCredentials()
    }
  }

  private func scanEnabledProvidersMissingOfficialCredentials() async {
    for provider in browserScanEnabled where !officialCredentialUsable(for: provider) {
      await scanAndReplaceBrowserSessions(provider)
    }
  }

  /// Full Disk Access usually lands on the next launch, but a cheap directory listing is worth
  /// asking for a few minutes in case it lands sooner; nothing here shows UI.
  private func startFullDiskAccessPolling() {
    fullDiskAccessPollTask?.cancel()
    fullDiskAccessPollTask = Task { @MainActor [weak self] in
      for _ in 0..<150 {
        try? await Task.sleep(for: .seconds(2))
        guard let self, !Task.isCancelled else { return }
        if self.accessProbe.hasFullDiskAccess() {
          self.fullDiskAccessSettingsOpened = false
          self.refreshAccessSnapshot()
          await self.scanEnabledProvidersMissingOfficialCredentials()
          return
        }
      }
    }
  }

  /// The Sign-in rows for one provider: every rung this Mac has, with its last verdict.
  func signInRungs(for provider: ProviderID) -> [SignInRung] {
    let browser: SignInRungPresentation.BrowserState? =
      provider.browserSession == nil
      ? nil
      : SignInRungPresentation.BrowserState(
        isEnabled: browserScanEnabled.contains(provider),
        isScanning: scanningProviders.contains(provider),
        accountLabels: (providerBrowserSessions[provider] ?? []).compactMap(\.accountLabel),
        readBrowsers: browserScanCoverage[provider]?.read ?? [],
        skippedBrowsers: browserScanCoverage[provider]?.skipped ?? [],
        candidatesFound: browserScanCoverage[provider]?.candidates ?? 0
      )
    return SignInRungPresentation.rungs(
      for: provider,
      result: result(for: provider),
      configuration: providerConfigurations[provider],
      browser: browser
    )
  }

  /// One line under a provider's name in the Agents list.
  func agentStatusLine(for provider: ProviderID) -> String {
    SignInRungPresentation.statusLine(
      rungs: signInRungs(for: provider),
      accountCount: overviewItems(for: provider).count,
      reportedByDevices: accountReportingProviders().contains(provider)
    )
  }

  /// Providers with no working credential on this Mac and no account device reporting them.
  func agentsNeedingSignIn() -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      SignInRungPresentation.needsSignIn(rungs: signInRungs(for: provider))
        && !accountReportingProviders().contains(provider)
    }
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  func displaySnapshots(for provider: ProviderID) -> [AccountQuotaPresentation] {
    overview
      .filter { $0.identity.provider == provider }
      .compactMap(Self.presentation)
  }

  func accountReportingProviders() -> Set<ProviderID> {
    Set(
      overview.compactMap { item in
        item.sources.contains(where: { $0.kind == .device }) ? item.identity.provider : nil
      }
    )
  }

  func overviewState(
    enabledProviders: [ProviderID],
    now: Date = Date()
  ) -> QuotaOverviewState {
    let providers: [ProviderQuotaPresentation] = enabledProviders.compactMap { provider in
      let accounts = displaySnapshots(for: provider)
      let result = result(for: provider)
      // Overview asks how much is left, and a row filled by another device's reading has
      // answered. This Mac's own failed collection is then the provider page's and
      // Diagnostics' subject, not the row's. It shows on the row only when this Mac's reading
      // is the one on it — the failure says why that reading stopped moving — or when there
      // is no reading at all.
      let status =
        accounts.isEmpty || showsThisMacsReading(for: provider)
        ? result.flatMap(ProviderStatusCopy.from) : nil
      guard !accounts.isEmpty || status != nil else { return nil }
      return ProviderQuotaPresentation(provider: provider, accounts: accounts, status: status)
    }

    guard !providers.isEmpty else {
      if report != nil { return .empty(refreshWarning: errorMessage) }
      if let errorMessage { return .unavailable(message: errorMessage) }
      return .loading
    }
    return .content(providers: providers, refreshWarning: errorMessage)
  }

  /// Whether any reading Overview shows for the provider was taken on this Mac.
  private func showsThisMacsReading(for provider: ProviderID) -> Bool {
    overview.contains { item in
      item.identity.provider == provider
        && item.sources.contains { $0.sourceID == item.selectedSourceID && $0.kind == .local }
    }
  }

  private func reloadState() async {
    guard let client else {
      errorMessage = initializationError
      return
    }
    do {
      apply(try await client.state())
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func apply(_ state: LocalServiceState) {
    revision = state.revision
    cache = state.cache
    usageUploadEnabled = state.usageUploadEnabled
    quotaRefreshIntervalSeconds = state.quotaRefreshIntervalSeconds
    usagePeriods = state.usagePeriods
    report = state.quota.value
    localUsage = state.usage.value
    accountSummary = state.account.value?.accountSummary
    signInDisplayLabel = state.account.value?.displayLabel
    let incomingAuth =
      state.account.value?.authStatus
      ?? (state.account.status == .signedOut ? .signedOut : nil)
    if incomingAuth == .signedIn {
      if !browserOpenFailed {
        accountActionErrorMessage = nil
      }
      loginAuthorizeURL = nil
      browserOpenFailed = false
    } else if incomingAuth == .loggingIn, authStatus != .loggingIn, !browserOpenFailed {
      accountActionErrorMessage = nil
    } else if incomingAuth != .loggingIn, authStatus == .loggingIn {
      loginAuthorizeURL = nil
      browserOpenFailed = false
    }
    authStatus = incomingAuth
    accountDisconnectReason =
      if authStatus == .signedOut {
        switch state.account.lastError?.code {
        case .deviceDeleted: .deviceDeleted
        case .staleGeneration, .authenticationRequired: .sessionEnded
        default: nil
        }
      } else {
        nil
      }
    overview = state.overview
    advanceMenuBarClock(to: Date(), forNewReadings: true)
    providerConfigurations = Dictionary(
      uniqueKeysWithValues: state.providers.map { ($0.provider, $0) }
    )
    providerBrowserSessions = Dictionary(grouping: state.providerBrowserSessions, by: \.provider)
    browserScanEnabled = Set(state.browserScanEnabled)
    scheduleBrowserScans(
      quotaUpdatedAt: state.quota.updatedAt, quotaRefreshing: state.quota.refreshing)
    usageRefreshing = state.usage.refreshing
    accountRefreshing = state.account.refreshing
    isRefreshing = state.quota.refreshing || usageRefreshing || accountRefreshing
    isLoggingIn = authStatus == .loggingIn || loginTask != nil
    isLoggingOut = authStatus == .logoutPending
    lastCheckedAt = [state.quota.updatedAt, state.usage.updatedAt].compactMap { $0 }.max()

    let componentError = state.quota.lastError ?? state.usage.lastError
    if let componentError {
      errorMessage = LocalServiceClientError.remote(componentError).errorDescription
    } else if state.quota.value != nil || state.usage.value != nil {
      errorMessage = nil
    }

    if let action = accountActionErrorMessage {
      accountErrorMessage = action
    } else if let accountError = state.account.lastError {
      accountErrorMessage = LocalServiceClientError.remote(accountError).errorDescription
    } else {
      accountErrorMessage = nil
    }
  }

  private static func presentation(
    for item: LocalServiceOverviewItem
  ) -> AccountQuotaPresentation? {
    let sourcePairs = item.sources.compactMap { source in
      source.observationSource.map { (source.sourceID, $0) }
    }
    // A selected source the service did not also describe is not a row this panel can stand
    // behind, so the whole observation is dropped rather than shown without provenance.
    guard sourcePairs.contains(where: { $0.0 == item.selectedSourceID }) else { return nil }

    let scope: QuotaSubscriptionIdentity.Scope
    switch item.identity.scope {
    case .global:
      scope = .global
    case .source:
      guard let sourceID = item.identity.sourceID,
        let source = sourcePairs.first(where: { $0.0 == sourceID })?.1
      else { return nil }
      scope = .source(source)
    }

    return AccountQuotaPresentation(
      identity: QuotaSubscriptionIdentity(
        provider: item.identity.provider,
        fingerprint: item.identity.fingerprint,
        scope: scope
      ),
      snapshot: item.snapshot,
      state: item.snapshot.reportedState == .available && item.isStale
        ? .stale
        : item.snapshot.reportedState,
      selectedSourceDisplayName: item.selectedSourceDisplayName
    )
  }

  private static func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return "QuotaBar's local service could not complete the request."
  }
}

protocol LoginURLOpening: Sendable {
  func open(_ url: URL) -> Bool
}

struct WorkspaceLoginURLOpener: LoginURLOpening {
  func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
  }
}
