import Foundation
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
    source: "test",
    status: .available,
    observedAt: now,
    validUntil: now.addingTimeInterval(300)
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
        message: nil
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
    ]
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
    overview: []
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
    coverage: [],
    coverageTruncated: nil
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
    LocalServiceDiagnosticReport(
      schemaVersion: 1,
      status: .healthy,
      generatedAt: Date(timeIntervalSince1970: 0),
      client: LocalServiceDiagnosticClient(name: "test", version: "1"),
      components: ["providers", "quota", "usage", "pricing", "account", "sync"].map {
        LocalServiceDiagnosticComponent(name: $0, status: .ready, message: nil, metrics: [:])
      },
      issues: []
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
  func shutdown() async {}
}
