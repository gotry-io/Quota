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

    private func loadedUsage(
      amountUSD: Decimal? = 50,
      periodResults: [AccountPeriodResult] = []
    ) -> (UsageModel, ScriptedActivityLoader, UsageHarness) {
      let defaults = UserDefaults(suiteName: "io.gotry.quota.usage-model-budget-test")!
      defaults.removePersistentDomain(forName: "io.gotry.quota.usage-model-budget-test")
      let store = UsageBudgetStore(defaults: defaults)
      store.save(UsageBudget(amountUSD: amountUSD, alerts: true))
      let harness = UsageHarness()
      let now = Self.now
      let days = VisualFixtureContent.activityDays(ending: now)
      let summary = VisualFixtureContent.summary(at: now)
      let loader = ScriptedActivityLoader(results: [], periodResults: periodResults)
      let usage = harness.model(loader: loader, budgetStore: store, now: { now })
      usage.accountSummaryAccepted(summary, etag: "etag-1")
      var period: PeriodReadPhase = .idle
      var budget: AccountUsagePeriodResponse?
      if let range = UsagePeriodSelection.last30Days.range(today: now) {
        period = .loaded(
          VisualFixtureContent.accountPeriodResponse(
            from: range.from,
            to: range.to,
            usage: summary.usage.last30Days,
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
      usage.pose(chart: .loaded(days), period: period, budgetMonth: budget)
      return (usage, loader, harness)
    }

    @Test
    func readsAllFromTheSummaryAndPresetsFromThePeriodRead() async {
      let todayRange = UsagePeriodSelection.today.range(today: Self.now)!
      let summary = VisualFixtureContent.summary(at: Self.now)
      let todayBody = VisualFixtureContent.accountPeriodResponse(
        from: todayRange.from,
        to: todayRange.to,
        usage: summary.usage.today,
        days: VisualFixtureContent.activityDays(ending: Self.now)
      )
      let (usage, loader, harness) = loadedUsage(periodResults: [.period(todayBody)])
      _ = harness
      usage.selectUsagePeriod(.today)
      await usage.loadPeriod()
      #expect(usage.usagePeriodValue?.totals == summary.usage.today.totals)
      #expect(usage.usagePeriodValue?.agents.isEmpty == false)
      let calls = await loader.periodCalls
      #expect(calls.count == 1)
      #expect(calls[0].from == todayRange.from)
      #expect(calls[0].to == todayRange.to)
      #expect(calls[0].breakdown)
      #expect(calls[0].modelSeries, "the river is drawn from series=model")

      usage.selectUsagePeriod(.all)
      #expect(usage.usagePeriodValue?.totals == summary.usage.all.totals)
    }

    @Test
    func aBudgetMeasuresThisMonthFromThePeriodRead() {
      let (usage, _, _) = loadedUsage()
      guard let progress = usage.budgetProgress else {
        Issue.record("A budget of $50 has progress")
        return
      }
      #expect(progress.budgetUSD == 50)
      #expect(progress.percent >= 0)
      #expect(progress.text.contains("$50.00"))

      let (none, _, _) = loadedUsage(amountUSD: nil)
      #expect(none.budgetProgress == nil)
    }

    @Test
    func keepsTheLastPeriodOnError() async {
      let todayRange = UsagePeriodSelection.today.range(today: Self.now)!
      let summary = VisualFixtureContent.summary(at: Self.now)
      let todayBody = VisualFixtureContent.accountPeriodResponse(
        from: todayRange.from,
        to: todayRange.to,
        usage: summary.usage.today,
        days: VisualFixtureContent.activityDays(ending: Self.now)
      )
      let (usage, _, harness) = loadedUsage(periodResults: [
        .period(todayBody),
        .failure(.relay(.unavailable)),
      ])
      _ = harness
      usage.selectUsagePeriod(.today)
      await usage.loadPeriod()
      #expect(usage.usagePeriodValue?.totals == summary.usage.today.totals)
      await usage.loadPeriod(force: true)
      #expect(usage.usagePeriodValue?.totals == summary.usage.today.totals)
    }

    @Test
    func anOlderPeriodRequestIsIgnoredAfterANewerOne() async {
      let todayRange = UsagePeriodSelection.today.range(today: Self.now)!
      let weekRange = UsagePeriodSelection.thisWeek.range(today: Self.now)!
      let summary = VisualFixtureContent.summary(at: Self.now)
      let days = VisualFixtureContent.activityDays(ending: Self.now)
      let loader = GatedActivityLoader(
        results: [],
        periodResults: [
          .period(
            VisualFixtureContent.accountPeriodResponse(
              from: todayRange.from,
              to: todayRange.to,
              usage: summary.usage.today,
              days: days
            )
          ),
          .period(
            VisualFixtureContent.accountPeriodResponse(
              from: weekRange.from,
              to: weekRange.to,
              usage: summary.usage.last7Days,
              days: days
            )
          ),
        ]
      )
      let harness = UsageHarness()
      let now = Self.now
      let usage = harness.model(loader: loader, now: { now })
      usage.accountSummaryAccepted(summary, etag: nil)
      usage.selectUsagePeriod(.today)
      let first = Task { await usage.loadPeriod() }
      await waitUntil { await loader.periodCalls.count == 1 }
      usage.selectUsagePeriod(.thisWeek)
      let second = Task { await usage.loadPeriod() }
      await waitUntil { await loader.periodCalls.count == 2 }
      await loader.release()
      await first.value
      await loader.release()
      await second.value
      #expect(usage.usagePeriodValue?.totals == summary.usage.last7Days.totals)
    }
  }
#endif
