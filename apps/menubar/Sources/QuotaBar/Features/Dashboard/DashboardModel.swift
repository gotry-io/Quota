import Foundation
import Observation
import QuotaPresentation
import QuotaWire

/// How far back Dashboard used to plot used-percent charts.
///
/// Persisted as `dashboard.range`. The Quota page no longer filters remaining history by
/// range (ADR 0042 keeps thirty days of samples). The key is left unread so a shipped value
/// is not rewritten.
enum DashboardRange: String, CaseIterable, Identifiable, Sendable {
  case today
  case sevenDays = "seven_days"
  case thirtyDays = "thirty_days"

  static let storageKey = "dashboard.range"
  static let fallback = DashboardRange.sevenDays

  var id: Self { self }
}

/// Copy the Quota workspace prints for remaining history and source provenance.
enum DashboardQuotaCopy {
  static let remainingHistory = "Remaining history"
  static let thisMac = "This Mac"
  static let remoteOnlyHistory =
    "This Mac has no readings of its own for this subscription."
  static let notEnoughHistory =
    "This Mac has not collected enough readings to draw remaining history yet."

  static func readings(_ count: Int) -> String {
    count == 1 ? "Readings from 1 device" : "Readings from \(count) devices"
  }
}

/// One subscription as the Quota workspace draws it: a list row and the selected detail.
struct DashboardProvider: Equatable, Identifiable {
  let id: String
  let provider: ProviderID
  /// Distinguishes several accounts of one provider. Omitted when the reading has no label.
  let accountLabel: String?
  let plan: String?
  /// Canonical freshness of the reading on screen (`Updated 3m ago`, or why it is not current).
  let freshness: String
  /// Current-reading windows, shortest-cadence first as the snapshot already ordered them.
  let quotaWindows: [QuotaWindow]
  let currentReading: QuotaSnapshot?
  /// The glance headline the panel prints for this reading (ADR 0035).
  let paceHeadline: String?
  /// The even-pace explanation, shown under the headline on this Quota page.
  let paceDetail: String?
  let resetsAt: Date?
  /// Remaining percent of the tightest (primary cadence) window, when this Mac has a reading.
  let remainingPercent: Double?
  /// Remaining history per window id. Empty unless the reading on screen is the one this Mac
  /// took: nothing else has samples behind it (ADR 0042).
  let remainingHistories: [String: QuotaRemainingHistory]
  let sources: [DashboardSourceRow]
  /// Whether the reading on screen is the one this Mac took for itself.
  let isLocalReading: Bool
  let isStale: Bool

  /// VoiceOver for a list row: provider, account, remaining — once.
  var rowAccessibilityLabel: String {
    var parts = [provider.displayName]
    if let accountLabel {
      parts.append(accountLabel)
    }
    if let remainingPercent {
      parts.append(RemainingQuotaFormat.percent(remainingPercent))
    }
    return parts.joined(separator: ", ")
  }

  /// A window menu is only useful when this Mac has readings to plot for at least one window.
  var showsHistoryWindowPicker: Bool {
    quotaWindows.count > 1
      && remainingHistories.values.contains { !$0.observedPoints.isEmpty }
  }
}

/// One device that contributed a reading of this subscription.
struct DashboardSourceRow: Equatable, Identifiable, Sendable {
  let id: String
  let displayName: String
  let remaining: String?
  let freshness: String
  let isReporting: Bool
  let isLocal: Bool
}

enum DashboardEmptyState: Equatable, Sendable {
  /// Cache is filling in and this Mac has no samples yet. Copy matches `CacheRebuildNotice`.
  case rebuilding
  case noSubscriptions
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

/// Read-only Dashboard projection over `MenuBarViewModel` and its ``UsageModel``. Refresh is
/// the only action it forwards; it never writes preferences, credentials, or Usage.
@Observable
@MainActor
final class DashboardModel {
  let model: MenuBarViewModel
  private var usage: UsageModel { model.usage }
  /// Selected subscription id for this window session. Not persisted.
  var selectedSubscriptionID: String?
  /// Visual QA / deep-link hint: pick this provider's first subscription until the user
  /// chooses otherwise.
  private let preferredProvider: ProviderID?
  /// Account when an account summary is available and Usage sync is on; otherwise This Mac.
  var usageSource: UsageSource = .account

  init(
    model: MenuBarViewModel,
    defaults _: UserDefaults = .standard,
    selection: ProviderID? = nil,
    usageSource: UsageSource = .account
  ) {
    self.model = model
    self.preferredProvider = selection
    self.usageSource = usageSource
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

  func selectSubscription(_ id: String) {
    selectedSubscriptionID = id
  }

  /// Subscriptions with a current reading, in Overview provider order.
  func subscriptions(now: Date) -> [DashboardProvider] {
    sidebarProviders.flatMap { provider in
      model.displaySnapshots(for: provider).map { makeProvider(account: $0, now: now) }
    }
  }

  func resolvedSubscriptionID(now: Date) -> String? {
    let items = subscriptions(now: now)
    if let selectedSubscriptionID, items.contains(where: { $0.id == selectedSubscriptionID }) {
      return selectedSubscriptionID
    }
    if let preferredProvider, let match = items.first(where: { $0.provider == preferredProvider })
    {
      return match.id
    }
    return items.first?.id
  }

  func selectedSubscription(now: Date) -> DashboardProvider? {
    let id = resolvedSubscriptionID(now: now)
    return subscriptions(now: now).first { $0.id == id }
  }

  func pageEmptyState(now: Date) -> DashboardEmptyState? {
    if !subscriptions(now: now).isEmpty { return nil }
    if model.showsCacheRebuildNotice { return .rebuilding }
    return .noSubscriptions
  }

  /// One row per provider × window that had samples on the reader's local day.
  func todayRows(now: Date, resetStyle: ResetCopyStyle = .relative) -> [DashboardTodayRow] {
    let utcOffset = usage.quotaHistorySamples?.utcOffsetSeconds ?? 0
    let startOfDay = Self.localDayStart(now, utcOffsetSeconds: utcOffset)
    return subscriptions(now: now).flatMap { provider in
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

  private func makeProvider(account: AccountQuotaPresentation, now: Date) -> DashboardProvider {
    let key = Self.subscriptionSelector(for: account.identity)
    let snapshot = account.snapshot
    let overviewItem = model.overviewItems(for: account.identity.provider).first {
      $0.identity.subscriptionSelector == key
    }
    let isLocalReading: Bool
    if let overviewItem {
      isLocalReading = overviewItem.sources.contains {
        $0.sourceID == overviewItem.selectedSourceID && $0.kind == .local
      }
    } else {
      isLocalReading = false
    }
    let paceWindow = snapshot.primaryCadenceWindows.first ?? snapshot.windows.first
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
    return DashboardProvider(
      id: key,
      provider: account.identity.provider,
      accountLabel: PlanDisplay.accountLabel(snapshot.account.label),
      plan: PlanDisplay.planBadge(snapshot.account.plan),
      freshness: FreshnessCopy.observation(
        state: account.state, observedAt: snapshot.observedAt, now: now),
      quotaWindows: snapshot.windows,
      currentReading: snapshot,
      paceHeadline: paceHeadline,
      paceDetail: paceDetail,
      resetsAt: paceWindow?.resetsAt,
      remainingPercent: paceWindow?.remainingPercent,
      remainingHistories: isLocalReading
        ? remainingHistories(subscriptionKey: key, snapshot: snapshot, now: now) : [:],
      sources: sourceRows(overviewItem, snapshot: snapshot, now: now),
      isLocalReading: isLocalReading,
      isStale: account.state != .available
    )
  }

  private func remainingHistories(
    subscriptionKey: String,
    snapshot: QuotaSnapshot,
    now: Date
  ) -> [String: QuotaRemainingHistory] {
    let byWindow = usage.quotaHistorySamples?.samplesBySubscription[subscriptionKey] ?? [:]
    var result: [String: QuotaRemainingHistory] = [:]
    for window in snapshot.windows {
      if let history = QuotaRemainingHistory.fold(
        window: QuotaHistoryReading(
          resetsAt: window.resetsAt, cadenceSeconds: window.durationSeconds),
        samples: byWindow[window.id] ?? [],
        usedPercent: window.usedPercent,
        now: now,
        isBalanceOnly: window.isBalanceOnly
      ) {
        result[window.id] = history
      }
    }
    return result
  }

  private func sourceRows(
    _ item: LocalServiceOverviewItem?,
    snapshot: QuotaSnapshot,
    now: Date
  ) -> [DashboardSourceRow] {
    guard let item else { return [] }
    return item.sources.map { source in
      DashboardSourceRow(
        id: source.sourceID,
        displayName: source.displayName,
        remaining: Self.primaryRemaining(source.snapshot ?? snapshot),
        freshness: FreshnessCopy.observation(
          state: source.isStale ? .stale : .available,
          observedAt: source.observedAt,
          now: now
        ),
        isReporting: source.sourceID == item.selectedSourceID,
        isLocal: source.kind == .local
      )
    }
  }

  static func primaryRemaining(_ snapshot: QuotaSnapshot?) -> String? {
    guard let snapshot else { return nil }
    guard let window = snapshot.primaryCadenceWindows.first ?? snapshot.windows.first else {
      return nil
    }
    return window.remainingDisplayLabel
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
