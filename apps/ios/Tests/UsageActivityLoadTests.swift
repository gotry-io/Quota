import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct UsageActivityLoadTests {
  @Test
  func restoreDoesNotFetchActivity() async {
    let loader = ScriptedActivityLoader(results: [])
    let model = makeActivityModel(loader: loader, session: true)
    await model.restore()
    #expect(await loader.calls.isEmpty)
    #expect(model.activityChart == .idle)
  }

  @Test
  func enteringUsageRequestsActivityOnce() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")]))
    ])
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    await model.loadActivity()
    let firstCalls = await loader.calls
    #expect(firstCalls.count == 1)
    #expect(firstCalls[0].from == "2025-08-15")
    #expect(firstCalls[0].to == "2026-08-14")
    #expect(firstCalls[0].detail == nil)
    guard case .loaded(let days) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    #expect(model.activityChart == .failed)
    await model.loadActivity()
    #expect(await loader.calls.count == 2)
    #expect(model.activityChart == .loaded([]))
  }

  @Test
  func advancingTheUtcDayReloadsActivity() async {
    let clock = TestClock(activityNow())
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-15")])),
    ])
    let model = makeActivityModel(loader: loader, session: true, now: { clock.now })
    model.phase = .signedIn
    await model.loadActivity()
    #expect(await loader.calls.count == 1)
    #expect(await loader.calls[0].to == "2026-08-14")
    clock.now = activityNow().addingTimeInterval(86_400)
    await model.loadActivity()
    #expect(await loader.calls.count == 2)
    #expect(await loader.calls[1].to == "2026-08-15")
    guard case .loaded(let days) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    #expect(await loader.calls.count == 1)
    model.summaryETag = "etag-2"
    await model.loadActivity()
    #expect(await loader.calls.count == 2)
    guard case .loaded(let days) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
      return
    }
    #expect(days.map(\.date) == ["2026-08-13"])
  }

  @Test
  func returningToTheForegroundReloadsLoadedActivity() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")])),
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-13")])),
    ])
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    #expect(await loader.calls.count == 1)
    await model.setForeground(true)
    #expect(await loader.calls.count == 2)
    guard case .loaded(let days) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    let first = Task { await model.loadActivity() }
    await waitUntil { await loader.calls.count == 1 }
    let second = Task { await model.loadActivity(force: true) }
    await waitUntil { await loader.calls.count == 2 }
    await loader.release()
    await first.value
    #expect(model.activityChart == .loading)
    await loader.release()
    await second.value
    guard case .loaded(let days) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    let first = Task { await model.loadActivity() }
    await waitUntil { await loader.calls.count == 1 }
    await loader.release()
    await first.value
    guard case .loaded(let firstDays) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
      return
    }
    #expect(firstDays.map(\.date) == ["2026-08-14"])

    let second = Task { await model.loadActivity(force: true) }
    await waitUntil { await loader.calls.count == 2 }
    guard case .refreshing(let held) = model.activityChart else {
      Issue.record("expected refreshing last-good, got \(model.activityChart)")
      await loader.release()
      await second.value
      return
    }
    #expect(held.map(\.date) == ["2026-08-14"])
    await loader.release()
    await second.value
    guard case .loaded(let next) = model.activityChart else {
      Issue.record("expected loaded chart, got \(model.activityChart)")
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
    let model = makeActivityModel(loader: loader, session: true, now: { clock.now })
    model.phase = .signedIn
    await model.loadRhythm()
    let firstCalls = await loader.calls
    #expect(firstCalls.count == 1)
    #expect(firstCalls[0].detail == .hours)
    await model.loadRhythm()
    #expect(await loader.calls.count == 1)
    clock.now = activityNow().addingTimeInterval(86_400)
    await model.loadRhythm()
    let calls = await loader.calls
    #expect(calls.count == 2)
    #expect(calls[1].detail == .hours)
    guard case .loaded(let hours, _) = model.activityRhythm else {
      Issue.record("expected loaded rhythm, got \(model.activityRhythm)")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    await model.openActivityDay(date: "2026-08-14")
    #expect(model.activityDaySheet?.date == "2026-08-14")
    #expect(model.activityDaySheet?.agents == .failed)
    #expect(await loader.calls.last?.detail == .agents)
    await model.retryActivityDay()
    guard case .loaded(let agents) = model.activityDaySheet?.agents else {
      Issue.record(
        "expected loaded agents, got \(String(describing: model.activityDaySheet?.agents))")
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
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    await model.openActivityDay(date: "2026-08-10")
    #expect(model.activityDaySheet?.agents == .empty)
  }

  @Test
  func daySheetStartsLoadingBeforeTheReadReturns() {
    let loader = ScriptedActivityLoader(results: [])
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    model.activityChart = .loaded([emptyDay("2026-08-14")])
    model.presentActivityDay(date: "2026-08-14")
    #expect(model.activityDaySheet?.date == "2026-08-14")
    #expect(model.activityDaySheet?.agents == .loading)
  }

  @Test
  func logoutClearsActivityMemory() async {
    let loader = ScriptedActivityLoader(results: [
      .activity(AccountUsageActivityResponse(days: [emptyDay("2026-08-14")]))
    ])
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    await model.openActivityDay(date: "2026-08-14")
    await model.logout()
    #expect(model.activityChart == .idle)
    #expect(model.activityDaySheet == nil)
  }
}

@MainActor
private func makeActivityModel(
  loader: any ActivityLoading,
  session: Bool,
  now: @escaping @Sendable () -> Date = { activityNow() }
) -> AppModel {
  AppModel(
    account: AccountClient(
      relay: RelayClient(transport: EmptyHTTPTransport()),
      sessionStore: MemoryAccountSessionStore(
        session: session ? activitySession() : nil
      ),
      summaryStore: MemoryAccountSummaryStore(),
      now: now
    ),
    authenticator: CancelledAuthenticator(),
    activity: loader,
    now: now
  )
}

private func activityNow() -> Date {
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime]
  return formatter.date(from: "2026-08-14T16:00:00Z")!
}

private func activitySession() -> AccountSession {
  AccountSession(
    accountID: "account_01",
    accessToken: "qia_synthetic_access_token",
    accessExpiresAt: activityNow(),
    refreshToken: "qiar_synthetic_refresh_token",
    refreshExpiresAt: activityNow().addingTimeInterval(8_000_000),
    activation: .active
  )
}

private func emptyDay(_ date: String) -> UsageActivityDay {
  UsageActivityChart.emptyDay(date: date)
}

private func rhythmResponse(tokensAtHour: Int) -> AccountUsageActivityResponse {
  AccountUsageActivityResponse(
    days: [],
    hoursOfDay: (0..<24).map { hour in
      UsageHourOfDay(
        hour: hour,
        totalTokens: hour == tokensAtHour ? 12 : 0,
        costMicrousd: nil
      )
    },
    weekdayHours: Array(repeating: Array(repeating: 0, count: 24), count: 7)
  )
}

private final class TestClock: @unchecked Sendable {
  var now: Date
  init(_ now: Date) { self.now = now }
}

private func waitUntil(_ condition: @escaping @Sendable () async -> Bool) async {
  for _ in 0..<2_000 {
    if await condition() { return }
    try? await Task.sleep(for: .milliseconds(2))
  }
  Issue.record("timed out waiting")
}

private actor GatedActivityLoader: ActivityLoading {
  struct Call: Equatable, Sendable {
    var from: String
    var to: String
    var detail: ActivityDetail?
    var timeZone: String?
  }

  private var results: [AccountActivityResult]
  private(set) var calls: [Call] = []
  private var permits = 0
  private var waiting: [CheckedContinuation<Void, Never>] = []

  init(results: [AccountActivityResult]) {
    self.results = results
  }

  func release() {
    if !waiting.isEmpty {
      waiting.removeFirst().resume()
    } else {
      permits += 1
    }
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult {
    calls.append(Call(from: from, to: to, detail: detail, timeZone: timeZone))
    if permits > 0 {
      permits -= 1
    } else {
      await withCheckedContinuation { continuation in
        waiting.append(continuation)
      }
    }
    return results.isEmpty ? .failure(.relay(.unavailable)) : results.removeFirst()
  }
}

private actor ScriptedActivityLoader: ActivityLoading {
  struct Call: Equatable, Sendable {
    var from: String
    var to: String
    var detail: ActivityDetail?
    var timeZone: String?
  }

  private var results: [AccountActivityResult]
  private(set) var calls: [Call] = []

  init(results: [AccountActivityResult]) {
    self.results = results
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?,
    timeZone: String?
  ) async -> AccountActivityResult {
    calls.append(Call(from: from, to: to, detail: detail, timeZone: timeZone))
    return results.isEmpty ? .failure(.relay(.unavailable)) : results.removeFirst()
  }
}

private final class EmptyHTTPTransport: HTTPTransport, @unchecked Sendable {
  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    throw HTTPTransportError.unavailable
  }
}

@MainActor
private final class CancelledAuthenticator: BrowserSessionAuthenticating {
  func authenticate(
    url: URL,
    callbackScheme: String,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws -> URL {
    throw AuthorizationError.cancelled
  }

  func present(
    url: URL,
    callbackScheme: String?,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws {}

  func cancelPresentation() {}
}
