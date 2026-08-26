import Foundation
import QuotaWire
import Testing

@testable import QuotaBar

@Test @MainActor
func consumesServiceMergedOverviewWithoutReprocessingObservations() async throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let snapshot = QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(
      fingerprint: "account_test",
      label: nil,
      plan: "Plus",
      fingerprintScope: .global
    ),
    windows: [QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20)],
    status: .available,
    observedAt: now
  )
  let report = QuotaCollectionReport(
    capturedAt: now,
    results: [
      QuotaCollectionResult(
        provider: .codex,
        outcome: .success,
        snapshots: [snapshot],
        source: "test",
        message: nil,
        sources: [
          QuotaCollectionSource(
            sourceID: "chatgpt_usage_api", outcome: .success, category: .success)
        ],
        accessDenied: nil
      )
    ]
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
    ipcVersion: 1,
    revision: 7,
    usageUploadEnabled: true,
    usagePeriods: emptyUsagePeriods(),
    quota: component(value: report, updatedAt: now),
    usage: component(value: unavailableUsage(now: now), updatedAt: now),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(
        authStatus: .signedOut,
        accountID: nil,
        deviceID: nil,
        deviceGeneration: nil,
        accountSummary: nil
      ),
      updatedAt: nil,
      lastError: LocalServiceRemoteError(
        code: .deviceDeleted,
        recoveryAction: .login
      ),
      refreshing: false
    ),
    pricing: LocalServiceComponent<PricingCatalog>(
      status: .unavailable,
      value: nil,
      updatedAt: nil,
      lastError: nil,
      refreshing: false
    ),
    providers: [
      LocalServiceProviderConfig(
        provider: .openrouter,
        configured: true,
        maskedAPIKey: "OpenRouter ···test",
        baseURL: nil
      )
    ],
    providerBrowserSessions: [],
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
        isStale: false
      )
    ],
    cache: .settled
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))

  await model.refreshIfNeeded()

  guard case .content(let providers, let warning) = model.overviewState(enabledProviders: [.codex])
  else {
    Issue.record("Expected service-provided quota content")
    return
  }
  #expect(warning == nil)
  // Overview no longer prints where the reading came from or how old it is; VoiceOver still says it.
  #expect(
    providers.first?.accounts.first?.accessibilityLabel(accountIndex: 0, now: now)
      == "Account 1. This Mac. Updated just now"
  )
  #expect(providers.first?.accounts.first?.snapshot == snapshot)
  #expect(model.providerConfigurations[.openrouter]?.maskedAPIKey == "OpenRouter ···test")
  #expect(model.lastCheckedAt == now)
  #expect(model.accountDisconnectReason == .deviceDeleted)
  #expect(
    model.accountErrorMessage == "This device was removed. Sign in again to reconnect it."
  )
}

@Test @MainActor
func emptyUsageCacheWhileRefreshingIsPreparingNotMissing() async throws {
  let state = LocalServiceState(
    ipcVersion: 1,
    revision: 1,
    usageUploadEnabled: true,
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
    overview: [],
    cache: .settled
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))
  await model.refreshIfNeeded()
  #expect(model.usageDetail(source: .local, period: .today) == nil)
  #expect(model.isPreparingUsage(source: .local))
  #expect(!model.isPreparingUsage(source: .account))
}

@Test @MainActor
func aRebuildingCacheShowsTheCatchUpNoticeAndASettledOneDoesNot() async throws {
  let settled = MenuBarViewModel(client: StubLocalService(state: loggingInState()))
  await settled.refreshIfNeeded()
  #expect(!settled.showsCacheRebuildNotice)

  let base = loggingInState()
  let rebuilding = LocalServiceState(
    ipcVersion: base.ipcVersion,
    revision: base.revision,
    usageUploadEnabled: base.usageUploadEnabled,
    usagePeriods: base.usagePeriods,
    quota: base.quota,
    usage: base.usage,
    account: base.account,
    pricing: base.pricing,
    providers: base.providers,
    providerBrowserSessions: base.providerBrowserSessions,
    overview: base.overview,
    cache: LocalServiceCacheState(
      rebuilding: true,
      resetAt: Date(timeIntervalSince1970: 1_786_300_000)
    )
  )
  let model = MenuBarViewModel(client: StubLocalService(state: rebuilding))
  await model.refreshIfNeeded()
  #expect(model.showsCacheRebuildNotice)
  #expect(model.cache.resetAt == Date(timeIntervalSince1970: 1_786_300_000))
}

@Test @MainActor
func successfulLoginCancellationDoesNotRestoreStaleLoggingInState() async throws {
  let model = MenuBarViewModel(
    client: StubLocalService(
      state: loggingInState(),
      loginDelayNanoseconds: 30_000_000_000,
      cancelDelayNanoseconds: 50_000_000
    )
  )
  await model.refreshIfNeeded()

  model.startLogin()
  model.cancelLogin()
  #expect(!model.isLoggingIn)
  try await Task.sleep(nanoseconds: 60_000_000)
  #expect(!model.isLoggingIn)
}

@Test @MainActor
func accountActionErrorSurvivesAStateWithoutAServiceError() async throws {
  let model = MenuBarViewModel(
    client: StubLocalService(
      state: loggingInState(),
      loginDelayNanoseconds: 30_000_000_000,
      cancelFails: true
    )
  )
  await model.refreshIfNeeded()

  model.startLogin()
  model.cancelLogin()
  await settle { model.accountErrorMessage != nil }

  #expect(model.accountErrorMessage == "QuotaBar's local service is unavailable.")
}

/// Waits for something the model reaches on its own. A fixed sleep asserts how fast the machine
/// is as much as what the code does; this asserts only the latter.
@MainActor
private func settle(
  within timeout: Duration = .seconds(5),
  until condition: () -> Bool
) async {
  let deadline = ContinuousClock.now + timeout
  while !condition(), ContinuousClock.now < deadline {
    try? await Task.sleep(for: .milliseconds(5))
  }
}

@Test @MainActor
func anotherDeviceReadingDoesNotHideThisMacsOwnCollectionFailure() async throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let snapshot = QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(
      fingerprint: "account_test",
      label: nil,
      plan: "Plus",
      fingerprintScope: .global
    ),
    windows: [QuotaWindow(id: "monthly", title: "Monthly", usedPercent: 0)],
    status: .available,
    observedAt: now
  )
  let source = LocalServiceOverviewSource(
    sourceID: "device:other",
    kind: .device,
    deviceID: "other",
    displayName: "Kyle's MacBook Air",
    observedAt: now,
    isStale: false
  )
  func state(sources: [QuotaCollectionSource]) -> LocalServiceState {
    LocalServiceState(
      ipcVersion: 1,
      revision: 3,
      usageUploadEnabled: true,
      usagePeriods: emptyUsagePeriods(),
      quota: component(
        value: QuotaCollectionReport(
          capturedAt: now,
          results: [
            QuotaCollectionResult(
              provider: .codex,
              outcome: .unavailable,
              snapshots: [],
              source: nil,
              message: nil,
              sources: sources,
              accessDenied: nil
            )
          ]
        ),
        updatedAt: now
      ),
      usage: component(value: unavailableUsage(now: now), updatedAt: now),
      account: emptyComponent(),
      pricing: emptyComponent(),
      providers: [],
      providerBrowserSessions: [],
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
          isStale: false
        )
      ],
      cache: .settled
    )
  }

  func codexRow(sources: [QuotaCollectionSource]) async -> ProviderQuotaPresentation? {
    let model = MenuBarViewModel(client: StubLocalService(state: state(sources: sources)))
    await model.refreshIfNeeded()
    guard case .content(let providers, _) = model.overviewState(enabledProviders: [.codex]) else {
      Issue.record("Expected quota content")
      return nil
    }
    return providers.first
  }

  // This Mac holds a Codex sign-in and could not read it. The MacBook Air's reading fills
  // the row; it does not mean anything about this Mac.  The status names the rung that
  // failed, so the reader knows which of Codex's readings to go fix.
  let tried = await codexRow(sources: [
    QuotaCollectionSource(
      sourceID: "chatgpt_usage_api", outcome: .unavailable, category: .unavailable)
  ])
  #expect(tried?.accounts.count == 1)
  #expect(tried?.status?.kind == .unavailable)
  #expect(tried?.status?.title == "OAuth · Unavailable")

  // A Mac that never had Codex has nothing to recover, so the account keeps the row quiet.
  let neverConfigured = await codexRow(sources: [])
  #expect(neverConfigured?.accounts.count == 1)
  #expect(neverConfigured?.status == nil)
}

@Test @MainActor
func bottomBarTodayLineFollowsTheSourceTheUsagePageWouldActuallyShow() async throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let state = LocalServiceState(
    ipcVersion: 1,
    revision: 2,
    usageUploadEnabled: true,
    usagePeriods: LocalServiceUsagePeriodCache(
      local: todayOnly(tokens: 1_234_567),
      account: todayOnly(tokens: 9_876_543)
    ),
    quota: emptyComponent(),
    usage: emptyComponent(),
    // No account summary, so Account cannot answer and This Mac's numbers are the honest ones.
    account: emptyComponent(),
    pricing: emptyComponent(),
    providers: [],
    providerBrowserSessions: [],
    overview: [],
    cache: .settled
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))

  await model.refreshIfNeeded()

  #expect(model.effectiveUsageSource(.account) == .local)
  #expect(model.todayUsageSummary(source: .account)?.text == "Today · 1.23M tokens")
  #expect(model.todayUsageSummary(source: .local)?.text == "Today · 1.23M tokens")
}

@Test @MainActor
func quittingAsksTheLocalServiceToShutDownBeforeTheAppGoes() async {
  let record = ShutdownRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState(), shutdownRecord: record)
  )
  model.start()

  await model.shutdown()

  let shutdowns = await record.count
  #expect(shutdowns == 1, "the app's termination path sends the service its shutdown")
}

/// The other half of that promise: a quit is a decision the person already made, so a service
/// that never answers costs the deadline and nothing more. The injected value stands in for the
/// two seconds production waits, which the first expectation pins.
@Test @MainActor
func quittingStopsWaitingOnAHelperThatNeverAnswersItsShutdown() async {
  #expect(MenuBarViewModel.shutdownDeadline == .seconds(2))
  let record = ShutdownRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(
      state: loggingInState(),
      shutdownRecord: record,
      shutdownAnswerDelayNanoseconds: 60_000_000_000
    ),
    shutdownDeadline: .milliseconds(120)
  )
  model.start()

  let started = ContinuousClock.now
  await model.shutdown()
  let waited = ContinuousClock.now - started

  #expect(waited < .seconds(2), "the quit waited on a helper that was never going to answer")
  let shutdowns = await record.count
  #expect(shutdowns == 0, "the helper had not answered, and the quit went ahead anyway")
}

private func todayOnly(tokens: Int) -> LocalServiceUsagePeriodValues {
  LocalServiceUsagePeriodValues(
    today: LocalServiceUsageDetail(
      range: UsageDateRange(from: "2026-08-10", to: "2026-08-10"),
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
        agents: []
      ),
      incomplete: false,
      detailsTruncated: false
    ),
    last7Days: nil,
    last30Days: nil,
    all: nil
  )
}

private func loggingInState() -> LocalServiceState {
  LocalServiceState(
    ipcVersion: 1,
    revision: 1,
    usageUploadEnabled: true,
    usagePeriods: emptyUsagePeriods(),
    quota: emptyComponent(),
    usage: emptyComponent(),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(
        authStatus: .loggingIn,
        accountID: nil,
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
    overview: [],
    cache: .settled
  )
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

private func component<Value: Decodable & Sendable>(
  value: Value,
  updatedAt: Date
) -> LocalServiceComponent<Value> {
  LocalServiceComponent(
    status: .ready,
    value: value,
    updatedAt: updatedAt,
    lastError: nil,
    refreshing: false
  )
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

private func unavailableUsage(now: Date) -> LocalUsageReport {
  LocalUsageReport(
    generatedAt: now,
    aggregationTimezone: nil,
    range: UsageDateRange(from: "2026-08-01", to: "2026-08-10"),
    status: .unavailable,
    coverage: []
  )
}

/// Counts the shutdowns a stub was asked for, which is all the app's termination path leaves
/// behind once the service it spoke to is gone.
private actor ShutdownRecord {
  private(set) var count = 0

  func record() {
    count += 1
  }
}

private struct StubLocalService: LocalServiceServing {
  let stateValue: LocalServiceState
  let events: AsyncStream<LocalServiceEvent>
  let loginDelayNanoseconds: UInt64
  let cancelDelayNanoseconds: UInt64
  let cancelFails: Bool
  let shutdownRecord: ShutdownRecord?
  let shutdownAnswerDelayNanoseconds: UInt64

  init(
    state: LocalServiceState,
    loginDelayNanoseconds: UInt64 = 0,
    cancelDelayNanoseconds: UInt64 = 0,
    cancelFails: Bool = false,
    shutdownRecord: ShutdownRecord? = nil,
    shutdownAnswerDelayNanoseconds: UInt64 = 0
  ) {
    stateValue = state
    events = AsyncStream { $0.finish() }
    self.loginDelayNanoseconds = loginDelayNanoseconds
    self.cancelDelayNanoseconds = cancelDelayNanoseconds
    self.cancelFails = cancelFails
    self.shutdownRecord = shutdownRecord
    self.shutdownAnswerDelayNanoseconds = shutdownAnswerDelayNanoseconds
  }

  func state() async throws -> LocalServiceState { stateValue }

  func diagnose() async throws -> LocalServiceDiagnosticReport {
    let date = Date()
    return LocalServiceDiagnosticReport(
      generatedAt: date,
      client: LocalServiceDiagnosticClient(name: "test", version: "1"),
      summary: LocalServiceDiagnosticSummary(operation: .healthy, attention: .none),
      surfaces: [
        LocalServiceDiagnosticSurface(
          id: "quota_overview", status: .ok, data: .empty, lastSuccessAt: nil,
          message: "No quota has been read yet.", recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "usage_this_device", status: .ok, data: .empty, lastSuccessAt: nil,
          message: "No Usage records have been found on this Mac yet.", recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "usage_account", status: .inactive, data: .empty, lastSuccessAt: nil,
          message: "Sign in to send Usage to your account.", recovery: .none),
        LocalServiceDiagnosticSurface(
          id: "account", status: .inactive, data: .empty, lastSuccessAt: nil,
          message: "This Mac is not signed in to a Quota account.", recovery: .none),
      ]
    )
  }
  func resetCache() async throws {}
  func refresh() async throws -> LocalServiceRefreshResult {
    LocalServiceRefreshResult(accepted: true, pending: false, revision: stateValue.revision)
  }
  func login() async throws -> LocalServiceLoginResult {
    if loginDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: loginDelayNanoseconds)
    }
    return LocalServiceLoginResult(
      status: .loggingIn,
      accountID: nil,
      deviceID: nil,
      deviceGeneration: nil
    )
  }
  func cancelLogin() async throws {
    if cancelDelayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: cancelDelayNanoseconds)
    }
    if cancelFails {
      throw LocalServiceClientError.connectionClosed
    }
  }
  func logout() async throws -> LocalServiceLogoutResult {
    LocalServiceLogoutResult(status: .signedOut)
  }
  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting {
    LocalServiceUsageUploadSetting(enabled: enabled)
  }

  func setProviderConfig(
    _ provider: ProviderID,
    apiKey: String,
    baseURL: String?
  ) async throws -> LocalServiceProviderConfig {
    LocalServiceProviderConfig(
      provider: provider,
      configured: true,
      maskedAPIKey: "API ···test",
      baseURL: baseURL
    )
  }
  func removeProviderConfig(_ provider: ProviderID) async throws -> LocalServiceProviderConfig {
    LocalServiceProviderConfig(
      provider: provider,
      configured: false,
      maskedAPIKey: nil,
      baseURL: nil
    )
  }

  func validateProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSessionCandidate {
    throw LocalServiceClientError.serviceMissing
  }

  func commitProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSession {
    throw LocalServiceClientError.serviceMissing
  }

  func reportProviderBrowserAccessDenied(
    _ provider: ProviderID, browserName: String, reason: BrowserAccessDenialReason
  ) async throws -> LocalServiceProviderBrowserSession {
    throw LocalServiceClientError.serviceMissing
  }

  func removeProviderBrowserSession(
    _ provider: ProviderID
  ) async throws -> LocalServiceProviderBrowserSession {
    throw LocalServiceClientError.serviceMissing
  }
  func shutdown() async {
    if shutdownAnswerDelayNanoseconds > 0 {
      try? await Task.sleep(nanoseconds: shutdownAnswerDelayNanoseconds)
    }
    await shutdownRecord?.record()
  }
}
