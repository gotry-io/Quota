import Foundation
import Observation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation

/// The IPC calls Usage makes. The rest of the local service stays on the app coordinator.
protocol UsageTransport: Sendable {
  /// One custom period: This Mac's hours, or Relay's Account period read.
  func usagePeriod(
    from: String, to: String, source: UsageSource, timezone: String
  ) async throws -> LocalServiceUsageDetail
  /// This Mac's stored quota samples since `since`. Reads cache.sqlite only.
  func quotaHistory(since: Date) async throws -> LocalServiceQuotaHistory
}

/// Usage, history, and the monthly budget. Login and quota projection stay on
/// ``MenuBarViewModel``, which hands each accepted service state through ``acceptState``.
/// Browser consent lives on ``BrowserConnectionModel``.
@Observable
@MainActor
final class UsageModel {
  private(set) var localUsage: LocalUsageReport?
  private(set) var usagePeriods: LocalServiceUsagePeriodCache?
  /// Which period Dashboard Usage is showing.
  private(set) var usagePeriod: UsagePeriodSelection = .today
  /// Custom periods already answered, keyed `source|from|to`. Memory only: a fold is cheap and
  /// the four `get_state` carries are the ones worth keeping.
  private(set) var customUsagePeriods: [String: LocalServiceUsageDetail] = [:]
  private(set) var customUsageLoading = false
  /// Folded 30-day quota history, keyed subscription selector then window id. Empty until
  /// ``loadQuotaHistory()``; state pushes keep the current-window slice Overview already draws.
  private(set) var quotaHistory: [String: [String: QuotaHistory]] = [:]
  /// The samples the last `quota_history` read returned, so a later surface can re-fold a range.
  private(set) var quotaHistorySamples: LocalServiceQuotaHistory?
  /// Why the last `quota_history` read failed. Dashboard's line, not the panel's.
  private(set) var quotaHistoryErrorMessage: String?
  /// This Mac's monthly budget, and how far into it this month's local spend has gone.
  private(set) var budget: UsageBudget
  private(set) var budgetMonthDetail: LocalServiceUsageDetail?
  private(set) var usageRefreshing = false

  @ObservationIgnored
  private let transport: (any UsageTransport)?

  @ObservationIgnored
  private let budgetStore: UsageBudgetStore

  @ObservationIgnored
  private let notificationSink: any AlertSink

  @ObservationIgnored
  private let now: @MainActor () -> Date

  @ObservationIgnored
  var onRequestError: (@MainActor (String) -> Void)?

  @ObservationIgnored
  private var customUsageTask: Task<Void, Never>?

  @ObservationIgnored
  private var customUsageGeneration: UInt64 = 0

  /// Last source Dashboard asked a custom period for. Summary periods ignore it.
  @ObservationIgnored
  private var customPeriodSource: UsageSource = .account

  @ObservationIgnored
  private var budgetMonthTask: Task<Void, Never>?

  @ObservationIgnored
  private var budgetMonthGeneration: UInt64 = 0

  @ObservationIgnored
  private var quotaHistoryTask: Task<Void, Never>?

  /// Overview rows used to fold `quota_history`. Updated from ``acceptState``; not a second
  /// copy of service state beyond what folding needs.
  @ObservationIgnored
  private var historyOverview: [LocalServiceOverviewItem] = []

  private var usageUploadEnabled = true
  private var hasAccountSummary = false
  private var accountRefreshing = false

  init(
    transport: (any UsageTransport)?,
    budgetStore: UsageBudgetStore,
    notificationSink: any AlertSink,
    now: @escaping @MainActor () -> Date = { Date() },
    budget: UsageBudget? = nil
  ) {
    self.transport = transport
    self.budgetStore = budgetStore
    self.notificationSink = notificationSink
    self.now = now
    self.budget = budget ?? budgetStore.load()
  }

  deinit {
    customUsageTask?.cancel()
    budgetMonthTask?.cancel()
    quotaHistoryTask?.cancel()
  }

  /// Takes the Usage slice of an accepted `get_state`. Custom folds are discarded and asked
  /// for again, matching today's `apply`: every incoming state rebuilds them.
  func acceptState(_ state: LocalServiceState) {
    usagePeriods = state.usagePeriods
    localUsage = state.usage.value
    usageRefreshing = state.usage.refreshing
    accountRefreshing = state.account.refreshing
    usageUploadEnabled = state.usageUploadEnabled
    hasAccountSummary = state.account.value?.accountSummary != nil
    historyOverview = state.overview
    customUsagePeriods = [:]
    loadCustomUsagePeriod()
    refreshBudgetMonth()
  }

  /// Seeds the visual fixture without going through ``acceptState``, which would clear folds
  /// and start IPC loads this fixture has no transport for.
  func applyVisualFixture(
    localUsage: LocalUsageReport?,
    usagePeriods: LocalServiceUsagePeriodCache?,
    budgetMonthDetail: LocalServiceUsageDetail?,
    budget: UsageBudget,
    quotaHistorySamples: LocalServiceQuotaHistory?,
    overview: [LocalServiceOverviewItem],
    now: Date,
    usageUploadEnabled: Bool,
    hasAccountSummary: Bool
  ) {
    self.localUsage = localUsage
    self.usagePeriods = usagePeriods
    self.budgetMonthDetail = budgetMonthDetail
    self.budget = budget
    self.usageUploadEnabled = usageUploadEnabled
    self.hasAccountSummary = hasAccountSummary
    historyOverview = overview
    if let quotaHistorySamples {
      self.quotaHistorySamples = quotaHistorySamples
      quotaHistory = Self.foldQuotaHistory(
        quotaHistorySamples, overview: overview, now: now)
    }
  }

  func usageDetail(source: UsageSource, period: UsagePeriod) -> LocalServiceUsageDetail? {
    usagePeriods?.detail(source: source, period: period)
  }

  /// The selected period, read from the four a refresh folds or from a custom `usage_period`.
  ///
  /// The four periods `get_state` carries are the same on both sources. Anything else is one
  /// range at a time: This Mac folds stored hours, Account reads Relay's local-date period.
  func usageDetail(source: UsageSource, selection: UsagePeriodSelection) -> LocalServiceUsageDetail?
  {
    if let key = selection.summaryKey {
      return usageDetail(source: source, period: UsagePeriod(summaryKey: key))
    }
    guard let range = selection.range(today: now()) else { return nil }
    return customUsagePeriods[Self.periodKey(source: source, range)]
  }

  /// Whether the selected period can be answered on this source. Account custom ranges now can.
  func usagePeriodIsAvailable(source: UsageSource, selection: UsagePeriodSelection) -> Bool {
    selection.summaryKey != nil || selection.range(today: now()) != nil
  }

  /// The title above the totals: the range the selected period covers.
  func usagePeriodTitle(now: Date) -> String {
    UsagePeriodTitle.text(for: usagePeriod, today: now)
  }

  func selectUsagePeriod(_ selection: UsagePeriodSelection, source: UsageSource? = nil) {
    var sourceChanged = false
    if let source, source != customPeriodSource {
      customPeriodSource = source
      sourceChanged = true
    }
    guard selection != usagePeriod || sourceChanged else { return }
    usagePeriod = selection
    loadCustomUsagePeriod()
  }

  /// Dashboard's Account / This Mac picker. Reloads a custom range for the source that is on
  /// screen; the monthly budget stays This Mac's hours.
  func setUsageSource(_ source: UsageSource) {
    guard source != customPeriodSource else { return }
    customPeriodSource = source
    loadCustomUsagePeriod()
  }

  /// Asks the service for this Mac's stored samples since the retention horizon, then folds
  /// them per provider and window. State pushes keep the current-window slice; this is the
  /// 30-day journal Dashboard reads (ADR 0051).
  func loadQuotaHistory() {
    guard let transport else { return }
    quotaHistoryTask?.cancel()
    quotaHistoryTask = Task { @MainActor [weak self] in
      guard let self else { return }
      let since = self.now().addingTimeInterval(-Double(QuotaHistory.retentionDays) * 86_400)
      do {
        let payload = try await transport.quotaHistory(since: since)
        guard !Task.isCancelled else { return }
        quotaHistorySamples = payload
        quotaHistory = Self.foldQuotaHistory(
          payload, overview: historyOverview, now: self.now())
        quotaHistoryErrorMessage = nil
      } catch is CancellationError {
        return
      } catch {
        quotaHistoryErrorMessage = Self.message(for: error)
      }
    }
  }

  /// One fold per subscription and window id, from the samples `quota_history` returned and the
  /// cadence the current Overview reading already names.
  static func foldQuotaHistory(
    _ payload: LocalServiceQuotaHistory,
    overview: [LocalServiceOverviewItem],
    now: Date
  ) -> [String: [String: QuotaHistory]] {
    var result: [String: [String: QuotaHistory]] = [:]
    for item in overview {
      let key = item.identity.subscriptionSelector
      guard let byWindow = payload.samplesBySubscription[key] else { continue }
      for window in item.snapshot.windows {
        guard let samples = byWindow[window.id],
          let folded = QuotaHistory.fold(
            window: QuotaHistoryReading(
              resetsAt: window.resetsAt, cadenceSeconds: window.durationSeconds),
            samples: samples,
            now: now,
            utcOffsetSeconds: payload.utcOffsetSeconds
          )
        else { continue }
        result[key, default: [:]][window.id] = folded
      }
    }
    return result
  }

  /// Asks the service for the selected period when it is not one of the four already folded.
  func loadCustomUsagePeriod() {
    guard usagePeriod.summaryKey == nil, let transport,
      let range = usagePeriod.range(today: now())
    else { return }
    let source = effectiveUsageSource(customPeriodSource)
    let key = Self.periodKey(source: source, range)
    guard customUsagePeriods[key] == nil else { return }
    customUsageTask?.cancel()
    customUsageGeneration += 1
    let generation = customUsageGeneration
    customUsageLoading = true
    let timezone = TimeZone.current.identifier
    customUsageTask = Task { @MainActor [weak self] in
      let detail: LocalServiceUsageDetail
      do {
        detail = try await transport.usagePeriod(
          from: range.from, to: range.to, source: source, timezone: timezone)
      } catch is CancellationError {
        if let self, self.customUsageGeneration == generation {
          self.customUsageLoading = false
        }
        return
      } catch {
        guard let self else { return }
        if self.customUsageGeneration == generation {
          self.customUsageLoading = false
          self.onRequestError?(Self.message(for: error))
        }
        return
      }
      guard let self else { return }
      guard self.customUsageGeneration == generation,
        Self.periodKey(source: source, range) == key
      else { return }
      customUsageLoading = false
      customUsagePeriods[key] = detail
    }
  }

  /// How far into this month's budget this Mac's own spend has gone.
  var budgetProgress: UsageBudgetProgress? {
    guard let amount = budget.amountUSD, let detail = budgetMonthDetail else { return nil }
    let spent = UsageBudgetProgress.dollars(microusd: detail.usage.cost.amountMicrousd) ?? 0
    return UsageBudgetProgress(
      spentUSD: spent,
      budgetUSD: amount,
      partial: detail.usage.cost.status != .complete
    )
  }

  func setBudget(_ next: UsageBudget) {
    budget = budgetStore.save(next)
    refreshBudgetMonth()
  }

  /// Folds this month once, so the bar has something to measure the budget against.
  func refreshBudgetMonth() {
    budgetMonthTask?.cancel()
    budgetMonthGeneration += 1
    let generation = budgetMonthGeneration
    guard budget.isSet, let transport,
      let range = UsagePeriodSelection.thisMonth.range(today: now())
    else {
      budgetMonthDetail = nil
      return
    }
    let key = Self.periodKey(range)
    budgetMonthTask = Task { @MainActor [weak self] in
      let detail: LocalServiceUsageDetail
      do {
        detail = try await transport.usagePeriod(
          from: range.from, to: range.to, source: .local, timezone: TimeZone.current.identifier)
      } catch {
        return
      }
      guard let self else { return }
      guard self.budgetMonthGeneration == generation, Self.periodKey(range) == key else { return }
      budgetMonthDetail = detail
      evaluateBudgetNotifications(now: now())
    }
  }

  /// Says once per month that 80%, and then 100%, of the budget has been spent.
  private func evaluateBudgetNotifications(now: Date) {
    let previous = budgetStore.loadFired()
    let result = BudgetAlertEvaluator.evaluate(
      budget: budget,
      progress: budgetProgress,
      month: BudgetAlertEvaluator.month(containing: now),
      previous: previous
    )
    if result.state != previous {
      budgetStore.saveFired(result.state)
    }
    if !result.events.isEmpty {
      notificationSink.deliver(result.events)
    }
  }

  /// Account answers for Usage only while it can. Everywhere the selection is honored uses
  /// this, so Overview and Dashboard Usage never disagree about which numbers are on screen.
  func effectiveUsageSource(_ selected: UsageSource) -> UsageSource {
    !usageUploadEnabled || !hasAccountSummary ? .local : selected
  }

  /// The bottom bar's one line of today's spend, or `nil` when there is nothing to say.
  func todayUsageSummary(source: UsageSource) -> UsageTodaySummary? {
    guard let detail = usageDetail(source: effectiveUsageSource(source), period: .today) else {
      return nil
    }
    return UsageValueFormatter.todaySummary(
      tokens: detail.usage.totals.totalTokens,
      cost: detail.usage.cost
    )
  }

  /// Today's spend the menu bar can show, using the same Usage source the footer would.
  func menuBarTodaySnapshot() -> MenuBarTodaySnapshot {
    guard let detail = usageDetail(source: effectiveUsageSource(.account), period: .today) else {
      return .empty
    }
    return MenuBarTodaySnapshot(
      total: MenuBarTodayUsage.make(
        tokens: detail.usage.totals.totalTokens,
        cost: detail.usage.cost
      ),
      byProvider: Dictionary(
        uniqueKeysWithValues: detail.usage.agents.compactMap { agent in
          guard let provider = agent.agent.menuBarProvider else { return nil }
          return (
            provider,
            MenuBarTodayUsage.make(tokens: agent.totals.totalTokens, cost: agent.cost)
          )
        }
      )
    )
  }

  func isPreparingUsage(source: UsageSource) -> Bool {
    source == .local ? usageRefreshing : accountRefreshing
  }

  static func periodKey(
    source: UsageSource = .local, _ range: (from: String, to: String)
  ) -> String {
    "\(source.rawValue)|\(range.from)|\(range.to)"
  }

  #if DEBUG
    func seedCustomUsagePeriodForVisuals(
      _ detail: LocalServiceUsageDetail,
      selection: UsagePeriodSelection,
      source: UsageSource
    ) {
      usagePeriod = selection
      customPeriodSource = source
      if let range = selection.range(today: now()) {
        customUsagePeriods[Self.periodKey(source: source, range)] = detail
      }
    }
  #endif

  private static func message(for error: Error) -> String {
    if let localized = error as? LocalizedError,
      let description = localized.errorDescription
    {
      return description
    }
    return "QuotaBar's local service could not complete the request."
  }
}
