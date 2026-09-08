import AuthenticationServices
import Foundation
import QuotaAccount
import QuotaProviderSessions
import QuotaPresentation
import QuotaProviderStatus
import QuotaRelay
import QuotaWidgetData
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct AppModelTests {
  /// The verdict itself is `DeviceActivityTests` in `packages/apple-shared`; what the card owes
  /// it is both witnessed instants, so a device quiet for a day but reporting minutes ago is
  /// still active.
  @Test
  func deviceActivityUsesTheNewerOfLastSeenAndLastReading() {
    let now = Fixtures.date("2026-08-15T08:10:00Z")
    func device(lastSeenAt: Date?, lastObservedAt: Date? = nil) -> AccountDevice {
      AccountDevice(
        id: "device_01",
        displayName: "Studio Mac",
        platform: .macos,
        lastSeenAt: lastSeenAt,
        lastObservedAt: lastObservedAt
      )
    }

    #expect(device(lastSeenAt: now.addingTimeInterval(-300)).activity(now: now).status == .active)
    #expect(
      device(
        lastSeenAt: now.addingTimeInterval(-86_400),
        lastObservedAt: now.addingTimeInterval(-120)
      ).activity(now: now).status == .active)
    #expect(device(lastSeenAt: nil).activity(now: now).status == .notReporting)
  }

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
  @Test
  func cancellingAtAppleIsSignedOutWithNothingSaid() async {
    let model = makeModel(session: nil, cache: nil, exchanges: [])
    model.prepareAppleRequest(ASAuthorizationAppleIDProvider().createRequest())

    await model.connectWithApple(.failure(ASAuthorizationError(.canceled)))
    #expect(model.phase == .signedOut)
    #expect(model.banner == nil)
    #expect(model.expiredMessage == nil)
  }

  @Test
  func aFailedAppleSheetSaysTheOneConnectFailureSentence() async {
    let model = makeModel(session: nil, cache: nil, exchanges: [])
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
    #expect(publisher.clearCount == 1)
    #expect(publisher.publishCount == 0)
    // Nothing to read, so nothing to be woken for.
    #expect(scheduler.scheduleCount == 0)
    #expect(scheduler.cancelCount == 1)
  }

  /// A deliberate logout, or a first launch, is not an expiry. Connect with GitHub says only what
  /// it always says, and the background window nobody can use any more is withdrawn.
  @Test
  func refreshWithoutASessionIsPlainSignedOutAndWithdrawsTheBackgroundWindow() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let model = makeModel(
      session: nil,
      cache: nil,
      exchanges: [],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler
    )

    #expect(await model.refresh() == false)
    #expect(model.phase == .signedOut)
    #expect(model.expiredMessage == nil)
    #expect(model.banner == nil)
    #expect(scheduler.scheduleCount == 0)
    #expect(scheduler.cancelCount == 1)
  }

  @Test
  func refreshStoresLastGoodProviderStatusFromThisDevice() async {
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
    #expect(await model.refresh() == false)
    #expect(model.providerStatus[.claude]?.indicator == .minor)
    #expect(model.providerStatus[.claude]?.description == "Partial System Outage")
  }

  /// The helper polls every ten minutes; the foreground app holds the same timer.
  @Test
  func providerStatusForegroundCadenceMatchesTheHelper() {
    #expect(AppModel.providerStatusInterval == 600)
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
    #expect(client.refreshCount == 1)
    #expect(model.providerStatus[.claude]?.indicator == .minor)
    await model.setForeground(true)
    #expect(client.refreshCount == 1)
    await model.setForeground(false)
    await model.setForeground(true)
    #expect(client.refreshCount == 2)
    await model.setForeground(false)
  }

  @Test
  func restoreShowsCacheThenFreshSummary() async throws {
    let cachedSummary = try decodeSummary()
    let freshData = try mutatedSummaryLabel("fresh-label")
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = makeModel(
      session: Fixtures.session(),
      cache: CachedAccountSummary(
        summary: cachedSummary,
        fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
      ),
      exchanges: [.init(status: 200, body: freshData)],
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .signedIn)
    #expect(model.accountLabel == "fresh-label")
    #expect(model.fromCache == false)
    #expect(publisher.publishCount == 2)
    #expect(publisher.clearCount == 0)
    #expect(publisher.lastPublished?.fetchedAt == Fixtures.date("2026-08-14T16:00:00Z"))
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
  @Test
  func sharedRefreshRepublishesSnapshotAndSchedulesTheNextWindow() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let scheduler = RecordingBackgroundRefreshScheduler()
    let model = makeModel(
      session: Fixtures.session(),
      cache: nil,
      exchanges: [.init(status: 200, body: try Fixtures.accountSummaryJSON())],
      widgetPublisher: publisher,
      backgroundRefresh: scheduler
    )

    #expect(await model.refresh())
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 0)
    #expect(publisher.lastPublished?.fetchedAt == Fixtures.date("2026-08-14T16:00:00Z"))
    #expect(scheduler.scheduleCount == 1)
  }

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
    #expect(published != nil)

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
    model.sessionActivation = .active

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
    model.sessionActivation = .active

    await model.loadIdentities()
    #expect(model.identities == .failed)
    #expect(model.identities.identities.isEmpty)
  }

  @Test
  func managingSignInMethodsOpensTheWebsiteSignInWithSettingsAsTheReturn() async throws {
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
    model.sessionActivation = .active

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
  func presentDeleteAccountOpensNonEphemeralGitHubStartWithEncodedReturnTo() async {
    let authenticator = ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled))
    let model = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: ScriptedHTTPTransport([])),
        sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
        summaryStore: MemoryAccountSummaryStore(),
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: authenticator
    )

    await model.presentDeleteAccount()
    #expect(authenticator.lastPresentURL == QuotaWebLinks.deleteAccountStart)
    #expect(authenticator.lastPresentCallbackScheme == nil)
    #expect(authenticator.lastPresentPrefersEphemeral == false)
    #expect(
      authenticator.lastPresentURL?.absoluteString
        == "https://quota.gotry.io/sign-in?return_to=%2Fmy%2Fsettings%3Fdelete%3Daccount"
    )
  }

  @Test
  func useDifferentAccountRevokesThenReauthenticatesEphemerally() async throws {
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(
        string:
          "https://quota.gotry.io/oauth/v2/authorize?response_type=code&client_id=quota-ios&redirect_uri=io.gotry.quota:/oauth/callback&state=client-state-123456789&code_challenge=challenge&code_challenge_method=S256"
      )!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )
    let callback = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!
    let authenticator = ScriptedAuthenticator(results: [.success(callback), .success(callback)])
    let transport = ScriptedHTTPTransport([
      .init(status: 200, body: try tokenResponse()),
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(status: 204, body: Data()),
      .init(status: 200, body: try tokenResponse()),
      .init(status: 200, body: try mutatedSummaryLabel("othercat")),
    ])
    let account = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let model = AppModel(
      account: account,
      authenticator: authenticator,
      makeAuthorizationAttempt: { attempt }
    )

    await model.connectAccount()
    #expect(model.phase == .confirmingAccount(label: "octocat"))
    #expect(authenticator.prefersEphemeralHistory == [false])

    await model.useDifferentAccount()
    #expect(authenticator.prefersEphemeralHistory == [false, true])
    #expect(model.phase == .confirmingAccount(label: "othercat"))
    #expect(try await account.hasSession())
  }

  @Test
  func connectAccountFailureCopyNamesTheCause() async {
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(string: "https://quota.gotry.io/oauth/v2/authorize")!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )

    func model(throwing error: Error) -> AppModel {
      AppModel(
        account: AccountClient(
          relay: RelayClient(transport: ScriptedHTTPTransport([])),
          sessionStore: MemoryAccountSessionStore(),
          summaryStore: MemoryAccountSummaryStore(),
          now: { Fixtures.date("2026-08-14T16:00:00Z") }
        ),
        authenticator: ScriptedAuthenticator(result: .failure(error)),
        makeAuthorizationAttempt: { attempt }
      )
    }

    let unexpected = model(throwing: AuthorizationError.stateMismatch)
    await unexpected.connectAccount()
    #expect(unexpected.phase == .signedOut)
    #expect(unexpected.banner?.text == AuthorizationError.unexpectedBrowserResponseMessage)

    let unreachable = model(throwing: AccountClientError.relay(.unavailable))
    await unreachable.connectAccount()
    #expect(unreachable.banner?.text == "Couldn't reach quota.gotry.io.")

    let expired = model(throwing: AccountClientError.relay(.invalidGrant))
    await expired.connectAccount()
    #expect(expired.banner?.text == AuthorizationError.expiredSignInMessage)

    let generic = model(throwing: AccountClientError.accountMismatch)
    await generic.connectAccount()
    #expect(generic.banner?.text == "Couldn't connect. Try again.")
  }

  @Test
  func restorePendingSessionReopensConfirmationAndDoesNotSignIn() async throws {
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
  }

  @Test
  func continueAfterRestorePromotesTheSamePendingSession() async throws {
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let first = connectModel(
      sessions: sessions,
      cache: cache,
      exchanges: [
        .init(status: 200, body: try tokenResponse()),
        .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      ]
    )
    await first.model.connectAccount()

    let restored = AppModel(
      account: AccountClient(
        relay: RelayClient(transport: ScriptedHTTPTransport([])),
        sessionStore: sessions,
        summaryStore: cache,
        now: { Fixtures.date("2026-08-14T16:00:00Z") }
      ),
      authenticator: ScriptedAuthenticator(result: .failure(AuthorizationError.cancelled))
    )
    await restored.restore()
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
  }

  private var exchanges: [Exchange]

  init(_ exchanges: [Exchange]) {
    self.exchanges = exchanges
  }

  func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
    guard !exchanges.isEmpty else { throw HTTPTransportError.unavailable }
    let exchange = exchanges.removeFirst()
    let url = request.url ?? URL(string: "https://quota.gotry.io")!
    let response = HTTPURLResponse(
      url: url,
      statusCode: exchange.status,
      httpVersion: "HTTP/1.1",
      headerFields: nil
    )!
    return (exchange.body, response)
  }
}

@MainActor
func makeModel(
  session: AccountSession?,
  cache: CachedAccountSummary?,
  exchanges: [ScriptedHTTPTransport.Exchange],
  widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
  backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler(),
  alertCoordinator: AlertCoordinator? = nil,
  alertRulesStore: IOSAlertRulesStore? = nil,
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
    now: now
  )
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
    makeAuthorizationAttempt: { connectAttempt() }
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
        "access_expires_at": "2026-08-14T12:15:00Z",
        "refresh_token": Fixtures.refreshToken,
        "refresh_expires_at": "2026-11-01T12:00:00Z",
      ],
    ]
  )
}

enum Fixtures {
  static let accessToken = "qia_synthetic_access_token"
  static let refreshToken = "qiar_synthetic_refresh_token"

  static func session(
    activation: AccountSessionActivation = .active,
    deviceID: String? = nil
  ) -> AccountSession {
    AccountSession(
      accountID: "account_01",
      deviceID: deviceID,
      accessToken: accessToken,
      accessExpiresAt: date("2026-08-14T12:15:00Z"),
      refreshToken: refreshToken,
      refreshExpiresAt: date("2026-11-01T12:00:00Z"),
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
