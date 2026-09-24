import Foundation
import QuotaWire
import SweetCookieKit
import Testing

@testable import QuotaBar

/// The consent popup is the gate. Declining it must leave every cookie store shut, so the
/// importer is never even asked and no browser is opened.
@Test @MainActor
func decliningConsentNeverReadsACookie() async throws {
  let transport = FlowTransport()
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
  let model = makeConnectionModel(transport: transport, importer: importer)
  model.requestEnableBrowserScan(.cursor)
  guard case .consent(let provider) = model.browserSessionPopup else {
    Issue.record("Expected the consent popup before any read")
    return
  }
  #expect(provider == .cursor)

  // Asking is not enabling: the service has not been told to scan, and nothing was read.
  #expect(await transport.scanSets.isEmpty)
  #expect(await importer.calls == 0)

  // Request and cancel are synchronous and start no work, so the answer is already final.
  model.cancelProviderBrowserSessionFlow()
  #expect(model.browserSessionPopup == nil)
  #expect(await importer.calls == 0)
  #expect(await transport.replaces.isEmpty)
  #expect(await transport.scanSets.isEmpty)
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
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: importer,
    probe: probe,
    presenter: presenter
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let replace = try #require(await transport.replaces.first)
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
  let enabled = await transport.scanSets
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
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: importer,
    probe: probe,
    presenter: presenter
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
func scheduledScanSkipsAKeychainPrompt() async throws {
  let probe = StubBrowserAccessProbe(
    installed: [.chrome, .firefox],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let importer = FlowImporter()
  let model = makeConnectionModel(importer: importer, probe: probe)
  model.acceptState(flowState(browserScanEnabled: [.cursor]))
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
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: importer,
    probe: probe,
    presenter: RecordingGrantPresenter()
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
  #expect(await transport.replaces.last?.headers == ["wos-session=allowed"])
}

@Test @MainActor
func officialCredentialDoesNotSkipTheGrantPanel() async throws {
  let presenter = RecordingGrantPresenter()
  let probe = StubBrowserAccessProbe(
    installed: [.chrome],
    fullDiskAccess: true,
    keychain: [.chrome: .interactionRequired]
  )
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    probe: probe,
    presenter: presenter
  )
  model.acceptState(flowState(officialCursorSuccess: true))
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { presenter.presented.isEmpty == false }
  #expect(await transport.replaces.isEmpty)
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
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: FlowImporter(outcome: .found([first, second]))
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  let replace = try #require(await transport.replaces.first)
  #expect(replace.provider == .cursor)
  #expect(Set(replace.headers) == ["wos-session=one", "wos-session=two"])
}

/// A refused store is its own answer. It must not read as "no session found", it must not keep
/// polling for two minutes, and the service has to learn about it so Support can say so too.
@Test @MainActor
func aRefusedCookieStoreIsItsOwnStateAndReachesTheService() async throws {
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: FlowImporter(
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
  let replace = try #require(await transport.replaces.first)
  #expect(replace.headers.isEmpty)
  #expect(
    replace.denials.contains(
      DeniedReport(provider: .cursor, browser: "Safari", reason: .fullDiskAccess)))
  #expect(Set(replace.denials.map(\.browser)).count == replace.denials.count)
}

@Test @MainActor
func automaticScanKeysOnQuotaUpdatedAtNotRevision() async throws {
  let updatedAt = Date(timeIntervalSince1970: 1_785_000_000)
  let importer = FlowImporter()
  let model = makeConnectionModel(importer: importer)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: updatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  try await waitUntil { model.browserSessionWaitingProvider == nil }
  let firstCalls = await importer.calls
  #expect(firstCalls > 0)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: updatedAt
    ))
  await expectNoScanStarted(model)
  #expect(await importer.calls == firstCalls)
}

@Test @MainActor
func successfulCollectionDoesNotRescanWhenASourceWasAuthRequired() async throws {
  let importer = FlowImporter()
  let model = makeConnectionModel(importer: importer)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      officialCursorSuccess: true,
      quotaUpdatedAt: Date(timeIntervalSince1970: 1_785_000_000),
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
  await expectNoScanStarted(model)
  #expect(await importer.calls == 0)
  #expect(model.browserSessionScanGeneration == 0)
}

@Test @MainActor
func unavailableCollectionDoesNotScanBrowsers() async throws {
  let importer = FlowImporter()
  let model = makeConnectionModel(importer: importer)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      quotaUpdatedAt: Date(timeIntervalSince1970: 1_785_000_000),
      quotaFailure: .unavailable
    ))
  await expectNoScanStarted(model)
  #expect(await importer.calls == 0)
  #expect(model.browserSessionScanGeneration == 0)
}

@Test @MainActor
func automaticScanIsRateLimitedAcrossNewCollections() async throws {
  let firstUpdatedAt = Date(timeIntervalSince1970: 1_785_000_000)
  let importer = FlowImporter()
  let model = makeConnectionModel(importer: importer)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: firstUpdatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  try await waitUntil { model.browserSessionWaitingProvider == nil }
  let firstCalls = await importer.calls
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: firstUpdatedAt.addingTimeInterval(1)
    ))
  await expectNoScanStarted(model)
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
  let model = makeConnectionModel(probe: probe)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 1,
      quotaUpdatedAt: updatedAt
    ))
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  try await waitUntil { model.browserSessionWaitingProvider == nil }
  let firstProbes = probe.snapshotCalls
  #expect(firstProbes == 1)
  model.acceptState(
    flowState(
      browserScanEnabled: [.cursor],
      revision: 2,
      quotaUpdatedAt: updatedAt
    ))
  // The probe runs inside `acceptState`, so it has already happened or never will.
  await expectNoScanStarted(model)
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
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    probe: probe,
    presenter: presenter
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
  let model = makeConnectionModel(
    probe: probe,
    presenter: presenter
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

/// Turning Scan browsers off while a read is still in flight must not commit that older result.
@Test @MainActor
func aScanResultFromAnOlderGenerationIsIgnored() async throws {
  let candidate = BrowserSessionCookieCandidate(
    cookieHeader: "wos-session=stale",
    headerFingerprint: "header-stale",
    browserName: "Safari",
    profileName: "Personal"
  )
  let probe = StubBrowserAccessProbe(
    installed: [.safari],
    fullDiskAccess: true,
    keychain: [:]
  )
  let importer = FlowImporter(outcome: .found([candidate]), holdsReads: true)
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: importer,
    probe: probe
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { await importer.calls >= 1 }
  model.setBrowserScanEnabled(.cursor, enabled: false)
  // The read that was already in flight finishes only now; the point is that its result is
  // dropped, which can only be checked once the read is done.
  await importer.releaseReads()
  try await waitUntil { await importer.completions >= 1 }
  #expect(await transport.replaces.isEmpty)
  #expect(model.browserSessionScanGeneration == 0)
}

/// Asking for consent again is a new gate: the previous refusal does not stay on the row.
@Test @MainActor
func aFreshConsentClearsAnAccessDenial() async throws {
  let transport = FlowTransport()
  let model = makeConnectionModel(
    transport: transport,
    importer: FlowImporter(
      outcome: .accessDenied(
        BrowserAccessDenial(browserName: "Safari", reason: .fullDiskAccess))
    )
  )
  model.requestEnableBrowserScan(.cursor)
  model.confirmProviderBrowserSessionConsent()
  try await waitUntil { model.browserSessionScanGeneration >= 1 }
  #expect(model.browserSessionAccessDenials[.cursor] != nil)
  #expect(model.browserSessionErrorMessages[.cursor] != nil)

  model.requestEnableBrowserScan(.cursor)
  #expect(model.browserSessionAccessDenials[.cursor] == nil)
  #expect(model.browserSessionErrorMessages[.cursor] == nil)
  guard case .consent(let provider) = model.browserSessionPopup else {
    Issue.record("Expected the consent popup")
    return
  }
  #expect(provider == .cursor)
}

@MainActor
private func makeConnectionModel(
  transport: FlowTransport = FlowTransport(),
  importer: FlowImporter = FlowImporter(),
  probe: (any BrowserAccessProbing)? = nil,
  presenter: (any BrowserAccessGrantPresenting)? = nil
) -> BrowserConnectionModel {
  BrowserConnectionModel(
    transport: transport,
    importer: importer,
    accessProbe: probe ?? UnrestrictedBrowserAccessProbe(),
    grantPresenter: presenter,
    relauncher: NoOpQuotaBarRelauncher()
  )
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

/// A scan the model schedules is a main-actor task that marks its provider as waiting before its
/// first suspension. Running one main-actor job behind everything already queued gives any such
/// task its first step, so a model that decided to scan is caught here without an interval.
@MainActor
private func expectNoScanStarted(_ model: BrowserConnectionModel) async {
  await Task { @MainActor in }.value
  #expect(model.browserSessionWaitingProvider == nil, "a scan was scheduled")
}

private actor FlowImporter: BrowserSessionImporting {
  let value: BrowserSessionReadOutcome
  let outcomes: [SweetCookieKit.Browser: BrowserSessionReadOutcome]
  /// Holds every read open until the test releases it: a read in flight, for exactly as long as
  /// the test needs one, rather than for an interval it guessed.
  let holdsReads: Bool
  private var released = false
  private var held: [CheckedContinuation<Void, Never>] = []
  private(set) var calls = 0
  /// How many reads have finished. A test that wants to know a scan had its chance waits for this.
  private(set) var completions = 0
  private(set) var browsers: [SweetCookieKit.Browser] = []

  init(
    outcome: BrowserSessionReadOutcome = .noSession,
    outcomes: [SweetCookieKit.Browser: BrowserSessionReadOutcome] = [:],
    holdsReads: Bool = false
  ) {
    value = outcome
    self.outcomes = outcomes
    self.holdsReads = holdsReads
  }

  func releaseReads() {
    released = true
    let waiting = held
    held = []
    for one in waiting { one.resume() }
  }

  func read(
    spec: BrowserSessionSpec,
    browser: SweetCookieKit.Browser,
    now: Date,
    deadline: Date
  ) async -> BrowserSessionReadOutcome {
    calls += 1
    browsers.append(browser)
    if holdsReads, !released {
      await withCheckedContinuation { held.append($0) }
    }
    completions += 1
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

private struct DeniedReport: Equatable, Sendable {
  let provider: ProviderID
  let browser: String
  let reason: BrowserAccessDenialReason
}

private struct ReplaceRecord: Equatable, Sendable {
  let provider: ProviderID
  let headers: [String]
  let denials: [DeniedReport]
}

private actor FlowTransport: BrowserConnectionTransport {
  private(set) var replaces: [ReplaceRecord] = []
  private(set) var scanSets: [(ProviderID, Bool)] = []

  func setProviderBrowserScan(_ provider: ProviderID, enabled: Bool) async throws
    -> LocalServiceProviderBrowserScanSetting
  {
    scanSets.append((provider, enabled))
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
  let emptyPeriods = LocalServiceUsagePeriodValues(
    today: nil, last7Days: nil, last30Days: nil, all: nil)
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
    let now = quotaUpdatedAt ?? Date(timeIntervalSince1970: 1_785_000_000)
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
    let now = quotaUpdatedAt ?? Date(timeIntervalSince1970: 1_785_000_000)
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
    ipcVersion: 3,
    revision: revision,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: LocalServiceUsagePeriodCache(local: emptyPeriods, account: emptyPeriods),
    quota: quota,
    usage: empty(),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(
        authStatus: .signedOut, accountID: nil, displayLabel: nil, deviceID: nil,
        deviceGeneration: nil, accountSummary: nil),
      updatedAt: nil, lastError: nil, refreshing: false),
    pricing: empty(),
    providers: [],
    providerBrowserSessions: providerBrowserSessions,
    browserScanEnabled: browserScanEnabled,
    overview: [],
    cache: .settled
  )
}
