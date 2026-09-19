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

/// One subscription as Dashboard's Quota section draws it.
struct DashboardProvider: Equatable, Identifiable {
  let id: String
  let provider: ProviderID
  /// Distinguishes several accounts of one provider. Omitted when the reading has no label.
  let accountLabel: String?
  /// Windows the last `quota_history` fold named for this subscription.
  let windows: [QuotaHistoryWindow]
  let currentReading: QuotaSnapshot?
  /// The glance headline the panel prints for this reading (ADR 0035).
  let paceHeadline: String?
  /// The even-pace explanation, shown under the headline on this Quota page.
  let paceDetail: String?
  let resetsAt: Date?
  /// `QuotaHistoryCopy.peak` of the current window, or of the highest window the fold named.
  let peak: String?
  /// Remaining percent of the primary cadence window, when this Mac has a reading.
  let remainingPercent: Double?
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

/// One provider × window that had samples on the reader's local day.
struct DashboardTodayRow: Equatable, Identifiable, Sendable {
  let id: String
  let provider: ProviderID
  let windowTitle: String
  /// Used percent at the start of the local day, or at the first sample of a window that
  /// started today.
  let usedStartPercent: Double
  let usedNowPercent: Double
  /// Today's cost when Usage can attribute it to this provider; nil otherwise.
  let cost: String?
  let resetAt: Date
  let resetText: String

  var windowName: String { "\(provider.displayName) · \(windowTitle)" }

  var usedLine: String {
    "\(QuotaHistoryCopy.peak(usedStartPercent)) → \(QuotaHistoryCopy.peak(usedNowPercent))"
  }
}

struct DashboardQuotaPoint: Equatable, Identifiable, Sendable {
  var id: Date { date }
  let date: Date
  let usedPercent: Double
  /// Which instance of the window this reading belongs to, so the chart draws one line per
  /// instance instead of joining a reset's drop to zero with the reading before it.
  var resetsAt: Date? = nil
}

/// Read-only Dashboard projection over `MenuBarViewModel` and its ``UsageModel``. Refresh is
/// the only action it forwards; it never writes preferences, credentials, or Usage.
@Observable
@MainActor
final class DashboardModel {
  let model: MenuBarViewModel
  private var usage: UsageModel { model.usage }
  var range: DashboardRange = .fallback {
    didSet { persistRange() }
  }
  /// `nil` is **All providers**.
  var selection: ProviderID?
  /// Account when an account summary is available and Usage sync is on; otherwise This Mac.
  var usageSource: UsageSource = .account

  @ObservationIgnored
  private let defaults: UserDefaults

  init(
    model: MenuBarViewModel,
    defaults: UserDefaults = .standard,
    selection: ProviderID? = nil,
    usageSource: UsageSource = .account
  ) {
    self.model = model
    self.defaults = defaults
    self.selection = selection
    self.usageSource = usageSource
    let raw = defaults.string(forKey: DashboardRange.storageKey) ?? ""
    range = DashboardRange(rawValue: raw) ?? .fallback
  }

  var sidebarProviders: [ProviderID] {
    ProviderDisplayOrder.enabledProviders()
  }

  var showsUsageSourcePicker: Bool {
    model.accountSummary != nil && model.usageUploadEnabled
  }

  /// The source Usage actually answers from. Account is only honest while a summary exists
  /// and sync is on.
  var presentedUsageSource: UsageSource {
    usage.effectiveUsageSource(usageSource)
  }

  /// The six-item period control's selection. A custom range selects none of them.
  var selectedUsagePeriodSegment: UsagePeriodSegment? {
    let segment = usage.usagePeriod.segment
    return segment == .custom ? nil : segment
  }

  var usagePeriod: UsagePeriodSelection { usage.usagePeriod }

  /// The per-window Today table belongs on Usage only while the selected period is Today.
  var showsTodayWindows: Bool { usagePeriod == .today }

  /// Projects stay on This Mac (ADR 0039). Account Usage has no such table.
  var showsUsageProjects: Bool {
    presentedUsageSource == .local && model.groupUsageByProject
  }

  func selectUsagePeriod(_ selection: UsagePeriodSelection) {
    usage.selectUsagePeriod(selection)
  }

  func usagePeriodTitle(now: Date) -> String {
    usage.usagePeriodTitle(now: now)
  }

  func providers(now: Date) -> [DashboardProvider] {
    sidebarProviders.flatMap { provider in
      let accounts = model.displaySnapshots(for: provider)
      if accounts.isEmpty {
        return [makeEmptyProvider(provider, now: now)]
      }
      return accounts.map { makeProvider(account: $0, now: now) }
    }
  }

  func displayedProviders(now: Date) -> [DashboardProvider] {
    let all = providers(now: now)
    if let selection {
      return all.filter { $0.provider == selection }
    }
    return all
  }

  /// One row per provider × window that had samples on the reader's local day.
  func todayRows(now: Date, resetStyle: ResetCopyStyle = .relative) -> [DashboardTodayRow] {
    let utcOffset = usage.quotaHistorySamples?.utcOffsetSeconds ?? 0
    let startOfDay = Self.localDayStart(now, utcOffsetSeconds: utcOffset)
    return displayedProviders(now: now).flatMap { provider in
      todayRows(
        for: provider,
        now: now,
        startOfDay: startOfDay,
        utcOffsetSeconds: utcOffset,
        resetStyle: resetStyle
      )
    }
  }

  func presentedUsage(now: Date) -> DashboardUsagePresentation {
    let source = presentedUsageSource
    let selection = usage.usagePeriod
    let detail = usage.usageDetail(source: source, selection: selection)
    let presented = detail.map { presentedUsage(from: $0, source: source) }
    return DashboardUsagePresentation(
      source: source,
      refreshWarning: model.errorMessage,
      accountWarning: source == .account ? model.accountErrorMessage : nil,
      statusWarning: usageStatusWarning(detail: detail, source: source),
      usage: presented,
      sessions: usage.localUsage?.sessions,
      isPreparing: usage.isPreparingUsage(source: source) || usage.customUsageLoading,
      title: usage.usagePeriodTitle(now: now),
      available: usage.usagePeriodIsAvailable(source: source, selection: selection),
      budget: usage.budgetProgress,
      showsProjects: showsUsageProjects
    )
  }

  func refresh() {
    Task { @MainActor in
      await model.refresh()
      usage.loadQuotaHistory()
    }
  }

  func loadHistory() {
    usage.loadQuotaHistory()
  }

  private func persistRange() {
    defaults.set(range.rawValue, forKey: DashboardRange.storageKey)
  }

  private func makeEmptyProvider(_ provider: ProviderID, now: Date) -> DashboardProvider {
    makeProvider(
      id: "empty:\(provider.rawValue)",
      provider: provider,
      accountLabel: nil,
      snapshot: nil,
      subscriptionKey: nil,
      accounts: [],
      now: now
    )
  }

  private func makeProvider(account: AccountQuotaPresentation, now: Date) -> DashboardProvider {
    let key = Self.subscriptionSelector(for: account.identity)
    return makeProvider(
      id: key,
      provider: account.identity.provider,
      accountLabel: PlanDisplay.accountLabel(account.snapshot.account.label),
      snapshot: account.snapshot,
      subscriptionKey: key,
      accounts: [account],
      now: now
    )
  }

  private func makeProvider(
    id: String,
    provider: ProviderID,
    accountLabel: String?,
    snapshot: QuotaSnapshot?,
    subscriptionKey: String?,
    accounts: [AccountQuotaPresentation],
    now: Date
  ) -> DashboardProvider {
    let histories = subscriptionKey.flatMap { usage.quotaHistory[$0] } ?? [:]
    let windows = histories.values.flatMap(\.windowsToday).sorted { $0.startedAt < $1.startedAt }
    let paceWindow = snapshot.flatMap { $0.primaryCadenceWindows.first ?? $0.windows.first }
    let paceHeadline: String?
    let paceDetail: String?
    if let paceWindow, let pace = paceWindow.pace,
      let headline = QuotaPaceCopy.headline(pace, resetsAt: paceWindow.resetsAt)
    {
      paceHeadline = headline
      paceDetail = QuotaPaceCopy.detail(pace)
    } else {
      paceHeadline = nil
      paceDetail = nil
    }
    let peakPercent =
      windows.first(where: \.isCurrent)?.peakUsedPercent
      ?? windows.map(\.peakUsedPercent).max()
      ?? paceWindow?.usedPercent
    let series = makeSeries(
      subscriptionKey: subscriptionKey, snapshot: snapshot, now: now)
    return DashboardProvider(
      id: id,
      provider: provider,
      accountLabel: accountLabel,
      windows: windows,
      currentReading: snapshot,
      paceHeadline: paceHeadline,
      paceDetail: paceDetail,
      resetsAt: paceWindow?.resetsAt,
      peak: peakPercent.map(QuotaHistoryCopy.peak),
      remainingPercent: paceWindow?.remainingPercent,
      series: series,
      empty: emptyState(provider: provider, accounts: accounts, series: series)
    )
  }

  private func makeSeries(
    subscriptionKey: String?,
    snapshot: QuotaSnapshot?,
    now: Date
  ) -> [DashboardQuotaSeries] {
    guard let snapshot, let subscriptionKey else { return [] }
    let start = range.start(now: now)
    let byWindow = usage.quotaHistorySamples?.samplesBySubscription[subscriptionKey] ?? [:]
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
      if let projected = usage.quotaHistory[subscriptionKey]?[window.id]?.projection,
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

  static func subscriptionSelector(for identity: QuotaSubscriptionIdentity) -> String {
    let sourceID: String?
    let scope: String
    switch identity.scope {
    case .global:
      sourceID = nil
      scope = "global"
    case .source(.local):
      sourceID = "local"
      scope = "source"
    case .source(.device(let id)):
      sourceID = id
      scope = "source"
    }
    return SubscriptionSelector.make(
      provider: identity.provider.rawValue,
      fingerprint: identity.fingerprint,
      fingerprintScope: scope,
      sourceID: sourceID
    )
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

  private func todayRows(
    for provider: DashboardProvider,
    now: Date,
    startOfDay: Date,
    utcOffsetSeconds: Int,
    resetStyle: ResetCopyStyle
  ) -> [DashboardTodayRow] {
    let byWindow = usage.quotaHistorySamples?.samplesBySubscription[provider.id] ?? [:]
    let histories = usage.quotaHistory[provider.id] ?? [:]
    let cost = todayCost(for: provider.provider)
    let snapshotWindows = Dictionary(
      uniqueKeysWithValues: (provider.currentReading?.windows ?? []).map { ($0.id, $0) }
    )
    var rows: [DashboardTodayRow] = []
    for (windowId, history) in histories {
      let title = snapshotWindows[windowId]?.displayTitle ?? windowId
      let samples = byWindow[windowId] ?? []
      for window in history.windowsToday {
        let instance = samples.filter { $0.resetsAt == window.resetsAt }
          .sorted { $0.observedAt < $1.observedAt }
        let todaySamples = instance.filter {
          $0.observedAt >= startOfDay && $0.observedAt <= now
        }
        guard !todaySamples.isEmpty else { continue }
        let usedStart =
          instance.last { $0.observedAt <= startOfDay }?.usedPercent
          ?? todaySamples.first?.usedPercent
          ?? window.peakUsedPercent
        let usedNow = todaySamples.last?.usedPercent ?? window.peakUsedPercent
        rows.append(
          DashboardTodayRow(
            id: "\(provider.id)|\(windowId)|\(window.startedAt.timeIntervalSince1970)",
            provider: provider.provider,
            windowTitle: title,
            usedStartPercent: usedStart,
            usedNowPercent: usedNow,
            cost: cost,
            resetAt: window.resetsAt,
            resetText: Self.resetColumn(resetsAt: window.resetsAt, now: now, style: resetStyle)
          )
        )
      }
    }
    return rows.sorted {
      $0.resetAt == $1.resetAt
        ? $0.windowTitle.localizedStandardCompare($1.windowTitle) == .orderedAscending
        : $0.resetAt < $1.resetAt
    }
  }

  private func todayCost(for provider: ProviderID) -> String? {
    guard let detail = usage.usageDetail(source: presentedUsageSource, period: .today) else {
      return nil
    }
    guard
      let agent = detail.usage.agents.first(where: { $0.agent.menuBarProvider == provider })
    else {
      return nil
    }
    return MenuBarTodayUsage.make(tokens: agent.totals.totalTokens, cost: agent.cost).cost?.text
  }

  private func presentedUsage(
    from detail: LocalServiceUsageDetail,
    source: UsageSource
  ) -> DashboardPresentedUsage {
    let usage = detail.usage
    let models = usage.agents.flatMap { agent in
      agent.providers.flatMap { provider in
        provider.models.map {
          DashboardPresentedUsageModel($0, provider: provider.provider, agent: agent.agent)
        }
      }
    }
    return DashboardPresentedUsage(
      totals: DashboardPresentedUsageTotals(usage.totals),
      cost: usage.cost,
      cacheSaved: usage.cacheSaved,
      cacheHitBasisPoints: usage.cacheHitBasisPoints,
      days: usage.days,
      hoursOfDay: usage.hoursOfDay,
      models: models,
      projects: source == .local && model.groupUsageByProject ? usage.projects : nil
    )
  }

  private func usageStatusWarning(detail: LocalServiceUsageDetail?, source: UsageSource) -> String?
  {
    guard let detail, detail.incomplete || detail.detailsTruncated else { return nil }
    return source == .local
      ? "Some local Usage may be incomplete."
      : "Some account Usage may be incomplete."
  }

  /// The reader's local midnight for `now`, using the offset the samples were folded with.
  static func localDayStart(_ now: Date, utcOffsetSeconds: Int) -> Date {
    let day = Int(
      ((now.timeIntervalSince1970 + Double(utcOffsetSeconds)) / 86_400).rounded(.down))
    return Date(timeIntervalSince1970: Double(day) * 86_400 - Double(utcOffsetSeconds))
  }

  static func resetColumn(resetsAt: Date, now: Date, style: ResetCopyStyle) -> String {
    if let copy = FreshnessCopy.resetCopy(resetsAt: resetsAt, now: now, style: style) {
      return copy
    }
    let formatter = DateFormatter()
    formatter.locale = Locale.autoupdatingCurrent
    formatter.setLocalizedDateFormatFromTemplate("jm")
    return formatter.string(from: resetsAt)
  }
}

struct DashboardUsagePresentation: Equatable {
  let source: UsageSource
  let refreshWarning: String?
  let accountWarning: String?
  let statusWarning: String?
  let usage: DashboardPresentedUsage?
  let sessions: LocalUsageSessions?
  let isPreparing: Bool
  let title: String
  let available: Bool
  let budget: UsageBudgetProgress?
  let showsProjects: Bool
}

struct DashboardPresentedUsage: Equatable {
  let totals: DashboardPresentedUsageTotals
  let cost: UsageCostOutcome
  let cacheSaved: UsageCacheSaved
  let cacheHitBasisPoints: Int?
  let days: [LocalUsageDay]?
  let hoursOfDay: [LocalUsageHourOfDay]?
  let models: [DashboardPresentedUsageModel]
  let projects: [LocalUsageProjectSummary]?
}

struct DashboardPresentedUsageTotals: Equatable {
  let totalTokens: Int
  let inputTokens: Int
  let outputTokens: Int
  let cacheReadInputTokens: Int
  let cacheWriteInputTokens: Int
  let reasoningTokens: Int
  let messages: Int

  init(_ totals: UsageSummaryTotals) {
    totalTokens = totals.totalTokens
    inputTokens = totals.inputTokens
    outputTokens = totals.outputTokens
    cacheReadInputTokens = totals.cacheReadInputTokens
    cacheWriteInputTokens = totals.cacheWriteInputTokens
    reasoningTokens = totals.reasoningTokens
    messages = totals.messages
  }
}

struct DashboardPresentedUsageModel: Equatable {
  let provider: InferenceProvider?
  let agent: BillingAgent?
  let model: String
  let totals: DashboardPresentedUsageTotals
  let cost: UsageCostOutcome

  var id: String {
    "\(agent?.rawValue ?? "account"):\(provider?.rawValue ?? "unknown"):\(model)"
  }

  init(
    _ model: LocalUsageModelSummary,
    provider: InferenceProvider,
    agent: BillingAgent
  ) {
    self.provider = provider
    self.agent = agent
    self.model = model.model
    totals = DashboardPresentedUsageTotals(model.totals)
    cost = model.cost
  }
}

struct DashboardPresentedUsageProvider: Identifiable {
  let provider: InferenceProvider?
  let models: [DashboardPresentedUsageModel]

  var id: String { provider?.rawValue ?? "unknown" }
}
