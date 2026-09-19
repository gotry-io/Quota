import Foundation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing

@testable import QuotaBar

@MainActor
struct UsageModelTests {
  @Test
  func loadQuotaHistoryFoldsSamplesOnDemandAndLeavesStateOnTheCurrentWindow() async throws {
    let now = Date(timeIntervalSince1970: 1_788_100_000)
    let fiveHourReset = now.addingTimeInterval(2 * 3_600)
    let weeklyReset = now.addingTimeInterval(3 * 86_400)
    let observed = now.addingTimeInterval(-3_600)
    let snapshot = QuotaSnapshot(
      provider: .codex,
      account: QuotaAccount(
        fingerprint: "account_test",
        label: nil,
        plan: "Plus",
        fingerprintScope: .global
      ),
      windows: [
        QuotaWindow(
          id: "five_hour",
          title: "5 Hours",
          usedPercent: 40,
          resetsAt: fiveHourReset,
          durationSeconds: 18_000
        ),
        QuotaWindow(
          id: "weekly",
          title: "Weekly",
          usedPercent: 20,
          resetsAt: weeklyReset,
          durationSeconds: 604_800,
          primaryCadence: .weekly
        ),
      ],
      status: .available,
      observedAt: now
    )
    let source = LocalServiceOverviewSource(
      sourceID: "local",
      kind: .local,
      deviceID: nil,
      displayName: "This Mac",
      observedAt: now,
      isStale: false
    )
    let state = LocalServiceState(
      ipcVersion: 3,
      revision: 7,
      usageUploadEnabled: true,
      groupUsageByProject: true,
      quotaRefreshIntervalSeconds: 300,
      usagePeriods: emptyUsagePeriods(),
      quota: emptyComponent(),
      usage: emptyComponent(),
      account: emptyComponent(),
      pricing: emptyComponent(),
      providers: [],
      providerBrowserSessions: [],
      browserScanEnabled: [],
      overview: [
        LocalServiceOverviewItem(
          identity: LocalServiceOverviewIdentity(
            provider: .codex,
            fingerprint: "account_test",
            scope: .global,
            sourceID: nil
          ),
          snapshot: snapshot,
          sources: [source],
          selectedSourceID: source.sourceID,
          selectedSourceDisplayName: source.displayName,
          automaticSourceID: source.sourceID,
          automaticSourceDisplayName: source.displayName,
          isStale: false
        )
      ],
      cache: .settled
    )
    let samples = LocalServiceQuotaHistory(
      samplesBySubscription: [
        "ccfc96629357": [
          "five_hour": [
            QuotaSample(resetsAt: fiveHourReset, observedAt: observed, usedPercent: 10),
            QuotaSample(resetsAt: fiveHourReset, observedAt: now, usedPercent: 40),
          ],
          "weekly": [
            QuotaSample(resetsAt: weeklyReset, observedAt: now, usedPercent: 20)
          ],
        ]
      ],
      utcOffsetSeconds: 0
    )
    let (model, defaults) = makeUsageModel(
      transport: StubLocalService(state: state, quotaHistoryValue: samples),
      now: { now }
    )
    defer { defaults.tearDown() }
    model.acceptState(state)
    #expect(model.quotaHistory.isEmpty)
    #expect(model.quotaHistorySamples == nil)

    model.loadQuotaHistory()
    try await waitUntil { !model.quotaHistory.isEmpty }

    #expect(model.quotaHistorySamples == samples)
    let fiveHour = try #require(model.quotaHistory["ccfc96629357"]?["five_hour"])
    let weekly = try #require(model.quotaHistory["ccfc96629357"]?["weekly"])
    #expect(fiveHour.points.map(\.usedPercent) == [10, 40])
    #expect(weekly.points.map(\.usedPercent) == [20])
  }

  @Test
  func emptyUsageCacheWhileRefreshingIsPreparingNotMissing() async throws {
    let state = LocalServiceState(
      ipcVersion: 3,
      revision: 1,
      usageUploadEnabled: true,
      groupUsageByProject: true,
      quotaRefreshIntervalSeconds: 300,
      usagePeriods: emptyUsagePeriods(),
      quota: emptyComponent(),
      usage: LocalServiceComponent(
        status: .unavailable,
        value: nil,
        updatedAt: nil,
        lastError: nil,
        refreshing: true
      ),
      account: LocalServiceComponent(
        status: .signedOut,
        value: LocalServiceAccountState(
          authStatus: .signedOut,
          accountID: nil,
          displayLabel: nil,
          deviceID: nil,
          deviceGeneration: nil,
          accountSummary: nil
        ),
        updatedAt: nil,
        lastError: nil,
        refreshing: false
      ),
      pricing: emptyComponent(),
      providers: [],
      providerBrowserSessions: [],
      browserScanEnabled: [],
      overview: [],
      cache: .settled
    )
    let (model, defaults) = makeUsageModel()
    defer { defaults.tearDown() }
    model.acceptState(state)
    #expect(model.usageDetail(source: .local, period: .today) == nil)
    #expect(model.isPreparingUsage(source: .local))
    #expect(!model.isPreparingUsage(source: .account))
  }

  @Test
  func bottomBarTodayLineFollowsTheSourceTheUsagePageWouldActuallyShow() async throws {
    let state = LocalServiceState(
      ipcVersion: 3,
      revision: 2,
      usageUploadEnabled: true,
      groupUsageByProject: true,
      quotaRefreshIntervalSeconds: 300,
      usagePeriods: LocalServiceUsagePeriodCache(
        local: todayOnly(tokens: 1_234_567),
        account: todayOnly(tokens: 9_876_543)
      ),
      quota: emptyComponent(),
      usage: emptyComponent(),
      account: emptyComponent(),
      pricing: emptyComponent(),
      providers: [],
      providerBrowserSessions: [],
      browserScanEnabled: [],
      overview: [],
      cache: .settled
    )
    let (model, defaults) = makeUsageModel()
    defer { defaults.tearDown() }
    model.acceptState(state)
    #expect(model.effectiveUsageSource(.account) == .local)
    #expect(model.todayUsageSummary(source: .account)?.text == "Today · 1.23M tokens")
    #expect(model.todayUsageSummary(source: .local)?.text == "Today · 1.23M tokens")
  }

  @Test
  func anOlderCustomPeriodResultIsIgnoredAfterANewerRequest() async throws {
    let transport = GatedUsageTransport()
    let (model, defaults) = makeUsageModel(transport: transport)
    defer { defaults.tearDown() }

    let first = periodDetail(from: "2026-08-01", to: "2026-08-03", tokens: 11)
    let second = periodDetail(from: "2026-08-10", to: "2026-08-12", tokens: 22)

    model.selectUsagePeriod(.custom(from: "2026-08-01", to: "2026-08-03"))
    try await waitUntil { await transport.pendingCount("2026-08-01|2026-08-03") == 1 }

    model.selectUsagePeriod(.custom(from: "2026-08-10", to: "2026-08-12"))
    try await waitUntil { await transport.pendingCount("2026-08-10|2026-08-12") == 1 }

    await transport.complete(from: "2026-08-10", to: "2026-08-12", with: second)
    try await waitUntil {
      model.customUsagePeriods[UsageModel.periodKey(("2026-08-10", "2026-08-12"))] != nil
    }

    await transport.complete(from: "2026-08-01", to: "2026-08-03", with: first)
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))

    #expect(model.customUsagePeriods[UsageModel.periodKey(("2026-08-01", "2026-08-03"))] == nil)
    #expect(
      model.customUsagePeriods[UsageModel.periodKey(("2026-08-10", "2026-08-12"))]?.usage.totals
        .totalTokens == 22)
    #expect(!model.customUsageLoading)
  }

  @Test
  func monthRolloverIgnoresThePreviousMonthFold() async throws {
    let calendar = Calendar.current
    let january = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 1, day: 31, hour: 12)))
    let february = try #require(
      calendar.date(from: DateComponents(year: 2026, month: 2, day: 1, hour: 12)))
    let januaryRange = try #require(UsagePeriodSelection.thisMonth.range(today: january))
    let februaryRange = try #require(UsagePeriodSelection.thisMonth.range(today: february))
    #expect(januaryRange.from != februaryRange.from)

    let clock = TestClock(january)
    let transport = GatedUsageTransport()
    let (model, defaults) = makeUsageModel(transport: transport, now: { clock.now })
    defer { defaults.tearDown() }

    model.setBudget(UsageBudget(amountUSD: 50, alerts: false))
    try await waitUntil {
      await transport.pendingCount(UsageModel.periodKey(januaryRange)) == 1
    }

    clock.now = february
    model.refreshBudgetMonth()
    try await waitUntil {
      await transport.pendingCount(UsageModel.periodKey(februaryRange)) == 1
    }

    await transport.complete(
      from: januaryRange.from, to: januaryRange.to,
      with: periodDetail(from: januaryRange.from, to: januaryRange.to, tokens: 1)
    )
    await Task.yield()
    try await Task.sleep(for: .milliseconds(30))
    #expect(model.budgetMonthDetail == nil)

    await transport.complete(
      from: februaryRange.from, to: februaryRange.to,
      with: periodDetail(from: februaryRange.from, to: februaryRange.to, tokens: 2)
    )
    try await waitUntil { model.budgetMonthDetail != nil }
    #expect(model.budgetMonthDetail?.range.from == februaryRange.from)
    #expect(model.budgetMonthDetail?.range.to == februaryRange.to)
    #expect(model.budgetMonthDetail?.usage.totals.totalTokens == 2)
  }

  @Test
  func acceptStateDiscardsCustomPeriodsEvenWhenUsageDidNotChange() async throws {
    let transport = GatedUsageTransport()
    let (model, defaults) = makeUsageModel(transport: transport)
    defer { defaults.tearDown() }

    let state = overviewOnlyState(overview: [])
    let detail = periodDetail(from: "2026-08-01", to: "2026-08-03", tokens: 9)
    let key = UsageModel.periodKey(("2026-08-01", "2026-08-03"))

    model.selectUsagePeriod(.custom(from: "2026-08-01", to: "2026-08-03"))
    try await waitUntil { await transport.pendingCount(key) == 1 }
    await transport.complete(from: "2026-08-01", to: "2026-08-03", with: detail)
    try await waitUntil { model.customUsagePeriods[key] != nil }
    #expect(model.customUsagePeriods[key]?.usage.totals.totalTokens == 9)

    model.acceptState(state)
    #expect(model.customUsagePeriods.isEmpty)

    try await waitUntil { await transport.pendingCount(key) == 1 }
    await transport.complete(from: "2026-08-01", to: "2026-08-03", with: detail)
    try await waitUntil { model.customUsagePeriods[key] != nil }
  }
}

@MainActor
private final class TestClock {
  var now: Date
  init(_ now: Date) { self.now = now }
}

private struct UsageDefaults {
  let suiteName: String
  let store: UserDefaults

  func tearDown() {
    store.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeUsageModel(
  transport: (any UsageTransport)? = nil,
  now: @escaping @MainActor () -> Date = { Date() }
) -> (UsageModel, UsageDefaults) {
  let suiteName = "UsageModelTests.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: suiteName)!
  store.removePersistentDomain(forName: suiteName)
  let model = UsageModel(
    transport: transport,
    budgetStore: UsageBudgetStore(defaults: store),
    notificationSink: NoOpAlertSink(),
    now: now
  )
  return (model, UsageDefaults(suiteName: suiteName, store: store))
}

private func emptyUsagePeriods() -> LocalServiceUsagePeriodCache {
  let values = LocalServiceUsagePeriodValues(
    today: nil,
    last7Days: nil,
    last30Days: nil,
    all: nil
  )
  return LocalServiceUsagePeriodCache(local: values, account: values)
}

private func emptyComponent<Value: Decodable & Sendable>() -> LocalServiceComponent<Value> {
  LocalServiceComponent(
    status: .unavailable,
    value: nil,
    updatedAt: nil,
    lastError: nil,
    refreshing: false
  )
}

private func todayOnly(tokens: Int) -> LocalServiceUsagePeriodValues {
  LocalServiceUsagePeriodValues(
    today: periodDetail(from: "2026-08-10", to: "2026-08-10", tokens: tokens),
    last7Days: nil,
    last30Days: nil,
    all: nil
  )
}

private func periodDetail(from: String, to: String, tokens: Int) -> LocalServiceUsageDetail {
  LocalServiceUsageDetail(
    range: UsageDateRange(from: from, to: to),
    usage: LocalUsagePeriodSummary(
      totals: UsageSummaryTotals(
        totalTokens: tokens,
        inputTokens: tokens,
        outputTokens: 0,
        cacheReadInputTokens: 0,
        cacheWriteInputTokens: 0,
        reasoningTokens: 0,
        messages: 1
      ),
      cost: UsageCostOutcome(
        mode: .calculate,
        basis: .none,
        status: .unavailable,
        amountMicrousd: nil,
        catalogRevision: nil,
        calculatedRows: 0,
        reportedRows: 0,
        unpricedRows: 1,
        assumptions: [],
        unpriced: []
      ),
      cacheSaved: UsageCacheSaved(amountMicrousd: "0", status: .complete, unpricedRows: 0),
      agents: []
    ),
    incomplete: false,
    detailsTruncated: false
  )
}

private func waitUntil(
  _ condition: @escaping @MainActor () async -> Bool,
  seconds: Double = 5
) async throws {
  let deadline = ContinuousClock.now + .seconds(seconds)
  while await !condition() {
    if ContinuousClock.now >= deadline {
      Issue.record("timed out waiting for condition")
      return
    }
    await Task.yield()
    try await Task.sleep(for: .milliseconds(10))
  }
}

actor GatedUsageTransport: UsageTransport {
  private var pending: [String: [CheckedContinuation<LocalServiceUsageDetail, Error>]] = [:]

  func usagePeriod(from: String, to: String) async throws -> LocalServiceUsageDetail {
    let key = "\(from)|\(to)"
    return try await withCheckedThrowingContinuation { continuation in
      pending[key, default: []].append(continuation)
    }
  }

  func quotaHistory(since: Date) async throws -> LocalServiceQuotaHistory {
    throw LocalServiceClientError.invalidMessage
  }

  func pendingCount(_ key: String) -> Int {
    pending[key]?.count ?? 0
  }

  func complete(from: String, to: String, with detail: LocalServiceUsageDetail) {
    let key = "\(from)|\(to)"
    guard var queue = pending[key], !queue.isEmpty else { return }
    let first = queue.removeFirst()
    pending[key] = queue
    first.resume(returning: detail)
  }
}
