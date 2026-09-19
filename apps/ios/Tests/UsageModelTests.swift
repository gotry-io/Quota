import Foundation
import QuotaAccount
import QuotaAlerts
import QuotaPresentation
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct UsageModelTests {
  @Test
  func enteringUsageRequestsActivityOnce() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")]))
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    await usage.loadActivity()
    await usage.loadActivity()
    let firstCalls = await loader.calls
    #expect(firstCalls.count == 1)
    #expect(firstCalls[0].from == "2025-08-15")
    #expect(firstCalls[0].to == "2026-08-14")
    #expect(firstCalls[0].detail == nil)
    guard case .loaded(let days) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-14"])
  }

  @Test
  func failedActivityRetriesWhenUsageIsSelectedAgain() async {
    let loader = ScriptedActivityLoader(results: [
      .failure(.relay(.unavailable)),
      .activity(AccountUsageActivityResponse(days: [])),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    await usage.loadActivity()
    #expect(usage.activityChart == .failed)
    await usage.loadActivity()
    #expect(await loader.calls.count == 2)
    #expect(usage.activityChart == .loaded([]))
  }

  @Test
  func advancingTheUtcDayReloadsActivity() async {
    let clock = TestClock(activityNow())
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-15")])),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader, now: { clock.now })
    await usage.loadActivity()
    #expect(await loader.calls.count == 1)
    #expect(await loader.calls[0].to == "2026-08-14")
    clock.now = activityNow().addingTimeInterval(86_400)
    await usage.loadActivity()
    #expect(await loader.calls.count == 2)
    #expect(await loader.calls[1].to == "2026-08-15")
    guard case .loaded(let days) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-15"])
  }

  @Test
  func aNewSummaryReloadsActivity() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-13")])),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    await usage.loadActivity()
    #expect(await loader.calls.count == 1)
    usage.accountSummaryAccepted(nil, etag: "etag-2")
    await usage.loadActivity()
    #expect(await loader.calls.count == 2)
    guard case .loaded(let days) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-13"])
  }

  @Test
  func anObsoleteActivityResponseIsDropped() async {
    let loader = GatedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-13")])),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    let first = Task { await usage.loadActivity() }
    await waitUntil { await loader.calls.count == 1 }
    let second = Task { await usage.loadActivity(force: true) }
    await waitUntil { await loader.calls.count == 2 }
    await loader.release()
    await first.value
    #expect(usage.activityChart == .loading)
    await loader.release()
    await second.value
    guard case .loaded(let days) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-13"])
  }

  @Test
  func aRevalidationKeepsLastGoodWithoutFlashingTheSkeleton() async {
    let loader = GatedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-13")])),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    let first = Task { await usage.loadActivity() }
    await waitUntil { await loader.calls.count == 1 }
    await loader.release()
    await first.value
    guard case .loaded(let firstDays) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(firstDays.map(\.date) == ["2026-08-14"])

    let second = Task { await usage.loadActivity(force: true) }
    await waitUntil { await loader.calls.count == 2 }
    guard case .refreshing(let held) = usage.activityChart else {
      Issue.record("expected refreshing last-good, got \(usage.activityChart)")
      await loader.release()
      await second.value
      return
    }
    #expect(held.map(\.date) == ["2026-08-14"])
    await loader.release()
    await second.value
    guard case .loaded(let next) = usage.activityChart else {
      Issue.record("expected loaded chart, got \(usage.activityChart)")
      return
    }
    #expect(next.map(\.date) == ["2026-08-13"])
  }

  @Test
  func rhythmReloadsWhenThePeriodRangeChanges() async {
    let clock = TestClock(activityNow())
    let loader = ScriptedActivityLoader(results: [
      .activity(rhythmResponse(tokensAtHour: 9)),
      .activity(rhythmResponse(tokensAtHour: 10)),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader, now: { clock.now })
    await usage.loadRhythm()
    let firstCalls = await loader.calls
    #expect(firstCalls.count == 1)
    #expect(firstCalls[0].detail == .hours)
    await usage.loadRhythm()
    #expect(await loader.calls.count == 1)
    clock.now = activityNow().addingTimeInterval(86_400)
    await usage.loadRhythm()
    let calls = await loader.calls
    #expect(calls.count == 2)
    #expect(calls[1].detail == .hours)
    guard case .loaded(let hours, _) = usage.activityRhythm else {
      Issue.record("expected loaded rhythm, got \(usage.activityRhythm)")
      return
    }
    #expect(hours.first { $0.totalTokens > 0 }?.hour == 10)
  }

  @Test
  func anOlderPeriodRequestIsIgnoredAfterANewerOne() async {
    let loader = GatedActivityLoader(results: [
      .activity(rhythmResponse(tokensAtHour: 9)),
      .activity(rhythmResponse(tokensAtHour: 10)),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    let first = Task { await usage.loadRhythm() }
    await waitUntil { await loader.calls.count == 1 }
    usage.selectUsagePeriod(.today)
    let second = Task { await usage.loadRhythm() }
    await waitUntil { await loader.calls.count == 2 }
    await loader.release()
    await first.value
    #expect(usage.activityRhythm == .loading)
    await loader.release()
    await second.value
    guard case .loaded(let hours, _) = usage.activityRhythm else {
      Issue.record("expected loaded rhythm, got \(usage.activityRhythm)")
      return
    }
    #expect(hours.first { $0.totalTokens > 0 }?.hour == 10)
  }

  @Test
  func daySheetLoadsAgentsThenRetryAfterFailure() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .failure(.relay(.unavailable)),
      .activity(
        AccountUsageActivityResponse(days: [
          UsageActivityDay(
            date: "2026-08-14",
            totals: UsageActivityChart.emptyTotals(),
            cost: UsageActivityChart.emptyCost(),
            partial: false,
            agents: [
              UsageAgentUsage(
                agent: .codex,
                providers: [
                  UsageProviderUsage(
                    provider: .openai,
                    models: [
                      UsageModelUsage(
                        model: "gpt-5",
                        totals: UsageSummaryTotals(
                          totalTokens: 12,
                          inputTokens: 10,
                          outputTokens: 2,
                          cacheReadInputTokens: 0,
                          cacheWriteInputTokens: 0,
                          reasoningTokens: 0,
                          messages: 1
                        ),
                        cost: UsageCostOutcome(
                          mode: .calculate,
                          basis: .calculated,
                          status: .complete,
                          amountMicrousd: "1000",
                          catalogRevision: "pricing_1",
                          calculatedRows: 1,
                          reportedRows: 0,
                          unpricedRows: 0,
                          assumptions: [.agentDefaultChannel],
                          unpriced: []
                        )
                      )
                    ]
                  )
                ]
              )
            ]
          )
        ])
      ),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    await usage.loadActivity()
    await usage.openActivityDay(date: "2026-08-14")
    #expect(usage.activityDaySheet?.date == "2026-08-14")
    #expect(usage.activityDaySheet?.agents == .failed)
    #expect(await loader.calls.last?.detail == .agents)
    await usage.retryActivityDay()
    guard case .loaded(let agents) = usage.activityDaySheet?.agents else {
      Issue.record(
        "expected loaded agents, got \(String(describing: usage.activityDaySheet?.agents))")
      return
    }
    #expect(agents.map(\.agent) == [.codex])
    #expect(UsageBreakdown.sections(agents: agents).first?.displayName == "Codex")
  }

  @Test
  func daySheetEmptyWhenTheDayHasNoAgents() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [])),
      .activity(
        AccountUsageActivityResponse(days: [
          UsageActivityDay(
            date: "2026-08-10",
            totals: UsageActivityChart.emptyTotals(),
            cost: UsageActivityChart.emptyCost(),
            partial: false,
            agents: []
          )
        ])
      ),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    await usage.loadActivity()
    await usage.openActivityDay(date: "2026-08-10")
    #expect(usage.activityDaySheet?.agents == .empty)
  }

  @Test
  func daySheetStartsLoadingBeforeTheReadReturns() {
    let loader = ScriptedActivityLoader(results: [])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    usage.activityChart = .loaded([emptyDay("2026-08-14")])
    usage.presentActivityDay(date: "2026-08-14")
    #expect(usage.activityDaySheet?.date == "2026-08-14")
    #expect(usage.activityDaySheet?.agents == .loading)
  }

  @Test
  func anOlderDayRequestIsIgnoredAfterANewerOne() async {
    let loader = GatedActivityLoader(results: [
      .activity(
        AccountUsageActivityResponse(days: [
          UsageActivityDay(
            date: "2026-08-14",
            totals: UsageActivityChart.emptyTotals(),
            cost: UsageActivityChart.emptyCost(),
            partial: false,
            agents: [
              UsageAgentUsage(agent: .codex, providers: [])
            ]
          )
        ])
      ),
      .activity(
        AccountUsageActivityResponse(days: [
          UsageActivityDay(
            date: "2026-08-14",
            totals: UsageActivityChart.emptyTotals(),
            cost: UsageActivityChart.emptyCost(),
            partial: false,
            agents: [
              UsageAgentUsage(agent: .grok, providers: [])
            ]
          )
        ])
      ),
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    usage.activityChart = .loaded([emptyDay("2026-08-14")])
    let first = Task { await usage.openActivityDay(date: "2026-08-14") }
    await waitUntil { await loader.calls.count == 1 }
    let second = Task { await usage.retryActivityDay() }
    await waitUntil { await loader.calls.count == 2 }
    await loader.release()
    await first.value
    #expect(usage.activityDaySheet?.agents == .loading)
    await loader.release()
    await second.value
    guard case .loaded(let agents) = usage.activityDaySheet?.agents else {
      Issue.record(
        "expected loaded agents, got \(String(describing: usage.activityDaySheet?.agents))")
      return
    }
    #expect(agents.map(\.agent) == [.grok])
  }

  @Test
  func aCompletionAfterLogoutDoesNotWriteState() async {
    let loader = GatedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")]))
    ])
    let harness = UsageHarness()
    let usage = harness.model(loader: loader)
    let first = Task { await usage.loadActivity() }
    await waitUntil { await loader.calls.count == 1 }
    harness.signedIn = false
    harness.epoch += 1
    usage.accountWentAway()
    await loader.release()
    await first.value
    #expect(usage.activityChart == .idle)
    #expect(usage.activityDaySheet == nil)
    #expect(usage.usagePeriod == .last30Days)
  }
}

#if DEBUG
  @MainActor
  struct UsageModelPeriodBudgetTests {
    private static let now = VisualFixture.referenceDate

    private func loadedUsage(amountUSD: Decimal? = 50) -> UsageModel {
      let defaults = UserDefaults(suiteName: "io.gotry.quota.usage-model-budget-test")!
      defaults.removePersistentDomain(forName: "io.gotry.quota.usage-model-budget-test")
      let store = UsageBudgetStore(defaults: defaults)
      store.save(UsageBudget(amountUSD: amountUSD, alerts: true))
      let harness = UsageHarness()
      let now = Self.now
      let usage = harness.model(
        loader: ScriptedActivityLoader(results: []),
        budgetStore: store,
        now: { now }
      )
      usage.accountSummaryAccepted(VisualFixtureContent.summary(at: now), etag: nil)
      usage.pose(chart: .loaded(VisualFixtureContent.activityDays(ending: now)))
      return usage
    }

    /// The four the summary folds are read; anything else is added up from the activity days.
    @Test
    func readsTheSummaryForItsFourPeriodsAndFoldsTheRest() {
      let usage = loadedUsage()
      usage.usagePeriod = .today
      #expect(!usage.usagePeriodIsFolded)
      #expect(
        usage.usagePeriodValue?.totals
          == VisualFixtureContent.summary(at: Self.now).usage.today.totals)

      usage.usagePeriod = .thisMonth
      #expect(usage.usagePeriodIsFolded)
      guard let range = usage.usagePeriodRange else {
        Issue.record("This month names a range")
        return
      }
      let expected = UsageDayFold.period(usage.activityDays, from: range.from, to: range.to)
      #expect(usage.usagePeriodValue?.totals == expected.totals)
      // A folded period has no breakdown: a day carries agents only when asked for on its own.
      #expect(usage.usagePeriodValue?.agents.isEmpty == true)
    }

    @Test
    func stepsAWeekBackAndForwardAndStopsAtThisWeek() {
      let usage = loadedUsage()
      usage.usagePeriod = .thisWeek
      let thisWeek = usage.usagePeriodRange?.from
      usage.selectUsagePeriod(usage.usagePeriod.previous ?? .thisWeek)
      #expect(usage.usagePeriod == .week(offset: 1))
      #expect(usage.usagePeriodRange?.from != thisWeek)
      usage.selectUsagePeriod(usage.usagePeriod.next ?? .thisWeek)
      #expect(usage.usagePeriod == .thisWeek)
      #expect(usage.usagePeriod.next == nil)
    }

    @Test
    func aCustomRangeFoldsExactlyTheDaysItNames() {
      let usage = loadedUsage()
      let day = usage.activityToday
      usage.selectUsagePeriod(.custom(from: day, to: day))
      #expect(usage.usagePeriodIsFolded)
      let expected = UsageDayFold.period(usage.activityDays, from: day, to: day)
      #expect(usage.usagePeriodValue?.totals == expected.totals)
    }

    @Test
    func aBudgetMeasuresThisMonthAndNoBudgetMeasuresNothing() {
      let usage = loadedUsage()
      guard let progress = usage.budgetProgress else {
        Issue.record("A budget of $50 has progress")
        return
      }
      #expect(progress.budgetUSD == 50)
      #expect(progress.percent >= 0)
      #expect(progress.text.contains("$50.00"))

      let none = loadedUsage(amountUSD: nil)
      #expect(none.budgetProgress == nil)
    }
  }
#endif
