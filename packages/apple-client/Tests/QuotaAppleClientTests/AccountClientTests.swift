import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire
import Testing

struct AccountClientTests {
  @Test
  func concurrent401sShareOneRefreshAndPersistRotatedTokens() async throws {
    let summary = try Fixtures.accountSummaryJSON()
    let transport = ScriptedTransport([
      .init(
        status: 401, body: try Fixtures.errorBody(code: "unauthorized"),
        delayNanoseconds: 20_000_000),
      .init(
        status: 401, body: try Fixtures.errorBody(code: "unauthorized"),
        delayNanoseconds: 20_000_000),
      .init(
        status: 401, body: try Fixtures.errorBody(code: "unauthorized"),
        delayNanoseconds: 20_000_000),
      .init(status: 200, body: try Fixtures.refreshResponse(), delayNanoseconds: 30_000_000),
      .init(status: 200, body: summary),
      .init(status: 200, body: summary),
      .init(status: 200, body: summary),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      calendar: Calendar(identifier: .gregorian),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    async let first = client.fetchTodaySummary()
    async let second = client.fetchTodaySummary()
    async let third = client.fetchTodaySummary()
    let results = await [first, second, third]
    #expect(results.allSatisfy { $0.error == nil && $0.summary != nil && $0.fromCache == false })
    #expect(transport.tokenPosts == 1)
    #expect(try sessions.load()?.accessToken == Fixtures.rotatedAccess)
    #expect(try sessions.load()?.refreshToken == Fixtures.rotatedRefresh)
    #expect(try cache.load()?.summary.account.displayLabel == "octocat")
  }

  /// One contract: a 304 is an answer. The stored summary stands, the read is not reported as
  /// coming from a failure, and the second request is the one that offered the validator.
  @Test
  func unchangedSummaryIsAnsweredFromTheStoredReadWithoutAnError() async throws {
    let summary = try Fixtures.accountSummaryJSON()
    let transport = ScriptedTransport([
      .init(status: 200, body: summary, headers: ["ETag": "\"stamp-one\""]),
      .init(status: 304, body: Data(), headers: ["ETag": "\"stamp-one\""]),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      calendar: Calendar(identifier: .gregorian),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let first = await client.fetchTodaySummary()
    #expect(first.error == nil)
    #expect(try cache.load()?.etag == "\"stamp-one\"")

    let second = await client.fetchTodaySummary()
    #expect(second.error == nil)
    #expect(second.fromCache == false)
    #expect(second.summary == first.summary)
    #expect(try cache.load()?.etag == "\"stamp-one\"")
    #expect(transport.recordedIfNoneMatch == [nil, "\"stamp-one\""])
  }

  @Test
  func invalidRefreshClearsSessionAndCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let transport = ScriptedTransport([
      .init(status: 401, body: try Fixtures.errorBody(code: "unauthorized")),
      .init(status: 400, body: try Fixtures.errorBody(code: "invalid_grant")),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchTodaySummary()
    #expect(result.error == .sessionExpired)
    #expect(try sessions.load() == nil)
    #expect(try cache.load() == nil)
    #expect(try await client.hasSession() == false)
  }

  @Test
  func loadCachedSummaryClearsOrphanedCacheWithoutSession() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: ScriptedTransport([])),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: cache
    )
    #expect(try await client.loadCachedSummary() == nil)
    #expect(try cache.load() == nil)
  }

  @Test
  func loadCachedSummaryClearsCacheForDifferentAccount() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON(accountID: "account_other")
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: ScriptedTransport([])),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: cache
    )
    #expect(try await client.loadCachedSummary() == nil)
    #expect(try cache.load() == nil)
  }

  @Test
  func loadCachedSummaryReturnsSameAccountLastGood() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: ScriptedTransport([])),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: cache
    )
    let loaded = try await client.loadCachedSummary()
    #expect(loaded?.summary.account.accountID == "account_01")
    #expect(try cache.load()?.summary.account.accountID == "account_01")
  }

  @Test
  func transientFailureDoesNotReturnMismatchedAccountCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON(accountID: "account_other")
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let transport = ScriptedTransport([
      .init(status: 503, body: try Fixtures.errorBody(code: "internal_error", message: "down"))
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchTodaySummary()
    #expect(result.error == .relay(.unavailable))
    #expect(result.summary == nil)
    #expect(result.fromCache == false)
    #expect(try sessions.load()?.accountID == "account_01")
    #expect(try cache.load() == nil)
  }

  @Test
  func lastGoodCacheSurvivesTransientFailureAndClearsOnLogout() async throws {
    let summaryData = try Fixtures.accountSummaryJSON()
    let transport = ScriptedTransport([
      .init(status: 200, body: summaryData),
      .init(status: 503, body: try Fixtures.errorBody(code: "internal_error", message: "down")),
      .init(status: 204),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let first = await client.fetchTodaySummary()
    #expect(first.fromCache == false)
    #expect(first.summary?.usage.today.totals.inputTokens == 1000)

    let second = await client.fetchTodaySummary()
    #expect(second.fromCache == true)
    #expect(second.summary?.usage.today.totals.inputTokens == 1000)
    #expect(second.error == .relay(.unavailable))

    await client.logout()
    #expect(try sessions.load() == nil)
    #expect(try cache.load() == nil)
    #expect(transport.recordedURLs.last?.path == "/oauth/v2/revoke")
  }

  @Test
  func refreshAccountMismatchKeepsPriorSessionAndCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let prior = Fixtures.session()
    let transport = ScriptedTransport([
      .init(status: 401, body: try Fixtures.errorBody(code: "unauthorized")),
      .init(
        status: 200, body: try Fixtures.refreshResponse(extra: ["account_id": "account_other"])),
    ])
    let sessions = MemoryAccountSessionStore(session: prior)
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchTodaySummary()
    #expect(result.error == .accountMismatch)
    #expect(result.fromCache == true)
    #expect(result.summary?.account.accountID == "account_01")
    #expect(try sessions.load() == prior)
    #expect(try cache.load()?.fetchedAt == cached.fetchedAt)
    #expect(try cache.load()?.summary.account.accountID == "account_01")
  }

  @Test
  func summaryAccountMismatchKeepsPriorSessionAndCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let prior = Fixtures.session()
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON(accountID: "account_other"))
    ])
    let sessions = MemoryAccountSessionStore(session: prior)
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchTodaySummary()
    #expect(result.error == .accountMismatch)
    #expect(result.fromCache == true)
    #expect(result.summary?.account.accountID == "account_01")
    #expect(try sessions.load() == prior)
    #expect(try cache.load()?.fetchedAt == cached.fetchedAt)
    #expect(try cache.load()?.summary.account.displayLabel == "octocat")
  }

  @Test
  func appleSignInPostsTheSignedTokenAndKeepsAPendingSession() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.tokenResponse())
    ])
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache
    )
    let nonce = try AppleSignIn.generateNonce()
    let identityToken = "\(String(repeating: "a", count: 20)).\(String(repeating: "b", count: 40)).\(String(repeating: "c", count: 43))"

    let session = try await client.exchangeApple(identityToken: identityToken, nonce: nonce.value)
    #expect(session.accessToken == Fixtures.accessToken)
    // Which Account this reached is still the question the confirm screen asks.
    #expect(session.activation == .pending)
    #expect(try sessions.load()?.activation == .pending)
    #expect(try cache.load() == nil)
    #expect(transport.recordedURLs.map(\.path) == ["/oauth/v2/apple"])

    let body =
      try JSONSerialization.jsonObject(with: transport.recordedBodies[0]) as? [String: Any] ?? [:]
    #expect(body["client_id"] as? String == "quota-ios")
    // Apple was handed the digest; Relay is handed the value and digests it again.
    #expect(body["nonce"] as? String == nonce.value)
    #expect(body["identity_token"] as? String == identityToken)
    #expect(body["intent"] == nil)
  }

  @Test
  func linkingApplePostsTheIntentUnderTheSessionAndKeepsIt() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.identityLinkJSON())
    ])
    let sessions = MemoryAccountSessionStore()
    try sessions.save(Fixtures.session())
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore()
    )
    let nonce = try AppleSignIn.generateNonce()

    let response = try await client.linkApple(
      identityToken: Fixtures.identityToken,
      nonce: nonce.value
    )
    #expect(response.provider == .apple)
    #expect(response.status == .linked)
    #expect(transport.recordedURLs.map(\.path) == ["/oauth/v2/apple"])
    #expect(transport.recordedAuthorization == ["Bearer \(Fixtures.accessToken)"])
    let body =
      try JSONSerialization.jsonObject(with: transport.recordedBodies[0]) as? [String: Any] ?? [:]
    #expect(body["intent"] as? String == "link")
    // Binding a channel is not a sign-in: the session this device holds is untouched.
    #expect(try sessions.load()?.accessToken == Fixtures.accessToken)
  }

  @Test
  func linkingAppleWithoutASessionNeverReachesRelay() async throws {
    let transport = ScriptedTransport([])
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: MemoryAccountSummaryStore()
    )
    let nonce = try AppleSignIn.generateNonce()
    await #expect(throws: AccountClientError.notSignedIn) {
      _ = try await client.linkApple(identityToken: Fixtures.identityToken, nonce: nonce.value)
    }
    #expect(transport.recordedURLs.isEmpty)
  }

  @Test
  func identitiesAreReadUnderTheSessionAndNotStored() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.accountIdentitiesJSON())
    ])
    let sessions = MemoryAccountSessionStore()
    try sessions.save(Fixtures.session())
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache
    )

    let identities = try await client.fetchIdentities()
    #expect(identities.map(\.provider) == [.github, .apple])
    #expect(identities[0].label == "octocat")
    #expect(identities[1].label == nil)
    #expect(transport.recordedURLs.map(\.path) == ["/api/v2/account"])
    #expect(transport.recordedMethods == ["GET"])
    #expect(transport.recordedAuthorization == ["Bearer \(Fixtures.accessToken)"])
    // What may sign in to an Account is read when asked for; nothing keeps a copy of it.
    #expect(try cache.load() == nil)
  }

  @Test
  func appleSignInRefusesAnythingThatIsNotASignedToken() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.tokenResponse())
    ])
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: MemoryAccountSummaryStore()
    )
    let nonce = try AppleSignIn.generateNonce()
    await #expect(throws: AccountClientError.relay(.invalidResponse)) {
      _ = try await client.exchangeApple(identityToken: "not-a-jws", nonce: nonce.value)
    }
    #expect(transport.recordedURLs.isEmpty)
  }

  @Test
  func completeLoginExchangesOnceAndCachesNothingUntilSummary() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.tokenResponse())
    ])
    let sessions = MemoryAccountSessionStore()
    let cache = MemoryAccountSummaryStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache
    )
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(string: "https://quota.gotry.io/oauth/v2/authorize")!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )
    let callback = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!
    let session = try await client.completeLogin(callback: callback, expected: attempt)
    #expect(session.accessToken == Fixtures.accessToken)
    #expect(session.activation == .pending)
    #expect(try sessions.load()?.activation == .pending)
    #expect(try cache.load() == nil)
    #expect(transport.tokenPosts == 1)
    #expect(transport.recordedURLs.first?.path == "/oauth/v2/token")
  }

  @Test
  func aDeviceSessionReadsTheControlDocumentThenUploadsWhatItRead() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.deviceSync(generation: 4)),
      .init(status: 200, body: try Fixtures.uploadResponse(generation: 4)),
    ])
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(
        session: Fixtures.session(deviceID: "device_01")
      ),
      summaryStore: MemoryAccountSummaryStore()
    )

    #expect(await client.uploadSnapshots([Fixtures.localSnapshot()]) == nil)
    #expect(transport.recordedURLs.map(\.path) == [
      "/api/v2/device/sync",
      "/api/v6/device/snapshots",
    ])
    let envelope =
      try JSONSerialization.jsonObject(with: transport.recordedBodies[1]) as? [String: Any] ?? [:]
    // The generation is the one the control document just answered.
    #expect(envelope["generation"] as? Int == 4)
    #expect(envelope["protocol_version"] as? Int == 6)
    #expect((envelope["snapshots"] as? [[String: Any]])?.count == 1)
    #expect(!String(decoding: transport.recordedBodies[1], as: UTF8.self).contains("cookie"))
  }

  @Test
  func aSessionThatNamesNoDeviceHasNothingToUploadWith() async throws {
    let transport = ScriptedTransport([])
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: MemoryAccountSessionStore(session: Fixtures.session()),
      summaryStore: MemoryAccountSummaryStore()
    )

    #expect(await client.uploadSnapshots([Fixtures.localSnapshot()]) == .notADevice)
    #expect(transport.recordedURLs.isEmpty)
  }

  @Test
  func signingInPresentsAnInstallationOrNone() async throws {
    let transport = ScriptedTransport([
      .init(
        status: 200,
        body: try Fixtures.tokenResponse(
          extra: ["device_id": "device_01", "device_generation": 1]
        )
      ),
      .init(status: 200, body: try Fixtures.tokenResponse()),
    ])
    let sessions = MemoryAccountSessionStore()
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore()
    )
    let attempt = AuthorizationAttempt(
      authorizationURL: URL(string: "https://quota.gotry.io/oauth/v2/authorize")!,
      state: "client-state-123456789",
      verifier: String(repeating: "a", count: 43),
      challenge: "challenge"
    )
    let callback = URL(
      string:
        "io.gotry.quota:/oauth/callback?code=synthetic-login-code&state=client-state-123456789"
    )!

    let registered = try await client.completeLogin(
      callback: callback,
      expected: attempt,
      device: IosDeviceRegistration(
        installationID: "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998",
        displayName: "Kyle iPhone"
      )
    )
    #expect(registered.deviceID == "device_01")
    let asked =
      try JSONSerialization.jsonObject(with: transport.recordedBodies[0]) as? [String: Any] ?? [:]
    #expect(asked["installation_id"] as? String == "6eec1da2-8d8f-4e77-9a9a-3b6d61bf8998")
    #expect(asked["device_display_name"] as? String == "Kyle iPhone")
    #expect(asked["platform"] as? String == "ios")

    let reader = try await client.completeLogin(callback: callback, expected: attempt)
    #expect(reader.deviceID == nil)
    let second =
      try JSONSerialization.jsonObject(with: transport.recordedBodies[1]) as? [String: Any] ?? [:]
    #expect(second["installation_id"] == nil)
    #expect(second["platform"] == nil)
  }

  @Test
  func activateSessionPromotesPendingAndLeavesActiveUnchanged() async throws {
    let sessions = MemoryAccountSessionStore(session: Fixtures.session(activation: .pending))
    let client = AccountClient(
      relay: RelayClient(transport: ScriptedTransport([])),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore()
    )
    try await client.activateSession()
    #expect(try sessions.load()?.activation == .active)
    try await client.activateSession()
    #expect(try sessions.load()?.activation == .active)
  }

  @Test
  func activateSessionWithoutARecordIsNotSignedIn() async throws {
    let client = AccountClient(
      relay: RelayClient(transport: ScriptedTransport([])),
      sessionStore: MemoryAccountSessionStore(),
      summaryStore: MemoryAccountSummaryStore()
    )
    await #expect(throws: AccountClientError.notSignedIn) {
      try await client.activateSession()
    }
  }

  @Test
  func tokenRotationPreservesPendingActivation() async throws {
    let summary = try Fixtures.accountSummaryJSON()
    let transport = ScriptedTransport([
      .init(status: 401, body: try Fixtures.errorBody(code: "unauthorized")),
      .init(status: 200, body: try Fixtures.refreshResponse()),
      .init(status: 200, body: summary),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session(activation: .pending))
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: MemoryAccountSummaryStore(),
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )
    let result = await client.fetchTodaySummary()
    #expect(result.error == nil)
    #expect(try sessions.load()?.accessToken == Fixtures.rotatedAccess)
    #expect(try sessions.load()?.activation == .pending)
  }

  @Test
  func persistedSessionRequiresActivation() throws {
    let encoded = try WireCodec.encode(Fixtures.session())
    let object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    #expect(object["activation"] as? String == "active")
    let decoded = try WireCodec.decode(AccountSession.self, from: encoded)
    #expect(decoded.activation == .active)

    var missing = object
    missing.removeValue(forKey: "activation")
    let stripped = try JSONSerialization.data(withJSONObject: missing)
    #expect(throws: DecodingError.self) {
      _ = try WireCodec.decode(AccountSession.self, from: stripped)
    }
  }

  @Test
  func protectedFileCacheReplacesOnlyAfterCompleteDecode() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = ProtectedFileAccountSummaryStore(directory: directory)
    let summary = try WireCodec.decode(AccountSummary.self, from: try Fixtures.accountSummaryJSON())
    let cached = CachedAccountSummary(
      summary: summary, fetchedAt: Fixtures.date("2026-08-14T16:00:00Z"))
    try store.save(cached)
    #expect(try store.load()?.summary.account.accountID == "account_01")

    let encoded = try String(contentsOf: store.fileURL, encoding: .utf8)
    #expect(!encoded.contains("qia_"))
    #expect(!encoded.contains("qiar_"))
    #expect(!encoded.contains("access_token"))
    #expect(!encoded.contains("bucket_start_utc"))

    try Data("{\"unexpected\":true}".utf8).write(to: store.fileURL)
    #expect(throws: DecodingError.self) {
      _ = try store.load()
    }
    try store.clear()
    #expect(try store.load() == nil)
  }

  @Test
  func activity401RetriesOnceAfterRefreshAndDoesNotWriteCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let activity = try Fixtures.usageActivityJSON(days: [
      Fixtures.usageActivityDay(date: "2026-08-10")
    ])
    let transport = ScriptedTransport([
      .init(status: 401, body: try Fixtures.errorBody(code: "unauthorized")),
      .init(status: 200, body: try Fixtures.refreshResponse()),
      .init(status: 200, body: activity),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchUsageActivity(
      from: "2026-08-10",
      to: "2026-08-10",
      detail: .agents
    )
    guard case .activity(let response) = result else {
      Issue.record("expected activity, got \(result)")
      return
    }
    #expect(response.days.map(\.date) == ["2026-08-10"])
    #expect(transport.tokenPosts == 1)
    #expect(try sessions.load()?.accessToken == Fixtures.rotatedAccess)
    #expect(try sessions.load()?.refreshToken == Fixtures.rotatedRefresh)
    #expect(try cache.load()?.fetchedAt == cached.fetchedAt)
    #expect(try cache.load()?.summary.account.accountID == "account_01")
    #expect(
      transport.recordedURLs.map(\.path) == [
        "/api/v6/account/usage/activity",
        "/oauth/v2/token",
        "/api/v6/account/usage/activity",
      ])
    #expect(transport.recordedIfNoneMatch == [nil, nil, nil])
    let activityQuery =
      URLComponents(
        url: transport.recordedURLs[0], resolvingAgainstBaseURL: false
      )?.queryItems ?? []
    #expect(activityQuery.map(\.name) == ["from", "to", "detail"])
    #expect(activityQuery.last?.value == "agents")
  }

  @Test
  func activity401RefreshFailureDoesNotWriteCache() async throws {
    let cached = CachedAccountSummary(
      summary: try WireCodec.decode(
        AccountSummary.self,
        from: try Fixtures.accountSummaryJSON()
      ),
      fetchedAt: Fixtures.date("2026-08-14T15:00:00Z")
    )
    let transport = ScriptedTransport([
      .init(status: 401, body: try Fixtures.errorBody(code: "unauthorized")),
      .init(status: 400, body: try Fixtures.errorBody(code: "invalid_grant")),
    ])
    let sessions = MemoryAccountSessionStore(session: Fixtures.session())
    let cache = MemoryAccountSummaryStore(value: cached)
    let client = AccountClient(
      relay: RelayClient(transport: transport),
      sessionStore: sessions,
      summaryStore: cache,
      now: { Fixtures.date("2026-08-14T16:00:00Z") }
    )

    let result = await client.fetchUsageActivity(from: "2026-08-10", to: "2026-08-10")
    #expect(result == .failure(.sessionExpired))
    #expect(try sessions.load() == nil)
    #expect(try cache.load() == nil)
    #expect(
      transport.recordedURLs.map(\.path) == [
        "/api/v6/account/usage/activity",
        "/oauth/v2/token",
      ])
  }
}
