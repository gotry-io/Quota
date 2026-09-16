import Foundation
import Observation
import QuotaPresentation
import QuotaWire

/// How far back Dashboard plots this Mac's quota samples.
///
/// Persisted as `dashboard.range`. Default is seven days: a week is enough to see a cadence
/// without drawing the whole retention horizon.
enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
  case today
  case sevenDays = "seven_days"
  case thirtyDays = "thirty_days"

  static let storageKey = "dashboard.range"
  static let fallback = DashboardRange.sevenDays

  var id: Self { self }

  var label: String {
    switch self {
    case .today: "Today"
    case .sevenDays: "7D"
    case .thirtyDays: "30D"
    }
  }

  func start(now: Date, calendar: Calendar = .current) -> Date {
    switch self {
    case .today:
      calendar.startOfDay(for: now)
    case .sevenDays:
      now.addingTimeInterval(-7 * 86_400)
    case .thirtyDays:
      now.addingTimeInterval(-Double(QuotaHistory.retentionDays) * 86_400)
    }
  }
}

/// One provider as Dashboard's Quota section draws it.
struct DashboardProvider: Equatable, Identifiable {
  var id: ProviderID { provider }
  let provider: ProviderID
  /// Windows the last `quota_history` fold named for this provider.
  let windows: [QuotaHistoryWindow]
  let currentReading: QuotaSnapshot?
  /// The same sentence the panel prints for this reading (ADR 0035).
  let pacePhrase: String?
  let resetsAt: Date?
  /// `QuotaHistoryCopy.peak` of the current window, or of the highest window the fold named.
  let peak: String?
  let series: [DashboardQuotaSeries]
  let empty: DashboardEmptyState?
}

enum DashboardEmptyState: Equatable, Sendable {
  /// Cache is filling in and this Mac has no samples yet. Copy matches `CacheRebuildNotice`.
  case rebuilding
  /// `SignInRungPresentation.statusLine` for a provider with no working credential here.
  case notSignedIn(String)
  case noHistory
}

/// One window id's samples in the selected range, plus the running window's projection.
struct DashboardQuotaSeries: Equatable, Identifiable, Sendable {
  let id: String
  let title: String
  let rank: Int
  let remainingPercent: Double
  let points: [DashboardQuotaPoint]
  let projection: DashboardQuotaPoint?
  let resetAt: Date?
  let startedAt: Date?
}

struct DashboardQuotaPoint: Equatable, Identifiable, Sendable {
  var id: Date { date }
  let date: Date
  let usedPercent: Double
  /// Which instance of the window this reading belongs to, so the chart draws one line per
  /// instance instead of joining a reset's drop to zero with the reading before it.
  var resetsAt: Date? = nil
}

/// Read-only Dashboard projection over `MenuBarViewModel`. Refresh is the only action it
/// forwards; it never writes preferences, credentials, or Usage.
@Observable
@MainActor
final class DashboardModel {
  let model: MenuBarViewModel
  var range: DashboardRange = .fallback {
    didSet { persistRange() }
  }
  /// `nil` is **All providers**.
  var selection: ProviderID?
  /// Placeholder until WP 7.8 wires Usage. Quota ignores it.
  var usageSource: UsageSource = .account

  @ObservationIgnored
  private let defaults: UserDefaults

  init(
    model: MenuBarViewModel,
    defaults: UserDefaults = .standard,
    selection: ProviderID? = nil
  ) {
    self.model = model
    self.defaults = defaults
    self.selection = selection
    let raw = defaults.string(forKey: DashboardRange.storageKey) ?? ""
    range = DashboardRange(rawValue: raw) ?? .fallback
  }

  var sidebarProviders: [ProviderID] {
    ProviderDisplayOrder.enabledProviders()
  }

  var showsUsageSourcePicker: Bool {
    model.accountSummary != nil
  }

  func providers(now: Date) -> [DashboardProvider] {
    sidebarProviders.map { makeProvider($0, now: now) }
  }

  func displayedProviders(now: Date) -> [DashboardProvider] {
    let all = providers(now: now)
    if let selection {
      return all.filter { $0.provider == selection }
    }
    return all
  }

  func refresh() {
    Task { @MainActor in
      await model.refresh()
      model.loadQuotaHistory()
    }
  }

  func loadHistory() {
    model.loadQuotaHistory()
  }

  private func persistRange() {
    defaults.set(range.rawValue, forKey: DashboardRange.storageKey)
  }

  private func makeProvider(_ provider: ProviderID, now: Date) -> DashboardProvider {
    let accounts = model.displaySnapshots(for: provider)
    let snapshot = accounts.first?.snapshot
    let histories = model.quotaHistory[provider] ?? [:]
    let windows = histories.values.flatMap(\.windowsToday).sorted { $0.startedAt < $1.startedAt }
    let paceWindow = snapshot.flatMap { $0.primaryCadenceWindows.first ?? $0.windows.first }
    let pacePhrase: String?
    if let paceWindow, let pace = paceWindow.pace {
      pacePhrase = QuotaPaceCopy.line(pace, resetsAt: paceWindow.resetsAt)
    } else {
      pacePhrase = nil
    }
    let peakPercent =
      windows.first(where: \.isCurrent)?.peakUsedPercent
      ?? windows.map(\.peakUsedPercent).max()
      ?? paceWindow?.usedPercent
    let series = makeSeries(provider: provider, snapshot: snapshot, now: now)
    return DashboardProvider(
      provider: provider,
      windows: windows,
      currentReading: snapshot,
      pacePhrase: pacePhrase,
      resetsAt: paceWindow?.resetsAt,
      peak: peakPercent.map(QuotaHistoryCopy.peak),
      series: series,
      empty: emptyState(provider: provider, accounts: accounts, series: series)
    )
  }

  private func makeSeries(
    provider: ProviderID,
    snapshot: QuotaSnapshot?,
    now: Date
  ) -> [DashboardQuotaSeries] {
    guard let snapshot else { return [] }
    let start = range.start(now: now)
    let byWindow = model.quotaHistorySamples?.samplesByProvider[provider.rawValue] ?? [:]
    var rank = 0
    var result: [DashboardQuotaSeries] = []
    for window in snapshot.windows {
      guard window.resetsAt != nil, window.durationSeconds != nil else { continue }
      let points = (byWindow[window.id] ?? [])
        .filter { $0.observedAt >= start && $0.observedAt <= now }
        .sorted { $0.observedAt < $1.observedAt }
        .map {
          DashboardQuotaPoint(
            date: $0.observedAt, usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        }
      guard !points.isEmpty else { continue }
      let projection: DashboardQuotaPoint?
      if let projected = model.quotaHistory[provider]?[window.id]?.projection,
        let resetsAt = window.resetsAt, let last = points.last
      {
        projection = Self.projectionPoint(
          from: last, toReset: resetsAt, projectedUsedPercent: projected.usedPercent)
      } else {
        projection = nil
      }
      let startedAt = window.resetsAt.flatMap { reset in
        window.durationSeconds.map { reset.addingTimeInterval(-TimeInterval($0)) }
      }
      result.append(
        DashboardQuotaSeries(
          id: window.id,
          title: window.displayTitle,
          rank: rank,
          remainingPercent: window.remainingPercent,
          points: points,
          projection: projection,
          resetAt: window.resetsAt,
          startedAt: startedAt
        )
      )
      rank += 1
    }
    return result
  }

  /// The projection ends at the reset, or at the moment the line would cross 100%: a window
  /// that runs out runs out, it does not keep climbing off the chart.
  static func projectionPoint(
    from last: DashboardQuotaPoint,
    toReset resetsAt: Date,
    projectedUsedPercent: Double
  ) -> DashboardQuotaPoint {
    guard projectedUsedPercent > 100, projectedUsedPercent > last.usedPercent,
      resetsAt > last.date
    else {
      return DashboardQuotaPoint(
        date: resetsAt, usedPercent: min(projectedUsedPercent, 100), resetsAt: last.resetsAt)
    }
    let fraction = (100 - last.usedPercent) / (projectedUsedPercent - last.usedPercent)
    let runsOutAt = last.date.addingTimeInterval(
      resetsAt.timeIntervalSince(last.date) * max(0, min(1, fraction)))
    return DashboardQuotaPoint(date: runsOutAt, usedPercent: 100, resetsAt: last.resetsAt)
  }

  private func emptyState(
    provider: ProviderID,
    accounts: [AccountQuotaPresentation],
    series: [DashboardQuotaSeries]
  ) -> DashboardEmptyState? {
    if !series.isEmpty { return nil }
    let rungs = model.signInRungs(for: provider)
    let reportedByDevices = model.accountReportingProviders().contains(provider)
    if accounts.isEmpty, SignInRungPresentation.needsSignIn(rungs: rungs), !reportedByDevices {
      return .notSignedIn(
        SignInRungPresentation.statusLine(
          rungs: rungs, accountCount: 0, reportedByDevices: false)
      )
    }
    if model.showsCacheRebuildNotice { return .rebuilding }
    return .noHistory
  }
}
