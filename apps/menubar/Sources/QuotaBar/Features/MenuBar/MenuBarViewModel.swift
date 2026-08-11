import Foundation
import Observation

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
  let isStale: Bool
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
    if isStale { parts.append("Stale") }
    parts.append("\(CompactAgeFormatter.string(since: observedAt, now: now)) ago")
    return parts.joined(separator: " · ")
  }
}

enum AccountViewState: Equatable {
  case notChecked
  case signedOut
  case logoutPending
  case signedIn
}

#if DEBUG
  struct MenuBarVisualState {
    let report: QuotaCollectionReport
    let localUsage: LocalUsageReport
    let accountSummary: AccountSummary?
    let authStatus: LocalServiceAuthStatus
    let overview: [LocalServiceOverviewItem]
  }
#endif

@MainActor
@Observable
final class MenuBarViewModel {
  private(set) var report: QuotaCollectionReport?
  private(set) var localUsage: LocalUsageReport?
  private(set) var accountSummary: AccountSummary?
  private(set) var errorMessage: String?
  private(set) var accountErrorMessage: String?
  private(set) var isRefreshing = false
  private(set) var isLoggingIn = false
  private(set) var isLoggingOut = false
  private(set) var lastCheckedAt: Date?
  private(set) var providerConfigurations: [ProviderID: LocalServiceProviderConfig] = [:]

  private var authStatus: LocalServiceAuthStatus?
  private var overview: [LocalServiceOverviewItem] = []
  private var revision = 0

  var accountState: AccountViewState {
    switch authStatus {
    case .signedIn: .signedIn
    case .logoutPending: .logoutPending
    case .loggingIn, .signedOut: .signedOut
    case nil: .notChecked
    }
  }

  var accountDisplayLabel: String {
    let label = accountSummary?.account.displayLabel?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return label?.isEmpty == false ? label! : "Quota account"
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

  @ObservationIgnored
  private var eventTask: Task<Void, Never>?

  @ObservationIgnored
  private var loginTask: Task<Void, Never>?

  init(client: (any LocalServiceServing)? = nil) {
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
      client = nil
      initializationError = nil
      self.errorMessage = errorMessage
      self.lastCheckedAt = lastCheckedAt
      guard let visualTestState else { return }
      report = visualTestState.report
      localUsage = visualTestState.localUsage
      accountSummary = visualTestState.accountSummary
      authStatus = visualTestState.authStatus
      overview = visualTestState.overview
    }
  #endif

  deinit {
    eventTask?.cancel()
    loginTask?.cancel()
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
        guard let self, event.revision > revision else { continue }
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

  func startLogin() {
    guard loginTask == nil, let client else {
      if self.client == nil { accountErrorMessage = initializationError }
      return
    }
    accountErrorMessage = nil
    isLoggingIn = true
    loginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        isLoggingIn = authStatus == .loggingIn
        loginTask = nil
      }
      do {
        _ = try await client.login()
        await reloadState()
      } catch is CancellationError {
        return
      } catch {
        accountErrorMessage = Self.message(for: error)
        await reloadState()
      }
    }
  }

  func cancelLogin() {
    guard let client else { return }
    Task { @MainActor [weak self] in
      do {
        try await client.cancelLogin()
      } catch {
        self?.accountErrorMessage = Self.message(for: error)
      }
      self?.loginTask?.cancel()
      self?.loginTask = nil
      self?.isLoggingIn = false
      await self?.reloadState()
    }
  }

  func logout() async {
    guard !isLoggingOut, let client else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    accountErrorMessage = nil
    do {
      _ = try await client.logout()
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      accountErrorMessage = Self.message(for: error)
      await reloadState()
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
      let status = accounts.isEmpty ? providerStatus(for: provider) : nil
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
    report = state.quota.value
    localUsage = state.usage.value
    accountSummary = state.account.value?.accountSummary
    authStatus =
      state.account.value?.authStatus
      ?? (state.account.status == .signedOut ? .signedOut : nil)
    overview = state.overview
    providerConfigurations = Dictionary(
      uniqueKeysWithValues: state.providers.map { ($0.provider, $0) }
    )
    isRefreshing = state.quota.refreshing || state.usage.refreshing || state.account.refreshing
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
    } else if state.account.value != nil {
      accountErrorMessage = nil
    }
  }

  private func providerStatus(for provider: ProviderID) -> ProviderStatusCopy? {
    result(for: provider).flatMap(ProviderStatusCopy.from)
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
      isStale: item.isStale,
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
