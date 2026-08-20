import Foundation
import SweetCookieKit
import Testing

@testable import QuotaBar

@Test @MainActor
func unsupportedDefaultBrowserRequestsAChoiceBeforeOpening() async throws {
  let service = FlowService(state: flowState())
  let router = FlowRouter(
    defaultApplication: URL(filePath: "/System/Applications/TextEdit.app"),
    applications: [URL(filePath: "/Applications/Safari.app")]
  )
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(),
    browserApplicationRouter: router
  )
  model.startProviderBrowserSessionLogin(.cursor)
  guard case .browser(let provider, let choices) = model.browserSessionPopup else {
    Issue.record("Expected browser picker")
    return
  }
  #expect(provider == .cursor)
  #expect(!choices.isEmpty)
  #expect(router.openCount == 0)
}

@Test @MainActor
func multipleCookieHeadersRequireAccountSelection() async throws {
  let first = BrowserSessionCookieCandidate(
    cookieHeader: "sso=one",
    headerFingerprint: "header-a",
    browserName: "Chrome",
    profileName: "Personal"
  )
  let second = BrowserSessionCookieCandidate(
    cookieHeader: "sso=two",
    headerFingerprint: "header-b",
    browserName: "Chrome",
    profileName: "Work"
  )
  let safari = URL(filePath: "/Applications/Safari.app")
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(candidates: [first, second]),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  model.startProviderBrowserSessionLogin(.grok)
  try await waitUntil {
    if case .account(_, let choices) = model.browserSessionPopup {
      return choices.count == 2
    }
    return false
  }
  #expect(await service.commits == 0)
}

@Test @MainActor
func addCommitsOneUnambiguousAccount() async throws {
  let candidate = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=new",
    headerFingerprint: "header",
    browserName: "Safari",
    profileName: "Personal"
  )
  let safari = URL(filePath: "/Applications/Safari.app")

  let addService = FlowService(state: flowState())
  let add = MenuBarViewModel(
    client: addService,
    browserSessionImporter: FlowImporter(candidates: [candidate]),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  add.startProviderBrowserSessionLogin(.cursor)
  try await waitUntil { await addService.commits == 1 }
}

@Test @MainActor
func cancelBeforeCandidateAndFailedOpenNeverCommit() async throws {
  let safari = URL(filePath: "/Applications/Safari.app")
  let candidate = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=new",
    headerFingerprint: "header",
    browserName: "Safari",
    profileName: "Personal"
  )
  let cancelledService = FlowService(state: flowState())
  let cancelled = MenuBarViewModel(
    client: cancelledService,
    browserSessionImporter: FlowImporter(candidates: [candidate], delay: .seconds(1)),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  cancelled.startProviderBrowserSessionLogin(.cursor)
  cancelled.cancelProviderBrowserSessionFlow()
  try await Task.sleep(for: .milliseconds(50))
  #expect(await cancelledService.commits == 0)

  let failedService = FlowService(state: flowState())
  let importer = FlowImporter(candidates: [candidate])
  let failed = MenuBarViewModel(
    client: failedService,
    browserSessionImporter: importer,
    browserApplicationRouter: FlowRouter(defaultApplication: safari, openResult: false)
  )
  failed.startProviderBrowserSessionLogin(.cursor)
  try await waitUntil { failed.browserSessionErrorMessages[.cursor] != nil }
  #expect(await failedService.commits == 0)
  #expect(await importer.calls == 0)
}

private func waitUntil(
  _ condition: @escaping @MainActor () async -> Bool
) async throws {
  for _ in 0..<100 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for state")
}

private actor FlowImporter: BrowserSessionImporting {
  let values: [BrowserSessionCookieCandidate]
  let delay: Duration
  private(set) var calls = 0

  init(candidates: [BrowserSessionCookieCandidate] = [], delay: Duration = .zero) {
    values = candidates
    self.delay = delay
  }

  func candidates(
    spec: BrowserSessionSpec,
    browser: SweetCookieKit.Browser,
    now: Date,
    deadline: Date
  ) async -> [BrowserSessionCookieCandidate] {
    calls += 1
    if delay > .zero { try? await Task.sleep(for: delay) }
    return Task.isCancelled ? [] : values
  }
}

@MainActor
private final class FlowRouter: BrowserApplicationRouting {
  let defaultApplication: URL?
  let applicationValues: [URL]
  let openResult: Bool
  private(set) var openCount = 0

  init(defaultApplication: URL?, applications: [URL] = [], openResult: Bool = true) {
    self.defaultApplication = defaultApplication
    applicationValues = applications
    self.openResult = openResult
  }

  func defaultApplication(for url: URL) -> URL? { defaultApplication }
  func applications(for url: URL) -> [URL] { applicationValues }
  func open(_ url: URL, with applicationURL: URL) async -> Bool {
    openCount += 1
    return openResult
  }
}

private actor FlowService: LocalServiceServing {
  nonisolated let events: AsyncStream<LocalServiceEvent> = AsyncStream { $0.finish() }
  let stateValue: LocalServiceState
  private(set) var commits = 0

  init(state: LocalServiceState) { stateValue = state }
  func state() async throws -> LocalServiceState { stateValue }
  func diagnose() async throws -> LocalServiceDiagnosticReport { throw LocalServiceClientError.serviceMissing }
  func refresh() async throws -> LocalServiceRefreshResult { throw LocalServiceClientError.serviceMissing }
  func login() async throws -> LocalServiceLoginResult { throw LocalServiceClientError.serviceMissing }
  func cancelLogin() async throws {}
  func logout() async throws -> LocalServiceLogoutResult { throw LocalServiceClientError.serviceMissing }
  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting { throw LocalServiceClientError.serviceMissing }
  func setProviderConfig(_ provider: ProviderID, apiKey: String, baseURL: String?) async throws -> LocalServiceProviderConfig { throw LocalServiceClientError.serviceMissing }
  func removeProviderConfig(_ provider: ProviderID) async throws -> LocalServiceProviderConfig { throw LocalServiceClientError.serviceMissing }
  func validateProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSessionCandidate {
    LocalServiceProviderBrowserSessionCandidate(
      provider: provider,
      accountFingerprint: String(repeating: "b", count: 64),
      accountLabel: "ad***@example.com"
    )
  }
  func commitProviderBrowserSession(
    _ provider: ProviderID, cookieHeader: String
  ) async throws -> LocalServiceProviderBrowserSession {
    commits += 1
    return LocalServiceProviderBrowserSession(
      provider: provider,
      configured: true,
      accountFingerprint: String(repeating: "b", count: 64),
      accountLabel: "ad***@example.com"
    )
  }
  func removeProviderBrowserSession(_ provider: ProviderID) async throws -> LocalServiceProviderBrowserSession { throw LocalServiceClientError.serviceMissing }
  func shutdown() async {}
}

private func flowState() -> LocalServiceState {
  let emptyPeriods = LocalServiceUsagePeriodValues(today: nil, last7Days: nil, last30Days: nil, all: nil)
  func empty<Value: Decodable & Sendable>() -> LocalServiceComponent<Value> {
    LocalServiceComponent(status: .unavailable, value: nil, updatedAt: nil, lastError: nil, refreshing: false)
  }
  return LocalServiceState(
    ipcVersion: 1,
    revision: 1,
    usageUploadEnabled: true,
    usagePeriods: LocalServiceUsagePeriodCache(local: emptyPeriods, account: emptyPeriods),
    quota: empty(),
    usage: empty(),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(authStatus: .signedOut, accountID: nil, deviceID: nil, deviceGeneration: nil, accountSummary: nil),
      updatedAt: nil, lastError: nil, refreshing: false),
    pricing: empty(),
    providers: [],
    providerBrowserSessions: [],
    overview: [],
    repair: .idle
  )
}
