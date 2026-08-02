import Foundation
import Observation

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
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  func displaySnapshot(for provider: ProviderID) -> QuotaSnapshot? {
    guard let result = result(for: provider), result.outcome == .success else {
      return nil
    }
    return result.snapshots.first { snapshot in
      !snapshot.windows.isEmpty && (snapshot.status == .available || snapshot.status == .stale)
    }
  }

  func displayedProviders(enabledProviders: Set<ProviderID>) -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      enabledProviders.contains(provider) && displaySnapshot(for: provider) != nil
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
