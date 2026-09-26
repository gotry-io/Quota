import Foundation
import QuotaAccount
import QuotaPresentation
import QuotaProviderSessions
import QuotaProviderStatus
import QuotaWire

#if DEBUG
  /// One visual fixture as a value: account phase, providers, summary, usage, and local readings.
  ///
  /// A scenario builds coherent owner state through `AppModel.pose` / `UsageModel.pose`, not by
  /// assigning production fields from the outside.
  struct VisualScenario: Sendable {
    var fixture: VisualFixture
    var phase: AppModel.Phase
    var sessionActivation: AccountSessionActivation?
    var sessionDeviceID: String?
    var summary: AccountSummary?
    var fetchedAt: Date?
    var fromCache: Bool
    var isRefreshing: Bool
    /// The Macs asked for a fresh reading and waited on, with the instant Relay stored.
    var collectionDemand: CollectionDemand?
    /// Provider sessions whose reading has not come back in the posed refresh.
    var pendingReadings: Set<String>
    var refreshReads: Int
    var banner: AppModel.Banner?
    var expiredMessage: String?
    var selectedTab: AppTab
    var presentsSignIn: Bool
    var identities: AppModel.IdentitiesPhase
    var providerStatus: [ProviderID: ProviderStatusReading]
    var localCollection: LocalCollection?
    var localSamples: LocalQuotaSamples
    var providerSessions: [StoredProviderSession]
    var usageChart: ActivityChartPhase
    var usageRhythm: ActivityRhythmPhase
    var usageDaySheet: ActivityDaySheetState?
    var usagePeriod: PeriodReadPhase
    var usageBudgetMonth: AccountUsagePeriodResponse?
    var activityLoaderDays: [UsageActivityDay]
    var activityLoaderUsage: AccountUsage

    @MainActor
    static func make(_ fixture: VisualFixture, now: Date) -> VisualScenario {
      let activation: AccountSessionActivation? =
        switch fixture {
        case .signedOut, .connecting, .connectError, .expired, .loading, .localOnly, .signIn:
          nil
        case .confirmAccount, .connectRefreshFailed:
          .pending
        case .content, .launch, .updating, .askingMac, .cachedError, .empty, .noDevices, .merged, .providers,
          .activityLoading, .activityFailed, .activityDayEmpty, .activityDayFailed, .signInMethods:
          .active
        }
      let phoneID = activation == nil ? nil : VisualFixtureContent.phoneDeviceID
      let populated = VisualFixtureContent.summary(at: now)
      let emptyWithDevices = VisualFixtureContent.emptySummary(
        at: now, devices: VisualFixtureContent.devices(at: now))
      let emptyNoDevices = VisualFixtureContent.emptySummary(at: now)
      let activityDays = VisualFixtureContent.activityDays(ending: now)
      let emptyUsage = emptyNoDevices.usage

      var scenario = VisualScenario(
        fixture: fixture,
        phase: .signedOut,
        sessionActivation: activation,
        sessionDeviceID: phoneID,
        summary: nil,
        fetchedAt: nil,
        fromCache: false,
        isRefreshing: false,
        collectionDemand: nil,
        pendingReadings: [],
        refreshReads: 0,
        banner: nil,
        expiredMessage: nil,
        selectedTab: .quota,
        presentsSignIn: false,
        identities: .idle,
        providerStatus: [:],
        localCollection: nil,
        localSamples: LocalQuotaSamples(),
        providerSessions: [],
        usageChart: .idle,
        usageRhythm: .idle,
        usageDaySheet: nil,
        usagePeriod: .idle,
        usageBudgetMonth: nil,
        activityLoaderDays: [],
        activityLoaderUsage: populated.usage
      )

      func signedInContent(
        fromCache: Bool,
        fetchedOffset: TimeInterval,
        banner: AppModel.Banner?,
        includeIncidentStatus: Bool = false
      ) {
        scenario.phase = .signedIn
        scenario.summary = populated
        scenario.fetchedAt = now.addingTimeInterval(fetchedOffset)
        scenario.fromCache = fromCache
        scenario.banner = banner
        poseUsage(days: activityDays, usage: populated.usage)
        scenario.activityLoaderDays = activityDays
        scenario.activityLoaderUsage = populated.usage
        if includeIncidentStatus {
          scenario.providerStatus = VisualFixtureContent.incidentStatus(at: now)
        }
      }

      func poseUsage(days: [UsageActivityDay], usage: AccountUsage) {
        var period: PeriodReadPhase = .idle
        var budget: AccountUsagePeriodResponse?
        if let range = UsagePeriodSelection.last30Days.range(today: now) {
          period = .loaded(
            VisualFixtureContent.accountPeriodResponse(
              from: range.from,
              to: range.to,
              usage: usage.last30Days,
              days: days
            )
          )
        }
        if let month = UsagePeriodSelection.thisMonth.range(today: now) {
          budget = VisualFixtureContent.accountPeriodResponse(
            from: month.from,
            to: month.to,
            usage: VisualFixtureContent.periodUsage(fromDays: days, from: month.from, to: month.to),
            days: days
          )
        }
        scenario.usageChart = .loaded(days)
        scenario.usagePeriod = period
        scenario.usageBudgetMonth = budget
      }

      func applyLocal(_ collection: LocalCollection) {
        scenario.localCollection = collection
        scenario.localSamples = VisualFixtureContent.localSamples(
          for: collection, at: collection.collectedAt)
      }

      switch fixture {
      case .signedOut:
        scenario.phase = .signedOut
      case .localOnly:
        scenario.phase = .signedOut
        applyLocal(VisualFixtureContent.localCollection(at: now))
      case .merged:
        signedInContent(fromCache: false, fetchedOffset: -90, banner: nil)
        applyLocal(VisualFixtureContent.mergedLocalCollection(at: now))
      case .connecting:
        scenario.phase = .connecting
      case .connectError:
        scenario.phase = .signedOut
        scenario.banner = AppModel.Banner(
          kind: .refreshFailed,
          text: AuthorizationError.genericConnectFailureMessage,
          symbolName: "exclamationmark.triangle"
        )
      case .expired:
        scenario.phase = .signedOut
        scenario.expiredMessage = "Session expired. Connect again."
      case .loading:
        // Nothing read yet, and the first refresh is asking both providers.
        scenario.phase = .signedOut
        scenario.providerSessions = VisualFixtureContent.providerSessions(for: .loading, at: now)
        scenario.isRefreshing = true
        scenario.pendingReadings = Set(scenario.providerSessions.map(\.key))
        scenario.refreshReads = scenario.providerSessions.count
      case .launch:
        signedInContent(fromCache: true, fetchedOffset: -180, banner: nil)
      case .updating:
        // The summary and Codex have answered; Claude's reading is still on its way.
        signedInContent(fromCache: false, fetchedOffset: -90, banner: nil)
        scenario.isRefreshing = true
        scenario.pendingReadings = Set(
          populated.subscriptions.filter { $0.provider == .claude }.map {
            LocalCollector.sessionKey(for: $0.snapshot)
          })
        scenario.refreshReads = 3
      case .askingMac:
        // Opened on readings older than two minutes: the Macs were asked twenty seconds ago.
        signedInContent(fromCache: false, fetchedOffset: -20, banner: nil)
        scenario.collectionDemand = CollectionDemand.stale(
          in: populated, selfDeviceID: phoneID, now: now
        ).map {
          var demand = $0
          demand.requestedAt = now.addingTimeInterval(-20)
          return demand
        }
      case .confirmAccount:
        scenario.phase = .confirmingAccount(label: populated.account.displayLabel ?? "octocat")
        scenario.summary = populated
        scenario.fetchedAt = now.addingTimeInterval(-90)
      case .connectRefreshFailed:
        scenario.phase = .pendingRefreshFailed
        scenario.banner = AppModel.Banner(
          kind: .refreshFailed,
          text: "Couldn't reach quota.gotry.io.",
          symbolName: "exclamationmark.triangle"
        )
      case .content:
        signedInContent(
          fromCache: false, fetchedOffset: -90, banner: nil, includeIncidentStatus: true)
      case .cachedError:
        signedInContent(
          fromCache: true,
          fetchedOffset: -180,
          banner: AppModel.Banner(
            kind: .offlineCached,
            text: AppModel.Banner.cachedText,
            symbolName: "icloud.slash"
          ),
          includeIncidentStatus: true
        )
      case .empty:
        scenario.phase = .signedIn
        scenario.summary = emptyWithDevices
        scenario.fetchedAt = now.addingTimeInterval(-60)
        poseUsage(days: [], usage: emptyWithDevices.usage)
        scenario.activityLoaderUsage = emptyUsage
      case .noDevices:
        scenario.phase = .signedIn
        scenario.summary = emptyNoDevices
        scenario.fetchedAt = now.addingTimeInterval(-60)
        poseUsage(days: [], usage: emptyNoDevices.usage)
        scenario.activityLoaderUsage = emptyUsage
      case .providers:
        signedInContent(fromCache: false, fetchedOffset: -90, banner: nil)
        applyLocal(VisualFixtureContent.refusedCollection(at: now))
        scenario.selectedTab = .settings
        scenario.providerSessions = VisualFixtureContent.providerSessions(
          for: .providers, at: now)
        scenario.activityLoaderDays = []
      case .signIn:
        scenario.phase = .signedOut
        applyLocal(VisualFixtureContent.localCollection(at: now))
        scenario.presentsSignIn = true
      case .signInMethods:
        signedInContent(fromCache: false, fetchedOffset: -90, banner: nil)
        scenario.selectedTab = .settings
        scenario.identities = .loaded([
          AccountIdentity(
            provider: .github,
            label: "octocat",
            linkedAt: now.addingTimeInterval(-86_400 * 210)
          ),
          AccountIdentity(
            provider: .apple,
            label: nil,
            linkedAt: now.addingTimeInterval(-86_400 * 30)
          ),
        ])
      case .activityLoading, .activityFailed, .activityDayEmpty, .activityDayFailed:
        signedInContent(fromCache: false, fetchedOffset: -90, banner: nil)
        scenario.selectedTab = .usage
        switch fixture {
        case .activityLoading:
          scenario.usageChart = .loading
          scenario.usageRhythm = .loading
        case .activityFailed:
          scenario.usageChart = .failed
          scenario.usageRhythm = .failed
        case .activityDayEmpty:
          let date = UsageActivityCalendar.addDays(
            -3,
            to: UsageActivityCalendar.utcDay(from: now)
          )
          scenario.usageDaySheet = ActivityDaySheetState(
            date: date,
            headline: UsageActivityChart.emptyDay(date: date),
            agents: .empty
          )
        case .activityDayFailed:
          let date = UsageActivityCalendar.utcDay(from: now)
          let headline =
            activityDays.first { $0.date == date }
            ?? UsageActivityChart.emptyDay(date: date)
          scenario.usageDaySheet = ActivityDaySheetState(
            date: date,
            headline: headline,
            agents: .failed
          )
        default:
          break
        }
      }

      return scenario
    }

    @MainActor
    func apply(to model: AppModel, clockIsFixed: Bool = true) {
      model.pose(
        phase: phase,
        sessionActivation: sessionActivation,
        sessionDeviceID: sessionDeviceID,
        summary: summary,
        fetchedAt: fetchedAt,
        fromCache: fromCache,
        isRefreshing: isRefreshing,
        collectionDemand: collectionDemand,
        pendingReadings: pendingReadings,
        refreshReads: refreshReads,
        banner: banner,
        expiredMessage: expiredMessage,
        localCollection: localCollection,
        localSamples: localSamples,
        selectedTab: selectedTab,
        presentsSignIn: presentsSignIn,
        identities: identities,
        providerStatus: providerStatus,
        skipsRestore: true,
        isOfflineFixture: true,
        displayClockIsFixed: clockIsFixed
      )
      model.usage.pose(
        chart: usageChart,
        rhythm: usageRhythm,
        daySheet: usageDaySheet,
        period: usagePeriod,
        budgetMonth: usageBudgetMonth
      )
    }

    /// Combinations a scenario may declare: session, phase, and content have to agree.
    var validationIssues: [String] {
      var issues: [String] = []
      switch (phase, sessionActivation) {
      case (.signedOut, nil), (.connecting, nil), (.launching, nil):
        break
      case (.confirmingAccount, .pending), (.pendingRefreshFailed, .pending):
        break
      case (.signedIn, .active):
        if summary == nil { issues.append("signedIn requires a summary") }
      default:
        issues.append(
          "phase \(phase) does not match session \(String(describing: sessionActivation))"
        )
      }
      if sessionActivation == nil, sessionDeviceID != nil {
        issues.append("no session must not name a Device")
      }
      if sessionActivation != nil, sessionDeviceID == nil {
        issues.append("a session must name this phone's Device")
      }
      if case .confirmingAccount = phase, summary == nil {
        issues.append("confirmingAccount requires a summary")
      }
      if fixture == .localOnly {
        if phase != .signedOut { issues.append("localOnly is signedOut") }
        if summary != nil { issues.append("localOnly has no Account summary") }
        if localCollection == nil { issues.append("localOnly needs local readings") }
      }
      if fixture == .merged {
        if localCollection == nil { issues.append("merged needs local readings") }
        if phase != .signedIn { issues.append("merged is signedIn") }
      }
      if fixture == .providers, providerSessions.isEmpty {
        issues.append("providers needs stored sessions")
      }
      if fixture == .loading, providerSessions.isEmpty || !isRefreshing {
        issues.append("loading is a first refresh of stored sessions")
      }
      if fixture == .updating, pendingReadings.isEmpty || !isRefreshing {
        issues.append("updating is a refresh with a reading still pending")
      }
      if fixture == .askingMac, collectionDemand?.requestedAt == nil {
        issues.append("askingMac waits on a request Relay stored")
      }
      if fixture == .signIn, presentsSignIn != true {
        issues.append("signIn presents the sheet")
      }
      return issues
    }
  }
#endif
