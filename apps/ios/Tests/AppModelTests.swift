import AuthenticationServices
import Foundation
import QuotaAccount
import QuotaAlertDelivery
import QuotaAlerts
import QuotaProviderSessions
import QuotaPresentation
import QuotaProviderStatus
import QuotaProviderWeb
import QuotaRelay
import QuotaWidgetData
import QuotaWire
import Testing
import UserNotifications
import os

@testable import Quota

@MainActor
struct AppModelTests {
  /// Apple is handed the nonce's digest and this device keeps the value, so a token minted for
  /// some earlier request proves nothing about this one.
  @Test
  func appleRequestAsksForTheAddressAndCarriesADigestedNonce() {
    let model = makeModel(session: nil, cache: nil, exchanges: [])
    let request = ASAuthorizationAppleIDProvider().createRequest()

    model.prepareAppleRequest(request)
    #expect(request.requestedScopes == [.fullName, .email])
    let nonce = request.nonce ?? ""
    #expect(nonce.count == 64)
    #expect(nonce.allSatisfy { $0.isHexDigit && !$0.isUppercase })

    let second = ASAuthorizationAppleIDProvider().createRequest()
    model.prepareAppleRequest(second)
    #expect(second.nonce != request.nonce)
  }

  /// Cancelling at Apple is where the person started, not a failure with a sentence under it.
  /// A sheet that failed is, and says the one connect sentence.
  @Test
  func cancellingAtAppleSaysNothingAndAFailedSheetSaysTheConnectSentence() async {
    let model = makeModel(session: nil, cache: nil, exchanges: [])
    model.prepareAppleRequest(ASAuthorizationAppleIDProvider().createRequest())

    await model.connectWithApple(.failure(ASAuthorizationError(.canceled)))
    #expect(model.phase == .signedOut)
    #expect(model.banner == nil)
    #expect(model.expiredMessage == nil)

    model.prepareAppleRequest(ASAuthorizationAppleIDProvider().createRequest())
    await model.connectWithApple(.failure(ASAuthorizationError(.failed)))
    #expect(model.phase == .signedOut)
    #expect(model.banner?.text == AuthorizationError.genericConnectFailureMessage)
  }

  /// A result arriving with no request behind it is not this device's round trip.
  @Test
  func anAppleResultWithoutARequestProvesNothing() async {
    let model = makeModel(session: nil, cache: nil, exchanges: [])

    await model.connectWithApple(.failure(ASAuthorizationError(.canceled)))
    #expect(model.phase == .signedOut)
    #expect(model.banner?.text == AuthorizationError.genericConnectFailureMessage)
  }

  @Test
  func restoreSignedOutWithoutSession() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler
    )
    await model.restore()
    #expect(model.phase == .signedOut)
    #expect(model.summary == nil)
    // A first launch is not an expiry: nothing is said.
    #expect(model.expiredMessage == nil)
    #expect(model.banner == nil)
    #expect(publisher.clearCount == 1)
    #expect(publisher.publishCount == 0)
    // Nothing to read, so nothing to be woken for.
    #expect(scheduler.scheduleCount == 0)
    #expect(scheduler.cancelCount == 1)
  }

  @Test
  func enteringForegroundPollsProviderStatusAndBackgroundStopsTheTimer() async {
    let client = ScriptedProviderStatusClient(
      readings: [
        ProviderStatusReading(
          provider: .claude,
          indicator: .minor,
          description: "Partial System Outage",
          checkedAt: Date(timeIntervalSince1970: 0)
        )
      ]
    )
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      providerStatusClient: client
    )
    await model.setForeground(true)
    await model.waitForDetachedLaunchWork()
    #expect(client.refreshCount == 1)
    #expect(model.providerStatus[.claude]?.indicator == .minor)
    await model.setForeground(true)
    await model.waitForDetachedLaunchWork()
    #expect(client.refreshCount == 1)
    await model.setForeground(false)
    await model.setForeground(true)
    await model.waitForDetachedLaunchWork()
    #expect(client.refreshCount == 2)
    await model.setForeground(false)
  }

  @Test
  func coldLaunchWithAFreshTokenAsksRelayOnceAndDoesNotWaitForStatus() async throws {
    let transport = ScriptedHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON())
    ])
    let hanging = HangingProviderStatusClient()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let range = UsageActivityCalendar.range(
      endingOn: UsageActivityCalendar.utcDay(from: now))
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: MemoryAccountSummaryStore(),
      usageStore: MemoryAccountUsageStore(
        value: CachedAccountUsage(
          accountID: "account_01",
          activity: CachedUsageActivity(
            from: range.from,
            to: range.to,
            etag: "\"a\"",
            fetchedAt: now,
            response: AccountUsageActivityResponse(days: [])
          )
        )
      ),
      now: { now }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      providerStatusClient: hanging,
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { now }
    )
    await model.restore()
    await model.setForeground(true)
    #expect(model.phase == .signedIn)
    #expect(model.summary != nil)
    #expect(transport.requests.map { $0.url?.path } == ["/api/v6/account/summary"])
  }

  @Test
  func coldLaunchWithAnExpiredTokenRefreshesThenReadsSummary() async throws {
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let transport = ScriptedHTTPTransport([
      .init(status: 200, body: try tokenResponse()),
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
    ])
    let hanging = HangingProviderStatusClient()
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(
        session: Fixtures.session(accessExpiresAt: now.addingTimeInterval(-120))
      ),
      summaryStore: MemoryAccountSummaryStore(),
      now: { now }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      providerStatusClient: hanging,
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { now }
    )
    await model.restore()
    await model.setForeground(true)
    #expect(model.phase == .signedIn)
    #expect(transport.requests.map { $0.url?.path } == [
      "/oauth/v2/token",
      "/api/v6/account/summary",
    ])
  }

  @Test
  func cachedSummaryIsFirstContentBeforeTheSummaryRead() async throws {
    let cachedSummary = try decodeSummary()
    let freshData = try mutatedSummaryLabel("fresh-label")
    let hanging = HangingProviderStatusClient()
    let inner = ScriptedHTTPTransport([.init(status: 200, body: freshData)])
    let transport = GatedHTTPTransport(inner: inner, gatePath: "/api/v6/account/summary")
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: MemoryAccountSummaryStore(
        value: CachedAccountSummary(
          summary: cachedSummary,
          fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
        )
      ),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      providerStatusClient: hanging,
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    async let done: Void = model.restore()
    await model.waitForFirstContent()
    #expect(model.summary?.account.displayLabel == "octocat")
    #expect(model.hasContent)
    await transport.release()
    await done
    #expect(model.accountLabel == "fresh-label")
    #expect(model.fromCache == false)
  }

  @Test
  func unreadableKeychainDuringRefreshDoesNotSignOut() async throws {
    let cachedSummary = try decodeSummary()
    let sessions = UnreadableSessionStore()
    let account = AccountClient(
      relay: RelayClient(transport: ScriptedHTTPTransport([])),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore(
        value: CachedAccountSummary(
          summary: cachedSummary,
          fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
        )
      ),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    model.pose(
      phase: .signedIn,
      sessionActivation: .active,
      sessionDeviceID: nil,
      summary: cachedSummary,
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z"),
      fromCache: true,
      isRefreshing: false,
      banner: nil,
      expiredMessage: nil,
      localCollection: nil,
      localSamples: LocalQuotaSamples(),
      selectedTab: .quota,
      presentsSignIn: false,
      identities: .idle,
      providerStatus: [:],
      skipsRestore: true,
      isOfflineFixture: false,
      displayClockIsFixed: true
    )
    #expect(await model.refresh() == false)
    #expect(model.phase == .signedIn)
    #expect(model.summary?.account.displayLabel == "octocat")
    #expect(model.expiredMessage == nil)
  }

  @Test
  func unreadableKeychainWithLocalReadingsDoesNotPublishAPoorerWidget() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let now = Fixtures.date("2026-08-14T16:00:00Z")
    let snapshot = localSnapshot()
    let providerSessions = MemoryProviderSessionStore(
      sessions: [
        StoredProviderSession(
          provider: .codex,
          accountFingerprint: "fp",
          cookieHeader: "session=fp",
          accountLabel: nil,
          storedAt: now,
          lastValidatedAt: now
        )
      ]
    )
    let account = AccountClient(
      relay: RelayClient(transport: ScriptedHTTPTransport([])),
      sessionStore: UnreadableSessionStore(),
      summaryStore: MemoryAccountSummaryStore(),
      now: { now }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      widgetPublisher: publisher,
      providerSessions: providerSessions,
      localCollector: LocalCollector(
        sessions: providerSessions,
        collectors: { _, _ in FixedSnapshotCollector(snapshot: snapshot) },
        now: { now }
      ),
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { now }
    )
    model.pose(
      phase: .signedIn,
      sessionActivation: .active,
      sessionDeviceID: nil,
      summary: nil,
      fetchedAt: nil,
      fromCache: false,
      isRefreshing: false,
      banner: nil,
      expiredMessage: nil,
      localCollection: nil,
      localSamples: LocalQuotaSamples(),
      selectedTab: .quota,
      presentsSignIn: false,
      identities: .idle,
      providerStatus: [:],
      skipsRestore: true,
      isOfflineFixture: false,
      displayClockIsFixed: true
    )
    #expect(await model.refresh() == true)
    #expect(model.phase == .signedIn)
    #expect(publisher.publishCount == 0)
    #expect(publisher.lastPublished == nil)
  }

  @Test
  func signedInWithNoCacheShowsLoadingUntilTheFirstSummaryAnswers() async throws {
    let inner = ScriptedHTTPTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON())
    ])
    let transport = GatedHTTPTransport(inner: inner, gatePath: "/api/v6/account/summary")
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      providerStatusClient: HangingProviderStatusClient(),
      settingsDefaults: UserDefaults(suiteName: "QuotaTests.Launch.\(UUID().uuidString)")!,
      syncAccountSettings: false,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    async let done: Void = model.restore()
    await model.waitForFirstContent()
    await transport.waitUntilGated()
    #expect(model.phase == .signedIn)
    #expect(model.isRefreshing)
    #expect(model.showsRootLoading)
    await transport.release()
    await done
    #expect(!model.showsRootLoading)
    #expect(model.phase == .signedIn)
    #expect(model.summary != nil)
  }

  @Test
  func refreshFailureKeepsLastGoodAndSetsTextBanner() async throws {
    let cachedSummary = try decodeSummary()
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: cachedSummary,
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [.init(status: 503, body: Data())],
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .signedIn)
    #expect(model.summary?.account.displayLabel == "octocat")
    #expect(model.banner?.kind == .offlineCached)
    #expect(model.banner?.text == AppModel.Banner.cachedText)
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 0)
    #expect(publisher.lastPublished?.fetchedAt == Fixtures.date("2026-08-14T15:00:00Z"))
  }

  @Test
  func signedInRefreshFailureWithoutCacheShowsRetryCopy() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [.init(status: 503, body: Data())],
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .signedIn)
    #expect(model.summary == nil)
    #expect(model.banner?.kind == .refreshFailed)
    #expect(model.banner?.text == AppModel.Banner.failedText)
    #expect(model.banner?.text.contains("saved") != true)
    #expect(publisher.clearCount == 1)
    #expect(publisher.publishCount == 0)
  }

  @Test
  func refreshWithoutTrustedCacheClearsPreviouslyRenderedSummary() async throws {
    let cached = CachedAccountSummary(
      summary: try decodeSummary(),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let cache = MemoryAccountSummaryStore(value: cached)
    let publisher = RecordingWidgetSnapshotPublisher()
    let account = AccountClient(
      relay: RelayClient(
        transport: ScriptedHTTPTransport([
          .init(status: 200, body: try Fixtures.accountSummaryJSON()),
          .init(status: 503, body: Data()),
        ])
      ),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      widgetPublisher: publisher
    )

    await model.restore()
    #expect(model.summary != nil)
    #expect(publisher.publishCount == 2)

    try cache.clear()
    await model.refresh()
    #expect(model.summary == nil)
    #expect(model.fetchedAt == nil)
    #expect(model.fromCache == false)
    #expect(model.banner?.text == AppModel.Banner.failedText)
    #expect(publisher.clearCount == 1)
    #expect(publisher.lastPublished == nil)
  }

  @Test
  func restoreIgnoresMismatchedAccountCache() async throws {
    let foreign = try WireCodec.decode(
      AccountSummary.self,
      from: try Fixtures.accountSummaryJSON(accountID: "account_other")
    )
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: foreign,
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [.init(status: 503, body: Data())],
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .signedIn)
    #expect(model.summary == nil)
    #expect(model.banner?.text == AppModel.Banner.failedText)
    #expect(publisher.publishCount == 0)
    #expect(publisher.clearCount == 1)
  }

  /// An expired session still says so — it is the one status line Connect with GitHub has — and the
  /// standing background window goes with the session behind it.
  @Test
  func expiredSessionReturnsToConnect() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: try decodeSummary(),
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [
        .init(status: 401, body: Data()),
        .init(
          status: 400,
          body: try JSONSerialization.data(withJSONObject: [
            "error": ["code": "invalid_grant", "message": "Rejected."]
          ])
        ),
      ],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler
    )
    await model.restore()
    #expect(model.phase == .signedOut)
    #expect(model.expiredMessage == "Session expired. Connect again.")
    #expect(model.summary == nil)
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 1)
    #expect(publisher.lastPublished == nil)
    #expect(scheduler.scheduleCount == 0)
    #expect(scheduler.cancelCount == 1)
  }

  /// The refresh a background app refresh runs is the refresh the pull-to-refresh gesture runs:
  /// it republishes the widget snapshot from the read it just made and asks for the next window.
  /// A refresh that never reaches Relay reports failure — which is the success a background task
  /// completes with — and leaves the snapshot the widget is already drawing in place.
  @Test
  func sharedRefreshFailureKeepsThePublishedSnapshot() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [
        .init(status: 200, body: try mutatedSummaryLabel("fresh-label")),
        .init(status: 503, body: Data()),
      ],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler
    )

    #expect(await model.refresh())
    let published = publisher.lastPublished
    #expect(published?.fetchedAt == Fixtures.date("2026-08-14T16:00:00Z"))
    #expect(scheduler.scheduleCount == 1)

    #expect(await model.refresh() == false)
    #expect(model.summary?.account.displayLabel == "fresh-label")
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 0)
    #expect(publisher.lastPublished == published)
    #expect(scheduler.scheduleCount == 2)
  }

  @Test
  func signingInIsAskedBeforeAnythingIsOpened() async throws {
    let authenticator = ScriptedAuthenticator(results: [])
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: ScriptedHTTPTransport([])),
        sessionStore: MemoryAccountSessionStore(),
        summaryStore: MemoryAccountSummaryStore()
      ),
      authenticator: authenticator,
      makeAuthorizationAttempt: { connectAttempt() }
    )
    model.phase = .signedOut

    model.showSignIn()
    #expect(model.presentsSignIn)
    // The page offering every way in opens no browser by itself.
    #expect(authenticator.lastURL == nil)

    await model.connectAccount()
    #expect(model.presentsSignIn == false)
  }

  /// An emailed sign-in link is opened by the mail app, so Relay's redirect back to the app
  /// arrives as a URL open rather than through the session sheet that is still waiting.
  @Test
  func anEmailedSignInFinishesThroughTheAppCallbackAndEndsTheWaitingSheet() async throws {
    let authenticator = WaitingAuthenticator()
    let sessions = MemoryAccountSessionStore()
    let account = AccountClient(
      relay: RelayClient(
        transport: ScriptedHTTPTransport([
          .init(status: 200, body: try tokenResponse()),
          .init(status: 200, body: try Fixtures.accountSummaryJSON()),
        ])),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: authenticator,
      makeAuthorizationAttempt: { connectAttempt() }
    )
    let connecting = Task { await model.connectAccount() }
    while model.phase != .connecting {
      await Task.yield()
    }

    model.openDeepLink(
      URL(
        string:
          "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
      )!
    )
    while model.phase == .connecting {
      await Task.yield()
    }
    await connecting.value

    #expect(authenticator.cancelCount == 1)
    #expect(model.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)
    // The cancel that ends the sheet is not a sign-out: the callback already answered.
    #expect(model.summary?.account.displayLabel == "octocat")
  }

  @Test
  func anAuthorizationCallbackWithNothingWaitingForItSaysSo() async throws {
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: ScriptedHTTPTransport([])),
        sessionStore: MemoryAccountSessionStore(),
        summaryStore: MemoryAccountSummaryStore()
      ),
      authenticator: ScriptedAuthenticator(results: []),
      makeAuthorizationAttempt: { connectAttempt() }
    )
    model.phase = .signedOut

    model.openDeepLink(
      URL(
        string:
          "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
      )!
    )
    while model.banner == nil {
      await Task.yield()
    }
    #expect(model.banner?.text == AuthorizationError.genericConnectFailureMessage)
    #expect(model.phase == .signedOut)
  }

  @Test
  func signInMethodsAreReadUnderTheSessionAndClearedWithIt() async throws {
    let sessions = MemoryAccountSessionStore()
    try sessions.save(Fixtures.session())
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([
            .init(status: 200, body: try Fixtures.accountIdentitiesJSON())
          ])),
        sessionStore: sessions,
        summaryStore: MemoryAccountSummaryStore()
      ),
      authenticator: ScriptedAuthenticator(results: []),
      makeAuthorizationAttempt: { connectAttempt() }
    )
    model.poseSession(activation: .active)

    await model.loadIdentities()
    #expect(model.identities.identities.map(\.provider) == [.github, .apple])

    await model.logout()
    #expect(model.identities == .idle)
  }

  @Test
  func aFailedIdentitiesReadIsItsOwnStateRatherThanAnEmptyList() async throws {
    let sessions = MemoryAccountSessionStore()
    try sessions.save(Fixtures.session())
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([.init(status: 500, body: Data())])),
        sessionStore: sessions,
        summaryStore: MemoryAccountSummaryStore()
      ),
      authenticator: ScriptedAuthenticator(results: []),
      makeAuthorizationAttempt: { connectAttempt() }
    )
    model.poseSession(activation: .active)

    await model.loadIdentities()
    #expect(model.identities == .failed)
    #expect(model.identities.identities.isEmpty)
  }

  @Test
  func accountPagesOnTheWebOpenInTheSharedBrowserWithSettingsAsTheReturn() async throws {
    let sessions = MemoryAccountSessionStore()
    try sessions.save(Fixtures.session())
    let authenticator = ScriptedAuthenticator(results: [])
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([
            .init(status: 200, body: try Fixtures.accountIdentitiesJSON())
          ])),
        sessionStore: sessions,
        summaryStore: MemoryAccountSummaryStore()
      ),
      authenticator: authenticator,
      makeAuthorizationAttempt: { connectAttempt() }
    )
    model.poseSession(activation: .active)

    await model.presentSignInMethodsOnWeb()
    #expect(
      authenticator.lastPresentURL
        == URL(string: "https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings")
    )
    // Shared Safari cookies: the browser must be able to be signed in as this Account.
    #expect(authenticator.lastPresentCallbackScheme == nil)
    #expect(authenticator.lastPresentPrefersEphemeral == false)
    // What came back is read rather than assumed.
    #expect(model.identities.identities.map(\.provider) == [.github, .apple])

    await model.presentDeleteAccount()
    #expect(authenticator.lastPresentURL == QuotaWebLinks.deleteAccountStart)
    #expect(
      authenticator.lastPresentURL?.absoluteString
        == "https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount"
    )
    #expect(authenticator.lastPresentCallbackScheme == nil)
    #expect(authenticator.lastPresentPrefersEphemeral == false)
  }

  @Test
  func connectAccountFetchesFreshSummaryThenLogout() async throws {
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(
        string:
          "https://quota.gotry.io/oauth/v2/authorize?response_type=code&client_id=quota-ios&redirect_uri=io.gotry.quota:/oauth/callback&state=client-state-123456789&code_challenge=challenge&code_challenge_method=S256"
      )!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )
    let authenticator = ScriptedAuthenticator(
      result: .success(
        URL(
          string:
            "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
        )!
      )
    )
    let transport = ScriptedHTTPTransport([
      .init(status: 200, body: try tokenResponse()),
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 204, body: Data()),
    ])
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: authenticator,
      widgetPublisher: publisher,
      backgroundRefresh: scheduler,
      makeAuthorizationAttempt: { attempt }
    )

    await model.connectAccount()
    #expect(authenticator.lastURL == attempt.authorizationURL)
    #expect(authenticator.lastCallbackScheme == QuotaIOSOAuth.callbackScheme)
    #expect(authenticator.lastPrefersEphemeral == false)
    #expect(model.phase == .confirmingAccount(label: "octocat"))
    #expect(try await account.loadSession()?.activation == .pending)
    #expect(model.summary?.account.displayLabel == "octocat")
    #expect(model.fromCache == false)
    #expect(publisher.publishCount == 0)
    #expect(publisher.clearCount == 0)

    await model.confirmAccount()
    #expect(model.phase == .signedIn)
    #expect(try await account.loadSession()?.activation == .active)
    #expect(publisher.publishCount == 1)
    #expect(scheduler.scheduleCount == 1)

    await model.logout()
    #expect(model.phase == .signedOut)
    #expect(model.summary == nil)
    #expect(model.expiredMessage == nil)
    #expect(try await account.hasSession() == false)
    #expect(publisher.clearCount == 1)
    #expect(publisher.lastPublished == nil)
    // The pending request outlives the session unless it is cancelled.
    #expect(scheduler.cancelCount == 1)
  }

  @Test
  func logoutClearsTheSelectionSaltSoTheNextPublishGetsANewOne() async throws {
    let salt = Data(repeating: 0x11, count: 32)
    let saltStore = InMemorySelectionSaltStore(salt: salt) {
      Data(repeating: 0x22, count: 32)
    }
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: ScriptedHTTPTransport([])),
        sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
        summaryStore: MemoryAccountSummaryStore(),
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      widgetPublisher: publisher,
      selectionSaltStore: saltStore
    )

    #expect(try saltStore.loadOrCreate() == salt)
    await model.logout()
    #expect(model.phase == .signedOut)
    #expect(try saltStore.loadOrCreate() == Data(repeating: 0x22, count: 32))
  }

  @Test
  func restoringAPendingSessionReopensConfirmationAndOnlyContinuePromotesIt() async throws {
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let publisher = RecordingWidgetSnapshotPublisher()
    let first = connectModel(
      sessions: sessions,
      cache: cache,
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      ],
      widgetPublisher: publisher
    )
    await first.model.connectAccount()
    #expect(first.model.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)
    #expect(publisher.publishCount == 0)

    let restored = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([
            .init(status: 200, body: try Fixtures.accountSummaryJSON())
          ])
        ),
        sessionStore: sessions,
        summaryStore: cache,
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      widgetPublisher: publisher
    )
    await restored.restore()
    #expect(restored.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)
    #expect(publisher.publishCount == 0)

    await restored.refresh()
    #expect(restored.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)

    // Continue promotes the same pending session rather than asking for a new one.
    await restored.confirmAccount()
    #expect(restored.phase == .signedIn)
    #expect(try sessions.load()?.activation == .active)
  }

  @Test
  func useDifferentAccountAfterRestoreRevokesPendingAndDoesNotActivate() async throws {
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let callback = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!
    let authenticator = ScriptedAuthenticator(results: [.success(callback), .success(callback)])
    let first = connectModel(
      sessions: sessions,
      cache: cache,
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      ],
      authenticator: authenticator
    )
    await first.model.connectAccount()

    let restored = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([
            .init(status: 204, body: Data()),
            .init(status: 200, body: try tokenResponse()),
            .init(status: 200, body: try mutatedSummaryLabel("othercat")),
          ])
        ),
        sessionStore: sessions,
        summaryStore: cache,
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: authenticator,
      makeAuthorizationAttempt: { connectAttempt() }
    )
    await restored.restore()
    #expect(restored.phase == .confirmingAccount(label: "octocat"))
    await restored.useDifferentAccount()
    #expect(restored.phase == .confirmingAccount(label: "othercat"))
    #expect(try sessions.load()?.activation == .pending)
    #expect(authenticator.prefersEphemeralHistory == [false, true])
  }

  @Test
  func firstRefreshNetworkFailureKeepsPendingAndShowsRetryCopy() async throws {
    let sessions = MemoryAccountSessionStore()
    let connected = connectModel(
      sessions: sessions,
      cache: MemoryAccountSummaryStore(),
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 503, body: Data()),
      ]
    )
    await connected.model.connectAccount()
    #expect(connected.model.phase == .pendingRefreshFailed)
    #expect(connected.model.banner?.text == "Couldn't reach quota.gotry.io.")
    #expect(try sessions.load()?.activation == .pending)
    #expect(connected.model.phase != .confirmingAccount(label: "Account"))
  }

  @Test
  func firstRefreshRelayExpiredClearsPending() async throws {
    let sessions = MemoryAccountSessionStore()
    let connected = connectModel(
      sessions: sessions,
      cache: MemoryAccountSummaryStore(),
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(
          status: 401,
          body: try JSONSerialization.data(withJSONObject: [
            "error": ["code": "unauthorized", "message": "Rejected."]
          ])
        ),
        .init(
          status: 400,
          body: try JSONSerialization.data(withJSONObject: [
            "error": ["code": "invalid_grant", "message": "Rejected."]
          ])
        ),
      ]
    )
    await connected.model.connectAccount()
    #expect(connected.model.phase == .signedOut)
    #expect(connected.model.banner?.text == AuthorizationError.expiredSignInMessage)
    #expect(try sessions.load() == nil)
  }

  @Test
  func firstRefreshMalformedResponseKeepsPending() async throws {
    let sessions = MemoryAccountSessionStore()
    let connected = connectModel(
      sessions: sessions,
      cache: MemoryAccountSummaryStore(),
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: Data("{\"unexpected\":true}".utf8)),
      ]
    )
    await connected.model.connectAccount()
    #expect(connected.model.phase == .pendingRefreshFailed)
    #expect(connected.model.banner?.text == AuthorizationError.genericConnectFailureMessage)
    #expect(try sessions.load()?.activation == .pending)
  }

  @Test
  func firstRefreshBlankLabelKeepsPendingAndDoesNotConfirm() async throws {
    let sessions = MemoryAccountSessionStore()
    let connected = connectModel(
      sessions: sessions,
      cache: MemoryAccountSummaryStore(),
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: try summaryWithNullDisplayLabel()),
      ]
    )
    await connected.model.connectAccount()
    #expect(connected.model.phase == .pendingRefreshFailed)
    #expect(connected.model.banner?.text == AuthorizationError.genericConnectFailureMessage)
    #expect(try sessions.load()?.activation == .pending)
    if case .confirmingAccount = connected.model.phase {
      Issue.record("blank display label must not open confirmation")
    }
  }

  @Test
  func retryPendingIdentificationThenContinue() async throws {
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let connected = connectModel(
      sessions: sessions,
      cache: cache,
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 503, body: Data()),
        .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      ]
    )
    await connected.model.connectAccount()
    #expect(connected.model.phase == .pendingRefreshFailed)
    await connected.model.retryPendingIdentification()
    #expect(connected.model.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)
    await connected.model.confirmAccount()
    #expect(connected.model.phase == .signedIn)
    #expect(try sessions.load()?.activation == .active)
  }

  @Test
  func logoutRevokesAPendingSession() async throws {
    let sessions = MemoryAccountSessionStore()
    let connected = connectModel(
      sessions: sessions,
      cache: MemoryAccountSummaryStore(),
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: try Fixtures.accountSummaryJSON()),
        .init(status: 204, body: Data()),
      ]
    )
    await connected.model.connectAccount()
    #expect(try sessions.load()?.activation == .pending)
    await connected.model.logout()
    #expect(connected.model.phase == .signedOut)
    #expect(try sessions.load() == nil)
  }

  @Test
  func restorePendingWithoutLabelRetriesIdentification() async throws {
    let sessions = MemoryAccountSessionStore(session: Fixtures.session(activation: .pending))
    let cache = MemoryAccountSummaryStore()
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(
          transport: ScriptedHTTPTransport([
            .init(status: 200, body: try Fixtures.accountSummaryJSON())
          ])
        ),
        sessionStore: sessions,
        summaryStore: cache,
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled)),
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .confirmingAccount(label: "octocat"))
    #expect(try sessions.load()?.activation == .pending)
    #expect(publisher.publishCount == 0)
  }
}

@MainActor
final class ScriptedAuthenticator: BrowserSessionAuthenticating {
  private var results: [Result<URL, Error>]
  var lastURL: URL?
  var lastCallbackScheme: String?
  var lastPrefersEphemeral: Bool?
  var prefersEphemeralHistory: [Bool] = []

  init(result: Result<URL, Error>) {
    self.results = [result]
  }

  init(results: [Result<URL, Error>]) {
    self.results = results
  }

  func authenticate(
    url: URL,
    callbackScheme: String,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws -> URL {
    lastURL = url
    lastCallbackScheme = callbackScheme
    lastPrefersEphemeral = prefersEphemeralWebBrowserSession
    prefersEphemeralHistory.append(prefersEphemeralWebBrowserSession)
    guard !results.isEmpty else {
      throw AuthorizationError.cancelled
    }
    return try results.removeFirst().get()
  }

  var lastPresentURL: URL?
  var lastPresentCallbackScheme: String?
  var lastPresentPrefersEphemeral: Bool?

  func present(
    url: URL,
    callbackScheme: String?,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws {
    lastPresentURL = url
    lastPresentCallbackScheme = callbackScheme
    lastPresentPrefersEphemeral = prefersEphemeralWebBrowserSession
  }

  var cancelCount = 0

  func cancelPresentation() {
    cancelCount += 1
    cancel?()
  }

  /// What ending the sheet does, when a test needs the waiting `authenticate` to answer.
  var cancel: (@MainActor () -> Void)?
}

/// A sheet that stays up until it is cancelled, which is what an emailed sign-in leaves behind:
/// the verifying navigation happens in the system browser, so nothing ever comes back to it.
@MainActor
final class WaitingAuthenticator: BrowserSessionAuthenticating {
  private var waiter: CheckedContinuation<URL, Error>?
  var cancelCount = 0
  var lastPresentURL: URL?

  func authenticate(
    url: URL,
    callbackScheme: String,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
      waiter = continuation
    }
  }

  func present(
    url: URL,
    callbackScheme: String?,
    prefersEphemeralWebBrowserSession: Bool
  ) async throws {
    lastPresentURL = url
  }

  func cancelPresentation() {
    cancelCount += 1
    let waiter = waiter
    self.waiter = nil
    waiter?.resume(throwing: AuthorizationError.cancelled)
  }
}

final class ScriptedHTTPTransport: HTTPTransport, @unchecked Sendable {
  struct Exchange {
    var status: Int
    var body: Data
    var headers: [String: String]
    var delayNanoseconds: UInt64

    init(
      status: Int, body: Data, headers: [String: String] = [:], delayNanoseconds: UInt64 = 0
    ) {
      self.status = status
      self.body = body
      self.headers = headers
      self.delayNanoseconds = delayNanoseconds
    }
  }

  private var exchanges: [Exchange]
  private let autoAnswerAccountSettings: Bool
  private(set) var requests: [URLRequest] = []

  init(_ exchanges: [Exchange], autoAnswerAccountSettings: Bool = true) {
    self.exchanges = exchanges
    self.autoAnswerAccountSettings = autoAnswerAccountSettings
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    requests.append(request)
    if autoAnswerAccountSettings, request.url?.path == "/api/v2/account/settings" {
      let body = cannedAccountSettingsBody(for: request)
      let url = request.url ?? URL(string: "https://quota.gotry.io")!
      let etag = request.httpMethod == "PUT" ? "\"1\"" : "\"0\""
      let response = HTTPURLResponse(
        url: url,
        statusCode: 200,
        httpVersion: "HTTP/1.1",
        headerFields: ["ETag": etag]
      )!
      return (body, response)
    }
    guard !exchanges.isEmpty else { throw HTTPTransportError.unavailable }
    let exchange = exchanges.removeFirst()
    if exchange.delayNanoseconds > 0 {
      try await Task.sleep(nanoseconds: exchange.delayNanoseconds)
    }
    let url = request.url ?? URL(string: "https://quota.gotry.io")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: exchange.headers.isEmpty ? nil : exchange.headers
    )!
    return (exchange.body, response)
  }
}

func cannedAccountSettingsBody(for request: URLRequest) -> Data {
  if request.httpMethod == "PUT", let body = request.httpBody,
    let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
  {
    var response = object
    response["revision"] = 1
    response["updated_at"] = "2026-09-21T10:00:00Z"
    return (try? JSONSerialization.data(withJSONObject: response)) ?? defaultAccountSettingsGETBody()
  }
  return defaultAccountSettingsGETBody()
}

func defaultAccountSettingsGETBody() -> Data {
  Data(
    """
    {"protocol_version":2,"revision":0,"updated_at":"1970-01-01T00:00:00Z","alerts":{"reset_reminders":true,"pace_alerts":true,"thresholds":{}},"budget":{"amount_usd":null,"alerts":true}}
    """.utf8
  )
}

@MainActor
func makeModel(
  session: AccountSession?,
  cache: CachedAccountSummary?,
  exchanges: [ScriptedHTTPTransport.Exchange],
  widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
  backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler(),
  alertCoordinator: AlertCoordinator? = nil,
  alertRulesStore: AlertRulesStore? = nil,
  notificationCenter: (any NotificationCentering)? = nil,
  providerSessions: any ProviderSessionStoring = MemoryProviderSessionStore(),
  localStore: any LocalCollectionStoring = MemoryLocalCollectionStore(),
  localCollector: LocalCollector? = nil,
  providerStatusClient: any ProviderStatusServing = IdleProviderStatusClient(),
  now: @escaping @Sendable () -> Date = { Date() }
) -> AppModel {
  AppModel(
    account: AccountClient(
      relay: RelayClient(transport: ScriptedHTTPTransport(exchanges)),
      sessionStore: MemoryAccountSessionStore(session: session),
      summaryStore: MemoryAccountSummaryStore(value: cache),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    ),
    authenticator: ScriptedAuthenticator(
      result: .failure(AuthorizationError.cancelled)
    ),
    widgetPublisher: widgetPublisher,
    backgroundRefresh: backgroundRefresh,
    alertCoordinator: alertCoordinator,
    alertRulesStore: alertRulesStore,
    notificationCenter: notificationCenter,
    providerSessions: providerSessions,
    localStore: localStore,
    localCollector: localCollector
      ?? LocalCollector(sessions: providerSessions, collectors: { _, _ in nil }, now: now),
    providerStatusClient: providerStatusClient,
    settingsDefaults: UserDefaults(suiteName: "QuotaTests.SettingsSync.\(UUID().uuidString)")!,
    syncAccountSettings: false,
    now: now
  )
}

private final class HangingProviderStatusClient: ProviderStatusServing, @unchecked Sendable {
  private let count = OSAllocatedUnfairLock(initialState: 0)

  var refreshCount: Int {
    count.withLock { $0 }
  }

  func refresh() async -> [ProviderStatusReading] {
    count.withLock { $0 += 1 }
    try? await Task.sleep(for: .seconds(2))
    return []
  }
}

actor GatedHTTPTransport: HTTPTransport {
  let inner: ScriptedHTTPTransport
  let gatePath: String
  private var hold: CheckedContinuation<Void, Never>?
  private var gatedWaiters: [CheckedContinuation<Void, Never>] = []
  private var released = false
  private(set) var gated = false

  init(inner: ScriptedHTTPTransport, gatePath: String) {
    self.inner = inner
    self.gatePath = gatePath
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    if request.url?.path == gatePath {
      gated = true
      let waiters = gatedWaiters
      gatedWaiters.removeAll()
      for waiter in waiters {
        waiter.resume()
      }
      if !released {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          hold = continuation
        }
      }
    }
    return try await inner.perform(request)
  }

  func release() {
    released = true
    hold?.resume()
    hold = nil
  }

  func waitUntilGated() async {
    if gated { return }
    await withCheckedContinuation { gatedWaiters.append($0) }
  }
}

private struct FixedSnapshotCollector: ProviderWebCollector {
  static var provider: ProviderID { .codex }
  let snapshot: QuotaSnapshot

  func validate(cookieHeader: String) async throws -> ValidatedBrowserSession {
    ValidatedBrowserSession(accountFingerprint: "fp", accountLabel: nil)
  }

  func collect(cookieHeader: String) async throws -> QuotaSnapshot {
    snapshot
  }
}

private func localSnapshot() -> QuotaSnapshot {
  QuotaSnapshot(
    provider: .codex,
    account: QuotaAccount(fingerprint: "fp", fingerprintScope: .global),
    windows: [
      QuotaWindow(id: "weekly", title: "Weekly", usedPercent: 20, durationSeconds: 604_800)
    ],
    status: .available,
    observedAt: Fixtures.date("2026-08-14T16:00:00Z")
  )
}

private final class UnreadableSessionStore: AccountSessionStore, @unchecked Sendable {
  func load() throws -> AccountSession? { throw AccountStoreError.unreadable }
  func save(_ session: AccountSession) throws {}
  func clear() throws {}
}

private final class ScriptedProviderStatusClient: ProviderStatusServing, @unchecked Sendable {
  var readings: [ProviderStatusReading]
  private(set) var refreshCount = 0

  init(readings: [ProviderStatusReading]) {
    self.readings = readings
  }

  func refresh() async -> [ProviderStatusReading] {
    refreshCount += 1
    return readings
  }
}

private func decodeSummary() throws -> AccountSummary {
  try WireCodec.decode(AccountSummary.self, from: try Fixtures.accountSummaryJSON())
}

private func mutatedSummaryLabel(_ label: String) throws -> Data {
  var object =
    try JSONSerialization.jsonObject(with: try Fixtures.accountSummaryJSON())
    as! [String: Any]
  var account = object["account"] as! [String: Any]
  account["display_label"] = label
  object["account"] = account
  return try JSONSerialization.data(withJSONObject: object)
}

private func connectAttempt() -> AuthorizationAttempt {
  AuthorizationAttempt(
    authorizationURL: URL(
      string:
        "https://quota.gotry.io/oauth/v2/authorize?response_type=code&client_id=quota-ios&redirect_uri=io.gotry.quota:/oauth/callback&state=client-state-123456789&code_challenge=challenge&code_challenge_method=S256"
    )!,
    state: "client-state-123456789",
    verifier: String(repeating: "a", count: 43),
    challenge: "challenge"
  )
}

@MainActor
private func connectModel(
  sessions: MemoryAccountSessionStore,
  cache: MemoryAccountSummaryStore,
  exchanges: [ScriptedHTTPTransport.Exchange],
  authenticator: ScriptedAuthenticator? = nil,
  widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher()
) -> (model: AppModel, account: AccountClient) {
  let callback = URL(
    string:
      "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
  )!
  let account = AccountClient(
    relay: RelayClient(transport: ScriptedHTTPTransport(exchanges)),
    sessionStore: sessions,
    summaryStore: cache,
    now: { Fixtures.date("2026-08-14T16:00:00Z") }
  )
  let model = AppModel(
    account: account,
    authenticator: authenticator
      ?? ScriptedAuthenticator(result: .success(callback)),
    widgetPublisher: widgetPublisher,
    makeAuthorizationAttempt: { connectAttempt() },
    settingsDefaults: UserDefaults(suiteName: "QuotaTests.SettingsSync.\(UUID().uuidString)")!,
    syncAccountSettings: false
  )
  return (model, account)
}

private func summaryWithNullDisplayLabel() throws -> Data {
  var object =
    try JSONSerialization.jsonObject(with: try Fixtures.accountSummaryJSON())
    as! [String: Any]
  var account = object["account"] as! [String: Any]
  account["display_label"] = NSNull()
  object["account"] = account
  return try JSONSerialization.data(withJSONObject: object)
}

private func tokenResponse() throws -> Data {
  try JSONSerialization.data(
    withJSONObject: [
      "protocol_version": 2,
      "token_type": "Bearer",
      "account_id": "account_01",
      "session": [
        "access_token": Fixtures.accessToken,
        "access_expires_at": "2999-01-01T00:00:00Z",
        "refresh_token": Fixtures.refreshToken,
        "refresh_expires_at": "2999-01-01T00:00:00Z",
      ],
    ]
  )
}

enum Fixtures {
  static let accessToken = "qia_synthetic_access_token"
  static let refreshToken = "qiar_synthetic_refresh_token"

  static func session(
    accountID: String = "account_01",
    activation: AccountSessionActivation = .active,
    deviceID: String? = nil,
    accessExpiresAt: Date? = nil
  ) -> AccountSession {
    AccountSession(
      accountID: accountID,
      deviceID: deviceID,
      accessToken: accessToken,
      accessExpiresAt: accessExpiresAt ?? date("2999-01-01T00:00:00Z"),
      refreshToken: refreshToken,
      refreshExpiresAt: date("2999-01-01T00:00:00Z"),
      activation: activation
    )
  }

  static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  static func accountIdentitiesJSON() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
      "protocol_version": 2,
      "account": [
        "account_id": "account_01",
        "display_label": "octocat",
        "created_at": "2026-01-04T12:00:00Z",
      ],
      "identities": [
        ["provider": "github", "label": "octocat", "linked_at": "2026-01-04T12:00:00Z"],
        ["provider": "apple", "label": NSNull(), "linked_at": "2026-02-04T12:00:00Z"],
      ],
    ])
  }

  static func accountSummaryJSON(
    accountID: String = "account_01",
    devices: [[String: Any]] = []
  ) throws -> Data {
    let period: [String: Any] = [
      "totals": [
        "total_tokens": 1200,
        "input_tokens": 1000,
        "output_tokens": 200,
        "cache_read_input_tokens": 100,
        "cache_write_input_tokens": 0,
        "reasoning_tokens": 50,
        "messages": 1,
      ] as [String: Any],
      "cost": [
        "mode": "calculate",
        "basis": "calculated",
        "status": "complete",
        "amount_microusd": "3138",
        "catalog_revision": "pricing_1",
        "calculated_rows": 1,
        "reported_rows": 0,
        "unpriced_rows": 0,
        "assumptions": ["agent_default_channel"],
        "unpriced": [],
      ] as [String: Any],
      "cache_saved": [
        "amount_microusd": "0",
        "status": "complete",
        "unpriced_rows": 0,
      ] as [String: Any],
      "partial": false,
      "agents": [],
    ]
    return try JSONSerialization.data(
      withJSONObject: [
        "protocol_version": 6,
        "account": [
          "account_id": accountID,
          "display_label": "octocat",
          "created_at": "2026-07-01T00:00:00Z",
        ],
        "devices": devices,
        "subscriptions": [],
        "usage": [
          "today": period,
          "last_7_days": period,
          "last_30_days": period,
          "all": period,
        ],
        "pricing_revision": "pricing_1",
        "model_catalog_revision": "models_1",
      ] as [String: Any]
    )
  }
}
