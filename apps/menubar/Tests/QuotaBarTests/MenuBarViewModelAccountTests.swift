import Foundation
import Testing

@testable import QuotaBar

@Test @MainActor
func refreshLoopInvokesOnlySyncAtLaunchAndAfterOneInterval() async throws {
  let summary = try makeAccountSummary()
  let client = RecordingAccountClient(summary: summary)
  let sleep = OneTickSleep()
  let model = MenuBarViewModel(
    client: client,
    reportCache: nil,
    refreshInterval: .seconds(300),
    refreshSleep: { _ in try await sleep.wait() }
  )

  model.startRefreshLoop()
  for _ in 0..<100 {
    if await client.counts().sync >= 2 { break }
    await Task.yield()
  }

  let counts = await client.counts()
  #expect(counts.sync == 2)
  #expect(counts.login == 0)
  #expect(counts.logout == 0)
  #expect(counts.accountSummary == 0)
}

@Test @MainActor
func accountSummaryCommandRunsOnlyForAnExplicitAccountRefresh() async throws {
  let summary = try makeAccountSummary()
  let client = RecordingAccountClient(summary: summary)
  let model = MenuBarViewModel(client: client, reportCache: nil)

  await model.refresh()
  #expect(await client.counts().sync == 1)
  #expect(await client.counts().accountSummary == 0)

  await model.refreshAccountSummary()
  #expect(await client.counts().sync == 1)
  #expect(await client.counts().accountSummary == 1)
  #expect(model.accountDisplayLabel == "octocat")
}

private actor RecordingAccountClient: LocalQuotaServing {
  struct Counts: Sendable {
    var sync = 0
    var login = 0
    var logout = 0
    var accountSummary = 0
  }

  private let summary: AccountSummary
  private var commandCounts = Counts()

  init(summary: AccountSummary) {
    self.summary = summary
  }

  func sync() async throws -> CLIAccountSyncOutput {
    commandCounts.sync += 1
    return CLIAccountSyncOutput(
      status: .synced,
      localReport: QuotaCollectionReport(
        schemaVersion: 2,
        capturedAt: summary.generatedAt,
        results: []
      ),
      localUsage: localUsage(from: summary),
      accountSummary: summary
    )
  }

  func login() async throws -> CLIAccountAuthOutput {
    commandCounts.login += 1
    throw UnexpectedAccountCommand()
  }

  func logout() async throws -> CLIAccountAuthOutput {
    commandCounts.logout += 1
    throw UnexpectedAccountCommand()
  }

  func accountSummary() async throws -> AccountSummary {
    commandCounts.accountSummary += 1
    return summary
  }

  func counts() -> Counts {
    commandCounts
  }
}

private func localUsage(from summary: AccountSummary) -> LocalUsageReport {
  LocalUsageReport(
    generatedAt: summary.generatedAt,
    aggregationTimezone: "UTC",
    range: summary.usage.range,
    status: .complete,
    totals: summary.usage.totals,
    cost: summary.usage.cost,
    coverage: [],
    breakdowns: summary.usage.breakdowns
  )
}

private actor OneTickSleep {
  private var calls = 0

  func wait() throws {
    calls += 1
    if calls > 1 { throw CancellationError() }
  }
}

private struct UnexpectedAccountCommand: Error {}

private func makeAccountSummary() throws -> AccountSummary {
  let data = Data(
    #"{"protocol_version":2,"generated_at":"2026-08-02T01:00:00Z","account":{"account_id":"account_test","display_label":"octocat","created_at":"2026-08-01T00:00:00Z"},"devices":[],"quota":[],"usage":{"range":{"from":"2026-08-01","to":"2026-08-02"},"totals":{"input_tokens":0,"cache_read_tokens":0,"cache_write_5m_tokens":0,"cache_write_1h_tokens":0,"cache_write_inferred_tokens":0,"output_tokens":0,"reasoning_tokens":0,"requests":0,"web_search_requests":0,"web_fetch_requests":0,"source_cost_microusd":null,"source_cost_covered_requests":0},"cost":{"mode":"calculate","basis":"none","status":"complete","amount_microusd":null,"catalog_revision":null,"calculated_rows":0,"reported_rows":0,"unpriced_rows":0,"assumptions":[],"unpriced":[]},"coverage":[],"breakdowns":[]}}"#
      .utf8
  )
  return try QuotaWireCodec.makeDecoder().decode(AccountSummary.self, from: data)
}
