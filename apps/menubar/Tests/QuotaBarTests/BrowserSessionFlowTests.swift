import Foundation
import QuotaWire
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

/// The consent popup is the gate. Declining it must leave every cookie store shut, so the
/// importer is never even asked and no browser is opened.
@Test @MainActor
func decliningConsentNeverReadsACookie() async throws {
  let safari = URL(filePath: "/Applications/Safari.app")
  let service = FlowService(state: flowState())
  let importer = FlowImporter(
    outcome: .found([
      BrowserSessionCookieCandidate(
        cookieHeader: "wos-session=new",
        headerFingerprint: "header",
        browserName: "Safari",
        profileName: "Personal"
      )
    ])
  )
  let router = FlowRouter(defaultApplication: safari)
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer,
    browserApplicationRouter: router
  )
  model.startProviderBrowserSessionLogin(.cursor)
  guard case .consent(let provider, let choice) = model.browserSessionPopup else {
    Issue.record("Expected the consent popup before any read")
    return
  }
  #expect(provider == .cursor)
  #expect(choice.browser == .safari)

  model.cancelProviderBrowserSessionFlow()
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.browserSessionPopup == nil)
  #expect(await importer.calls == 0)
  #expect(router.openCount == 0)
  #expect(await service.commits == 0)
}

/// The consent copy has to say what is about to happen: which browser, which permission macOS
/// will ask for, which cookies on which hosts, where the session is kept, and that it stays here.
@Test
func consentCopyNamesTheBrowserThePermissionAndTheCookies() throws {
  let spec = try #require(ProviderID.cursor.browserSession)
  let safari = BrowserSessionCopy.consentMessage(
    provider: .cursor, browserName: "Safari", spec: spec)
  #expect(safari.contains("Safari"))
  #expect(safari.contains("Full Disk Access"))
  #expect(safari.contains("cursor.com"))
  #expect(safari.contains("WorkosCursorSessionToken"))
  #expect(safari.contains("stored in QuotaBar's local service database"))
  #expect(safari.contains("until you disconnect it"))
  #expect(safari.contains("Nothing about it is uploaded"))

  let chrome = BrowserSessionCopy.consentMessage(
    provider: .cursor, browserName: "Chrome", spec: spec)
  #expect(chrome.contains("Chrome Safe Storage"))
  #expect(!chrome.contains("Full Disk Access"))
  #expect(BrowserSessionCopy.consentTitle(provider: .cursor) == "Read Cursor Cookies?")
}

@Test @MainActor
func multipleCookieHeadersRequireAccountSelection() async throws {
  let first = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=one",
    headerFingerprint: "header-a",
    browserName: "Chrome",
    profileName: "Personal"
  )
  let second = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=two",
    headerFingerprint: "header-b",
    browserName: "Chrome",
    profileName: "Work"
  )
  let safari = URL(filePath: "/Applications/Safari.app")
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(outcome: .found([first, second])),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  model.startProviderBrowserSessionLogin(.cursor)
  model.confirmProviderBrowserSessionConsent()
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
    browserSessionImporter: FlowImporter(outcome: .found([candidate])),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  add.startProviderBrowserSessionLogin(.cursor)
  add.confirmProviderBrowserSessionConsent()
  try await waitUntil { await addService.commits == 1 }
}

/// A refused store is its own answer. It must not read as "no session found", it must not keep
/// polling for two minutes, and the service has to learn about it so Support can say so too.
@Test @MainActor
func aRefusedCookieStoreIsItsOwnStateAndReachesTheService() async throws {
  let safari = URL(filePath: "/Applications/Safari.app")
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(
      outcome: .accessDenied(
        BrowserAccessDenial(browserName: "Safari", reason: .fullDiskAccess))
    ),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  model.startProviderBrowserSessionLogin(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionAccessDenials[.cursor] != nil }

  let denial = try #require(model.browserSessionAccessDenials[.cursor])
  #expect(denial.reason == .fullDiskAccess)
  #expect(denial.browserName == "Safari")
  #expect(
    model.browserSessionErrorMessages[.cursor]
      == """
      QuotaBar could not read Safari's cookies. Grant Full Disk Access in System \
      Settings › Privacy & Security, then try again.
      """
  )
  #expect(model.browserSessionErrorMessages[.cursor]?.contains("No signed-in browser") != true)
  #expect(await service.commits == 0)
  #expect(await service.denials == [DeniedReport(provider: .cursor, browser: "Safari", reason: .fullDiskAccess)])
}

@Test
func eachRefusalNamesADifferentThingToDo() {
  let keychain = BrowserSessionCopy.accessDeniedMessage(
    browserName: "Chrome", reason: .keychainRefused)
  #expect(keychain.contains("Chrome Safe Storage"))
  #expect(!keychain.contains("Full Disk Access"))
  let unreadable = BrowserSessionCopy.accessDeniedMessage(
    browserName: "Firefox", reason: .storeUnreadable)
  #expect(unreadable.contains("could not be opened"))
  #expect(unreadable.contains("Firefox"))
}

/// A store that is not there is not a refusal: that browser has simply never been used.
@Test
func onlyARefusalCountsAsARefusal() {
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.notFound(browser: .safari, details: "/Users/ada/Library"),
      browser: .safari
    ) == nil
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .safari, details: "/Users/ada/Library"),
      browser: .safari
    ) == .fullDiskAccess
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .chrome, details: "keychain"),
      browser: .chrome
    ) == .keychainRefused
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.accessDenied(browser: .firefox, details: "profile"),
      browser: .firefox
    ) == .storeUnreadable
  )
  #expect(
    BrowserSessionImporter.denialReason(
      for: BrowserCookieError.loadFailed(browser: .chrome, details: "sqlite"),
      browser: .chrome
    ) == .storeUnreadable
  )
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
    browserSessionImporter: FlowImporter(outcome: .found([candidate]), delay: .seconds(1)),
    browserApplicationRouter: FlowRouter(defaultApplication: safari)
  )
  cancelled.startProviderBrowserSessionLogin(.cursor)
  cancelled.confirmProviderBrowserSessionConsent()
  cancelled.cancelProviderBrowserSessionFlow()
  try await Task.sleep(for: .milliseconds(50))
  #expect(await cancelledService.commits == 0)

  let failedService = FlowService(state: flowState())
  let importer = FlowImporter(outcome: .found([candidate]))
  let failed = MenuBarViewModel(
    client: failedService,
    browserSessionImporter: importer,
    browserApplicationRouter: FlowRouter(defaultApplication: safari, openResult: false)
  )
  failed.startProviderBrowserSessionLogin(.cursor)
  failed.confirmProviderBrowserSessionConsent()
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
  let value: BrowserSessionReadOutcome
  let delay: Duration
  private(set) var calls = 0

  init(outcome: BrowserSessionReadOutcome = .noSession, delay: Duration = .zero) {
    value = outcome
    self.delay = delay
  }

  func read(
    spec: BrowserSessionSpec,
    browser: SweetCookieKit.Browser,
    now: Date,
    deadline: Date
  ) async -> BrowserSessionReadOutcome {
    calls += 1
    if delay > .zero { try? await Task.sleep(for: delay) }
    return Task.isCancelled ? .noSession : value
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

struct DeniedReport: Equatable, Sendable {
  let provider: ProviderID
  let browser: String
  let reason: BrowserAccessDenialReason
}

private actor FlowService: LocalServiceServing {
  nonisolated let events: AsyncStream<LocalServiceEvent> = AsyncStream { $0.finish() }
  let stateValue: LocalServiceState
  private(set) var commits = 0
  private(set) var denials: [DeniedReport] = []

  init(state: LocalServiceState) { stateValue = state }
  func state() async throws -> LocalServiceState { stateValue }
  func diagnose() async throws -> LocalServiceDiagnosticReport { throw LocalServiceClientError.serviceMissing }
  func resetCache() async throws { throw LocalServiceClientError.serviceMissing }
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
  func reportProviderBrowserAccessDenied(
    _ provider: ProviderID, browserName: String, reason: BrowserAccessDenialReason
  ) async throws -> LocalServiceProviderBrowserSession {
    denials.append(DeniedReport(provider: provider, browser: browserName, reason: reason))
    return LocalServiceProviderBrowserSession(
      provider: provider,
      configured: false,
      accountFingerprint: nil,
      accountLabel: nil
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
    cache: .settled
  )
}
