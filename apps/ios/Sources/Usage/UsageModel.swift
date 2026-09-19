import Foundation
import Observation
import QuotaAccount
import QuotaAlerts
import QuotaPresentation
import QuotaRelay
import QuotaWire

/// Selected Usage range, activity/rhythm/day reads, and the monthly budget this device keeps.
///
/// The managed Account session stays on `AppModel`. This owner is told when a summary is
/// accepted and when the account goes away; in-flight reads carry the session epoch and drop
/// their completion when it no longer matches.
@MainActor
@Observable
final class UsageModel {
  private let activity: any ActivityLoading
  private let budgetStore: UsageBudgetStore
  private let now: @Sendable () -> Date

  /// True while `AppModel.phase` is `signedIn`. Not a copy of the session.
  @ObservationIgnored var isSignedIn: () -> Bool = { false }
  /// Session epoch owned by `AppModel`; incremented when the account goes away.
  @ObservationIgnored var sessionEpoch: () -> Int = { 0 }
  @ObservationIgnored var skipsUnforcedLoad: () -> Bool = { false }
  @ObservationIgnored var onSessionExpired: () -> Void = {}
  @ObservationIgnored var onNotSignedIn: () -> Void = {}
  @ObservationIgnored var evaluateBudget: (UsageBudget, UsageBudgetProgress?) -> Void = { _, _ in }

  var usagePeriod: UsagePeriodSelection = .last30Days
  /// The monthly budget this device keeps, which is a preference and never leaves it.
  var budget: UsageBudget
  /// Last 365 UTC days. Memory only; a failed read stays here and does not block the period list.
  var activityChart: ActivityChartPhase = .idle
  /// The selected period's hour-of-day rhythm, asked with `detail=hours`.
  var activityRhythm: ActivityRhythmPhase = .idle
  /// Presented day sheet, if any.
  var activityDaySheet: ActivityDaySheetState?
  /// The selected period's Account period read, except All which stays on the summary.
  var periodRead: PeriodReadPhase = .idle

  @ObservationIgnored private var activityGeneration = 0
  @ObservationIgnored private var rhythmGeneration = 0
  @ObservationIgnored private var dayGeneration = 0
  @ObservationIgnored private var periodGeneration = 0
  @ObservationIgnored private var budgetPeriodGeneration = 0
  @ObservationIgnored private var lastActivityToday: String?
  @ObservationIgnored private var lastActivitySummaryETag: String?
  @ObservationIgnored private var lastRhythmKey: RhythmLoadKey?
  @ObservationIgnored private var lastPeriodKey: PeriodLoadKey?
  @ObservationIgnored private var lastBudgetPeriodKey: PeriodLoadKey?
  @ObservationIgnored private var lastPeriodSummaryETag: String?
  @ObservationIgnored private var periodCache: [PeriodLoadKey: AccountUsagePeriodResponse] = [:]
  @ObservationIgnored private var budgetPeriod: AccountUsagePeriodResponse?
  /// The Account usage fold last accepted from a summary. Nil after the account goes away.
  @ObservationIgnored private var acceptedSummary: AccountSummary?
  @ObservationIgnored private var summaryETag: String?

  init(
    activity: any ActivityLoading,
    budgetStore: UsageBudgetStore = UsageBudgetStore(),
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.activity = activity
    self.budgetStore = budgetStore
    self.now = now
    self.budget = budgetStore.load()
  }

  /// The Account summary this owner may fold periods from. Called when AppModel accepts one,
  /// including a cached restore and a refresh that left last-good in place.
  func accountSummaryAccepted(_ summary: AccountSummary?, etag: String?) {
    acceptedSummary = summary
    summaryETag = etag
  }

  /// Logout, expiry, or a missing session: reset the same Usage fields `applySignedOut` reset.
  func accountWentAway() {
    acceptedSummary = nil
    summaryETag = nil
    usagePeriod = .last30Days
    activityChart = .idle
    activityRhythm = .idle
    activityDaySheet = nil
    periodRead = .idle
    lastActivityToday = nil
    lastActivitySummaryETag = nil
    lastRhythmKey = nil
    lastPeriodKey = nil
    lastBudgetPeriodKey = nil
    lastPeriodSummaryETag = nil
    periodCache = [:]
    budgetPeriod = nil
    activityGeneration += 1
    rhythmGeneration += 1
    dayGeneration += 1
    periodGeneration += 1
    budgetPeriodGeneration += 1
  }

  var activityToday: String {
    UsageActivityCalendar.utcDay(from: now())
  }

  var activityDateRange: (from: String, to: String) {
    UsageActivityCalendar.range(endingOn: activityToday)
  }

  /// The dates the selected period covers, or nil for `all`, which names no first day.
  var usagePeriodRange: (from: String, to: String)? {
    usagePeriod.range(today: now())
  }

  /// The title above the totals: the range the selected period covers.
  var usagePeriodTitle: String {
    UsagePeriodTitle.text(for: usagePeriod, today: now())
  }

  /// The earliest day a custom range may name, which is what the activity read still answers.
  var usageEarliestDay: String {
    activityDateRange.from
  }

  /// The activity days this device has, which the year heatmap draws.
  var activityDays: [UsageActivityDay] {
    activityChart.days ?? []
  }

  /// The selected period. All stays on the summary's 730 UTC-day window; every other selection
  /// is the Account period read for that local range.
  var usagePeriodValue: UsagePeriod? {
    if usagePeriod == .all {
      return acceptedSummary?.usage.all
    }
    guard let range = usagePeriodRange, let response = periodRead.response,
      lastPeriodKey?.from == range.from, lastPeriodKey?.to == range.to
    else { return nil }
    return response.usagePeriod
  }

  /// Local `days[]` for the selected period's asked dates. All has none.
  var usagePeriodDays: [UsagePeriodDayBucket] {
    guard usagePeriod != .all, let range = usagePeriodRange, let response = periodRead.response,
      lastPeriodKey?.from == range.from, lastPeriodKey?.to == range.to
    else { return [] }
    return response.days
  }

  /// Retention cut the asked local range, which the Usage page names in one line.
  var usagePeriodTruncated: Bool {
    guard usagePeriod != .all, let range = usagePeriodRange, let response = periodRead.response,
      lastPeriodKey?.from == range.from, lastPeriodKey?.to == range.to
    else { return false }
    return response.coverage.truncatedByRetention
  }

  /// How far into this month's budget its spend has gone, or nil when there is no budget yet.
  var budgetProgress: UsageBudgetProgress? {
    guard let amount = budget.amountUSD, let month = budgetPeriod else { return nil }
    let spent = UsageBudgetProgress.dollars(microusd: month.cost.amountMicrousd) ?? 0
    return UsageBudgetProgress(
      spentUSD: spent,
      budgetUSD: amount,
      partial: month.cost.status != .complete
    )
  }

  func selectUsagePeriod(_ selection: UsagePeriodSelection) {
    usagePeriod = selection
    activityRhythm = .idle
    lastRhythmKey = nil
    rhythmGeneration += 1
    periodGeneration += 1
  }

  func setBudget(_ next: UsageBudget) {
    budget = budgetStore.save(next)
    Task { @MainActor in
      await loadBudgetPeriod(force: true)
    }
    evaluateBudgetAlerts()
  }

  /// Says once per month that 80% and then 100% of the budget has been spent.
  func evaluateBudgetAlerts() {
    evaluateBudget(budget, budgetProgress)
  }

  /// First visit to Usage asks once. Last-good stays on screen while a later read revalidates.
  func loadActivity(force: Bool = false) async {
    guard isSignedIn() else { return }
    #if DEBUG
      // Visual fixtures pose loading/failed; an unforced tab task must not replace them.
      if skipsUnforcedLoad(), !force {
        switch activityChart {
        case .loading, .failed: return
        default: break
        }
      }
    #endif
    if force, case .idle = activityChart { return }
    let lastGood = activityChart.days
    if !force {
      switch activityChart {
      case .idle, .failed:
        break
      case .loading:
        return
      case .loaded, .refreshing:
        guard activityNeedsRevalidation else { return }
      }
    }
    activityGeneration += 1
    let generation = activityGeneration
    let epoch = sessionEpoch()
    if let lastGood {
      activityChart = .refreshing(lastGood)
    } else {
      activityChart = .loading
    }
    let range = activityDateRange
    let result = await activity.fetchUsageActivity(
      from: range.from,
      to: range.to,
      detail: nil,
      timeZone: nil
    )
    guard generation == activityGeneration, epoch == sessionEpoch(), isSignedIn() else { return }
    applyActivity(result, lastGood: lastGood)
  }

  /// Every selection except All reads the period route. Presets are the same path.
  func loadPeriod(force: Bool = false) async {
    guard isSignedIn() else { return }
    guard let range = usagePeriodRange else {
      periodRead = .idle
      lastPeriodKey = nil
      return
    }
    if force, case .idle = periodRead, lastPeriodKey == nil { return }
    #if DEBUG
      if skipsUnforcedLoad(), !force {
        switch periodRead {
        case .loading, .failed: return
        default: break
        }
      }
    #endif
    let key = currentPeriodKey(from: range.from, to: range.to, breakdown: true)
    let lastGood = periodCache[key]
    if !force {
      switch periodRead {
      case .loading:
        if lastPeriodKey == key { return }
      case .loaded, .refreshing:
        if lastPeriodKey == key && !periodNeedsRevalidation { return }
      case .idle, .failed:
        break
      }
    }
    periodGeneration += 1
    let generation = periodGeneration
    let epoch = sessionEpoch()
    lastPeriodKey = key
    if let lastGood {
      periodRead = .refreshing(lastGood)
    } else {
      periodRead = .loading
    }
    let result = await activity.fetchUsagePeriod(
      from: range.from,
      to: range.to,
      timezone: key.timezone,
      breakdown: true
    )
    guard generation == periodGeneration, epoch == sessionEpoch(), isSignedIn(),
      usagePeriodRange?.from == range.from, usagePeriodRange?.to == range.to
    else { return }
    applyPeriod(result, key: key, lastGood: lastGood)
  }

  /// The monthly budget measures this local month through the same period read.
  func loadBudgetPeriod(force: Bool = false) async {
    guard isSignedIn(), budget.isSet,
      let range = UsagePeriodSelection.thisMonth.range(today: now())
    else {
      budgetPeriod = nil
      lastBudgetPeriodKey = nil
      return
    }
    if force, budgetPeriod == nil, lastBudgetPeriodKey == nil { return }
    #if DEBUG
      if skipsUnforcedLoad(), !force, budgetPeriod != nil { return }
    #endif
    let key = currentPeriodKey(from: range.from, to: range.to, breakdown: false)
    if !force, lastBudgetPeriodKey == key, budgetPeriod != nil, !periodNeedsRevalidation {
      return
    }
    budgetPeriodGeneration += 1
    let generation = budgetPeriodGeneration
    let epoch = sessionEpoch()
    let result = await activity.fetchUsagePeriod(
      from: range.from,
      to: range.to,
      timezone: key.timezone,
      breakdown: false
    )
    guard generation == budgetPeriodGeneration, epoch == sessionEpoch(), isSignedIn() else {
      return
    }
    switch result {
    case .period(let response):
      lastBudgetPeriodKey = key
      lastPeriodSummaryETag = summaryETag
      budgetPeriod = response
      periodCache[key] = response
      evaluateBudgetAlerts()
    case .failure(.sessionExpired):
      onSessionExpired()
    case .failure(.notSignedIn):
      onNotSignedIn()
    case .failure:
      if budgetPeriod == nil, let cached = periodCache[key] {
        budgetPeriod = cached
        lastBudgetPeriodKey = key
        evaluateBudgetAlerts()
      }
    }
  }

  /// The selected period's rhythm, omitted for All, which has no first day.
  func loadRhythm(force: Bool = false) async {
    #if DEBUG
      if skipsUnforcedLoad(), !force {
        switch activityRhythm {
        case .loading, .failed: return
        default: break
        }
      }
    #endif
    guard isSignedIn(), let range = usagePeriodRange else {
      activityRhythm = .idle
      lastRhythmKey = nil
      return
    }
    let key = RhythmLoadKey(
      from: range.from,
      to: range.to,
      today: activityToday,
      etag: summaryETag
    )
    let lastGood = activityRhythm.hours
    if force, case .idle = activityRhythm, lastRhythmKey == nil { return }
    if !force {
      switch activityRhythm {
      case .failed:
        break
      case .loading:
        return
      case .idle, .loaded, .refreshing:
        if lastRhythmKey == key { return }
      }
    }
    rhythmGeneration += 1
    let generation = rhythmGeneration
    let epoch = sessionEpoch()
    if let lastGood {
      activityRhythm = .refreshing(
        hoursOfDay: lastGood.hoursOfDay, weekdayHours: lastGood.weekdayHours)
    } else {
      activityRhythm = .loading
    }
    let result = await activity.fetchUsageActivity(
      from: range.from,
      to: range.to,
      detail: .hours,
      timeZone: TimeZone.current.identifier
    )
    guard generation == rhythmGeneration, epoch == sessionEpoch(), isSignedIn(),
      usagePeriodRange?.from == range.from, usagePeriodRange?.to == range.to
    else { return }
    applyRhythm(result, lastGood: lastGood, key: key)
  }

  func retryActivity() async {
    await loadActivity(force: true)
  }

  func openActivityDay(date: String) async {
    guard isSignedIn() else { return }
    presentActivityDay(date: date)
    await loadActivityDayAgents()
  }

  func presentActivityDay(date: String) {
    dayGeneration += 1
    activityDaySheet = ActivityDaySheetState(
      date: date,
      headline: reportedDay(on: date),
      agents: .loading
    )
  }

  func retryActivityDay() async {
    guard activityDaySheet != nil else { return }
    dayGeneration += 1
    updateDaySheet { $0.agents = .loading }
    await loadActivityDayAgents()
  }

  private func loadActivityDayAgents() async {
    guard let current = activityDaySheet else { return }
    let generation = dayGeneration
    let epoch = sessionEpoch()
    let result = await activity.fetchUsageActivity(
      from: current.date,
      to: current.date,
      detail: .agents,
      timeZone: nil
    )
    guard generation == dayGeneration, epoch == sessionEpoch(), isSignedIn(),
      activityDaySheet?.date == current.date
    else { return }
    switch result {
    case .activity(let response):
      applyDayDetail(response, onto: current.date)
    case .failure(.sessionExpired):
      onSessionExpired()
    case .failure(.notSignedIn):
      onNotSignedIn()
    case .failure:
      updateDaySheet { $0.agents = .failed }
    }
  }

  /// A new summary body is new Usage behind the chart; last-good stays until the activity read
  /// answers. An unchanged ETag (or an equal summary when no ETag was offered) is not new data.
  func revalidateActivityIfSummaryChanged(
    previousETag: String?,
    previousSummary: AccountSummary?,
    result: AccountRefreshResult
  ) {
    guard result.error == nil else { return }
    let changed: Bool
    if let previousETag, let newETag = result.etag {
      changed = previousETag != newETag
    } else {
      changed = result.summary != previousSummary
    }
    guard changed else { return }
    Task { @MainActor in
      await loadActivity(force: true)
      await loadPeriod(force: true)
      await loadBudgetPeriod(force: true)
      await loadRhythm(force: true)
    }
  }

  private var activityNeedsRevalidation: Bool {
    guard lastActivityToday != nil else { return false }
    return lastActivityToday != activityToday || lastActivitySummaryETag != summaryETag
  }

  private var periodNeedsRevalidation: Bool {
    lastPeriodSummaryETag != summaryETag
  }

  private func currentPeriodKey(from: String, to: String, breakdown: Bool) -> PeriodLoadKey {
    PeriodLoadKey(
      from: from,
      to: to,
      timezone: TimeZone.current.identifier,
      breakdown: breakdown
    )
  }

  private func applyPeriod(
    _ result: AccountPeriodResult,
    key: PeriodLoadKey,
    lastGood: AccountUsagePeriodResponse?
  ) {
    switch result {
    case .period(let response):
      periodCache[key] = response
      lastPeriodKey = key
      lastPeriodSummaryETag = summaryETag
      periodRead = .loaded(response)
    case .failure(.sessionExpired):
      onSessionExpired()
    case .failure(.notSignedIn):
      onNotSignedIn()
    case .failure:
      if let lastGood {
        lastPeriodKey = key
        periodRead = .loaded(lastGood)
      } else {
        periodRead = .failed
      }
    }
  }

  private func applyActivity(_ result: AccountActivityResult, lastGood: [UsageActivityDay]?) {
    switch result {
    case .activity(let response):
      activityChart = .loaded(response.days)
      lastActivityToday = activityToday
      lastActivitySummaryETag = summaryETag
      evaluateBudgetAlerts()
    case .failure(.sessionExpired):
      onSessionExpired()
    case .failure(.notSignedIn):
      onNotSignedIn()
    case .failure:
      if let lastGood {
        activityChart = .loaded(lastGood)
      } else {
        activityChart = .failed
      }
    }
  }

  private func applyRhythm(
    _ result: AccountActivityResult,
    lastGood: (hoursOfDay: [QuotaWire.UsageHourOfDay], weekdayHours: [[Int]])?,
    key: RhythmLoadKey
  ) {
    switch result {
    case .activity(let response):
      lastRhythmKey = key
      if let hours = response.hoursOfDay, let weekdays = response.weekdayHours,
        hours.contains(where: { $0.totalTokens > 0 })
      {
        activityRhythm = .loaded(hoursOfDay: hours, weekdayHours: weekdays)
      } else {
        activityRhythm = .idle
      }
    case .failure(.sessionExpired):
      onSessionExpired()
    case .failure(.notSignedIn):
      onNotSignedIn()
    case .failure:
      if let lastGood {
        activityRhythm = .loaded(
          hoursOfDay: lastGood.hoursOfDay, weekdayHours: lastGood.weekdayHours)
      } else {
        activityRhythm = .failed
      }
    }
  }

  private func applyDayDetail(_ response: AccountUsageActivityResponse, onto date: String) {
    updateDaySheet { sheet in
      if let day = response.days.first(where: { $0.date == date }) ?? response.days.first {
        sheet.headline = day
        let agents = day.agents ?? []
        sheet.agents = agents.isEmpty ? .empty : .loaded(agents)
      } else {
        sheet.agents = .empty
      }
    }
  }

  private func reportedDay(on date: String) -> UsageActivityDay {
    if let day = activityChart.days?.first(where: { $0.date == date }) {
      return day
    }
    return UsageActivityChart.emptyDay(date: date)
  }

  private func updateDaySheet(_ mutate: (inout ActivityDaySheetState) -> Void) {
    guard var sheet = activityDaySheet else { return }
    mutate(&sheet)
    activityDaySheet = sheet
  }

  #if DEBUG
    /// Fixture seam: pose chart/rhythm/day state without fetching.
    func pose(
      chart: ActivityChartPhase? = nil,
      rhythm: ActivityRhythmPhase? = nil,
      daySheet: ActivityDaySheetState? = nil,
      period: PeriodReadPhase? = nil,
      budgetMonth: AccountUsagePeriodResponse? = nil
    ) {
      if let chart { activityChart = chart }
      if let rhythm { activityRhythm = rhythm }
      if let daySheet { activityDaySheet = daySheet }
      if let period {
        periodRead = period
        if let response = period.response, let range = usagePeriodRange {
          let key = currentPeriodKey(from: range.from, to: range.to, breakdown: true)
          lastPeriodKey = key
          lastPeriodSummaryETag = summaryETag
          periodCache[key] = response
        }
      }
      if let budgetMonth {
        budgetPeriod = budgetMonth
        if let range = UsagePeriodSelection.thisMonth.range(today: now()) {
          let key = currentPeriodKey(from: range.from, to: range.to, breakdown: false)
          lastBudgetPeriodKey = key
          periodCache[key] = budgetMonth
        }
      }
    }
  #endif
}

enum ActivityChartPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded([UsageActivityDay])
  case refreshing([UsageActivityDay])
  case failed

  var days: [UsageActivityDay]? {
    switch self {
    case .loaded(let days), .refreshing(let days): return days
    default: return nil
    }
  }
}

enum ActivityRhythmPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded(hoursOfDay: [QuotaWire.UsageHourOfDay], weekdayHours: [[Int]])
  case refreshing(hoursOfDay: [QuotaWire.UsageHourOfDay], weekdayHours: [[Int]])
  case failed

  var hours: (hoursOfDay: [QuotaWire.UsageHourOfDay], weekdayHours: [[Int]])? {
    switch self {
    case .loaded(let hours, let weekdays), .refreshing(let hours, let weekdays):
      return (hours, weekdays)
    default:
      return nil
    }
  }
}

private struct RhythmLoadKey: Equatable {
  var from: String
  var to: String
  var today: String
  var etag: String?
}

struct PeriodLoadKey: Hashable, Sendable {
  var from: String
  var to: String
  var timezone: String
  var breakdown: Bool
}

enum PeriodReadPhase: Equatable, Sendable {
  case idle
  case loading
  case loaded(AccountUsagePeriodResponse)
  case refreshing(AccountUsagePeriodResponse)
  case failed

  var response: AccountUsagePeriodResponse? {
    switch self {
    case .loaded(let response), .refreshing(let response): return response
    default: return nil
    }
  }
}

enum ActivityDayAgentsPhase: Equatable, Sendable {
  case loading
  case loaded([UsageAgentUsage])
  case empty
  case failed
}

struct ActivityDaySheetState: Identifiable, Equatable, Sendable {
  var id: String { date }
  var date: String
  var headline: UsageActivityDay
  var agents: ActivityDayAgentsPhase
}
