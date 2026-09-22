import Foundation
import QuotaAlertDelivery
import QuotaAlerts
import QuotaPresentation
import QuotaWire
import Testing
import UserNotifications

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
    ipcVersion: 3,
    revision: 7,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: emptyUsagePeriods(),
    quota: component(value: report, updatedAt: now),
    usage: component(value: unavailableUsage(now: now), updatedAt: now),
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
  #expect(model.accountFlow.accountDisconnectReason == .deviceDeleted)
  #expect(
    model.accountFlow.accountErrorMessage
      == "This device was removed. Sign in again to reconnect it."
  )
}

@Test @MainActor
func applyingANonEmptyOverviewSetsLaunchHasShownQuotaOnce() {
  let key = LaunchHasShownQuota.storageKey
  let previous = UserDefaults.standard.object(forKey: key)
  defer {
    if let previous {
      UserDefaults.standard.set(previous, forKey: key)
    } else {
      UserDefaults.standard.removeObject(forKey: key)
    }
  }
  UserDefaults.standard.removeObject(forKey: key)

  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let item = sourceScopedOverviewItem(
    sourceID: "local",
    kind: .local,
    deviceID: nil,
    displayName: "This Mac",
    usedPercent: 20,
    now: now
  )
  let model = MenuBarViewModel(client: StubLocalService(state: overviewOnlyState(overview: [])))
  model.apply(overviewOnlyState(overview: []))
  #expect(!LaunchHasShownQuota.hasShown)

  model.apply(overviewOnlyState(overview: [item]))
  #expect(LaunchHasShownQuota.hasShown)

  model.apply(overviewOnlyState(overview: []))
  #expect(LaunchHasShownQuota.hasShown)
}

@Test @MainActor
func sourceDetailLooksUpTheSourceScopedRowNotTheFirstSharedFingerprint() async throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let remote = sourceScopedOverviewItem(
    sourceID: "device:other",
    kind: .device,
    deviceID: "other",
    displayName: "Studio",
    usedPercent: 90,
    now: now
  )
  let local = sourceScopedOverviewItem(
    sourceID: "local",
    kind: .local,
    deviceID: nil,
    displayName: "This Mac",
    usedPercent: 10,
    now: now
  )
  let model = MenuBarViewModel(
    client: StubLocalService(state: overviewOnlyState(overview: [remote, local]))
  )
  await model.refreshIfNeeded()

  #expect(
    model.overviewItems(for: .grok).first { $0.identity.fingerprint == "fp-source" }?
      .identity.sourceID == "device:other")
  #expect(
    model.overviewItem(provider: .grok, identityKey: local.pinIdentityKey)?
      .identity.sourceID == "local")
  #expect(
    model.overviewItem(provider: .grok, identityKey: remote.pinIdentityKey)?
      .identity.sourceID == "device:other")
}

@Test @MainActor
func setOverviewSourcePinSendsTheSourceScopedIdentity() async throws {
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let item = sourceScopedOverviewItem(
    sourceID: "local",
    kind: .local,
    deviceID: nil,
    displayName: "This Mac",
    usedPercent: 10,
    now: now
  )
  let record = PinCallRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(
      state: overviewOnlyState(overview: [item]), pinRecord: record)
  )
  await model.refreshIfNeeded()
  await model.setOverviewSourcePin(item: item, pin: "local")

  #expect(await record.identitySourceID == "local")
  #expect(await record.identityKey == "grok|fp-source|source|local")
  #expect(await record.pin == "local")
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
    groupUsageByProject: base.groupUsageByProject,
    quotaRefreshIntervalSeconds: base.quotaRefreshIntervalSeconds,
    usagePeriods: base.usagePeriods,
    quota: base.quota,
    usage: base.usage,
    account: base.account,
    pricing: base.pricing,
    providers: base.providers,
    providerBrowserSessions: base.providerBrowserSessions,
    browserScanEnabled: base.browserScanEnabled,
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

func accountSettingsDocument(
  revision: Int,
  resetReminders: Bool = true,
  paceAlerts: Bool = true,
  thresholds: [String: [Int]] = [:],
  amountUSD: Decimal? = nil,
  budgetAlerts: Bool = true
) -> AccountSettingsDocument {
  AccountSettingsDocument(
    revision: revision,
    updatedAt: ISO8601DateFormatter().date(from: "2026-09-21T10:00:00Z"),
    alerts: AccountSettingsDocument.Alerts(
      resetReminders: resetReminders,
      paceAlerts: paceAlerts,
      thresholds: thresholds
    ),
    budget: AccountSettingsDocument.Budget(amountUSD: amountUSD, alerts: budgetAlerts)
  )
}

func signedInSettingsState(
  accountID: String = "account_1",
  label: String? = "octocat",
  settings: LocalServiceAccountSettingsState,
  overview: [LocalServiceOverviewItem] = [],
  revision: Int = 2
) -> LocalServiceState {
  LocalServiceState(
    ipcVersion: LocalServiceState.supportedIPCVersion,
    revision: revision,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: emptyUsagePeriods(),
    quota: emptyComponent(),
    usage: emptyComponent(),
    account: LocalServiceComponent(
      status: .ready,
      value: LocalServiceAccountState(
        authStatus: .signedIn,
        accountID: accountID,
        displayLabel: label,
        deviceID: "device_1",
        deviceGeneration: 1,
        accountSummary: nil
      ),
      updatedAt: Date(timeIntervalSince1970: 1_786_300_000),
      lastError: nil,
      refreshing: false
    ),
    accountSettings: settings,
    pricing: emptyComponent(),
    providers: [],
    providerBrowserSessions: [],
    browserScanEnabled: [],
    overview: overview,
    cache: .settled
  )
}

/// A device signed in, with the first account read still running.
func justSignedInState(
  label: String?,
  overview: [LocalServiceOverviewItem] = []
) -> LocalServiceState {
  LocalServiceState(
    ipcVersion: 3,
    revision: 2,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: emptyUsagePeriods(),
    quota: emptyComponent(),
    usage: emptyComponent(),
    account: LocalServiceComponent(
      status: .ready,
      value: LocalServiceAccountState(
        authStatus: .signedIn,
        accountID: "account_1",
        displayLabel: label,
        deviceID: "device_1",
        deviceGeneration: 1,
        accountSummary: nil
      ),
      updatedAt: Date(timeIntervalSince1970: 1_786_300_000),
      lastError: nil,
      refreshing: true
    ),
    pricing: emptyComponent(),
    providers: [],
    providerBrowserSessions: [],
    browserScanEnabled: [],
    overview: overview,
    cache: .settled
  )
}

/// Overview answers how much is left. A row another device's reading fills has answered, so
/// this Mac's own failed collection stays off it; the failure shows only when this Mac's reading
/// is the one on the row — it says why that reading stopped moving — or when there is none.
@Test @MainActor
func thisMacsCollectionFailureShowsOnlyWhenItsOwnReadingIsTheOneOnTheRow() async throws {
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
  let deviceSource = LocalServiceOverviewSource(
    sourceID: "device:other",
    kind: .device,
    deviceID: "other",
    displayName: "Kyle's MacBook Air",
    observedAt: now,
    isStale: false
  )
  let localSource = LocalServiceOverviewSource(
    sourceID: "chatgpt_usage_api",
    kind: .local,
    deviceID: nil,
    displayName: "OAuth",
    observedAt: now.addingTimeInterval(-3_600),
    isStale: true
  )
  func state(
    reading: [LocalServiceOverviewSource],
    selected: LocalServiceOverviewSource,
    sources: [QuotaCollectionSource]
  ) -> LocalServiceState {
    LocalServiceState(
      ipcVersion: 3,
      revision: 3,
      usageUploadEnabled: true,
      groupUsageByProject: true,
      quotaRefreshIntervalSeconds: 300,
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
          sources: reading,
          selectedSourceID: selected.sourceID,
          selectedSourceDisplayName: selected.displayName,
          automaticSourceID: selected.sourceID,
          automaticSourceDisplayName: selected.displayName,
          isStale: selected.isStale
        )
      ],
      cache: .settled
    )
  }

  func codexRow(
    reading: [LocalServiceOverviewSource],
    selected: LocalServiceOverviewSource,
    sources: [QuotaCollectionSource]
  ) async -> ProviderQuotaPresentation? {
    let model = MenuBarViewModel(
      client: StubLocalService(state: state(reading: reading, selected: selected, sources: sources))
    )
    await model.refreshIfNeeded()
    guard case .content(let providers, _) = model.overviewState(enabledProviders: [.codex]) else {
      Issue.record("Expected quota content")
      return nil
    }
    return providers.first
  }
  let failedHere = [
    QuotaCollectionSource(
      sourceID: "chatgpt_usage_api", outcome: .unavailable, category: .unavailable)
  ]

  // This Mac holds a Codex sign-in and could not read it, and the MacBook Air's reading is the
  // one on the row. The row has its answer; what went wrong here is the provider page's.
  let filledByDevice = await codexRow(
    reading: [localSource, deviceSource], selected: deviceSource, sources: failedHere)
  #expect(filledByDevice?.accounts.count == 1)
  #expect(filledByDevice?.status == nil)

  // The same failure with this Mac's own reading on the row: the status names the rung that
  // failed, so the reader knows why the numbers stopped moving and which reading to go fix.
  let ownReading = await codexRow(
    reading: [localSource], selected: localSource, sources: failedHere)
  #expect(ownReading?.accounts.count == 1)
  #expect(ownReading?.status?.kind == .unavailable)
  #expect(ownReading?.status?.title == "OAuth · Unavailable")

  // A Mac that never had Codex has nothing to recover, so the account keeps the row quiet.
  let neverConfigured = await codexRow(
    reading: [deviceSource], selected: deviceSource, sources: [])
  #expect(neverConfigured?.accounts.count == 1)
  #expect(neverConfigured?.status == nil)
}

@Test @MainActor
func quittingAsksTheLocalServiceToShutDownBeforeTheAppGoes() async {
  let record = CallRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState(), shutdownRecord: record)
  )
  model.start()

  await model.shutdown()

  let shutdowns = await record.count
  #expect(shutdowns == 1, "the app's termination path sends the service its shutdown")
}

/// The other half of that promise: a quit is a decision the person already made, so a service that
/// never answers costs the deadline and nothing more. What this pins is which wait ends the quit —
/// the deadline's, released here on purpose — rather than how many milliseconds passed on the
/// machine that happened to run it. The time limit is the hang detector, not the assertion.
@Test(.timeLimit(.minutes(1))) @MainActor
func quittingStopsWaitingOnAHelperThatNeverAnswersItsShutdown() async {
  #expect(MenuBarViewModel.shutdownDeadline == .seconds(2))
  let record = CallRecord()
  let heldGoodbye = TestGate()
  let waitingOnTheDeadline = TestGate()
  let deadlineElapsed = TestGate()
  let askedFor = DurationRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(
      state: loggingInState(),
      shutdownRecord: record,
      shutdownGate: heldGoodbye
    ),
    shutdownDeadline: .milliseconds(120),
    deadlineSleeper: { duration in
      await askedFor.record(duration)
      await waitingOnTheDeadline.open()
      await deadlineElapsed.wait()
    }
  )
  model.start()

  let quit = Task { await model.shutdown() }
  await waitingOnTheDeadline.wait()
  // The quit is inside the deadline's wait, so it has not returned, and the helper it is waiting
  // for has not answered.
  #expect(await askedFor.durations == [.milliseconds(120)], "the quit waits out its deadline")
  #expect(await record.count == 0)

  await deadlineElapsed.open()
  await quit.value
  #expect(
    await record.count == 0,
    "the helper had not answered, and the quit went ahead anyway"
  )
  // Let the abandoned goodbye finish rather than leaving a task parked on the gate.
  await heldGoodbye.open()
}

/// A healthy quit is not slowed to the deadline: the goodbye that lands cancels it. The sleeper
/// here only ends by cancellation, so a quit that returns proves the arrival cancelled it.
@Test(.timeLimit(.minutes(1))) @MainActor
func quittingThatGetsItsGoodbyeDoesNotWaitOutTheDeadline() async {
  let record = CallRecord()
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState(), shutdownRecord: record),
    deadlineSleeper: { _ in try await Task.sleep(for: .seconds(3_600)) }
  )
  model.start()

  await model.shutdown()

  #expect(await record.count == 1, "the helper answered, and the quit took that as its answer")
}

@Test @MainActor
func quotaApplyDeliversFirstSeenThresholdEventsWhenNotificationsAreEnabled() throws {
  let defaults = notificationDefaultsSuite()
  defer { defaults.tearDown() }
  NotificationRules.store(defaults: defaults.store).save(
    AlertRules(enabled: true, resetReminders: true)
  )
  let store = InMemoryAlertStateStore()
  let sink = RecordingNotificationSink()
  let now = Date(timeIntervalSince1970: 1_786_300_000)
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState()),
    notificationStore: store,
    notificationSink: sink,
    notificationDefaults: defaults.store
  )
  model.apply(overviewOnlyState(overview: [codexOverviewItem(remainingPercent: 12, now: now)]))

  #expect(sink.events.count == 1)
  #expect(
    sink.events
      == [
        .thresholdCrossed(
          selector: "ccfc96629357",
          windowID: "weekly",
          threshold: 20,
          remainingPercent: 12,
          resetsAt: nil
        )
      ]
  )
  #expect(try store.load().fired.count == 1)
}

@Test @MainActor
func signingOutClearsNotificationDedupState() throws {
  let defaults = notificationDefaultsSuite()
  defer { defaults.tearDown() }
  let store = InMemoryAlertStateStore(
    state: AlertDedupState(
      fired: [
        AlertDedupKey(
          kind: .threshold,
          selector: "ccfc96629357", windowID: "weekly", resetsAt: nil, threshold: 20)
      ],
      readings: [
        AlertStoredReading(
          selector: "ccfc96629357", windowID: "weekly", remainingPercent: 18, resetsAt: nil)
      ]
    )
  )
  let model = MenuBarViewModel(
    client: StubLocalService(state: justSignedInState(label: "octocat")),
    notificationStore: store,
    notificationDefaults: defaults.store
  )
  model.apply(justSignedInState(label: "octocat"))
  #expect(try store.load().fired.count == 1)

  model.apply(signedOutWithSessionEndedState())
  #expect(try store.load() == .empty)
}

@Test @MainActor
func newReadingsRescheduleResetReminders() throws {
  let defaults = notificationDefaultsSuite()
  defer { defaults.tearDown() }
  NotificationRules.store(defaults: defaults.store).save(
    AlertRules(enabled: true, resetReminders: true)
  )
  let center = FakeNotificationCenter()
  let now = Date()
  let firstReset = now.addingTimeInterval(3_600)
  let secondReset = now.addingTimeInterval(7_200)
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState()),
    notificationCenter: center,
    notificationDefaults: defaults.store
  )

  model.apply(
    overviewOnlyState(overview: [codexOverviewItem(remainingPercent: 40, now: now, resetsAt: firstReset)])
  )
  #expect(center.pending.count == 1)
  let firstID = try #require(center.pending.first?.identifier)
  #expect(center.pending.first?.trigger is UNCalendarNotificationTrigger)
  #expect(
    firstID
      == AlertDedupKey(
        kind: .reset,
        selector: "ccfc96629357", windowID: "weekly", resetsAt: firstReset, threshold: nil
      ).requestIdentifier
  )

  model.apply(
    overviewOnlyState(
      overview: [codexOverviewItem(remainingPercent: 40, now: now, resetsAt: secondReset)])
  )
  #expect(center.pending.count == 1)
  #expect(center.pending.first?.identifier != firstID)
  #expect(
    center.pending.first?.identifier
      == AlertDedupKey(
        kind: .reset,
        selector: "ccfc96629357", windowID: "weekly", resetsAt: secondReset, threshold: nil
      ).requestIdentifier
  )
}

@Test @MainActor
func signingOutRemovesScheduledResetReminders() {
  let defaults = notificationDefaultsSuite()
  defer { defaults.tearDown() }
  NotificationRules.store(defaults: defaults.store).save(
    AlertRules(enabled: true, resetReminders: true)
  )
  let center = FakeNotificationCenter()
  let now = Date()
  let resetsAt = now.addingTimeInterval(3_600)
  let item = codexOverviewItem(remainingPercent: 40, now: now, resetsAt: resetsAt)
  let model = MenuBarViewModel(
    client: StubLocalService(state: justSignedInState(label: "octocat", overview: [item])),
    notificationCenter: center,
    notificationDefaults: defaults.store
  )
  model.apply(justSignedInState(label: "octocat", overview: [item]))
  #expect(!center.pending.isEmpty)

  model.apply(signedOutWithSessionEndedState())
  #expect(center.pending.isEmpty)
  #expect(center.removedAllPendingCount >= 1)
}

@Test @MainActor
func turningOffResetRemindersClearsScheduledReminders() {
  let defaults = notificationDefaultsSuite()
  defer { defaults.tearDown() }
  NotificationRules.store(defaults: defaults.store).save(
    AlertRules(enabled: true, resetReminders: true)
  )
  let center = FakeNotificationCenter()
  let now = Date()
  let model = MenuBarViewModel(
    client: StubLocalService(state: loggingInState()),
    notificationCenter: center,
    notificationDefaults: defaults.store
  )
  model.apply(
    overviewOnlyState(
      overview: [
        codexOverviewItem(
          remainingPercent: 40, now: now, resetsAt: now.addingTimeInterval(3_600))
      ])
  )
  #expect(!center.pending.isEmpty)

  model.setResetReminders(false)
  #expect(center.pending.isEmpty)
  #expect(!model.notificationRules.resetReminders)
}

final class FakeNotificationCenter: NotificationCentering, @unchecked Sendable {
  var authorizationStatusValue: UNAuthorizationStatus = .notDetermined
  var requestAuthorizationGranted = true
  var requestedOptions: UNAuthorizationOptions?
  var added: [UNNotificationRequest] = []
  var pending: [UNNotificationRequest] = []
  var removedAllPendingCount = 0

  func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool {
    requestedOptions = options
    if requestAuthorizationGranted {
      authorizationStatusValue = .authorized
    } else {
      authorizationStatusValue = .denied
    }
    return requestAuthorizationGranted
  }

  func authorizationStatus() async -> UNAuthorizationStatus {
    authorizationStatusValue
  }

  func add(_ request: UNNotificationRequest) {
    added.append(request)
    if request.trigger != nil {
      pending.removeAll { $0.identifier == request.identifier }
      pending.append(request)
    }
  }

  func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
    pending.removeAll { identifiers.contains($0.identifier) }
  }

  func removeAllPendingNotificationRequests() {
    removedAllPendingCount += 1
    pending.removeAll()
  }
}

final class RecordingNotificationSink: AlertSink, @unchecked Sendable {
  var events: [AlertEvent] = []

  func deliver(_ events: [AlertEvent]) {
    self.events.append(contentsOf: events)
  }
}

struct NotificationDefaultsSuite {
  let name: String
  let store: UserDefaults

  func tearDown() {
    store.removePersistentDomain(forName: name)
  }
}

func notificationDefaultsSuite() -> NotificationDefaultsSuite {
  let name = "QuotaBarTests.MenuBarNotifications.\(UUID().uuidString)"
  let store = UserDefaults(suiteName: name)!
  store.removePersistentDomain(forName: name)
  return NotificationDefaultsSuite(name: name, store: store)
}

func codexOverviewItem(
  remainingPercent: Double,
  now: Date,
  resetsAt: Date? = nil
) -> LocalServiceOverviewItem {
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
        id: "weekly",
        title: "Weekly",
        usedPercent: 100 - remainingPercent,
        resetsAt: resetsAt,
        primaryCadence: .weekly
      )
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
  return LocalServiceOverviewItem(
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
}

func signedOutWithSessionEndedState() -> LocalServiceState {
  LocalServiceState(
    ipcVersion: 3,
    revision: 1,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: emptyUsagePeriods(),
    quota: emptyComponent(),
    usage: emptyComponent(),
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
      lastError: LocalServiceRemoteError(
        code: .authenticationRequired,
        recoveryAction: .login
      ),
      refreshing: false
    ),
    pricing: emptyComponent(),
    providers: [],
    providerBrowserSessions: [],
    browserScanEnabled: [],
    overview: [],
    cache: .settled
  )
}

func loggingInState() -> LocalServiceState {
  LocalServiceState(
    ipcVersion: 3,
    revision: 1,
    usageUploadEnabled: true,
    groupUsageByProject: true,
    quotaRefreshIntervalSeconds: 300,
    usagePeriods: emptyUsagePeriods(),
    quota: emptyComponent(),
    usage: emptyComponent(),
    account: LocalServiceComponent(
      status: .signedOut,
      value: LocalServiceAccountState(
        authStatus: .loggingIn,
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
}

private func sourceScopedOverviewItem(
  sourceID: String,
  kind: LocalServiceOverviewSourceKind,
  deviceID: String?,
  displayName: String,
  usedPercent: Double,
  now: Date
) -> LocalServiceOverviewItem {
  let snapshot = QuotaSnapshot(
    provider: .grok,
    account: QuotaAccount(
      fingerprint: "fp-source",
      fingerprintScope: .source
    ),
    windows: [QuotaWindow(id: "weekly", title: "Weekly", usedPercent: usedPercent)],
    status: .available,
    observedAt: now
  )
  let source = LocalServiceOverviewSource(
    sourceID: sourceID,
    kind: kind,
    deviceID: deviceID,
    displayName: displayName,
    observedAt: now,
    isStale: false,
    snapshot: snapshot
  )
  return LocalServiceOverviewItem(
    identity: LocalServiceOverviewIdentity(
      provider: .grok,
      fingerprint: "fp-source",
      scope: .source,
      sourceID: sourceID
    ),
    snapshot: snapshot,
    sources: [source],
    selectedSourceID: source.sourceID,
    selectedSourceDisplayName: source.displayName,
    automaticSourceID: source.sourceID,
    automaticSourceDisplayName: source.displayName,
    isStale: false
  )
}

func overviewOnlyState(
  overview: [LocalServiceOverviewItem]
) -> LocalServiceState {
  LocalServiceState(
    ipcVersion: 3,
    revision: 1,
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
    overview: overview,
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

final class QuotaHistoryAccountScript: @unchecked Sendable {
  var results: [Result<LocalServiceQuotaHistory, any Error>]

  init(_ results: [Result<LocalServiceQuotaHistory, any Error>]) {
    self.results = results
  }

  func next() throws -> LocalServiceQuotaHistory {
    guard !results.isEmpty else { throw LocalServiceClientError.invalidMessage }
    return try results.removeFirst().get()
  }
}

actor AccountSettingsWriteRecord {
  private(set) var calls: [(document: AccountSettingsDocument, ifMatch: String)] = []
  var results: [Result<LocalServiceAccountSettingsWriteResult, Error>] = []
  var refreshValue: LocalServiceAccountSettingsState?
  var gate: TestGate?

  func queue(_ result: Result<LocalServiceAccountSettingsWriteResult, Error>) {
    results.append(result)
  }

  func setGate(_ gate: TestGate) {
    self.gate = gate
  }

  func record(document: AccountSettingsDocument, ifMatch: String) async throws
    -> LocalServiceAccountSettingsWriteResult
  {
    calls.append((document, ifMatch))
    if let gate {
      await gate.wait()
    }
    if results.isEmpty {
      return .written(document)
    }
    let next = results.removeFirst()
    return try next.get()
  }

  func refresh() async throws -> LocalServiceAccountSettingsState {
    if let refreshValue { return refreshValue }
    throw LocalServiceClientError.invalidMessage
  }
}

actor PinCallRecord {
  private(set) var identitySourceID: String?
  private(set) var identityKey: String?
  private(set) var pin: String?

  func record(identitySourceID: String?, identityKey: String, pin: String?) {
    self.identitySourceID = identitySourceID
    self.identityKey = identityKey
    self.pin = pin
  }
}

/// Counts the calls a stub was asked for, which is all a fire-and-forget operation leaves behind
/// once the service it spoke to is gone.
/// A one-shot signal. Whoever waits proceeds when the test opens it, which is how these tests say
/// "this work has not finished yet" without naming an interval.
actor TestGate {
  private var isOpen = false
  private var waiting: [CheckedContinuation<Void, Never>] = []

  func open() {
    guard !isOpen else { return }
    isOpen = true
    let resuming = waiting
    waiting = []
    for one in resuming { one.resume() }
  }

  func wait() async {
    if isOpen { return }
    await withCheckedContinuation { waiting.append($0) }
  }
}

/// What a sleeper was asked to wait for, in order.
actor DurationRecord {
  private(set) var durations: [Duration] = []

  func record(_ duration: Duration) {
    durations.append(duration)
  }
}

actor CallRecord {
  private(set) var count = 0

  func record() {
    count += 1
  }

  /// Waits for the recorded count to reach `target` so the test paces off the work, not the clock.
  func waitForCount(_ target: Int, within seconds: Double = 5) async throws {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while count < target {
      if ContinuousClock.now >= deadline {
        Issue.record("cancel_login count reached \(count), expected \(target)")
        return
      }
      try await Task.sleep(for: .milliseconds(10))
    }
  }
}

struct StubLocalService: LocalServiceServing {
  let stateValue: LocalServiceState
  let events: AsyncStream<LocalServiceEvent>
  let loginDelayNanoseconds: UInt64
  let cancelDelayNanoseconds: UInt64
  let cancelFails: Bool
  let cancelRecord: CallRecord?
  let shutdownRecord: CallRecord?
  /// Where the helper's goodbye waits. A held goodbye is a helper that has not answered yet — no
  /// interval to guess, and nothing that answers early on a fast machine or late on a loaded one.
  let shutdownGate: TestGate?
  let loginError: LocalServiceClientError?
  let authorizeURL: String?
  let pinRecord: PinCallRecord?
  /// What `usage_period` answers, for the tests that ask for a period `get_state` does not carry.
  let customPeriod: LocalServiceUsageDetail?
  /// What `quota_history` answers, for the tests that load 30-day samples on demand.
  let quotaHistoryValue: LocalServiceQuotaHistory?
  /// What `quota_history` with `source: account` answers, in order. Nil refuses the read.
  let accountQuotaHistory: QuotaHistoryAccountScript?
  let accountSettingsWriteRecord: AccountSettingsWriteRecord?

  init(
    state: LocalServiceState,
    loginDelayNanoseconds: UInt64 = 0,
    cancelDelayNanoseconds: UInt64 = 0,
    cancelFails: Bool = false,
    cancelRecord: CallRecord? = nil,
    shutdownRecord: CallRecord? = nil,
    shutdownGate: TestGate? = nil,
    loginError: LocalServiceClientError? = nil,
    authorizeURL: String? = nil,
    pinRecord: PinCallRecord? = nil,
    customPeriod: LocalServiceUsageDetail? = nil,
    quotaHistoryValue: LocalServiceQuotaHistory? = nil,
    accountQuotaHistory: QuotaHistoryAccountScript? = nil,
    accountSettingsWriteRecord: AccountSettingsWriteRecord? = nil
  ) {
    stateValue = state
    events = AsyncStream { $0.finish() }
    self.loginDelayNanoseconds = loginDelayNanoseconds
    self.cancelDelayNanoseconds = cancelDelayNanoseconds
    self.cancelFails = cancelFails
    self.cancelRecord = cancelRecord
    self.shutdownRecord = shutdownRecord
    self.shutdownGate = shutdownGate
    self.loginError = loginError
    self.authorizeURL = authorizeURL
    self.pinRecord = pinRecord
    self.customPeriod = customPeriod
    self.quotaHistoryValue = quotaHistoryValue
    self.accountQuotaHistory = accountQuotaHistory
    self.accountSettingsWriteRecord = accountSettingsWriteRecord
  }

  func state() async throws -> LocalServiceState { stateValue }

  func usagePeriod(
    from: String, to: String, source: UsageSource, timezone: String
  ) async throws -> LocalServiceUsageDetail {
    let _ = (source, timezone)
    guard let customPeriod else { throw LocalServiceClientError.invalidMessage }
    return customPeriod
  }

  func quotaHistory(
    source: QuotaHistoryRequestSource,
    provider: String?,
    fingerprint: String?,
    since: Date
  ) async throws -> LocalServiceQuotaHistory {
    let _ = (provider, fingerprint, since)
    if source == .account {
      guard let accountQuotaHistory else { throw LocalServiceClientError.invalidMessage }
      return try accountQuotaHistory.next()
    }
    guard let quotaHistoryValue else { throw LocalServiceClientError.invalidMessage }
    return quotaHistoryValue
  }

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
    if let loginError {
      throw loginError
    }
    return LocalServiceLoginResult(
      status: .loggingIn,
      accountID: nil,
      deviceID: nil,
      deviceGeneration: nil,
      authorizeURL: authorizeURL
    )
  }
  func cancelLogin() async throws {
    await cancelRecord?.record()
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

  func setGroupUsageByProject(enabled: Bool) async throws -> LocalServiceGroupUsageByProjectSetting {
    LocalServiceGroupUsageByProjectSetting(enabled: enabled)
  }
  func setQuotaRefreshInterval(seconds: Int) async throws -> LocalServiceQuotaRefreshIntervalSetting {
    LocalServiceQuotaRefreshIntervalSetting(intervalSeconds: seconds)
  }
  func setOverviewSourcePin(
    provider: ProviderID,
    fingerprint: String,
    scope: String,
    identitySourceID: String?,
    pin: String?
  ) async throws -> LocalServiceOverviewSourcePinSetting {
    let identityKey = "\(provider.rawValue)|\(fingerprint)|\(scope)|\(identitySourceID ?? "")"
    await pinRecord?.record(identitySourceID: identitySourceID, identityKey: identityKey, pin: pin)
    return LocalServiceOverviewSourcePinSetting(identityKey: identityKey, pin: pin)
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

  func setProviderBrowserScan(_ provider: ProviderID, enabled: Bool) async throws
    -> LocalServiceProviderBrowserScanSetting
  {
    LocalServiceProviderBrowserScanSetting(provider: provider, enabled: enabled)
  }

  func replaceProviderBrowserSessions(
    _ provider: ProviderID,
    cookieHeaders: [String],
    accessDenials: [BrowserAccessDenial]
  ) async throws {}

  func setAccountSettings(document: AccountSettingsDocument, ifMatch: String) async throws
    -> LocalServiceAccountSettingsWriteResult
  {
    if let accountSettingsWriteRecord {
      return try await accountSettingsWriteRecord.record(document: document, ifMatch: ifMatch)
    }
    return .written(document)
  }

  func refreshAccountSettings() async throws -> LocalServiceAccountSettingsState {
    if let accountSettingsWriteRecord {
      return try await accountSettingsWriteRecord.refresh()
    }
    throw LocalServiceClientError.invalidMessage
  }

  func shutdown() async {
    await shutdownGate?.wait()
    await shutdownRecord?.record()
  }
}
