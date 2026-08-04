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
  /// Local collection issue when this provider has no usable live windows, or a soft warning
  /// alongside cached/remote accounts.
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

  var id: QuotaSubscriptionIdentity { identity }

  var sourceSummary: String {
    let hasLocal = sources.contains(.local)
    let remoteCount = sources.count - (hasLocal ? 1 : 0)
    if hasLocal {
      switch remoteCount {
      case 0: return "Local"
      case 1: return "Local + Remote"
      default: return "Local + \(remoteCount) remote"
      }
    }
    return remoteCount == 1 ? "Remote" : "\(remoteCount) remote"
  }
}

@MainActor
@Observable
final class MenuBarViewModel {
  let relayStateModel: RelayStateModel
  private(set) var report: QuotaCollectionReport?
  private(set) var errorMessage: String?

  var isRefreshing: Bool {
    localRefreshInProgress || relayStateModel.profileStates.values.contains { $0.isRefreshing }
  }

  var refreshedAt: Date? {
    ([localRefreshedAt] + relayStateModel.profileStates.values.map(\.lastSuccessfulRefreshAt))
      .compactMap { $0 }
      .max()
  }

  private var localRefreshInProgress = false

  private var localRefreshedAt: Date?

  @ObservationIgnored
  private let collector: (any LocalQuotaCollecting)?

  @ObservationIgnored
  private let initializationError: String?

  @ObservationIgnored
  private let reportCache: LocalQuotaReportCache?

  init(
    collector: (any LocalQuotaCollecting)? = nil,
    reportCache: LocalQuotaReportCache? = .live,
    relayStateModel: RelayStateModel = RelayStateModel.live()
  ) {
    self.relayStateModel = relayStateModel
    self.reportCache = reportCache
    if let cached = reportCache?.load() {
      report = cached.report
      localRefreshedAt = cached.refreshedAt
    }

    if let collector {
      self.collector = collector
      initializationError = nil
    } else {
      do {
        self.collector = try LocalQuotaClient()
        initializationError = nil
      } catch {
        self.collector = nil
        initializationError = Self.message(for: error)
      }
    }
  }

  #if DEBUG
    init(
      visualTestReport: QuotaCollectionReport?,
      errorMessage: String?,
      refreshedAt: Date?,
      relayStateModel: RelayStateModel = RelayStateModel.live()
    ) {
      self.relayStateModel = relayStateModel
      report = visualTestReport
      self.errorMessage = errorMessage
      localRefreshedAt = refreshedAt
      collector = nil
      initializationError = nil
      reportCache = nil
    }
  #endif

  func refreshIfNeeded(now: Date = Date()) async {
    let localIsFresh = if collector == nil {
      errorMessage != nil
    } else {
      localRefreshedAt.map { now.timeIntervalSince($0) < 60 } == true
    }
    let relayIsFresh = relayStateModel.profiles.allSatisfy { profile in
      guard let state = relayStateModel.state(for: profile.id), state.refreshIssue == nil else {
        return false
      }
      return state.lastSuccessfulRefreshAt.map { now.timeIntervalSince($0) < 60 } == true
    }
    if localIsFresh, relayIsFresh {
      return
    }
    await refresh()
  }

  func refresh() async {
    guard !localRefreshInProgress else { return }

    localRefreshInProgress = true
    defer { localRefreshInProgress = false }

    if let collector {
      do {
        report = try await collector.collect()
        localRefreshedAt = Date()
        if let report, let localRefreshedAt {
          reportCache?.save(report: report, refreshedAt: localRefreshedAt)
        }
        errorMessage = nil
      } catch is CancellationError {
        if Task.isCancelled {
          return
        }
      } catch {
        errorMessage = Self.message(for: error)
      }
    } else {
      errorMessage = initializationError ?? "QuotaCLI is unavailable."
    }

    if !Task.isCancelled {
      await relayStateModel.refreshAllProfiles()
    }
  }

  func deleteAllQuotaBarData() async throws {
    try await relayStateModel.deleteAllQuotaBarData()
    clearLocalState()
  }

  func deleteAllQuotaBarDataLocally() throws {
    try relayStateModel.deleteAllQuotaBarDataLocally()
    clearLocalState()
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  private func clearLocalState() {
    report = nil
    errorMessage = nil
    localRefreshedAt = nil
  }

  func displaySnapshots(
    for provider: ProviderID,
    now: Date = Date()
  ) -> [AccountQuotaPresentation] {
    resolvedSubscriptions(now: now)
      .filter { $0.identity.provider == provider }
      .map(Self.presentation(for:))
  }

  func overviewState(
    enabledProviders: Set<ProviderID>,
    now: Date = Date()
  ) -> QuotaOverviewState {
    let warning = refreshWarning

    let providers: [ProviderQuotaPresentation] = ProviderID.allCases.compactMap { provider in
      guard enabledProviders.contains(provider) else { return nil }
      let accounts = displaySnapshots(for: provider, now: now)
      let status = providerStatus(for: provider)
      guard !accounts.isEmpty || status != nil else { return nil }
      return ProviderQuotaPresentation(provider: provider, accounts: accounts, status: status)
    }

    guard !providers.isEmpty else {
      if hasCompletedRefresh {
        return .empty(refreshWarning: warning)
      }
      if let warning {
        return .unavailable(message: warning)
      }
      return .loading
    }
    return .content(providers: providers, refreshWarning: warning)
  }

  private var hasCompletedRefresh: Bool {
    report != nil
      || relayStateModel.profileStates.values.contains { $0.lastSuccessfulRefreshAt != nil }
  }

  private var refreshWarning: String? {
    var messages: [String] = []
    if let errorMessage {
      messages.append(errorMessage)
    }
    for profile in relayStateModel.profiles {
      guard let message = relayStateModel.state(for: profile.id)?.refreshIssue?.message else {
        continue
      }
      messages.append("\(profile.name): \(message)")
    }
    return messages.isEmpty ? nil : messages.joined(separator: " ")
  }

  private func providerStatus(for provider: ProviderID) -> ProviderStatusCopy? {
    // Prefer live local collection outcomes. Remote-only success still shows accounts above.
    guard let result = result(for: provider) else { return nil }
    return ProviderStatusCopy.from(result: result)
  }

  private func resolvedSubscriptions(now: Date) -> [ResolvedQuotaSubscription] {
    SubscriptionResolver().resolve(observations, now: now)
  }

  private var observations: [QuotaObservation] {
    var observations = report?.results.flatMap { result in
      guard result.outcome == .success else { return [QuotaObservation]() }
      return result.snapshots.compactMap { snapshot in
        Self.isPresentable(snapshot)
          ? QuotaObservation(snapshot: snapshot, source: .local)
          : nil
      }
    } ?? []

    for profile in relayStateModel.profiles {
      guard let state = relayStateModel.state(for: profile.id) else { continue }
      observations.append(contentsOf: state.observations.compactMap { observation in
        guard Self.isPresentable(observation.snapshot) else { return nil }
        return QuotaObservation(
          snapshot: observation.snapshot,
          source: .remote(
            relayInstanceID: profile.instanceID,
            deviceID: observation.deviceID
          )
        )
      })
    }
    return observations
  }

  private static func isPresentable(_ snapshot: QuotaSnapshot) -> Bool {
    !snapshot.windows.isEmpty && (snapshot.status == .available || snapshot.status == .stale)
  }

  private static func presentation(
    for subscription: ResolvedQuotaSubscription
  ) -> AccountQuotaPresentation {
    AccountQuotaPresentation(
      identity: subscription.identity,
      snapshot: subscription.selectedSnapshot,
      isStale: subscription.isStale,
      sources: subscription.sources,
      selectedSource: subscription.selectedSource
    )
  }

  private static func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return "Local quota could not be refreshed."
  }
}
