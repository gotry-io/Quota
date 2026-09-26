import Foundation
import QuotaAlerts
import QuotaWire
import Testing

@testable import QuotaBar

/// A service whose state answers are scripted in order and whose event stream is the test's to
/// feed, so the panel can be watched with and without the event that normally follows a change.
final class ScriptedLocalService: LocalServiceServing, @unchecked Sendable {
  private let lock = NSLock()
  private var queue: [LocalServiceState]
  /// A state the service holds back until the test lets it through.
  private var held: LocalServiceState?
  private(set) var stateCalls = 0
  let events: AsyncStream<LocalServiceEvent>
  private let base: StubLocalService

  init(states: [LocalServiceState], holding held: LocalServiceState? = nil) {
    queue = states
    self.held = held
    events = AsyncStream { $0.finish() }
    base = StubLocalService(state: states[0])
  }

  /// Lets the held state through: every answer from now on is it.
  func release() {
    lock.withLock {
      if let held { queue = [held] }
      held = nil
    }
  }

  private func next() -> LocalServiceState {
    lock.withLock {
      stateCalls += 1
      if queue.count > 1 { return queue.removeFirst() }
      return queue[0]
    }
  }

  func state() async throws -> LocalServiceState { next() }
  func usagePeriod(
    from: String, to: String, source: UsageSource, timezone: String
  ) async throws -> LocalServiceUsageDetail {
    try await base.usagePeriod(from: from, to: to, source: source, timezone: timezone)
  }
  func quotaHistory(
    source: QuotaHistoryRequestSource,
    provider: String?,
    fingerprint: String?,
    since: Date
  ) async throws -> LocalServiceQuotaHistory {
    try await base.quotaHistory(
      source: source, provider: provider, fingerprint: fingerprint, since: since)
  }
  func diagnose() async throws -> LocalServiceDiagnosticReport { try await base.diagnose() }
  func recheckDiagnostics() async throws -> LocalServiceRefreshResult {
    try await base.recheckDiagnostics()
  }
  func resetCache() async throws {}
  func refresh() async throws -> LocalServiceRefreshResult { try await base.refresh() }
  func login() async throws -> LocalServiceLoginResult { try await base.login() }
  func cancelLogin() async throws {}
  func logout() async throws -> LocalServiceLogoutResult { try await base.logout() }
  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting {
    try await base.setUsageUpload(enabled: enabled)
  }
  func setGroupUsageByProject(enabled: Bool) async throws
    -> LocalServiceGroupUsageByProjectSetting
  {
    try await base.setGroupUsageByProject(enabled: enabled)
  }
  func setQuotaRefresh(_ choice: QuotaRefreshChoice) async throws
    -> LocalServiceQuotaRefreshIntervalSetting
  {
    try await base.setQuotaRefresh(choice)
  }
  func setOverviewSourcePin(
    provider: ProviderID, fingerprint: String, scope: String, identitySourceID: String?,
    pin: String?
  ) async throws -> LocalServiceOverviewSourcePinSetting {
    try await base.setOverviewSourcePin(
      provider: provider, fingerprint: fingerprint, scope: scope,
      identitySourceID: identitySourceID, pin: pin)
  }
  func setProviderConfig(_ provider: ProviderID, apiKey: String, baseURL: String?) async throws
    -> LocalServiceProviderConfig
  {
    try await base.setProviderConfig(provider, apiKey: apiKey, baseURL: baseURL)
  }
  func removeProviderConfig(_ provider: ProviderID) async throws -> LocalServiceProviderConfig {
    try await base.removeProviderConfig(provider)
  }
  func validateProviderBrowserSession(_ provider: ProviderID, cookieHeader: String) async throws
    -> LocalServiceProviderBrowserSessionCandidate
  {
    try await base.validateProviderBrowserSession(provider, cookieHeader: cookieHeader)
  }
  func setProviderBrowserScan(_ provider: ProviderID, enabled: Bool) async throws
    -> LocalServiceProviderBrowserScanSetting
  {
    try await base.setProviderBrowserScan(provider, enabled: enabled)
  }
  func replaceProviderBrowserSessions(
    _ provider: ProviderID, cookieHeaders: [String], accessDenials: [BrowserAccessDenial]
  ) async throws {}
  func setAccountSettings(document: AccountSettingsDocument, ifMatch: String) async throws
    -> LocalServiceAccountSettingsWriteResult
  {
    try await base.setAccountSettings(document: document, ifMatch: ifMatch)
  }
  func refreshAccountSettings() async throws -> LocalServiceAccountSettingsState {
    try await base.refreshAccountSettings()
  }
  func shutdown() async {}
}

/// Waits for `condition`, checking often, for at most `timeout`.
@MainActor
private func eventually(
  _ timeout: Duration = .seconds(3),
  _ condition: @MainActor () -> Bool
) async throws -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// Events are the fast path; the panel still re-reads state on its own so nothing it shows can
/// stay behind the service for longer than one interval.
@Test @MainActor
func thePanelReReadsStateOnItsOwnCadence() async throws {
  let service = ScriptedLocalService(
    states: [signedOutWithSessionEndedState()],
    holding: justSignedInState(label: "kyledh")
  )
  let model = MenuBarViewModel(
    client: service,
    loginPollInterval: .seconds(3600),
    statePollInterval: .milliseconds(60)
  )
  model.start()
  #expect(try await eventually { model.accountFlow.accountState == .signedOut })
  service.release()
  #expect(try await eventually { model.accountFlow.accountState == .signedIn })
  await model.shutdown()
}
