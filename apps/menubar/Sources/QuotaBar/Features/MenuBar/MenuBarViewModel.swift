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

@MainActor
@Observable
final class MenuBarViewModel {
  private(set) var report: QuotaCollectionReport?
  private(set) var localUsage: LocalUsageReport?
  private(set) var accountSummary: AccountSummary?
  private(set) var syncStatus: CLIAccountSyncStatus?
  private(set) var syncReason: CLIAccountSyncReason?
  private(set) var errorMessage: String?
  private(set) var accountErrorMessage: String?
  private(set) var isRefreshing = false
  private(set) var isLoggingIn = false
  private(set) var isLoggingOut = false
  private(set) var isLoadingAccountSummary = false
  private(set) var lastCheckedAt: Date?

  var accountState: AccountViewState {
    switch syncStatus {
    case .synced, .accountUnavailable: .signedIn
    case .signedOut: .signedOut
    case .logoutPending: .logoutPending
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
  private let client: (any LocalQuotaServing)?

  @ObservationIgnored
  private let initializationError: String?

  @ObservationIgnored
  private let reportCache: LocalQuotaReportCache?

  @ObservationIgnored
  private let refreshInterval: Duration

  @ObservationIgnored
  private let refreshSleep: @Sendable (Duration) async throws -> Void

  @ObservationIgnored
  private var refreshTask: Task<Void, Never>?

  @ObservationIgnored
  private var loginTask: Task<Void, Never>?

  init(
    client: (any LocalQuotaServing)? = nil,
    reportCache: LocalQuotaReportCache? = .live,
    refreshInterval: Duration = .seconds(300),
    refreshSleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
      try await Task.sleep(for: duration)
    }
  ) {
    self.reportCache = reportCache
    self.refreshInterval = refreshInterval
    self.refreshSleep = refreshSleep

    if let client {
      self.client = client
      initializationError = nil
    } else {
      do {
        self.client = try LocalQuotaClient()
        initializationError = nil
      } catch {
        self.client = nil
        initializationError = Self.message(for: error)
      }
    }

    if let cached = reportCache?.load() {
      apply(cached.output, refreshedAt: cached.refreshedAt)
    }
  }

  #if DEBUG
    init(
      visualTestOutput: CLIAccountSyncOutput?,
      errorMessage: String?,
      lastCheckedAt: Date?
    ) {
      client = nil
      initializationError = nil
      reportCache = nil
      refreshInterval = .seconds(300)
      refreshSleep = { duration in try await Task.sleep(for: duration) }
      self.errorMessage = errorMessage
      if let visualTestOutput {
        apply(visualTestOutput, refreshedAt: lastCheckedAt)
      } else {
        self.lastCheckedAt = lastCheckedAt
      }
    }
  #endif

  deinit {
    refreshTask?.cancel()
    loginTask?.cancel()
  }

  func refreshIfNeeded(now: Date = Date()) async {
    guard lastCheckedAt.map({ now.timeIntervalSince($0) < 60 }) != true else { return }
    await refresh()
  }

  func refresh() async {
    guard !isRefreshing else { return }
    guard let client else {
      errorMessage = initializationError ?? "QuotaCLI is unavailable."
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }
    do {
      let output = try await client.sync()
      let refreshedAt = Date()
      apply(output, refreshedAt: refreshedAt)
      reportCache?.save(output: output, refreshedAt: refreshedAt)
      errorMessage =
        output.status == .accountUnavailable
        ? "Account sync is unavailable. Local quota and Usage are still current."
        : nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  /// The only app-lifetime scheduler: one sync at launch, then one every five minutes.
  func startRefreshLoop() {
    guard refreshTask == nil, client != nil else { return }
    let interval = refreshInterval
    let sleep = refreshSleep
    refreshTask = Task { @MainActor [weak self] in
      await self?.refresh()
      while !Task.isCancelled {
        do {
          try await sleep(interval)
        } catch {
          break
        }
        guard !Task.isCancelled else { break }
        await self?.refresh()
      }
    }
  }

  func startLogin() {
    guard loginTask == nil, let client else {
      if self.client == nil {
        accountErrorMessage = initializationError ?? "QuotaCLI is unavailable."
      }
      return
    }

    accountErrorMessage = nil
    isLoggingIn = true
    loginTask = Task { @MainActor [weak self] in
      guard let self else { return }
      defer {
        isLoggingIn = false
        loginTask = nil
      }
      do {
        _ = try await client.login()
        try Task.checkCancellation()
        await refresh()
      } catch is CancellationError {
        return
      } catch {
        accountErrorMessage = Self.message(for: error)
      }
    }
  }

  func cancelLogin() {
    loginTask?.cancel()
  }

  func logout() async {
    guard !isLoggingOut, let client else { return }
    isLoggingOut = true
    defer { isLoggingOut = false }
    accountErrorMessage = nil
    do {
      _ = try await client.logout()
      accountSummary = nil
      syncStatus = .signedOut
      syncReason = nil
      reportCache?.clear()
      await refresh()
    } catch is CancellationError {
      return
    } catch {
      accountErrorMessage = Self.message(for: error)
      // QuotaCLI may have committed a retryable logout-pending state before an offline revoke.
      await refresh()
    }
  }

  func refreshAccountSummary() async {
    guard accountState == .signedIn, !isLoadingAccountSummary, let client else { return }
    isLoadingAccountSummary = true
    defer { isLoadingAccountSummary = false }
    do {
      accountSummary = try await client.accountSummary()
      accountErrorMessage = nil
      saveCurrentState()
    } catch is CancellationError {
      return
    } catch {
      accountErrorMessage = Self.message(for: error)
    }
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  func displaySnapshots(
    for provider: ProviderID,
    now: Date = Date()
  ) -> [AccountQuotaPresentation] {
    resolvedSubscriptions(now: now)
      .filter { $0.identity.provider == provider }
      .map(presentation)
  }

  func reportingSources(
    for provider: ProviderID,
    now: Date
  ) -> [ProviderReportingSourcePresentation] {
    let grouped = Dictionary(grouping: observations.filter { $0.snapshot.provider == provider }) {
      $0.source
    }
    return grouped.compactMap { source, observations in
      guard let snapshot = observations.map(\.snapshot).max(by: { $0.observedAt < $1.observedAt })
      else { return nil }
      return ProviderReportingSourcePresentation(
        id: source.stableID,
        displayName: displayName(for: source),
        kind: source.isLocal ? .local : .device,
        observedAt: snapshot.observedAt,
        isStale: Self.isStale(snapshot, now: now)
      )
    }
    .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
  }

  func accountReportingProviders() -> Set<ProviderID> {
    Set(accountSummary?.quota.map(\.snapshot.provider) ?? [])
  }

  func overviewState(
    enabledProviders: [ProviderID],
    now: Date = Date()
  ) -> QuotaOverviewState {
    let providers: [ProviderQuotaPresentation] = enabledProviders.compactMap { provider in
      let accounts = displaySnapshots(for: provider, now: now)
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

  private func apply(_ output: CLIAccountSyncOutput, refreshedAt: Date?) {
    report = output.localReport
    localUsage = output.localUsage
    if output.status != .accountUnavailable {
      accountSummary = output.accountSummary
    }
    syncStatus = output.status
    syncReason = output.reason
    lastCheckedAt = refreshedAt
  }

  private func saveCurrentState() {
    guard let report, let localUsage, let accountSummary, let lastCheckedAt else { return }
    reportCache?.save(
      output: CLIAccountSyncOutput(
        status: .synced,
        localReport: report,
        localUsage: localUsage,
        accountSummary: accountSummary
      ),
      refreshedAt: lastCheckedAt
    )
  }

  private func providerStatus(for provider: ProviderID) -> ProviderStatusCopy? {
    result(for: provider).flatMap(ProviderStatusCopy.from)
  }

  private func resolvedSubscriptions(now: Date) -> [ResolvedQuotaSubscription] {
    SubscriptionResolver().resolve(observations, now: now)
  }

  private var observations: [QuotaObservation] {
    if let accountSummary, !accountSummary.quota.isEmpty {
      return accountSummary.quota.compactMap { observation in
        Self.isPresentable(observation.snapshot)
          ? QuotaObservation(
            snapshot: observation.snapshot,
            source: .device(deviceID: observation.deviceID)
          )
          : nil
      }
    }
    return report?.results.flatMap { result in
      guard result.outcome == .success else { return [QuotaObservation]() }
      return result.snapshots.compactMap { snapshot in
        Self.isPresentable(snapshot)
          ? QuotaObservation(snapshot: snapshot, source: .local)
          : nil
      }
    } ?? []
  }

  private static func isPresentable(_ snapshot: QuotaSnapshot) -> Bool {
    !snapshot.windows.isEmpty && (snapshot.status == .available || snapshot.status == .stale)
  }

  private static func isStale(_ snapshot: QuotaSnapshot, now: Date) -> Bool {
    snapshot.status == .stale || snapshot.validUntil.map { $0 <= now } == true
  }

  private func presentation(
    for subscription: ResolvedQuotaSubscription
  ) -> AccountQuotaPresentation {
    AccountQuotaPresentation(
      identity: subscription.identity,
      snapshot: subscription.selectedSnapshot,
      isStale: subscription.isStale,
      sources: subscription.sources,
      selectedSource: subscription.selectedSource,
      selectedSourceDisplayName: displayName(for: subscription.selectedSource)
    )
  }

  private func displayName(for source: QuotaObservationSource) -> String {
    switch source {
    case .local:
      "This Mac"
    case .device(let deviceID):
      accountSummary?.devices.first(where: { $0.deviceID == deviceID })?.displayName
        ?? "Account device"
    }
  }

  private static func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return "QuotaCLI could not complete the request."
  }
}
