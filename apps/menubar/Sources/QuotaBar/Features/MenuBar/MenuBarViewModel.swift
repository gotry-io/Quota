import AppKit
import Foundation
import Observation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaWidgetData
import QuotaWidgetProjection
import QuotaWire
import UserNotifications

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
  let serviceStatus: LocalServiceProviderStatus?

  var id: ProviderID { provider }

  init(
    provider: ProviderID,
    accounts: [AccountQuotaPresentation],
    status: ProviderStatusCopy? = nil,
    serviceStatus: LocalServiceProviderStatus? = nil
  ) {
    self.provider = provider
    self.accounts = accounts
    self.status = status
    self.serviceStatus = serviceStatus
  }
}

struct AccountQuotaPresentation: Equatable, Identifiable {
  let identity: QuotaSubscriptionIdentity
  let snapshot: QuotaSnapshot
  /// What the row says about this reading: the source's own report, or aged out by the
  /// service's verdict. Resolved once here so the view never re-derives it.
  let state: QuotaObservationState
  let selectedSourceDisplayName: String

  var id: QuotaSubscriptionIdentity { identity }

  /// An Overview row spends no line on which source answered or how old the reading is; a
  /// reading that no longer describes live quota says so in tone. Tone cannot be read aloud,
  /// so the sentence it replaced is what VoiceOver announces for the row.
  func accessibilityLabel(accountIndex: Int, now: Date) -> String {
    let account =
      PlanDisplay.accountLabel(snapshot.account.label).map { "Account: \($0)" }
      ?? "Account \(accountIndex + 1)"
    let freshness = FreshnessCopy.observation(
      state: state,
      observedAt: snapshot.observedAt,
      now: now
    )
    return "\(account). \(selectedSourceDisplayName). \(freshness)"
  }
}

#if DEBUG
  struct MenuBarVisualState {
    let report: QuotaCollectionReport
    let localUsage: LocalUsageReport
    let accountSummary: AccountSummary?
    let authStatus: LocalServiceAuthStatus
    let overview: [LocalServiceOverviewItem]
    var cache: LocalServiceCacheState = .settled
    var providerStatus: [LocalServiceProviderStatus] = []
    var deviceID: String? = nil
    var quotaHistorySamples: LocalServiceQuotaHistory? = nil
  }
#endif

@MainActor
@Observable
final class MenuBarViewModel {
  private(set) var report: QuotaCollectionReport?
  /// Usage, history, and the monthly budget. This coordinator hands it each accepted state.
  let usage: UsageModel
  /// Consent, cookie-store reads, reconnect, and the Browser Access grant window.
  let browserConnection: BrowserConnectionModel
  /// Sign-in phases, session identity/epoch, and sign-out.
  let accountFlow: AccountFlowModel
  /// Seed, adopt, merge, and 412 re-apply of the Account settings document.
  let accountSettings: AccountSettingsModel
  private(set) var errorMessage: String?
  private(set) var isRefreshing = false
  private(set) var isUpdatingUsageUpload = false
  private(set) var usageUploadEnabled = true
  /// The helper's `history_sync` while signed in. Nil when signed out.
  private(set) var quotaHistorySync: LocalServiceHistorySync?

  var quotaHistorySyncStatus: String? {
    quotaHistorySync?.statusLine()
  }
  private(set) var isUpdatingGroupUsageByProject = false
  private(set) var groupUsageByProject = true
  private(set) var quotaRefreshIntervalSeconds = QuotaRefreshInterval.fallback.rawValue
  private(set) var quotaRefreshMode = QuotaRefreshMode.automatic
  private(set) var quotaRefreshTier: LocalServiceQuotaRefreshTier?
  private(set) var isUpdatingQuotaRefreshInterval = false

  var quotaRefreshChoice: QuotaRefreshChoice {
    QuotaRefreshChoice(mode: quotaRefreshMode, intervalSeconds: quotaRefreshIntervalSeconds)
  }
  private(set) var lastCheckedAt: Date?
  private(set) var providerConfigurations: [ProviderID: LocalServiceProviderConfig] = [:]
  private(set) var providerStatus: [ProviderID: LocalServiceProviderStatus] = [:]

  private var overview: [LocalServiceOverviewItem] = []
  private var revision = 0
  private(set) var cache: LocalServiceCacheState = .settled

  /// The instant the menu-bar item is drawn for.
  ///
  /// The item's content is a function of time — the shared freshness rule retires a reading —
  /// but observation only re-reads it when something it read changed. Without a clock of its
  /// own the item would keep a percent that stopped describing live quota until the next
  /// service event, which for a Mac that has stopped collecting is never.
  private(set) var menuBarClock = Date()

  @ObservationIgnored
  private let client: (any LocalServiceServing)?

  @ObservationIgnored
  private let initializationError: String?

  var showsCacheRebuildNotice: Bool {
    cache.rebuilding
  }

  @ObservationIgnored
  private var eventTask: Task<Void, Never>?

  /// Re-reads state on a fixed cadence, whatever events did or did not arrive.
  @ObservationIgnored
  private var statePollTask: Task<Void, Never>?

  @ObservationIgnored
  private var menuBarClockTask: Task<Void, Never>?

  /// Which readings were current the last time the clock was published.
  @ObservationIgnored
  private var menuBarCurrency: [Bool] = []

  @ObservationIgnored
  private let loginURLOpener: any LoginURLOpening

  /// How long a quit waits for the service's goodbye before going ahead without it.
  nonisolated static let shutdownDeadline: Duration = .seconds(2)
  /// How often the panel re-reads the service's state on its own. Events are the fast path and
  /// carry every change; this is the bound on how stale the panel can be without one.
  nonisolated static let statePollInterval: Duration = .seconds(60)

  /// How often the menu-bar item is re-evaluated against the clock. The shared freshness rule's
  /// smallest unit is a minute — under one everything reads "just now" — so a minute is as fine
  /// as the item's answer can change.
  nonisolated static let menuBarClockInterval: Duration = .seconds(60)

  @ObservationIgnored
  private let shutdownDeadline: Duration
  /// What the quit's deadline actually is: production sleeps, and a test can hold the deadline
  /// open and release it on purpose. Injected so proving the deadline governs the wait does not
  /// mean measuring elapsed time on a loaded machine.
  @ObservationIgnored
  private let deadlineSleeper: @Sendable (Duration) async throws -> Void
  private let statePollInterval: Duration

  @ObservationIgnored
  private let notificationStore: any AlertStateStore

  @ObservationIgnored
  private let notificationSink: any AlertSink

  @ObservationIgnored
  private let notificationDefaults: UserDefaults

  @ObservationIgnored
  private let notificationCenter: any NotificationCentering

  @ObservationIgnored
  private let resetScheduler: ResetReminderScheduler

  @ObservationIgnored
  private let widgetPublisher: DesktopWidgetPublisher

  /// The Diagnostics sentence about the desktop widgets, republished with the snapshot.
  private(set) var widgetPublishingStatus: DesktopWidgetPublishingStatus

  /// Whether a status item's window is on screen, as AppKit last reported it. `nil` until the
  /// bar has placed one. macOS keeps an item off the bar when the app is switched off in
  /// System Settings › Menu Bar, or when the bar has no room; the app cannot tell which.
  private(set) var menuBarItemOnScreen: Bool?

  func noteMenuBarItemPresence(onScreen: Bool) {
    if menuBarItemOnScreen != onScreen {
      menuBarItemOnScreen = onScreen
    }
  }

  @ObservationIgnored
  private let userNotificationSink: UserNotificationAlertSink?

  private(set) var notificationRules: AlertRules
  private(set) var notificationAuthorizationDenied = false

  init(
    client: (any LocalServiceServing)? = nil,
    browserSessionImporter: any BrowserSessionImporting = BrowserSessionImporter(),
    loginURLOpener: any LoginURLOpening = WorkspaceLoginURLOpener(),
    accessProbe: (any BrowserAccessProbing)? = nil,
    grantPresenter: (any BrowserAccessGrantPresenting)? = nil,
    relauncher: (any QuotaBarRelaunching)? = nil,
    notificationStore: (any AlertStateStore)? = nil,
    notificationSink: (any AlertSink)? = nil,
    notificationCenter: (any NotificationCentering)? = nil,
    notificationDefaults: UserDefaults = .standard,
    budgetStore: UsageBudgetStore? = nil,
    widgetPublisher: DesktopWidgetPublisher? = nil,
    shutdownDeadline: Duration = MenuBarViewModel.shutdownDeadline,
    deadlineSleeper: @escaping @Sendable (Duration) async throws -> Void = {
      try await Task.sleep(for: $0)
    },
    loginPollInterval: Duration = AccountFlowModel.loginPollInterval,
    statePollInterval: Duration = MenuBarViewModel.statePollInterval
  ) {
    let injectedClient = client != nil
    // A test's QuotaBar publishes nowhere: it neither joins the App Group nor asks the Keychain
    // for the installation salt.
    let resolvedWidgetPublisher =
      widgetPublisher ?? (injectedClient ? DesktopWidgetPublisher(publisher: nil)
        : DesktopWidgetPublisher())
    self.widgetPublisher = resolvedWidgetPublisher
    self.widgetPublishingStatus = resolvedWidgetPublisher.status
    let resolvedBudgetStore = budgetStore ?? UsageBudgetStore(defaults: notificationDefaults)
    self.loginURLOpener = loginURLOpener
    let resolvedAccessProbe =
      accessProbe
      ?? (injectedClient ? UnrestrictedBrowserAccessProbe() : SystemBrowserAccessProbe())
    let resolvedRelauncher =
      relauncher
      ?? (injectedClient ? NoOpQuotaBarRelauncher() : WorkspaceQuotaBarRelauncher())
    self.shutdownDeadline = shutdownDeadline
    self.deadlineSleeper = deadlineSleeper
    self.statePollInterval = statePollInterval
    self.notificationDefaults = notificationDefaults
    self.notificationRules = NotificationRules.store(defaults: notificationDefaults).load()
    let resolvedCenter =
      notificationCenter
      ?? (injectedClient ? NoOpNotificationCenter() : SystemNotificationCenter())
    self.notificationCenter = resolvedCenter
    self.resetScheduler = ResetReminderScheduler(center: resolvedCenter)
    if let notificationSink {
      self.notificationSink = notificationSink
      self.userNotificationSink = nil
    } else if injectedClient && notificationCenter == nil {
      self.notificationSink = NoOpAlertSink()
      self.userNotificationSink = nil
    } else {
      let sink = UserNotificationAlertSink(center: resolvedCenter)
      self.notificationSink = sink
      self.userNotificationSink = sink
    }
    if let notificationStore {
      self.notificationStore = notificationStore
    } else if injectedClient {
      self.notificationStore = InMemoryAlertStateStore()
    } else {
      self.notificationStore = FileAlertStateStore(
        fileURL: NotificationRules.stateFileURL(
          applicationSupport: FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        )
      )
    }
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
    let resolvedGrantPresenter: (any BrowserAccessGrantPresenting)?
    if injectedClient {
      resolvedGrantPresenter = grantPresenter
    } else if let grantPresenter {
      resolvedGrantPresenter = grantPresenter
    } else {
      resolvedGrantPresenter = BrowserAccessWindowController()
    }
    self.usage = UsageModel(
      transport: self.client,
      budgetStore: resolvedBudgetStore,
      notificationSink: self.notificationSink
    )
    self.browserConnection = BrowserConnectionModel(
      transport: self.client,
      importer: browserSessionImporter,
      accessProbe: resolvedAccessProbe,
      grantPresenter: resolvedGrantPresenter,
      relauncher: resolvedRelauncher
    )
    self.accountFlow = AccountFlowModel(
      transport: self.client,
      loginURLOpener: loginURLOpener,
      unavailableMessage: initializationError,
      loginPollInterval: loginPollInterval
    )
    self.accountSettings = AccountSettingsModel(
      transport: self.client, defaults: notificationDefaults)
    self.usage.onRequestError = { [weak self] message in
      self?.errorMessage = message
    }
    self.browserConnection.onNeedsReload = { [weak self] in
      await self?.reloadState()
    }
    self.usage.sessionEpoch = { [weak self] in self?.accountFlow.sessionEpoch ?? 0 }
    self.browserConnection.sessionEpoch = { [weak self] in self?.accountFlow.sessionEpoch ?? 0 }
    self.accountSettings.sessionEpoch = { [weak self] in self?.accountFlow.sessionEpoch ?? 0 }
    self.accountSettings.currentPolicy = { [weak self] in
      guard let self else { return AccountSettingsPolicy(rules: AlertRules(), budget: .none) }
      return AccountSettingsPolicy(rules: self.notificationRules, budget: self.usage.budget)
    }
    self.accountSettings.applyPolicy = { [weak self] policy in
      self?.applyAccountSettingsPolicy(policy)
    }
    self.accountSettings.onNeedsReload = { [weak self] in
      await self?.reloadState()
    }
    self.usage.onLocalBudgetEdit = { [weak self] budget in
      self?.accountSettings.noteLocalEdit(
        .setBudget(amount: budget.amountUSD, alerts: budget.alerts)
      )
    }
    self.accountFlow.onNeedsReload = { [weak self] in
      await self?.reloadState()
    }
    self.accountFlow.onAccountWentAway = { [weak self] _ in
      guard let self else { return }
      self.usage.accountDidGoAway()
      self.browserConnection.accountDidGoAway()
      self.accountSettings.accountDidGoAway()
      self.quotaHistorySync = nil
      try? self.notificationStore.clear()
      self.resetScheduler.removeAll()
    }
  }

  #if DEBUG
    init(
      visualTestState: MenuBarVisualState?,
      errorMessage: String?,
      lastCheckedAt: Date?
    ) {
      loginURLOpener = WorkspaceLoginURLOpener()
      widgetPublisher = DesktopWidgetPublisher(publisher: nil)
      widgetPublishingStatus = .unentitled
      client = nil
      shutdownDeadline = MenuBarViewModel.shutdownDeadline
      deadlineSleeper = { try await Task.sleep(for: $0) }
      statePollInterval = MenuBarViewModel.statePollInterval
      notificationStore = InMemoryAlertStateStore()
      notificationSink = NoOpAlertSink()
      notificationDefaults = .standard
      let usage = UsageModel(
        transport: nil,
        budgetStore: UsageBudgetStore(defaults: .standard),
        notificationSink: NoOpAlertSink(),
        budget: UsageBudget(amountUSD: 50, alerts: true)
      )
      self.usage = usage
      self.browserConnection = BrowserConnectionModel(
        transport: nil,
        accessProbe: UnrestrictedBrowserAccessProbe(),
        relauncher: NoOpQuotaBarRelauncher()
      )
      self.accountFlow = AccountFlowModel(
        transport: nil,
        loginURLOpener: loginURLOpener
      )
      self.accountSettings = AccountSettingsModel(transport: nil, defaults: notificationDefaults)
      let center = NoOpNotificationCenter()
      notificationCenter = center
      resetScheduler = ResetReminderScheduler(center: center)
      userNotificationSink = nil
      notificationRules = AlertRules()
      initializationError = nil
      self.errorMessage = errorMessage
      self.lastCheckedAt = lastCheckedAt
      guard let visualTestState else { return }
      report = visualTestState.report
      var fixturePeriods: LocalServiceUsagePeriodCache?
      var fixtureBudgetMonth: LocalServiceUsageDetail?
      if let accountUsage = visualTestState.accountSummary?.usage {
        let account = LocalServiceUsagePeriodValues(
          today: Self.periodDetail(accountUsage.today, span: 1),
          last7Days: Self.periodDetail(accountUsage.last7Days, span: 7),
          last30Days: Self.periodDetail(accountUsage.last30Days, span: 30),
          all: Self.periodDetail(accountUsage.all, span: nil)
        )
        let local = LocalServiceUsagePeriodValues(
          today: Self.localPeriodDetail(accountUsage.today, span: 1),
          last7Days: Self.localPeriodDetail(accountUsage.last7Days, span: 7),
          last30Days: Self.localPeriodDetail(accountUsage.last30Days, span: 30),
          all: Self.localPeriodDetail(accountUsage.all, span: nil)
        )
        fixturePeriods = LocalServiceUsagePeriodCache(local: local, account: account)
        fixtureBudgetMonth = local.last30Days
      }
      usage.applyVisualFixture(
        localUsage: visualTestState.localUsage,
        usagePeriods: fixturePeriods,
        budgetMonthDetail: fixtureBudgetMonth,
        budget: UsageBudget(amountUSD: 50, alerts: true),
        quotaHistorySamples: visualTestState.quotaHistorySamples,
        overview: visualTestState.overview,
        now: visualTestState.report.capturedAt,
        usageUploadEnabled: true,
        hasAccountSummary: visualTestState.accountSummary != nil
      )
      accountFlow.applyVisualFixture(
        authStatus: visualTestState.authStatus,
        accountSummary: visualTestState.accountSummary,
        displayLabel: visualTestState.accountSummary?.account.displayLabel,
        deviceID: visualTestState.deviceID
      )
      applyOverview(visualTestState.overview)
      cache = visualTestState.cache
      providerStatus = Dictionary(
        uniqueKeysWithValues: visualTestState.providerStatus.map { ($0.provider, $0) }
      )
    }

    /// The managed period, in the shape the panel already reads. A managed tree states totals
    /// and cost only at the leaf, so what a fixture shows above them is folded here. A period of
    /// `span` days ends on the fixture's day, Aug 3, 2026; `all` names no days.
    private static func periodDetail(_ period: QuotaWire.UsagePeriod, span: Int?)
      -> LocalServiceUsageDetail
    {
      let agents = period.agents.map { agent in
        LocalUsageAgentSummary(
          agent: agent.agent,
          totals: period.totals,
          cost: period.cost,
          providers: agent.providers.map { provider in
            LocalUsageProviderSummary(
              provider: provider.provider,
              totals: period.totals,
              cost: period.cost,
              models: provider.models.map {
                LocalUsageModelSummary(model: $0.model, totals: $0.totals, cost: $0.cost)
              }
            )
          }
        )
      }
      let dates = span.map { fixtureDates(count: $0) } ?? []
      return LocalServiceUsageDetail(
        range: UsageDateRange(from: dates.first ?? "2026-08-03", to: dates.last ?? "2026-08-03"),
        usage: LocalUsagePeriodSummary(
          totals: period.totals,
          cost: period.cost,
          cacheSaved: period.cacheSaved,
          agents: agents,
          days: span == nil ? nil : fixtureDays(period.totals, cost: period.cost, dates: dates),
          hoursOfDay: span == nil ? nil : fixtureHours(period.totals),
          modelSeries: span == nil ? nil : fixtureSeries(period, dates: dates)
        ),
        incomplete: period.partial,
        detailsTruncated: period.hasTruncatedDetails
      )
    }

    /// Local days carrying a fixed share of the period, so the river has a shape; the fifth is
    /// a day with no usage.
    private static let dayWeights = [4, 7, 9, 3, 0, 6, 11, 8, 5, 12, 9, 2, 10, 14]

    /// A working day: quiet overnight, busiest late morning and mid afternoon.
    private static let hourWeights = [
      0, 0, 0, 0, 0, 1, 3, 6, 9, 12, 14, 13, 8, 11, 15, 13, 10, 7, 5, 4, 3, 2, 1, 0,
    ]

    private static func fixtureDates(count: Int) -> [String] {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
      let last = DateComponents(calendar: calendar, year: 2026, month: 8, day: 3).date ?? Date()
      return (0..<count).reversed().compactMap { back in
        calendar.date(byAdding: .day, value: -back, to: last).map {
          UsageDateText.date($0, calendar)
        }
      }
    }

    private static func weight(_ index: Int, model: Int = 0) -> Int {
      dayWeights[(index + model * 3) % dayWeights.count]
    }

    private static func fixtureDays(
      _ totals: UsageSummaryTotals,
      cost: UsageCostOutcome,
      dates: [String]
    ) -> [LocalUsageDay] {
      let sum = max(dates.indices.map { weight($0) }.reduce(0, +), 1)
      return dates.enumerated().map { index, date in
        LocalUsageDay(
          date: date,
          totals: scaled(totals, numerator: weight(index), denominator: sum),
          cost: cost
        )
      }
    }

    /// Each model's tokens spread over the same days, each model a little out of step with the
    /// others, empty where the day is.
    private static func fixtureSeries(
      _ period: QuotaWire.UsagePeriod,
      dates: [String]
    ) -> UsageModelSeries {
      let leaves = period.agents.flatMap { agent in
        agent.providers.flatMap { provider in provider.models.map { (provider.provider, $0) } }
      }
      .sorted { $0.1.totals.totalTokens > $1.1.totals.totalTokens }
      let days = dates.enumerated().map { index, date in
        UsageModelSeriesDay(
          date: date,
          partial: false,
          models: weight(index) == 0
            ? []
            : leaves.enumerated().compactMap { position, leaf in
              let share = weight(index, model: position)
              guard share > 0 else { return nil }
              let tokens = leaf.1.totals.totalTokens * share / (7 * max(dates.count, 1))
              let input = tokens * 5 / 6
              return UsageModelSeriesCell(
                model: leaf.1.model,
                totalTokens: tokens,
                inputTokens: input,
                outputTokens: tokens - input,
                cacheReadInputTokens: input / 3,
                cacheWriteInputTokens: 0,
                costMicrousd: String(tokens)
              )
            }
        )
      }
      return UsageModelSeries(
        models: leaves.map { UsageModelSeriesEntry(model: $0.1.model, provider: $0.0) },
        days: days
      )
    }

    private static func fixtureHours(_ totals: UsageSummaryTotals) -> [LocalUsageHourOfDay] {
      let sum = hourWeights.reduce(0, +)
      return hourWeights.enumerated().map { hour, weight in
        LocalUsageHourOfDay(
          hour: hour,
          totalTokens: totals.totalTokens * weight / sum,
          costMicrousd: nil
        )
      }
    }

    private static func scaled(
      _ totals: UsageSummaryTotals,
      numerator: Int,
      denominator: Int
    ) -> UsageSummaryTotals {
      let part = { (value: Int) in value * numerator / denominator }
      let input = part(totals.inputTokens)
      let output = part(totals.outputTokens)
      return UsageSummaryTotals(
        totalTokens: input + output,
        inputTokens: input,
        outputTokens: output,
        cacheReadInputTokens: part(totals.cacheReadInputTokens),
        cacheWriteInputTokens: part(totals.cacheWriteInputTokens),
        reasoningTokens: min(output, part(totals.reasoningTokens)),
        messages: part(totals.messages)
      )
    }

    /// The same fixture with the Projects fold This Mac adds.
    private static func localPeriodDetail(_ period: QuotaWire.UsagePeriod, span: Int?)
      -> LocalServiceUsageDetail
    {
      let detail = periodDetail(period, span: span)
      let projects = [
        LocalUsageProjectSummary(
          projectKey: "Quota",
          totalTokens: 1_204_620,
          cost: period.cost,
          messages: 110,
          topModel: "gpt-5"
        ),
        LocalUsageProjectSummary(
          projectKey: "other",
          totalTokens: 500_000,
          cost: period.cost,
          messages: 54,
          topModel: "claude-sonnet-4"
        ),
      ]
      return LocalServiceUsageDetail(
        range: detail.range,
        usage: LocalUsagePeriodSummary(
          totals: detail.usage.totals,
          cost: detail.usage.cost,
          cacheSaved: detail.usage.cacheSaved,
          agents: detail.usage.agents,
          projects: projects,
          days: detail.usage.days,
          hoursOfDay: detail.usage.hoursOfDay,
          modelSeries: detail.usage.modelSeries,
          modelsTruncated: detail.usage.modelsTruncated
        ),
        incomplete: detail.incomplete,
        detailsTruncated: detail.detailsTruncated
      )
    }
  #endif

  deinit {
    eventTask?.cancel()
    statePollTask?.cancel()
    menuBarClockTask?.cancel()
  }

  func start() {
    browserConnection.start()
    guard eventTask == nil, let client else {
      if self.client == nil { errorMessage = initializationError }
      return
    }
    eventTask = Task { @MainActor [weak self] in
      await self?.reloadState()
      for await event in client.events {
        guard !Task.isCancelled else { return }
        guard let self else { continue }
        guard event.revision > revision else { continue }
        await reloadState()
      }
    }
    // Events carry every change and arrive at once; this is the bound on how long the panel can
    // disagree with the service when one does not, which a reader cannot otherwise tell from
    // "nothing changed".
    let statePollInterval = statePollInterval
    statePollTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: statePollInterval)
        } catch {
          return
        }
        await self?.reloadState()
      }
    }
    let interval = Self.menuBarClockInterval
    menuBarClockTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        do {
          try await Task.sleep(for: interval)
        } catch {
          return
        }
        self?.advanceMenuBarClock(to: Date())
      }
    }
  }

  /// Publishes the instant the menu-bar item is drawn for.
  ///
  /// The item depends on time only through which readings still describe live quota, so a
  /// minute in which that set did not change is a minute in which the item cannot have changed
  /// either, and publishing would rebuild the status item for the same answer. New readings are
  /// the exception: the label is re-read for them anyway, and they have to be judged against the
  /// present rather than against whenever the clock last had reason to move.
  func advanceMenuBarClock(to now: Date, forNewReadings: Bool = false) {
    let currency = MenuBarLabelModel.currency(of: overview, now: now)
    guard forNewReadings || currency != menuBarCurrency else { return }
    menuBarCurrency = currency
    menuBarClock = now
  }

  /// QuotaBar's last word to its local service, and the last thing that can hold up a quit. The
  /// panel stops following the service, then the client asks the helper to exit and escalates to
  /// terminate and kill if it will not — but the wait for that answer is capped, because the
  /// person pressed Quit. A helper wedged badly enough to answer neither its `shutdown` nor a
  /// ping would otherwise hold the run loop AppKit is turning on our behalf; past the deadline
  /// the escalation finishes without an audience, and this process exiting closes the child's
  /// stdin, which says the same thing by a slower route.
  func shutdown() async {
    eventTask?.cancel()
    eventTask = nil
    statePollTask?.cancel()
    statePollTask = nil
    accountFlow.shutdown()
    accountSettings.shutdown()
    browserConnection.shutdown()
    guard let client else { return }
    // A race whose loser is abandoned rather than awaited: the deadline is the thing waited on,
    // and a goodbye that lands first cancels it so a healthy quit is not slowed to two seconds.
    let goodbye = Task { await client.shutdown() }
    let sleeper = deadlineSleeper
    let deadline = Task { try await sleeper(shutdownDeadline) }
    let arrival = Task {
      await goodbye.value
      deadline.cancel()
    }
    _ = await deadline.result
    arrival.cancel()
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

  func diagnose() async throws -> LocalServiceDiagnosticReport {
    guard let client else {
      throw LocalServiceClientError.serviceMissing
    }
    let previous = try await client.diagnose()
    let refresh = try await client.recheckDiagnostics()
    guard refresh.accepted || refresh.pending else { return previous }
    // A running refresh keeps answering with the report it already had, so a different
    // evaluation time is the only proof that a newer one exists.
    let deadline = Date().addingTimeInterval(12)
    var latest = previous
    repeat {
      try await Task.sleep(for: .milliseconds(150))
      latest = try await client.diagnose()
      if latest.generatedAt != previous.generatedAt { return latest }
    } while Date() < deadline
    return latest
  }

  /// Deletes this Mac's derived cache and starts filling it in again. The session, the upload
  /// queue, and saved browser sessions live in a different file and are untouched.
  func resetLocalData() async {
    guard let client else { return }
    do {
      try await client.resetCache()
      await reloadState()
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  /// The menu-bar item, drawn for `now` — which in the app is ``menuBarClock``, so reading the
  /// label subscribes the item to the clock as well as to the readings.
  func menuBarLabel(
    style: MenuBarStylePreference,
    provider: MenuBarProviderPreference = .automatic,
    arrangement: MenuBarArrangementPreference = .combined,
    now: Date
  ) -> MenuBarLabelModel {
    let layout = MenuBarLayout.resolve(
      selection: provider,
      arrangement: arrangement,
      visibleProviders: ProviderDisplayOrder.enabledProviders()
    )
    return menuBarSpecs(style: style, layout: layout, now: now).first?.label ?? .empty
  }

  func menuBarSpecs(
    style: MenuBarStylePreference,
    layout: MenuBarLayout,
    now: Date
  ) -> [MenuBarStatusItemSpec] {
    MenuBarLabelModel.specs(
      overview: overview,
      style: style,
      layout: layout,
      now: now,
      today: usage.menuBarTodaySnapshot()
    )
  }

  func setUsageUploadEnabled(_ enabled: Bool) async {
    guard !isUpdatingUsageUpload, enabled != usageUploadEnabled, let client else { return }
    isUpdatingUsageUpload = true
    defer { isUpdatingUsageUpload = false }
    do {
      usageUploadEnabled = try await client.setUsageUpload(enabled: enabled).enabled
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func setGroupUsageByProject(_ enabled: Bool) async {
    guard !isUpdatingGroupUsageByProject, enabled != groupUsageByProject, let client else { return }
    isUpdatingGroupUsageByProject = true
    defer { isUpdatingGroupUsageByProject = false }
    do {
      groupUsageByProject = try await client.setGroupUsageByProject(enabled: enabled).enabled
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func overviewItems(for provider: ProviderID) -> [LocalServiceOverviewItem] {
    overview.filter { $0.identity.provider == provider }
  }

  func overviewItem(provider: ProviderID, identityKey: String) -> LocalServiceOverviewItem? {
    overviewItems(for: provider).first { $0.pinIdentityKey == identityKey }
  }

  func setOverviewSourcePin(item: LocalServiceOverviewItem, pin: String?) async {
    guard let client else { return }
    do {
      _ = try await client.setOverviewSourcePin(
        provider: item.identity.provider,
        fingerprint: item.identity.fingerprint,
        scope: item.identity.scope.rawValue,
        identitySourceID: item.identity.sourceID,
        pin: pin
      )
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
    }
  }

  func setQuotaRefresh(_ choice: QuotaRefreshChoice) async {
    guard !isUpdatingQuotaRefreshInterval, choice != quotaRefreshChoice, let client else {
      return
    }
    isUpdatingQuotaRefreshInterval = true
    defer { isUpdatingQuotaRefreshInterval = false }
    do {
      let setting = try await client.setQuotaRefresh(choice)
      quotaRefreshMode = setting.mode
      quotaRefreshIntervalSeconds = setting.intervalSeconds
      await reloadState()
    } catch is CancellationError {
      return
    } catch {
      errorMessage = Self.message(for: error)
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

  /// The Sign-in rows for one provider: every rung this Mac has, with its last verdict.
  func signInRungs(for provider: ProviderID) -> [SignInRung] {
    SignInRungPresentation.rungs(
      for: provider,
      result: result(for: provider),
      configuration: providerConfigurations[provider],
      browser: browserConnection.signInBrowserState(for: provider)
    )
  }

  /// One line under a provider's name in the Agents list.
  func agentStatusLine(for provider: ProviderID) -> String {
    if let serviceStatus = providerStatus[provider] {
      return serviceStatus.settingsLine
    }
    return SignInRungPresentation.statusLine(
      rungs: signInRungs(for: provider),
      accountCount: overviewItems(for: provider).count,
      reportedByDevices: accountReportingProviders().contains(provider)
    )
  }

  /// Providers with no working credential on this Mac and no account device reporting them.
  func agentsNeedingSignIn() -> [ProviderID] {
    ProviderID.allCases.filter { provider in
      SignInRungPresentation.needsSignIn(rungs: signInRungs(for: provider))
        && !accountReportingProviders().contains(provider)
    }
  }

  /// Sidebar badge for Agents: how many are shown, and whether any still need sign-in.
  func agentsSidebarBadge() -> String {
    let visible = ProviderID.allCases.filter { ProviderVisibility.isVisible($0) }.count
    let needing = agentsNeedingSignIn().filter { ProviderVisibility.isVisible($0) }.count
    let shown = "\(visible) shown"
    guard needing > 0 else { return shown }
    return "\(shown) · \(needing) need\(needing == 1 ? "s" : "") sign-in"
  }

  func result(for provider: ProviderID) -> QuotaCollectionResult? {
    report?.results.first { $0.provider == provider }
  }

  func displaySnapshots(for provider: ProviderID) -> [AccountQuotaPresentation] {
    overview
      .filter { $0.identity.provider == provider }
      .compactMap(Self.presentation)
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
      let result = result(for: provider)
      // Overview asks how much is left, and a row filled by another device's reading has
      // answered. This Mac's own failed collection is then the provider page's and
      // Diagnostics' subject, not the row's. It shows on the row only when this Mac's reading
      // is the one on it — the failure says why that reading stopped moving — or when there
      // is no reading at all.
      let status =
        accounts.isEmpty || showsThisMacsReading(for: provider)
        ? result.flatMap(ProviderStatusCopy.from) : nil
      guard !accounts.isEmpty || status != nil else { return nil }
      return ProviderQuotaPresentation(
        provider: provider,
        accounts: accounts,
        status: status,
        serviceStatus: providerStatus[provider]
      )
    }

    guard !providers.isEmpty else {
      if report != nil { return .empty(refreshWarning: errorMessage) }
      if let errorMessage { return .unavailable(message: errorMessage) }
      return .loading
    }
    return .content(providers: providers, refreshWarning: errorMessage)
  }

  /// Whether any reading Overview shows for the provider was taken on this Mac.
  private func showsThisMacsReading(for provider: ProviderID) -> Bool {
    overview.contains { item in
      item.identity.provider == provider
        && item.sources.contains { $0.sourceID == item.selectedSourceID && $0.kind == .local }
    }
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

  private func applyOverview(_ items: [LocalServiceOverviewItem]) {
    overview = items
    if !items.isEmpty {
      LaunchHasShownQuota.markShown()
    }
  }

  func apply(_ state: LocalServiceState) {
    revision = state.revision
    cache = state.cache
    usageUploadEnabled = state.usageUploadEnabled
    quotaHistorySync = state.historySync
    groupUsageByProject = state.groupUsageByProject
    quotaRefreshIntervalSeconds = state.quotaRefreshIntervalSeconds
    quotaRefreshMode = state.quotaRefreshMode
    quotaRefreshTier = state.quotaRefreshTier
    report = state.quota.value
    let previouslySignedIn = accountFlow.hasAccountSession
    accountFlow.acceptState(state)
    usage.acceptState(state)
    accountSettings.accountSettingsAccepted(state)
    applyOverview(state.overview)
    advanceMenuBarClock(to: Date(), forNewReadings: true)
    providerConfigurations = Dictionary(
      uniqueKeysWithValues: state.providers.map { ($0.provider, $0) }
    )
    providerStatus = Dictionary(
      uniqueKeysWithValues: state.providerStatus.map { ($0.provider, $0) }
    )
    browserConnection.acceptState(state)
    isRefreshing =
      state.quota.refreshing || usage.usageRefreshing || accountFlow.accountRefreshing
    lastCheckedAt = [state.quota.updatedAt, state.usage.updatedAt].compactMap { $0 }.max()

    let componentError = state.quota.lastError ?? state.usage.lastError
    if let componentError {
      errorMessage = LocalServiceClientError.remote(componentError).errorDescription
    } else if state.quota.value != nil || state.usage.value != nil {
      errorMessage = nil
    }

    if previouslySignedIn && !accountFlow.hasAccountSession {
      // onAccountWentAway already cleared notification state and told the other owners.
    } else {
      evaluateNotifications(overview: state.overview, now: Date())
    }

    publishWidgetSnapshot()
  }

  /// What the desktop widgets read is what Overview shows: the same resolved rows, ranked by the
  /// projection both Apple clients share. Publishing never fails a state update — an
  /// unentitled or unwritable App Group leaves a sentence on Diagnostics instead.
  private func publishWidgetSnapshot() {
    let today = usage.usageDetail(source: usage.effectiveUsageSource(.account), period: .today)
    widgetPublisher.publish(
      subscriptions: widgetSubscriptions,
      today: today.map {
        WidgetSnapshotProjection.todayUsage(totals: $0.usage.totals, cost: $0.usage.cost)
      },
      fetchedAt: overview.map(\.snapshot.observedAt).max() ?? Date()
    )
    widgetPublishingStatus = widgetPublisher.status
  }

  var widgetPublishingMessage: String {
    widgetPublishingStatus.message()
  }

  private var widgetSubscriptions: [DesktopWidgetSubscription] {
    overview.map {
      DesktopWidgetSubscription(snapshot: $0.snapshot, selector: $0.pinIdentityKey)
    }
  }

  /// Which Overview provider a widget's `quotabar:/subscriptions/<selection_id>` names.
  /// `nil` when no row published under that id, and the panel then opens on Overview.
  func provider(forWidgetSelectionID selectionID: String) -> ProviderID? {
    widgetPublisher.subscription(forSelectionID: selectionID, in: widgetSubscriptions)?
      .snapshot.provider
  }

  func notificationSubscriptions() -> [NotificationSettingsSubscription] {
    var result: [NotificationSettingsSubscription] = []
    for provider in ProviderDisplayOrder.enabledProviders() {
      let items = overview.filter { $0.identity.provider == provider }
      var accountIndex = 0
      for item in items {
        guard Self.presentation(for: item) != nil else { continue }
        let label =
          PlanDisplay.accountLabel(item.snapshot.account.label)
          ?? "Account \(accountIndex + 1)"
        accountIndex += 1
        let selector = NotificationOverview.selector(for: item)
        let values = notificationRules.thresholds(for: selector)
        result.append(
          NotificationSettingsSubscription(
            selector: selector,
            provider: provider,
            providerDisplayName: provider.displayName,
            accountLabel: label,
            firstThreshold: values[0],
            secondThreshold: values.count > 1 ? values[1] : nil
          )
        )
      }
    }
    return result
  }

  func setNotificationsEnabled(_ enabled: Bool) async {
    if enabled {
      let granted: Bool
      do {
        granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound])
      } catch {
        granted = false
      }
      if granted {
        notificationAuthorizationDenied = false
        persistNotificationRules { $0.enabled = true }
      } else {
        notificationAuthorizationDenied = true
        persistNotificationRules { $0.enabled = false }
        resetScheduler.removeAll()
      }
    } else {
      persistNotificationRules { $0.enabled = false }
      resetScheduler.removeAll()
    }
  }

  func setHistorySync(_ enabled: Bool) {
    accountSettings.noteLocalEdit(.setHistorySync(enabled))
  }

  func setResetReminders(_ enabled: Bool) {
    persistNotificationRules { $0.resetReminders = enabled }
    accountSettings.noteLocalEdit(.setResetReminders(enabled))
  }

  func setPaceAlerts(_ enabled: Bool) {
    persistNotificationRules { $0.paceAlerts = enabled }
    accountSettings.noteLocalEdit(.setPaceAlerts(enabled))
  }

  func setNotificationFirstThreshold(_ value: Int, for selector: String) {
    let current = notificationRules.thresholds(for: selector)
    var next = [value]
    if current.count > 1, current[1] != value {
      next.append(current[1])
    }
    persistNotificationRules { $0.setThresholds(next, for: selector) }
    accountSettings.noteLocalEdit(.setThresholds(selector: selector, next))
  }

  func setNotificationSecondThreshold(_ value: Int?, for selector: String) {
    let current = notificationRules.thresholds(for: selector)
    var next = [current[0]]
    if let value, value != current[0] {
      next.append(value)
    }
    persistNotificationRules { $0.setThresholds(next, for: selector) }
    accountSettings.noteLocalEdit(.setThresholds(selector: selector, next))
  }

  func refreshNotificationAuthorization() async {
    let status = await notificationCenter.authorizationStatus()
    switch status {
    case .denied:
      notificationAuthorizationDenied = true
      if notificationRules.enabled {
        persistNotificationRules { $0.enabled = false }
        resetScheduler.removeAll()
      }
    case .authorized, .provisional, .notDetermined:
      notificationAuthorizationDenied = false
    default:
      break
    }
  }

  func openNotificationSystemSettings() {
    _ = loginURLOpener.open(NotificationsSettingsCopy.systemSettingsURL)
  }

  private func applyAccountSettingsPolicy(_ policy: AccountSettingsPolicy) {
    persistNotificationRules { $0 = $0.applying(policy) }
    usage.replaceBudget(UsageBudget(policy: policy))
  }

  private func persistNotificationRules(_ update: (inout AlertRules) -> Void) {
    var rules = notificationRules
    update(&rules)
    guard rules != notificationRules else { return }
    NotificationRules.store(defaults: notificationDefaults).save(rules)
    notificationRules = rules
    evaluateNotifications(overview: overview, now: Date())
  }

  /// Compare the latest Overview readings against the last available ones, hand events to the
  /// sink, and rebuild reset reminders. A `windowReset` whose selector and window already have
  /// a scheduled reminder is left to that reminder.
  private func evaluateNotifications(overview: [LocalServiceOverviewItem], now: Date) {
    let rules = notificationRules
    let previous = (try? notificationStore.load()) ?? .empty
    let current = NotificationOverview.readings(from: overview)
    let catalog = NotificationOverview.catalog(from: overview)
    let result = AlertEvaluator.evaluate(
      rules: rules,
      previous: previous,
      current: current,
      now: now
    )
    if result.state != previous {
      try? notificationStore.save(result.state)
    }
    if let userNotificationSink {
      userNotificationSink.catalog = catalog
      userNotificationSink.scheduledResetKeys = resetScheduler.scheduledResetKeys
      userNotificationSink.now = now
    }
    if !result.events.isEmpty {
      notificationSink.deliver(result.events)
    }
    resetScheduler.reschedule(
      rules: rules,
      subscriptions: current,
      catalog: catalog,
      now: now
    )
  }

  private static func presentation(
    for item: LocalServiceOverviewItem
  ) -> AccountQuotaPresentation? {
    let sourcePairs = item.sources.compactMap { source in
      source.observationSource.map { (source.sourceID, $0) }
    }
    // A selected source the service did not also describe is not a row this panel can stand
    // behind, so the whole observation is dropped rather than shown without provenance.
    guard sourcePairs.contains(where: { $0.0 == item.selectedSourceID }) else { return nil }

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
      state: item.snapshot.reportedState == .available && item.isStale
        ? .stale
        : item.snapshot.reportedState,
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
