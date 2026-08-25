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
    protocolVersion: 2,
    capturedAt: now,
    results: [
      QuotaCollectionResult(
        provider: .codex,
        outcome: .success,
        snapshots: [snapshot],
        source: "test",
        message: nil,
        sources: 1,
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
    repair: .idle
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))

  await model.refreshIfNeeded()

  guard case .content(let providers, let warning) = model.overviewState(enabledProviders: [.codex])
  else {
    Issue.record("Expected service-provided quota content")
    return
  }
  #expect(warning == nil)
  #expect(providers.first?.accounts.first?.sourceSummary == "Local")
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
    repair: .idle
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))
  await model.refreshIfNeeded()
  #expect(model.usageDetail(source: .local, period: .today) == nil)
  #expect(model.isPreparingUsage(source: .local))
  #expect(!model.isPreparingUsage(source: .account))
}

@Test @MainActor
func idleRepairStaysOnOverviewAndDurableRepairBlocksQuit() async throws {
  let idle = MenuBarViewModel(client: StubLocalService(state: loggingInState()))
  await idle.refreshIfNeeded()
  #expect(idle.repairPresentation == .overview)
  #expect(!idle.showsFullRepairPage)
  #expect(!idle.repairBlocksQuit)

  var repairing = loggingInState()
  repairing = LocalServiceState(
    ipcVersion: repairing.ipcVersion,
    revision: repairing.revision,
    usageUploadEnabled: repairing.usageUploadEnabled,
    usagePeriods: repairing.usagePeriods,
    quota: repairing.quota,
    usage: repairing.usage,
    account: repairing.account,
    pricing: repairing.pricing,
    providers: repairing.providers,
    providerBrowserSessions: repairing.providerBrowserSessions,
    overview: repairing.overview,
    repair: LocalServiceRepairSession(
      status: .repairing,
      severity: .durable,
      phase: .preservingAccount,
      title: "Repairing local data",
      guidance: "Keep QuotaBar open. You can close this menu.",
      activity: "Copying account",
      startedAt: Date(timeIntervalSince1970: 1_786_300_000),
      heartbeatAt: Date(timeIntervalSince1970: 1_786_300_014),
      progressCurrent: 1,
      progressTotal: 7,
      stuck: false,
      blocksQuit: true,
      recoveryAction: nil
    )
  )
  let model = MenuBarViewModel(client: StubLocalService(state: repairing))
  await model.refreshIfNeeded()
  #expect(model.repairPresentation == .fullPage)
  #expect(model.showsFullRepairPage)
  #expect(model.repairBlocksQuit)
  #expect(model.repairHeaderTitle == "Repairing")
  model.presentRepairPageFromQuitAttempt()
  #expect(model.showsFullRepairPage)
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
  try await Task.sleep(nanoseconds: 20_000_000)

  #expect(model.accountErrorMessage == "QuotaBar's local service is unavailable.")
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
  func state(sources: Int) -> LocalServiceState {
    LocalServiceState(
      ipcVersion: 1,
      revision: 3,
      usageUploadEnabled: true,
      usagePeriods: emptyUsagePeriods(),
      quota: component(
        value: QuotaCollectionReport(
          protocolVersion: 2,
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
      repair: .idle
    )
  }

  func codexRow(sources: Int) async -> ProviderQuotaPresentation? {
    let model = MenuBarViewModel(client: StubLocalService(state: state(sources: sources)))
    await model.refreshIfNeeded()
    guard case .content(let providers, _) = model.overviewState(enabledProviders: [.codex]) else {
      Issue.record("Expected quota content")
      return nil
    }
    return providers.first
  }

  // This Mac holds a Codex sign-in and could not read it. The MacBook Air's reading fills
  // the row; it does not mean anything about this Mac.
  let tried = await codexRow(sources: 1)
  #expect(tried?.accounts.count == 1)
  #expect(tried?.status?.kind == .unavailable)

  // A Mac that never had Codex has nothing to recover, so the account keeps the row quiet.
  let neverConfigured = await codexRow(sources: 0)
  #expect(neverConfigured?.accounts.count == 1)
  #expect(neverConfigured?.status == nil)
}

@Test @MainActor
func overviewTodayLineFollowsTheSourceTheUsagePageWouldActuallyShow() async throws {
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
    repair: .idle
  )
  let model = MenuBarViewModel(client: StubLocalService(state: state))

  await model.refreshIfNeeded()

  #expect(model.effectiveUsageSource(.account) == .local)
  #expect(model.todayUsageSummary(source: .account)?.text == "Today · 1.23M tokens")
  #expect(model.todayUsageSummary(source: .local)?.text == "Today · 1.23M tokens")
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
    repair: .idle
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

private struct StubLocalService: LocalServiceServing {
  let stateValue: LocalServiceState
  let events: AsyncStream<LocalServiceEvent>
  let loginDelayNanoseconds: UInt64
  let cancelDelayNanoseconds: UInt64
  let cancelFails: Bool

  init(
    state: LocalServiceState,
    loginDelayNanoseconds: UInt64 = 0,
    cancelDelayNanoseconds: UInt64 = 0,
    cancelFails: Bool = false
  ) {
    stateValue = state
    events = AsyncStream { $0.finish() }
    self.loginDelayNanoseconds = loginDelayNanoseconds
    self.cancelDelayNanoseconds = cancelDelayNanoseconds
    self.cancelFails = cancelFails
  }

  func state() async throws -> LocalServiceState { stateValue }

  func diagnose() async throws -> LocalServiceDiagnosticReport {
    let date = Date()
    return LocalServiceDiagnosticReport(
      schemaVersion: 2,
      summary: LocalServiceDiagnosticSummary(
        operation: .healthy, data: .empty, attention: .none),
      refresh: LocalServiceDiagnosticRefresh(
        phase: .idle, asOf: date, startedAt: nil, nextDueAt: nil),
      generatedAt: date,
      client: LocalServiceDiagnosticClient(name: "test", version: "1"),
      surfaces: [
        LocalServiceDiagnosticSurface(
          name: "quota_overview", operation: .healthy, data: .empty, source: nil, metrics: [:]),
        LocalServiceDiagnosticSurface(
          name: "usage_this_device", operation: .healthy, data: .empty,
          source: .thisDevice, metrics: [:]),
        LocalServiceDiagnosticSurface(
          name: "usage_account", operation: .healthy, data: .empty, source: .account, metrics: [:]),
        LocalServiceDiagnosticSurface(
          name: "account", operation: .healthy, data: .empty, source: .account, metrics: [:]),
      ],
      checks: [],
      findings: []
    )
  }
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

  func removeProviderBrowserSession(
    _ provider: ProviderID
  ) async throws -> LocalServiceProviderBrowserSession {
    throw LocalServiceClientError.serviceMissing
  }
  func shutdown() async {}
}
