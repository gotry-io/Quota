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
    #expect(try cache.load() == nil)
    #expect(transport.tokenPosts == 1)
    #expect(transport.recordedURLs.first?.path == "/oauth/v2/token")
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
    let activityQuery = URLComponents(
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
