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
  /// Every contributing source (debug / future use). UI provenance follows selectedSource only.
  let sources: [QuotaObservationSource]
  /// Snapshot chosen by SubscriptionResolver — single source of truth for numbers and badge.
  let selectedSource: QuotaObservationSource
  /// Human label for selectedSource ("This Mac" or Relay device display name).
  let selectedSourceDisplayName: String

  var id: QuotaSubscriptionIdentity { identity }

  /// Compact kind label aligned to selectedSource only (never a multi-source blend).
  var sourceSummary: String {
    selectedSource.isLocal ? "Local" : "Remote"
  }

  var sourceSymbolName: String {
    selectedSource.isLocal ? "laptopcomputer" : "network"
  }

  var sourceAccessibilityLabel: String {
    "Source: \(selectedSourceDisplayName)"
  }
}

struct ProviderReportingSourcePresentation: Equatable, Identifiable {
  enum Kind: String, Equatable {
    case local = "Local"
    case relay = "Relay"
  }

  let id: String
  let displayName: String
  let kind: Kind
  let observedAt: Date
  let isStale: Bool

  var symbolName: String {
    kind == .local ? "laptopcomputer" : "network"
  }

  func detailLabel(now: Date) -> String {
    var parts = [kind.rawValue]
    if isStale {
      parts.append("Stale")
    }
    parts.append("\(CompactAgeFormatter.string(since: observedAt, now: now)) ago")
    return parts.joined(separator: " · ")
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

  /// When QuotaBar last finished a local collect and/or Relay pull (orchestration).
  /// Not provider data age — use each snapshot's `observedAt` for that.
  var lastCheckedAt: Date? {
    ([localLastCheckedAt] + relayStateModel.profileStates.values.map(\.lastSuccessfulRefreshAt))
      .compactMap { $0 }
      .max()
  }

  private var localRefreshInProgress = false

  private var localLastCheckedAt: Date?

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
      localLastCheckedAt = cached.refreshedAt
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
      lastCheckedAt: Date?,
      relayStateModel: RelayStateModel = RelayStateModel.live()
    ) {
      self.relayStateModel = relayStateModel
      report = visualTestReport
      self.errorMessage = errorMessage
      localLastCheckedAt = lastCheckedAt
      collector = nil
      initializationError = nil
      reportCache = nil
    }
  #endif

  func refreshIfNeeded(now: Date = Date()) async {
    let localIsFresh = if collector == nil {
      errorMessage != nil
    } else {
      localLastCheckedAt.map { now.timeIntervalSince($0) < 60 } == true
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
        localLastCheckedAt = Date()
        if let report, let localLastCheckedAt {
          reportCache?.save(report: report, refreshedAt: localLastCheckedAt)
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
    localLastCheckedAt = nil
    reportCache?.clear()
  }

  func displaySnapshots(
    for provider: ProviderID,
    now: Date = Date()
  ) -> [AccountQuotaPresentation] {
    resolvedSubscriptions(now: now)
      .filter { $0.identity.provider == provider }
      .map { presentation(for: $0) }
  }

  func reportingSources(
    for provider: ProviderID,
    now: Date
  ) -> [ProviderReportingSourcePresentation] {
    var sources: [ProviderReportingSourcePresentation] = []

    if let snapshot = latestPresentableLocalSnapshot(for: provider) {
      sources.append(
        ProviderReportingSourcePresentation(
          id: "local",
          displayName: "This Mac",
          kind: .local,
          observedAt: snapshot.observedAt,
          isStale: Self.isStale(snapshot, now: now)
        )
      )
    }

    var seenSources = Set<String>()
    for owned in relayStateModel.ownedDevices where seenSources.insert(owned.id).inserted {
      guard let state = relayStateModel.state(for: owned.profileID) else { continue }
      let snapshots = state.observations.compactMap { observation in
        observation.deviceID == owned.device.deviceID
          && observation.snapshot.provider == provider
          && Self.isPresentable(observation.snapshot)
          ? observation.snapshot
          : nil
      }
      guard let snapshot = snapshots.max(by: { $0.observedAt < $1.observedAt }) else { continue }

      sources.append(
        ProviderReportingSourcePresentation(
          id: owned.id,
          displayName: owned.device.displayName,
          kind: .relay,
          observedAt: snapshot.observedAt,
          isStale: Self.isStale(snapshot, now: now)
        )
      )
    }

    return sources
  }

  func relayReportingProviders(now: Date) -> Set<ProviderID> {
    Set(
      ProviderID.allCases.filter { provider in
        reportingSources(for: provider, now: now).contains { $0.kind == .relay }
      }
    )
  }

  func overviewState(
    enabledProviders: [ProviderID],
    now: Date = Date()
  ) -> QuotaOverviewState {
    let warning = refreshWarning

    let providers: [ProviderQuotaPresentation] = enabledProviders.compactMap { provider in
      let accounts = displaySnapshots(for: provider, now: now)
      // Local auth/error chrome is only for issue-only rows. Once any account (local or
      // remote) is presentable, Overview shows that quota without blending setup-required copy.
      let status = accounts.isEmpty ? providerStatus(for: provider) : nil
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

  private func latestPresentableLocalSnapshot(for provider: ProviderID) -> QuotaSnapshot? {
    guard let result = result(for: provider), result.outcome == .success else { return nil }
    return result.snapshots
      .filter(Self.isPresentable)
      .max(by: { $0.observedAt < $1.observedAt })
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
      return "This Mac"
    case .remote(let relayInstanceID, let deviceID):
      if let profile = relayStateModel.profiles.first(where: { $0.instanceID == relayInstanceID }),
        let device = relayStateModel.state(for: profile.id)?.devices.first(where: {
          $0.deviceID == deviceID
        })
      {
        let name = device.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
          return name
        }
      }
      return "Relay Device"
    }
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
