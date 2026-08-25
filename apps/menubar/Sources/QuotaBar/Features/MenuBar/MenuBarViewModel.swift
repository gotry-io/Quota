import AppKit
import Foundation
import Observation
import QuotaPresentation
import QuotaWire

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
  let sources: [QuotaObservationSource]
  let selectedSource: QuotaObservationSource
  let selectedSourceDisplayName: String

  var id: QuotaSubscriptionIdentity { identity }
  var sourceSummary: String { selectedSource.isLocal ? "Local" : "Device" }
  var sourceSymbolName: String { selectedSource.isLocal ? "laptopcomputer" : "desktopcomputer" }
  var sourceAccessibilityLabel: String { "Source: \(selectedSourceDisplayName)" }
}

struct ProviderReportingSourcePresentation: Equatable, Identifiable {
  enum Kind: String, Equatable {
    case local = "Local"
    case device = "Device"
  }

  let id: String
  let displayName: String
  let kind: Kind
  let observedAt: Date
  let isStale: Bool

  var symbolName: String { kind == .local ? "laptopcomputer" : "desktopcomputer" }

  func detailLabel(now: Date) -> String {
    var parts = [kind.rawValue]
    if isStale { parts.append(QuotaObservationState.stale.label) }
    parts.append("\(CompactAgeFormat.string(since: observedAt, now: now)) ago")
    return parts.joined(separator: " · ")
  }
}

struct BrowserSessionAccountChoice: Identifiable, Equatable, Sendable {
  let provider: ProviderID
  let accountFingerprint: String
  let accountLabel: String?
  let browserName: String
  let profileName: String
  let headerFingerprint: String
  let cookieHeader: String

  var id: String { headerFingerprint }
  var title: String { PlanDisplay.accountLabel(accountLabel) ?? "Account" }
  var subtitle: String { "\(browserName) · \(profileName)" }
}

enum ProviderBrowserSessionPopup: Equatable, Sendable {
  case browser(provider: ProviderID, choices: [BrowserApplicationChoice])
  case account(provider: ProviderID, choices: [BrowserSessionAccountChoice])
  case confirmDisconnect(provider: ProviderID)
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
final class MenuBarViewModel {
  private(set) var report: QuotaCollectionReport?
  private(set) var localUsage: LocalUsageReport?
  private(set) var accountSummary: AccountSummary?
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
  private(set) var accountDisconnectReason: AccountDisconnectReason?
  private(set) var lastCheckedAt: Date?
  private(set) var providerConfigurations: [ProviderID: LocalServiceProviderConfig] = [:]
  private(set) var providerBrowserSessions: [ProviderID: LocalServiceProviderBrowserSession] = [:]
  private(set) var browserSessionPopup: ProviderBrowserSessionPopup?
  private(set) var browserSessionErrorMessages: [ProviderID: String] = [:]
  private(set) var browserSessionWaitingProvider: ProviderID?
  private(set) var canCancelBrowserSessionLogin = false
  private(set) var browserSessionActivityText: String?

  private var authStatus: LocalServiceAuthStatus?
  private var overview: [LocalServiceOverviewItem] = []
  private var revision = 0
  private(set) var cache: LocalServiceCacheState = .settled

  var accountState: AccountViewState {
    switch authStatus {
    case .signedIn: .signedIn
    case .logoutPending: .logoutPending
    case .loggingIn, .signedOut: .signedOut
    case nil: .notChecked
    }
  }

  var accountDisplayLabel: String {
    PlanDisplay.accountLabel(accountSummary?.account.displayLabel) ?? "Quota account"
  }

  var accountDeviceSummary: String {
    guard let devices = accountSummary?.devices else {
      return accountState == .signedIn ? "Unavailable" : "Sign in"
    }
    let active = devices.filter { $0.status == .active }.count
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
  private var browserSessionTask: Task<Void, Never>?

  @ObservationIgnored
  private let browserSessionImporter: any BrowserSessionImporting

  @ObservationIgnored
  private let browserApplicationRouter: any BrowserApplicationRouting

  @ObservationIgnored
  private var accountActionErrorMessage: String?

  init(
    client: (any LocalServiceServing)? = nil,
    browserSessionImporter: any BrowserSessionImporting = BrowserSessionImporter(),
    browserApplicationRouter: any BrowserApplicationRouting = WorkspaceBrowserApplicationRouter()
  ) {
    self.browserSessionImporter = browserSessionImporter
    self.browserApplicationRouter = browserApplicationRouter
    if let client {
      self.client = client
      initializationError = nil
    } else {
      do {
        self.client = try LocalServiceClient()
        initializationError = nil
      } catch {
        self.client = nil
        initializationError = Self.message(for: error)
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
      browserApplicationRouter = WorkspaceBrowserApplicationRouter()
      client = nil
      initializationError = nil
      self.errorMessage = errorMessage
      self.lastCheckedAt = lastCheckedAt
      guard let visualTestState else { return }
      report = visualTestState.report
      localUsage = visualTestState.localUsage
      accountSummary = visualTestState.accountSummary
      if let usage = visualTestState.accountSummary?.usage {
        let detail = LocalServiceUsageDetail(
          range: usage.range,
          usage: LocalUsagePeriodSummary(
            totals: UsageSummaryTotals(usage.totals),
            cost: usage.cost,
            agents: usage.agents ?? [],
            modelsTruncated: usage.breakdownsTruncated
          ),
          incomplete: usage.coverage == .partial,
          detailsTruncated: usage.hasTruncatedDetails
        )
        let values = LocalServiceUsagePeriodValues(
          today: detail,
          last7Days: detail,
          last30Days: detail,
          all: detail
        )
        usagePeriods = LocalServiceUsagePeriodCache(local: values, account: values)
      }
      authStatus = visualTestState.authStatus
      overview = visualTestState.overview
      cache = visualTestState.cache
    }
  #endif

  deinit {
    eventTask?.cancel()
    loginTask?.cancel()
    browserSessionTask?.cancel()
  }

  func start() {
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
    let deadline = Date().addingTimeInterval(12)
    var latest = previous
    repeat {
      try await Task.sleep(for: .milliseconds(150))
      latest = try await client.diagnose()
      if latest.refresh.phase == .idle, latest.refresh.revision != previous.refresh.revision {
        return latest
      }
    } while Date() < deadline
    return latest
  }

  func usageDetail(source: UsageSource, period: UsagePeriod) -> LocalServiceUsageDetail? {
    usagePeriods?.detail(source: source, period: period)
  }

  /// Account answers for Usage only while it can. Everywhere the selection is honored uses
  /// this, so Overview and the Usage page never disagree about which numbers are on screen.
  func effectiveUsageSource(_ selected: UsageSource) -> UsageSource {
    !usageUploadEnabled || accountSummary == nil ? .local : selected
  }

  /// The Overview footer's one line of today's spend, or `nil` when there is nothing to say.
  func todayUsageSummary(source: UsageSource) -> UsageTodaySummary? {
    guard let detail = usageDetail(source: effectiveUsageSource(source), period: .today) else {
      return nil
    }
    return UsageValueFormatter.todaySummary(
      tokens: detail.usage.totals.totalTokens,
      cost: detail.usage.cost
    )
  }

  func menuBarLabel(
    preference: MenuBarDisplayPreference,
    now: Date = Date()
  ) -> MenuBarLabelModel {
    MenuBarLabelModel.make(overview: overview, preference: preference, now: now)
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
    isLoggingIn = true
    loginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        isLoggingIn = !Task.isCancelled && authStatus == .loggingIn
        loginTask = nil
      }
      do {
        _ = try await client.login()
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

  func cancelLogin() {
    guard let client else { return }
    loginTask?.cancel()
    loginTask = nil
    isLoggingIn = false
    accountActionErrorMessage = nil
    accountErrorMessage = nil
    Task { @MainActor [weak self] in
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

  func startProviderBrowserSessionLogin(_ provider: ProviderID) {
    guard
      browserSessionTask == nil,
      let spec = provider.browserSession,
      let loginURL = URL(string: spec.loginURL)
    else { return }
    browserSessionErrorMessages[provider] = nil
    let browsers = BrowserSessionImporter.orderedBrowsers(for: spec)
    if let applicationURL = browserApplicationRouter.defaultApplication(for: loginURL),
      let choice = BrowserApplicationCatalog.choice(
        for: applicationURL, allowed: browsers)
    {
      beginBrowserSessionPolling(provider, choice: choice)
      return
    }
    var seen = Set<String>()
    let choices = browserApplicationRouter.applications(for: loginURL)
      .compactMap { BrowserApplicationCatalog.choice(for: $0, allowed: browsers) }
      .filter { seen.insert($0.browser.rawValue).inserted }
      .sorted {
        guard
          let left = browsers.firstIndex(of: $0.browser),
          let right = browsers.firstIndex(of: $1.browser)
        else { return $0.title < $1.title }
        return left < right
      }
    guard !choices.isEmpty else {
      browserSessionErrorMessages[provider] = "No supported browser is available."
      return
    }
    browserSessionPopup = .browser(provider: provider, choices: choices)
  }

  func selectBrowserApplication(_ id: String, provider: ProviderID) {
    guard
      case .browser(let popupProvider, let choices) = browserSessionPopup,
      popupProvider == provider,
      let choice = choices.first(where: { $0.id == id })
    else { return }
    browserSessionPopup = nil
    beginBrowserSessionPolling(provider, choice: choice)
  }

  func selectBrowserSessionAccount(_ id: String) {
    guard
      case .account(_, let choices) = browserSessionPopup,
      let choice = choices.first(where: { $0.id == id })
    else { return }
    browserSessionPopup = nil
    startBrowserSessionCommit(choice)
  }

  func requestProviderBrowserSessionDisconnect(_ provider: ProviderID) {
    browserSessionPopup = .confirmDisconnect(provider: provider)
  }

  func confirmProviderBrowserSessionDisconnect() {
    guard
      case .confirmDisconnect(let provider) = browserSessionPopup,
      let client,
      browserSessionTask == nil
    else { return }
    browserSessionPopup = nil
    browserSessionWaitingProvider = provider
    canCancelBrowserSessionLogin = false
    browserSessionActivityText = "Disconnecting…"
    browserSessionTask = Task { @MainActor [weak self] in
      defer {
        self?.browserSessionTask = nil
        self?.browserSessionWaitingProvider = nil
        self?.browserSessionActivityText = nil
      }
      do {
        _ = try await client.removeProviderBrowserSession(provider)
        await self?.reloadState()
      } catch {
        self?.browserSessionErrorMessages[provider] = Self.message(for: error)
      }
    }
  }

  func cancelProviderBrowserSessionFlow() {
    if canCancelBrowserSessionLogin {
      browserSessionTask?.cancel()
      canCancelBrowserSessionLogin = false
      browserSessionActivityText = "Cancelling…"
    }
    browserSessionPopup = nil
  }

  private func beginBrowserSessionPolling(
    _ provider: ProviderID,
    choice: BrowserApplicationChoice
  ) {
    guard let client, let spec = provider.browserSession,
      let loginURL = URL(string: spec.loginURL)
    else {
      browserSessionErrorMessages[provider] = "Could not open the browser."
      return
    }
    browserSessionWaitingProvider = provider
    canCancelBrowserSessionLogin = true
    browserSessionActivityText = "Waiting for browser sign-in…"
    let currentFingerprint = providerBrowserSessions[provider]?.accountFingerprint
    browserSessionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        browserSessionTask = nil
        browserSessionWaitingProvider = nil
        canCancelBrowserSessionLogin = false
        browserSessionActivityText = nil
      }
      guard await browserApplicationRouter.open(loginURL, with: choice.applicationURL) else {
        if !Task.isCancelled {
          browserSessionErrorMessages[provider] = "Could not open the browser."
        }
        return
      }
      guard !Task.isCancelled else { return }
      let deadline = Date().addingTimeInterval(120)
      var seenHeaders = Set<String>()
      while !Task.isCancelled, Date() < deadline {
        let candidates = await browserSessionImporter.candidates(
          spec: spec, browser: choice.browser, now: Date(), deadline: deadline)
        var accounts: [String: BrowserSessionAccountChoice] = [:]
        for candidate in candidates where !Task.isCancelled && Date() < deadline {
          guard seenHeaders.insert(candidate.headerFingerprint).inserted else { continue }
          do {
            let validated = try await client.validateProviderBrowserSession(
              provider, cookieHeader: candidate.cookieHeader)
            guard !Task.isCancelled, Date() < deadline else { return }
            guard validated.accountFingerprint != currentFingerprint else { continue }
            accounts[candidate.headerFingerprint] = BrowserSessionAccountChoice(
              provider: provider,
              accountFingerprint: validated.accountFingerprint,
              accountLabel: validated.accountLabel,
              browserName: candidate.browserName,
              profileName: candidate.profileName,
              headerFingerprint: candidate.headerFingerprint,
              cookieHeader: candidate.cookieHeader
            )
          } catch is CancellationError {
            return
          } catch {
            continue
          }
        }
        let choices = accounts.values.sorted {
          ($0.accountLabel ?? $0.accountFingerprint)
            .localizedStandardCompare($1.accountLabel ?? $1.accountFingerprint)
            == .orderedAscending
        }
        if choices.count == 1, let candidate = choices.first {
          canCancelBrowserSessionLogin = false
          await commitBrowserSession(candidate)
          return
        }
        if choices.count > 1 {
          browserSessionPopup = .account(provider: provider, choices: choices)
          return
        }
        do {
          try await Task.sleep(for: .seconds(2))
        } catch { return }
      }
      if !Task.isCancelled {
        browserSessionErrorMessages[provider] =
          "No signed-in browser session was found before the request timed out."
      }
    }
  }

  private func startBrowserSessionCommit(_ choice: BrowserSessionAccountChoice) {
    guard browserSessionTask == nil else { return }
    canCancelBrowserSessionLogin = false
    browserSessionTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        browserSessionTask = nil
        browserSessionActivityText = nil
      }
      await commitBrowserSession(choice)
    }
  }

  private func commitBrowserSession(_ choice: BrowserSessionAccountChoice) async {
    guard let client else { return }
    browserSessionWaitingProvider = choice.provider
    browserSessionActivityText = "Connecting…"
    defer {
      browserSessionWaitingProvider = nil
      browserSessionActivityText = nil
    }
    do {
      guard !Task.isCancelled else { return }
      _ = try await client.commitProviderBrowserSession(
        choice.provider, cookieHeader: choice.cookieHeader)
      guard !Task.isCancelled else { return }
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      browserSessionErrorMessages[choice.provider] = Self.message(for: error)
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

  func reportingSources(
    for provider: ProviderID,
    now: Date
  ) -> [ProviderReportingSourcePresentation] {
    var sources: [String: ProviderReportingSourcePresentation] = [:]
    for item in overview where item.identity.provider == provider {
      for source in item.sources {
        let presentation = ProviderReportingSourcePresentation(
          id: source.sourceID,
          displayName: source.displayName,
          kind: source.kind == .local ? .local : .device,
          observedAt: source.observedAt,
          isStale: source.isStale
        )
        if sources[source.sourceID].map({ $0.observedAt < source.observedAt }) != false {
          sources[source.sourceID] = presentation
        }
      }
    }
    return sources.values.sorted {
      $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
    }
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
      // A local failure is about this Mac. Another device's reading fills the row but does
      // not mean collection here is fine, so the failure still shows. A provider that was
      // never set up here has nothing to recover and stays quiet once the account covers it.
      let collectedHere = !(result?.sources.isEmpty ?? true)
      let status =
        accounts.isEmpty || collectedHere ? result.flatMap(ProviderStatusCopy.from) : nil
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

  private func apply(_ state: LocalServiceState) {
    revision = state.revision
    cache = state.cache
    usageUploadEnabled = state.usageUploadEnabled
    usagePeriods = state.usagePeriods
    report = state.quota.value
    localUsage = state.usage.value
    accountSummary = state.account.value?.accountSummary
    authStatus =
      state.account.value?.authStatus
      ?? (state.account.status == .signedOut ? .signedOut : nil)
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
    providerConfigurations = Dictionary(
      uniqueKeysWithValues: state.providers.map { ($0.provider, $0) }
    )
    providerBrowserSessions = Dictionary(
      uniqueKeysWithValues: state.providerBrowserSessions.map { ($0.provider, $0) }
    )
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

    if let accountError = state.account.lastError {
      accountErrorMessage = LocalServiceClientError.remote(accountError).errorDescription
    } else {
      accountErrorMessage = accountActionErrorMessage
    }
  }

  private static func presentation(
    for item: LocalServiceOverviewItem
  ) -> AccountQuotaPresentation? {
    let sourcePairs = item.sources.compactMap { source in
      source.observationSource.map { (source.sourceID, $0) }
    }
    guard
      let selectedSource = sourcePairs.first(where: { $0.0 == item.selectedSourceID })?.1,
      !sourcePairs.isEmpty
    else { return nil }

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
      sources: sourcePairs.map(\.1),
      selectedSource: selectedSource,
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
