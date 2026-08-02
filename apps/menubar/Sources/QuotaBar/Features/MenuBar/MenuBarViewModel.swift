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

  var id: ProviderID { provider }
}

struct AccountQuotaPresentation: Equatable, Identifiable {
  let id: String
  let snapshot: QuotaSnapshot
  let isStale: Bool
}

@MainActor
@Observable
final class MenuBarViewModel {
  private(set) var report: QuotaCollectionReport?
  private(set) var isRefreshing = false
  private(set) var errorMessage: String?
  private(set) var refreshedAt: Date?

  @ObservationIgnored
  private let collector: (any LocalQuotaCollecting)?

  @ObservationIgnored
  private let initializationError: String?

  @ObservationIgnored
  private let reportCache: LocalQuotaReportCache?

  init(
    collector: (any LocalQuotaCollecting)? = nil,
    reportCache: LocalQuotaReportCache? = .live,
    startsAutomatically: Bool = true
  ) {
    self.reportCache = reportCache
    if let cached = reportCache?.load() {
      report = cached.report
      refreshedAt = cached.refreshedAt
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

    if startsAutomatically {
      Task { [weak self] in
        await self?.refreshIfNeeded()
      }
    }
  }

  #if DEBUG
    init(
      visualTestReport: QuotaCollectionReport?,
      errorMessage: String?,
      refreshedAt: Date?
    ) {
      report = visualTestReport
      self.errorMessage = errorMessage
      self.refreshedAt = refreshedAt
      collector = nil
      initializationError = nil
      reportCache = nil
    }
  #endif

  func refreshIfNeeded(now: Date = Date()) async {
    if let refreshedAt, now.timeIntervalSince(refreshedAt) < 60 {
      return
    }
    await refresh()
  }

  func refresh() async {
    guard !isRefreshing else { return }
    guard let collector else {
      errorMessage = initializationError ?? "QuotaCLI is unavailable."
      return
    }

    isRefreshing = true
    defer { isRefreshing = false }

    do {
      report = try await collector.collect()
      refreshedAt = Date()
      if let report, let refreshedAt {
        reportCache?.save(report: report, refreshedAt: refreshedAt)
      }
      errorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  func displaySnapshots(
    for provider: ProviderID,
    now: Date = Date()
  ) -> [AccountQuotaPresentation] {
    guard let result = result(for: provider), result.outcome == .success else {
      return []
    }

    return result.snapshots.enumerated().compactMap { index, snapshot in
      guard !snapshot.windows.isEmpty,
        snapshot.status == .available || snapshot.status == .stale
      else {
        return nil
      }

      return AccountQuotaPresentation(
        id: "\(snapshot.account.fingerprint):\(index)",
        snapshot: snapshot,
        isStale: snapshot.status == .stale || snapshot.validUntil.map({ $0 <= now }) == true
      )
    }
  }

  func overviewState(
    enabledProviders: Set<ProviderID>,
    now: Date = Date()
  ) -> QuotaOverviewState {
    guard report != nil else {
      if let errorMessage {
        return .unavailable(message: errorMessage)
      }
      return .loading
    }

    let providers: [ProviderQuotaPresentation] = ProviderID.allCases.compactMap { provider in
      guard enabledProviders.contains(provider) else { return nil }
      let accounts = displaySnapshots(for: provider, now: now)
      guard !accounts.isEmpty else { return nil }
      return ProviderQuotaPresentation(provider: provider, accounts: accounts)
    }

    guard !providers.isEmpty else {
      return .empty(refreshWarning: errorMessage)
    }
    return .content(providers: providers, refreshWarning: errorMessage)
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
