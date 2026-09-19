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

  @ObservationIgnored private var activityGeneration = 0
  @ObservationIgnored private var rhythmGeneration = 0
  @ObservationIgnored private var dayGeneration = 0
  @ObservationIgnored private var lastActivityToday: String?
  @ObservationIgnored private var lastActivitySummaryETag: String?
  @ObservationIgnored private var lastRhythmKey: RhythmLoadKey?
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
    lastActivityToday = nil
    lastActivitySummaryETag = nil
    lastRhythmKey = nil
    activityGeneration += 1
    rhythmGeneration += 1
    dayGeneration += 1
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

  /// The days a folded period may reach back over, which is what the activity read answered.
  var usageEarliestDay: String {
    activityDateRange.from
  }

  /// The activity days this device has, which is what a folded period is added up from.
  var activityDays: [UsageActivityDay] {
    activityChart.days ?? []
  }

  /// The selected period, read from the summary when it folds it and added up here when not.
  ///
  /// The summary answers four periods exactly, in the caller's own calendar. Anything else is
  /// the activity days the page already holds, which are UTC days: a range is chosen in this
  /// device's calendar and folded from the UTC days carrying those dates.
  var usagePeriodValue: UsagePeriod? {
    if let key = usagePeriod.summaryKey, let usage = acceptedSummary?.usage {
      return period(usage, key)
    }
    guard let range = usagePeriodRange, let days = activityChart.days else { return nil }
    return UsageDayFold.period(days, from: range.from, to: range.to)
  }

  /// Whether the shown period was added up here, which is why it has no model breakdown.
  var usagePeriodIsFolded: Bool {
    usagePeriod.summaryKey == nil
  }

  /// How far into this month's budget its spend has gone, or nil when there is no budget yet.
  var budgetProgress: UsageBudgetProgress? {
    guard let amount = budget.amountUSD,
      let range = UsagePeriodSelection.thisMonth.range(today: now()),
      let days = activityChart.days
    else { return nil }
    let month = UsageDayFold.period(days, from: range.from, to: range.to)
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
  }

  func setBudget(_ next: UsageBudget) {
    budget = budgetStore.save(next)
    evaluateBudgetAlerts()
  }

  /// Says once per month that 80% and then 100% of the budget has been spent.
  func evaluateBudgetAlerts() {
    evaluateBudget(budget, budgetProgress)
  }

  private func period(_ usage: AccountUsage, _ key: UsageSummaryPeriodKey) -> UsagePeriod {
    switch key {
    case .today: usage.today
    case .last7Days: usage.last7Days
    case .last30Days: usage.last30Days
    case .all: usage.all
    }
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
      await loadRhythm(force: true)
    }
  }

  private var activityNeedsRevalidation: Bool {
    guard lastActivityToday != nil else { return false }
    return lastActivityToday != activityToday || lastActivitySummaryETag != summaryETag
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
      chart: ActivityChartPhase = .idle,
      rhythm: ActivityRhythmPhase = .idle,
      daySheet: ActivityDaySheetState? = nil
    ) {
      activityChart = chart
      activityRhythm = rhythm
      activityDaySheet = daySheet
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
