import Foundation
import QuotaAccount
import QuotaRelay
import QuotaWire
import Testing

@testable import Quota

@MainActor
struct AppModelTests {
  @Test
  func remoteDeviceActivityUsesTheNewerOfLastSeenAndLastReading() {
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

    #expect(
      RemoteDeviceActivity.make(
        for: device(lastSeenAt: now.addingTimeInterval(-300)), now: now).status == .active)
    // A device that has not called in a day can still have sent a reading minutes ago.
    #expect(
      RemoteDeviceActivity.make(
        for: device(
          lastSeenAt: now.addingTimeInterval(-86_400),
          lastObservedAt: now.addingTimeInterval(-120)
        ),
        now: now).status == .active)
    #expect(
      RemoteDeviceActivity.make(
        for: device(lastSeenAt: now.addingTimeInterval(-3 * 3_600)), now: now).status == .idle)
    #expect(
      RemoteDeviceActivity.make(
        for: device(lastSeenAt: now.addingTimeInterval(-3 * 86_400)), now: now).status
        == .notReporting)
    #expect(
      RemoteDeviceActivity.make(for: device(lastSeenAt: nil), now: now).status == .notReporting)
  }

  @Test
  func restoreSignedOutWithoutSession() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
    let model = makeModel(session: nil, cache: nil, exchanges: [], widgetPublisher: publisher)
    await model.restore()
    #expect(model.phase == .signedOut)
    #expect(model.summary == nil)
    #expect(publisher.clearCount == 1)
    #expect(publisher.publishCount == 0)
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
    #expect(model.banner?.text.contains("saved account data") == true)
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
    #expect(model.banner?.text == "Could not refresh account data. Pull to try again.")
    #expect(model.banner?.text.contains("saved account data") != true)
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
    #expect(model.banner?.text == "Could not refresh account data. Pull to try again.")
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
    #expect(model.banner?.text == "Could not refresh account data. Pull to try again.")
    #expect(publisher.publishCount == 0)
    #expect(publisher.clearCount == 1)
  }

  @Test
  func expiredSessionReturnsToConnect() async throws {
    let publisher = RecordingWidgetSnapshotPublisher()
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
      widgetPublisher: publisher
    )
    await model.restore()
    #expect(model.phase == .signedOut)
    #expect(model.expiredMessage?.contains("Session expired") == true)
    #expect(model.summary == nil)
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 1)
    #expect(publisher.lastPublished == nil)
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
      makeAuthorizationAttempt: { attempt }
    )

    await model.connectAccount()
    #expect(authenticator.lastURL == attempt.authorizationURL)
    #expect(authenticator.lastCallbackScheme == QuotaIOSOAuth.callbackScheme)
    #expect(model.phase == .signedIn)
    #expect(model.summary?.account.displayLabel == "octocat")
    #expect(model.fromCache == false)
    #expect(publisher.publishCount == 1)
    #expect(publisher.clearCount == 0)

    await model.logout()
    #expect(model.phase == .signedOut)
    #expect(model.summary == nil)
    #expect(try await account.hasSession() == false)
    #expect(publisher.clearCount == 1)
    #expect(publisher.lastPublished == nil)
  }
}

@MainActor
private final class ScriptedAuthenticator: BrowserSessionAuthenticating {
  var result: Result<URL, Error>
  var lastURL: URL?
  var lastCallbackScheme: String?

  init(result: Result<URL, Error>) {
    self.result = result
  }

  func authenticate(url: URL, callbackScheme: String) async throws -> URL {
    lastURL = url
    lastCallbackScheme = callbackScheme
    return try result.get()
  }
}

private final class ScriptedHTTPTransport: HTTPTransport, @unchecked Sendable {
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
private func makeModel(
  session: AccountSession?,
  cache: CachedAccountSummary?,
  exchanges: [ScriptedHTTPTransport.Exchange],
  widgetPublisher: any WidgetSnapshotPublishing = NoOpWidgetSnapshotPublisher(),
  backgroundRefresh: any BackgroundRefreshScheduling = NoOpBackgroundRefreshScheduler()
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
    backgroundRefresh: backgroundRefresh
  )
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

private enum Fixtures {
  static let accessToken = "qia_synthetic_access_token"
  static let refreshToken = "qiar_synthetic_refresh_token"

  static func session() -> AccountSession {
    AccountSession(
      accountID: "account_01",
      accessToken: accessToken,
      accessExpiresAt: date("2026-08-14T12:15:00Z"),
      refreshToken: refreshToken,
      refreshExpiresAt: date("2026-11-01T12:00:00Z")
    )
  }

  static func date(_ value: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: value)!
  }

  static func accountSummaryJSON(accountID: String = "account_01") throws -> Data {
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
        "devices": [],
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
