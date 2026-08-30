import Foundation
import QuotaWire
import SweetCookieKit
import Testing

@testable import QuotaBar

@Test @MainActor
func enablingScanAsksForConsentBeforeReading() async throws {
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter()
  )
  model.requestEnableBrowserScan(.cursor)
  guard case .consent(let provider) = model.browserSessionPopup else {
    Issue.record("Expected the consent popup")
    return
  }
  #expect(provider == .cursor)
  #expect(await service.scanSets.isEmpty)
}

/// The consent popup is the gate. Declining it must leave every cookie store shut, so the
/// importer is never even asked and no browser is opened.
@Test @MainActor
func decliningConsentNeverReadsACookie() async throws {
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
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer
  )
  model.requestEnableBrowserScan(.cursor)
  guard case .consent(let provider) = model.browserSessionPopup else {
    Issue.record("Expected the consent popup before any read")
    return
  }
  #expect(provider == .cursor)

  model.cancelProviderBrowserSessionFlow()
  try await Task.sleep(for: .milliseconds(50))
  #expect(model.browserSessionPopup == nil)
  #expect(await importer.calls == 0)
  #expect(await service.replaces.isEmpty)
}

/// The consent copy has to say what is about to happen: which cookies on which hosts, where
/// the session is kept, and that it stays here — and nothing that belongs to a browser.
@Test
func consentCopyNamesTheBrowserThePermissionAndTheCookies() throws {
  let spec = try #require(ProviderID.cursor.browserSession)
  let message = BrowserSessionCopy.scanConsentMessage(provider: .cursor, spec: spec)
  #expect(message.contains("Cursor"))
  #expect(message.contains("cursor.com"))
  #expect(message.contains("WorkosCursorSessionToken"))
  #expect(message.contains("local service database"))
  #expect(message.contains("until you turn this off"))
  #expect(message.contains("never uploaded"))
  // Which permission each browser needs is the Browser Access window's sentence, not this one's.
  #expect(!message.contains("Full Disk Access"))
  #expect(!message.contains("Chrome Safe Storage"))
  #expect(message.count < 360)
  #expect(BrowserSessionCopy.consentTitle(provider: .cursor) == "Read Cursor Cookies?")
}

/// The permission a browser will ask for is a fact about the browser, not about the name on the
/// button, so the importer's classification is the one both the sheet and the refusal answer to.
@Test
func theConsentSheetNamesTheGatekeeperTheImporterFound() {
  #expect(BrowserSessionImporter.family(of: .safari) == .safari)
  #expect(BrowserSessionImporter.family(of: .chrome) == .chromium)
  #expect(BrowserSessionImporter.family(of: .arc) == .chromium)
  #expect(BrowserSessionImporter.family(of: .firefoxDeveloperEdition) == .gecko)
  #expect(BrowserSessionImporter.family(of: .zen) == .gecko)
}

/// The sheet cannot promise a narrower read than the one that happens, so for every provider
/// that declares a session it names that provider, every host it will open, and every cookie
/// name it will take.
@Test
func consentCopyNamesEveryHostAndCookieTheCatalogDeclares() throws {
  for provider in ProviderID.allCases {
    guard let spec = provider.browserSession else { continue }
    let message = BrowserSessionCopy.scanConsentMessage(provider: provider, spec: spec)
    for host in spec.cookieHosts {
      #expect(message.contains(host), "\(provider.rawValue) consent omits \(host)")
    }
    for name in spec.cookieNames {
      #expect(message.contains(name), "\(provider.rawValue) consent omits \(name)")
    }
    #expect(message.contains("local service database"))
    #expect(message.contains("never uploaded"))
    #expect(
      BrowserSessionCopy.consentTitle(provider: provider)
        == "Read \(provider.displayName) Cookies?")
  }
}

@Test @MainActor
func confirmingConsentWithMissingSafariAccessStillScansOtherBrowsers() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.safari, .chrome, .firefox],
    fullDiskAccess: false,
    keychain: [.chrome: .allowed]
  )
  let importer = FlowImporter(outcomes: [
    .safari: .accessDenied(BrowserAccessDenial(browserName: "Safari", reason: .fullDiskAccess)),
    .chrome: .found([
      BrowserSessionCookieCandidate(
        cookieHeader: "wos-session=chrome",
        headerFingerprint: "header-chrome",
        browserName: "Chrome",
        profileName: "Personal"
      )
    ]),
    .firefox: .noSession,
  ])
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer,
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let replace = try #require(await service.replaces.first)
  #expect(replace.headers == ["wos-session=chrome"])
  let browsers = await importer.browsers
  #expect(!browsers.contains(.safari))
  #expect(browsers.contains(.chrome))
  #expect(browsers.contains(.firefox))
  #expect(presenter.presented.first?.needs == [
    BrowserAccessNeed(browser: .safari, kind: .fullDiskAccess)
  ])
  // The page can then say where it looked: Chrome and Firefox were read, Safari was not.
  #expect(model.browserScanCoverage[.cursor]?.read == ["Chrome", "Firefox"])
  #expect(model.browserScanCoverage[.cursor]?.skipped == ["Safari"])
  let enabled = await service.scanSets
  #expect(enabled.count == 1)
  #expect(enabled.first?.0 == .cursor)
  #expect(enabled.first?.1 == true)
}

@Test @MainActor
func confirmingConsentDoesNotReadAChromiumJarThatStillNeedsKeychain() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.chrome, .firefox],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let importer = FlowImporter()
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer,
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let browsers = await importer.browsers
  #expect(!browsers.contains(.chrome))
  #expect(browsers.contains(.firefox))
  #expect(presenter.presented.first?.needs == [
    BrowserAccessNeed(browser: .chrome, kind: .keychain)
  ])
}

@Test @MainActor
func dismissingGrantPanelLeavesScanEnabled() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.safari],
    fullDiskAccess: false,
    keychain: [:]
  )
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(),
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { await service.scanSets.isEmpty == false }
  #expect(presenter.isPresented)
  model.browserAccessGrantDidDismiss()
  let enabled = await service.scanSets
  #expect(enabled.count == 1)
  #expect(enabled.first?.0 == .cursor)
  #expect(enabled.first?.1 == true)
  #expect(
    model.browserAccessNeeds == [BrowserAccessNeed(browser: .safari, kind: .fullDiskAccess)])
}

@Test @MainActor
func scheduledScanSkipsAKeychainPrompt() async throws {
  let probe = StubBrowserAccessProbe(
    installed: [.chrome, .firefox],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let importer = FlowImporter()
  let service = FlowService(state: flowState(browserScanEnabled: [.cursor]))
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer,
    accessProbe: probe
  )
  await model.refreshIfNeeded()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let browsers = await importer.browsers
  #expect(!browsers.contains(.chrome))
  #expect(browsers.contains(.firefox))
}

@Test @MainActor
func allowingKeychainReadsThatBrowser() async throws {
  let probe = StubBrowserAccessProbe(
    installed: [.chrome],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let importer = FlowImporter(outcomes: [
    .chrome: .found([
      BrowserSessionCookieCandidate(
        cookieHeader: "wos-session=allowed",
        headerFingerprint: "header-allowed",
        browserName: "Chrome",
        profileName: "Personal"
      )
    ])
  ])
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: importer,
    accessProbe: probe,
    grantPresenter: RecordingGrantPresenter()
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  try await waitUntil { model.browserSessionWaitingProvider == nil }
  #expect(await importer.browsers.contains(.chrome) == false)
  let generation = model.browserSessionScanGeneration
  probe.keychainOnRequest[.chrome] = .allowed
  model.browserAccessGrantDidRequestKeychain(.chrome)
  try await waitUntil { model.browserSessionScanGeneration > generation }
  #expect(probe.keychainRequests == [.chrome])
  #expect(await importer.browsers.contains(.chrome))
  #expect(await service.replaces.last?.headers == ["wos-session=allowed"])
}

@Test @MainActor
func officialCredentialDoesNotSkipTheGrantPanel() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.chrome],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let service = FlowService(state: flowState(officialCursorSuccess: true))
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(),
    accessProbe: probe,
    grantPresenter: presenter
  )
  await model.refreshIfNeeded()
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { presenter.presented.isEmpty == false }
  #expect(await service.replaces.isEmpty)
  #expect(presenter.presented.first?.needs == [
    BrowserAccessNeed(browser: .chrome, kind: .keychain)
  ])
}

@Test @MainActor
func confirmingConsentStoresEveryFoundSession() async throws {
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
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(outcome: .found([first, second]))
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let replace = try #require(await service.replaces.first)
  #expect(replace.provider == .cursor)
  #expect(Set(replace.headers) == ["wos-session=one", "wos-session=two"])
}

/// A refused store is its own answer. It must not read as "no session found", it must not keep
/// polling for two minutes, and the service has to learn about it so Support can say so too.
@Test @MainActor
func aRefusedCookieStoreIsItsOwnStateAndReachesTheService() async throws {
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(
      outcome: .accessDenied(
        BrowserAccessDenial(browserName: "Safari", reason: .fullDiskAccess))
    )
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }

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
  let replace = try #require(await service.replaces.first)
  #expect(replace.headers.isEmpty)
  #expect(replace.denials.contains(DeniedReport(provider: .cursor, browser: "Safari", reason: .fullDiskAccess)))
  #expect(Set(replace.denials.map(\.browser)).count == replace.denials.count)
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
  let candidate = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=new",
    headerFingerprint: "header",
    browserName: "Safari",
    profileName: "Personal"
  )
  let cancelledService = FlowService(state: flowState())
  let cancelled = MenuBarViewModel(
    client: cancelledService,
    browserSessionImporter: FlowImporter(outcome: .found([candidate]), delay: .seconds(1))
  )
  cancelled.requestEnableBrowserScan(.cursor)
  cancelled.cancelProviderBrowserSessionFlow()
  try await Task.sleep(for: .milliseconds(50))
  #expect(await cancelledService.replaces.isEmpty)
  #expect(await cancelledService.scanSets.isEmpty)
}

@Test @MainActor
func automaticScanKeysOnQuotaUpdatedAtNotRevision() async throws {
  let updatedAt = Date(timeIntervalSince1970: 1_785_000_000)
  let importer = FlowImporter()
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: importer
  )
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: updatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let firstCalls = await importer.calls
  #expect(firstCalls > 0)
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: updatedAt
    ))
  try await Task.sleep(for: .milliseconds(80))
  #expect(await importer.calls == firstCalls)
}

@Test @MainActor
func successfulCollectionDoesNotRescanWhenASourceWasAuthRequired() async throws {
  let importer = FlowImporter()
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: importer
  )
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      officialCursorSuccess: true,
      quotaUpdatedAt: Date(),
      cursorSources: [
        QuotaCollectionSource(
          sourceID: "cursor_app_auth", outcome: .authRequired, category: .authRequired),
        QuotaCollectionSource(
          sourceID: "browser_session", outcome: .success, category: .success),
      ],
      providerBrowserSessions: [
        LocalServiceProviderBrowserSession(
          provider: .cursor,
          configured: true,
          accountFingerprint: String(repeating: "a", count: 64),
          accountLabel: "ad***@example.com")
      ]
    ))
  try await Task.sleep(for: .milliseconds(80))
  #expect(await importer.calls == 0)
  #expect(model.browserSessionScanGeneration == 0)
}

@Test @MainActor
func unavailableCollectionDoesNotScanBrowsers() async throws {
  let importer = FlowImporter()
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: importer
  )
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      quotaUpdatedAt: Date(),
      quotaFailure: .unavailable
    ))
  try await Task.sleep(for: .milliseconds(80))
  #expect(await importer.calls == 0)
  #expect(model.browserSessionScanGeneration == 0)
}

@Test @MainActor
func automaticScanIsRateLimitedAcrossNewCollections() async throws {
  let firstUpdatedAt = Date(timeIntervalSince1970: 1_785_000_000)
  let importer = FlowImporter()
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: importer
  )
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: firstUpdatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let firstCalls = await importer.calls
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: firstUpdatedAt.addingTimeInterval(1)
    ))
  try await Task.sleep(for: .milliseconds(80))
  #expect(await importer.calls == firstCalls)
  #expect(model.browserSessionScanGeneration == 1)
}

@Test @MainActor
func applyingTheSameEnabledSetProbesAccessOnce() async throws {
  let updatedAt = Date(timeIntervalSince1970: 1_785_000_000)
  let probe = StubBrowserAccessProbe(
    installed: [.firefox],
    fullDiskAccess: true,
    keychain: [:]
  )
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: FlowImporter(),
    accessProbe: probe
  )
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: updatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let firstProbes = probe.snapshotCalls
  #expect(firstProbes == 1)
  model.apply(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: updatedAt
    ))
  try await Task.sleep(for: .milliseconds(80))
  #expect(probe.snapshotCalls == firstProbes)
}

/// Full Disk Access reaches a process on its next launch, so after the pane is opened the
/// window offers a relaunch and the Agent row says so — without claiming the grant is in
/// place, which this process cannot know.
@Test @MainActor
func openingFullDiskAccessSettingsOffersRelaunchWithoutClaimingTheGrant() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.safari],
    fullDiskAccess: false,
    keychain: [:]
  )
  let service = FlowService(state: flowState())
  let model = MenuBarViewModel(
    client: service,
    browserSessionImporter: FlowImporter(),
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { presenter.isPresented }
  #expect(model.browserAccessAwaitingRelaunch == false)
  #expect(model.browserAccessSummary == "Safari needs Full Disk Access")

  model.browserAccessGrantDidRequestFullDiskAccess()
  #expect(presenter.settingsOpened == 1)
  #expect(model.browserAccessAwaitingRelaunch)
  #expect(model.browserAccessSummary == "Relaunch QuotaBar to finish granting Full Disk Access")
  #expect(presenter.updates.last?.awaitingRelaunch == true)

  // Once the grant is readable nothing is outstanding: the window closes on its own.
  probe.fullDiskAccess = true
  model.showBrowserAccessGrants()
  #expect(model.browserAccessSummary == nil)
  #expect(model.browserAccessAwaitingRelaunch == false)
  #expect(presenter.isPresented == false)
}

/// A drop on the Full Disk Access list is the same place as having opened the pane: the grant
/// lands on the next launch, so the window moves to the relaunch step and keeps probing.
@Test @MainActor
func droppingTheIconIntoFullDiskAccessOffersRelaunch() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.safari],
    fullDiskAccess: false,
    keychain: [:]
  )
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: FlowImporter(),
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { presenter.isPresented }
  #expect(model.browserAccessAwaitingRelaunch == false)

  model.browserAccessGrantDidDropIntoFullDiskAccess()
  #expect(presenter.settingsOpened == 0)
  #expect(model.browserAccessAwaitingRelaunch)
  #expect(presenter.updates.last?.awaitingRelaunch == true)
}

@Test @MainActor
func agentRowSummarisesEveryOutstandingGrantInOneLine() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.safari, .chrome, .firefox],
    fullDiskAccess: false,
    keychain: [.chrome: .interactionRequired]
  )
  let model = MenuBarViewModel(
    client: FlowService(state: flowState()),
    browserSessionImporter: FlowImporter(),
    accessProbe: probe,
    grantPresenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { presenter.isPresented }
  #expect(model.browserAccessSummary == "Safari and Chrome need permission")
  #expect(
    presenter.presented.first?.statuses.map(\.state)
      == [.needsFullDiskAccess, .needsKeychain, .readable])
}

private func waitUntil(
  _ condition: @escaping @MainActor () async -> Bool
) async throws {
  for _ in 0..<400 {
    if await condition() { return }
    try await Task.sleep(for: .milliseconds(10))
  }
  Issue.record("Timed out waiting for state")
}

private actor FlowImporter: BrowserSessionImporting {
  let value: BrowserSessionReadOutcome
  let outcomes: [SweetCookieKit.Browser: BrowserSessionReadOutcome]
  let delay: Duration
  private(set) var calls = 0
  private(set) var browsers: [SweetCookieKit.Browser] = []

  init(
    outcome: BrowserSessionReadOutcome = .noSession,
    outcomes: [SweetCookieKit.Browser: BrowserSessionReadOutcome] = [:],
    delay: Duration = .zero
  ) {
    value = outcome
    self.outcomes = outcomes
    self.delay = delay
  }

  func read(
    spec: BrowserSessionSpec,
    browser: SweetCookieKit.Browser,
    now: Date,
    deadline: Date
  ) async -> BrowserSessionReadOutcome {
    calls += 1
    browsers.append(browser)
    if delay > .zero { try? await Task.sleep(for: delay) }
    return Task.isCancelled ? .noSession : (outcomes[browser] ?? value)
  }
}

@MainActor
private final class StubBrowserAccessProbe: BrowserAccessProbing {
  var installed: Set<SweetCookieKit.Browser>
  var fullDiskAccess: Bool
  var keychain: [SweetCookieKit.Browser: BrowserKeychainAccess]
  /// What the system prompt would answer when a person presses Allow; applied to `keychain`.
  var keychainOnRequest: [SweetCookieKit.Browser: BrowserKeychainAccess] = [:]
  private(set) var snapshotCalls = 0
  private(set) var keychainRequests: [SweetCookieKit.Browser] = []

  init(
    installed: Set<SweetCookieKit.Browser>,
    fullDiskAccess: Bool,
    keychain: [SweetCookieKit.Browser: BrowserKeychainAccess]
  ) {
    self.installed = installed
    self.fullDiskAccess = fullDiskAccess
    self.keychain = keychain
  }

  func isInstalled(_ browser: SweetCookieKit.Browser) -> Bool {
    installed.contains(browser)
  }

  func hasFullDiskAccess() -> Bool { fullDiskAccess }

  func keychainAccess(for browser: SweetCookieKit.Browser) -> BrowserKeychainAccess {
    keychain[browser] ?? .notFound
  }

  func requestKeychainAccess(for browser: SweetCookieKit.Browser) async -> BrowserKeychainAccess {
    keychainRequests.append(browser)
    let answer = keychainOnRequest[browser] ?? keychainAccess(for: browser)
    keychain[browser] = answer
    return answer
  }

  func snapshot(browsers: [Browser], fullDiskAccessSettingsOpened: Bool) -> BrowserAccessSnapshot {
    snapshotCalls += 1
    return BrowserAccessEvaluation.snapshot(
      browsers: browsers,
      fullDiskAccessSettingsOpened: fullDiskAccessSettingsOpened,
      isInstalled: isInstalled,
      hasFullDiskAccess: hasFullDiskAccess,
      keychainAccess: keychainAccess
    )
  }
}

@MainActor
private final class RecordingGrantPresenter: BrowserAccessGrantPresenting {
  var handler: (any BrowserAccessGrantHandling)?
  private(set) var presented: [BrowserAccessGrantSnapshot] = []
  private(set) var updates: [BrowserAccessGrantSnapshot] = []
  private(set) var dismissed = 0
  private(set) var settingsOpened = 0
  private(set) var isPresented = false

  func present(_ snapshot: BrowserAccessGrantSnapshot) {
    presented.append(snapshot)
    isPresented = true
  }

  func update(_ snapshot: BrowserAccessGrantSnapshot) {
    updates.append(snapshot)
    if !snapshot.hasOutstandingGrants { dismiss() }
  }

  func dismiss() {
    dismissed += 1
    isPresented = false
  }

  func openFullDiskAccessSettings() { settingsOpened += 1 }
}

struct DeniedReport: Equatable, Sendable {
  let provider: ProviderID
  let browser: String
  let reason: BrowserAccessDenialReason
}

private struct ReplaceRecord: Equatable, Sendable {
  let provider: ProviderID
  let headers: [String]
  let denials: [DeniedReport]
}

private actor FlowService: LocalServiceServing {
  nonisolated let events: AsyncStream<LocalServiceEvent> = AsyncStream { $0.finish() }
  let stateValue: LocalServiceState
  private var enabledScans: [ProviderID]
  private(set) var replaces: [ReplaceRecord] = []
  private(set) var scanSets: [(ProviderID, Bool)] = []

  init(state: LocalServiceState) {
    stateValue = state
    enabledScans = state.browserScanEnabled
  }

  func state() async throws -> LocalServiceState {
    LocalServiceState(
      ipcVersion: stateValue.ipcVersion,
      revision: stateValue.revision,
      usageUploadEnabled: stateValue.usageUploadEnabled,
      quotaRefreshIntervalSeconds: stateValue.quotaRefreshIntervalSeconds,
      usagePeriods: stateValue.usagePeriods,
      quota: stateValue.quota,
      usage: stateValue.usage,
      account: stateValue.account,
      pricing: stateValue.pricing,
      providers: stateValue.providers,
      providerBrowserSessions: stateValue.providerBrowserSessions,
      browserScanEnabled: enabledScans,
      overview: stateValue.overview,
      cache: stateValue.cache
    )
  }
  func diagnose() async throws -> LocalServiceDiagnosticReport { throw LocalServiceClientError.serviceMissing }
  func resetCache() async throws { throw LocalServiceClientError.serviceMissing }
  func refresh() async throws -> LocalServiceRefreshResult { throw LocalServiceClientError.serviceMissing }
  func login() async throws -> LocalServiceLoginResult { throw LocalServiceClientError.serviceMissing }
  func cancelLogin() async throws {}
  func logout() async throws -> LocalServiceLogoutResult { throw LocalServiceClientError.serviceMissing }
  func setUsageUpload(enabled: Bool) async throws -> LocalServiceUsageUploadSetting { throw LocalServiceClientError.serviceMissing }
  func setQuotaRefreshInterval(seconds: Int) async throws -> LocalServiceQuotaRefreshIntervalSetting { throw LocalServiceClientError.serviceMissing }
  func setOverviewSourcePin(
    provider: ProviderID,
    fingerprint: String,
    scope: String,
    identitySourceID: String?,
    pin: String?
  ) async throws -> LocalServiceOverviewSourcePinSetting { throw LocalServiceClientError.serviceMissing }
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
  func setProviderBrowserScan(_ provider: ProviderID, enabled: Bool) async throws
    -> LocalServiceProviderBrowserScanSetting
  {
    scanSets.append((provider, enabled))
    if enabled {
      if !enabledScans.contains(provider) { enabledScans.append(provider) }
    } else {
      enabledScans.removeAll { $0 == provider }
    }
    return LocalServiceProviderBrowserScanSetting(provider: provider, enabled: enabled)
  }

  func replaceProviderBrowserSessions(
    _ provider: ProviderID,
    cookieHeaders: [String],
    accessDenials: [BrowserAccessDenial]
  ) async throws {
    replaces.append(
      ReplaceRecord(
        provider: provider,
        headers: cookieHeaders,
        denials: accessDenials.map {
          DeniedReport(provider: provider, browser: $0.browserName, reason: $0.reason)
        }
      )
    )
  }
  func shutdown() async {}
}

private func flowState(
  browserScanEnabled: [ProviderID] = [],
  officialCursorSuccess: Bool = false,
  revision: Int = 1,
  quotaUpdatedAt: Date? = nil,
  quotaRefreshing: Bool = false,
  quotaFailure: CollectionOutcome? = nil,
  cursorSources: [QuotaCollectionSource]? = nil,
  providerBrowserSessions: [LocalServiceProviderBrowserSession] = []
) -> LocalServiceState {
  let emptyPeriods = LocalServiceUsagePeriodValues(today: nil, last7Days: nil, last30Days: nil, all: nil)
  func empty<Value: Decodable & Sendable>() -> LocalServiceComponent<Value> {
    LocalServiceComponent(
      status: .unavailable, value: nil, updatedAt: quotaUpdatedAt, lastError: nil,
      refreshing: quotaRefreshing)
  }
  func sourceCategory(_ outcome: CollectionOutcome) -> CollectionSourceCategory {
    switch outcome {
    case .success: .success
    case .authRequired: .authRequired
    case .unavailable: .unavailable
    case .unsupported: .unsupported
    case .error: .error
    }
  }
  let quota: LocalServiceComponent<QuotaCollectionReport>
  if officialCursorSuccess {
    let now = quotaUpdatedAt ?? Date()
    let snapshot = QuotaSnapshot(
      provider: .cursor,
      account: QuotaAccount(
        fingerprint: "account_test",
        label: nil,
        plan: "Pro",
        fingerprintScope: .global
      ),
      windows: [QuotaWindow(id: "monthly", title: "Monthly", usedPercent: 10)],
      status: .available,
      observedAt: now
    )
    quota = LocalServiceComponent(
      status: .ready,
      value: QuotaCollectionReport(
        capturedAt: now,
        results: [
          QuotaCollectionResult(
            provider: .cursor,
            outcome: .success,
            snapshots: [snapshot],
            source: (cursorSources ?? []).first(where: { $0.outcome == .success })?.sourceID
              ?? "cursor_app_auth",
            message: nil,
            sources: cursorSources ?? [
              QuotaCollectionSource(
                sourceID: "cursor_app_auth", outcome: .success, category: .success)
            ],
            accessDenied: nil
          )
        ]
      ),
      updatedAt: now,
      lastError: nil,
      refreshing: quotaRefreshing
    )
  } else if let failure = quotaFailure {
    let now = quotaUpdatedAt ?? Date()
    quota = LocalServiceComponent(
      status: .ready,
      value: QuotaCollectionReport(
        capturedAt: now,
        results: [
          QuotaCollectionResult(
            provider: .cursor,
            outcome: failure,
            snapshots: [],
            source: "cursor_app_auth",
            message: nil,
            sources: [
              QuotaCollectionSource(
                sourceID: "cursor_app_auth", outcome: failure, category: sourceCategory(failure))
            ],
            accessDenied: nil
          )
        ]
      ),
      updatedAt: now,
      lastError: nil,
      refreshing: quotaRefreshing
    )
  } else {
    quota = empty()
  }
  return LocalServiceState(
    ipcVersion: 1,
    revision: revision,
    usageUploadEnabled: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: LocalServiceUsagePeriodCache(local: emptyPeriods, account: emptyPeriods),
    quota: quota,
    usage: empty(),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(authStatus: .signedOut, accountID: nil, displayLabel: nil, deviceID: nil, deviceGeneration: nil, accountSummary: nil),
      updatedAt: nil, lastError: nil, refreshing: false),
    pricing: empty(),
    providers: [],
    providerBrowserSessions: providerBrowserSessions,
    browserScanEnabled: browserScanEnabled,
    overview: [],
    cache: .settled
  )
}
