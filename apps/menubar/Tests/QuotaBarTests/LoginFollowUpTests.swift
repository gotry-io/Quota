import Foundation
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
  func usagePeriod(from: String, to: String) async throws -> LocalServiceUsageDetail {
    try await base.usagePeriod(from: from, to: to)
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
  func setQuotaRefreshInterval(seconds: Int) async throws
    -> LocalServiceQuotaRefreshIntervalSetting
  {
    try await base.setQuotaRefreshInterval(seconds: seconds)
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

/// A sign-in finishes on the service's thread and is announced by an event. When that event does
/// not arrive, the panel still stops saying "finish sign-in in browser": it asks.
@Test @MainActor
func aSignInThatFinishedWithoutAnEventIsNoticedByThePoll() async throws {
  let service = ScriptedLocalService(
    states: [signedOutWithSessionEndedState(), loggingInState()],
    holding: justSignedInState(label: "kyledh")
  )
  let model = MenuBarViewModel(
    client: service,
    loginPollInterval: .milliseconds(50),
    statePollInterval: .seconds(3600)
  )
  model.start()
  #expect(try await eventually { model.accountState == .signedOut })

  model.startLogin()
  #expect(try await eventually { model.isLoggingIn })
  try await Task.sleep(for: .milliseconds(150))
  #expect(model.isLoggingIn, "the service still answers logging_in and no event has followed")

  service.release()
  #expect(try await eventually { model.accountState == .signedIn && !model.isLoggingIn })
  try await Task.sleep(for: .milliseconds(100))
  let calls = service.stateCalls
  try await Task.sleep(for: .milliseconds(200))
  #expect(service.stateCalls == calls, "a finished sign-in is not followed any further")
  await model.shutdown()
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
  #expect(try await eventually { model.accountState == .signedOut })
  service.release()
  #expect(try await eventually { model.accountState == .signedIn })
  await model.shutdown()
}

/// Cancelling the sign-in also stops following it.
@Test @MainActor
func cancellingASignInStopsThePoll() async throws {
  let service = ScriptedLocalService(states: [
    signedOutWithSessionEndedState(),
    loggingInState(),
  ])
  let model = MenuBarViewModel(
    client: service,
    loginPollInterval: .milliseconds(40),
    statePollInterval: .seconds(3600)
  )
  model.start()
  #expect(try await eventually { model.accountState == .signedOut })
  model.startLogin()
  #expect(try await eventually { model.isLoggingIn })
  model.cancelLogin()
  // A poll iteration already on the main actor's queue when Cancel landed still runs once, and
  // on a loaded runner it can land later than any fixed offset. Wait for the count to hold
  // still across a whole window instead of sampling it at one.
  let deadline = ContinuousClock.now + .seconds(3)
  var calls = service.stateCalls
  var settled = false
  while !settled, ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(200))
    settled = service.stateCalls == calls
    calls = service.stateCalls
  }
  #expect(settled, "state() is still being polled after Cancel")
  await model.shutdown()
}
