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
  func failedActivityStaysInTheCardUntilRetry() async {
    let loader = ScriptedActivityLoader(results: [
      .failure(.relay(.unavailable)),
      .activity(AccountUsageActivityResponse(days: [])),
    ])
    let model = makeActivityModel(loader: loader, session: true)
    model.phase = .signedIn
    await model.loadActivity()
    #expect(model.activityChart == .failed)
    await model.loadActivity()
    #expect(await loader.calls.count == 1)
    await model.retryActivity()
    #expect(await loader.calls.count == 2)
    #expect(model.activityChart == .loaded([]))
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
      Issue.record("expected loaded agents, got \(String(describing: model.activityDaySheet?.agents))")
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
  session: Bool
) -> AppModel {
  AppModel(
    account: AccountClient(
      relay: RelayClient(transport: EmptyHTTPTransport()),
      sessionStore: MemoryAccountSessionStore(
        session: session ? activitySession() : nil
      ),
      summaryStore: MemoryAccountSummaryStore(),
      now: { activityNow() }
    ),
    authenticator: CancelledAuthenticator(),
    activity: loader,
    now: { activityNow() }
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
    refreshExpiresAt: activityNow().addingTimeInterval(8_000_000)
  )
}

private func emptyDay(_ date: String) -> UsageActivityDay {
  UsageActivityChart.emptyDay(date: date)
}

private actor ScriptedActivityLoader: ActivityLoading {
  struct Call: Equatable, Sendable {
    var from: String
    var to: String
    var detail: ActivityDetail?
  }

  private var results: [AccountActivityResult]
  private(set) var calls: [Call] = []

  init(results: [AccountActivityResult]) {
    self.results = results
  }

  func fetchUsageActivity(
    from: String,
    to: String,
    detail: ActivityDetail?
  ) async -> AccountActivityResult {
    calls.append(Call(from: from, to: to, detail: detail))
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
}
