import Foundation
import QuotaAlerts
import QuotaPresentation
import QuotaRelay
import QuotaWire
import Testing

struct RelayClientTests {
  /// What this client can reach. The device routes are the phone's own Device and nothing more:
  /// its readings and the control document behind them
  /// ([ADR 0041](../../../../docs/decisions/0041-ios-is-a-device-when-sync-is-paid.md)). Usage is
  /// a Mac's. Account management stays the browser's, except the settings document
  /// ([ADR 0061](../../../../docs/decisions/0061-alert-policy-and-the-budget-follow-the-account.md)).
  @Test
  func publicAPIReachesOnlyThisDeviceAndTheAccountReads() {
    #expect(
      Set(RelayRoute.allCases.map(\.path)) == [
        "/oauth/v2/token",
        "/oauth/v2/apple",
        "/oauth/v2/revoke",
        "/api/v2/account",
        "/api/v6/account/summary",
        "/api/v6/account/collection-request",
        "/api/v2/account/settings",
        "/api/v6/account/usage/activity",
        "/api/v6/account/usage/period",
        "/api/v2/device/sync",
        "/api/v6/device/snapshots",
        "/api/v2/providers/status",
        "/api/v6/device/quota-history",
        "/api/v6/account/quota-history",
      ])
    #expect(RelayRoute.allCases.allSatisfy { !$0.path.contains("/device/usage") })
    #expect(RelayRoute.allCases.allSatisfy { !$0.path.contains("/account/devices") })
    #expect(!RelayRoute.allCases.contains { $0.method == "DELETE" })
    #expect(
      Set(RelayRoute.allCases.filter { $0.method == "PUT" }.map(\.path)) == [
        "/api/v2/account/settings",
        "/api/v6/device/snapshots",
        "/api/v6/device/quota-history",
      ])
  }

  @Test
  func requestsStayOnTheFixedOriginAndRejectRedirects() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.accountSummaryJSON()),
      .init(
        status: 302,
        body: Data(),
        headers: ["Location": "https://evil.example/steal"]
      ),
    ])
    let client = RelayClient(transport: transport)
    _ = try await client.fetchAccountSummary(
      timeZone: "UTC",
      accessToken: Fixtures.accessToken
    )
    await #expect(throws: RelayClientError.redirectRefused) {
      _ = try await client.fetchAccountSummary(
        timeZone: "UTC",
        accessToken: Fixtures.accessToken
      )
    }

    #expect(
      transport.recordedURLs.allSatisfy { url in
        url.scheme == "https" && url.host == "quota.gotry.io"
          && (url.port == nil || url.port == 443)
      })
    #expect(transport.recordedURLs.first?.path == "/api/v6/account/summary")
    let query =
      URLComponents(url: transport.recordedURLs[0], resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    // One read, one contract: the calendar this device keeps and nothing to negotiate.
    #expect(items["tz"] == "UTC")
    for retired in [
      "usage_agents", "usage_clients", "model_catalog", "usage_channels", "cost_mode", "from",
      "to",
    ] {
      #expect(items[retired] == nil)
    }
    #expect(transport.recordedAuthorization.first == "Bearer \(Fixtures.accessToken)")
  }

  @Test
  func refusesResponsesOverOneMebibyte() async throws {
    let oversized = Data(repeating: 0x61, count: WireCodec.maximumResponseBytes + 1)
    let transport = ScriptedTransport([.init(status: 200, body: oversized)])
    let client = RelayClient(transport: transport)
    await #expect(throws: RelayClientError.responseTooLarge) {
      _ = try await client.fetchAccountSummary(
        timeZone: "UTC",
        accessToken: Fixtures.accessToken
      )
    }
  }

  @Test
  func exchangeAndRefreshStayOnTokenRoute() async throws {
    let transport = ScriptedTransport([
      .init(status: 200, body: try Fixtures.tokenResponse()),
      .init(status: 200, body: try Fixtures.refreshResponse()),
      .init(status: 204),
    ])
    let client = RelayClient(transport: transport)
    let exchanged = try await client.exchangeAuthorizationCode(
      code: "synthetic-login-code",
      verifier: String(repeating: "a", count: 43)
    )
    #expect(exchanged.accountID == "account_01")
    let refreshed = try await client.refreshSession(refreshToken: Fixtures.refreshToken)
    #expect(refreshed.session.accessToken == Fixtures.rotatedAccess)
    try await client.revokeSession(refreshToken: Fixtures.rotatedRefresh)
    #expect(
      transport.recordedURLs.map(\.path) == [
        "/oauth/v2/token",
        "/oauth/v2/token",
        "/oauth/v2/revoke",
      ])
    #expect(transport.recordedAuthorization.last == "Bearer \(Fixtures.rotatedRefresh)")
    let exchangeBody = String(data: transport.recordedBodies.first ?? Data(), encoding: .utf8) ?? ""
    #expect(exchangeBody.contains("\"client_id\""))
    #expect(exchangeBody.contains("\"redirect_uri\""))
    #expect(exchangeBody.contains("\"code_verifier\""))
    #expect(!exchangeBody.contains("\"clientId\""))
  }

  /// A malformed date or an unknown zone is refused here, before a bearer leaves the device.
  @Test
  func aMalformedDateOrZoneIsRefusedBeforeAnythingIsSent() async {
    let transport = ScriptedTransport([])
    let client = RelayClient(transport: transport)
    await #expect(throws: RelayClientError.invalidQuery) {
      _ = try await client.fetchAccountUsageActivity(
        accessToken: Fixtures.accessToken,
        from: "2026-8-10",
        to: "2026-08-10"
      )
    }
    await #expect(throws: RelayClientError.invalidQuery) {
      _ = try await client.fetchAccountUsageActivity(
        accessToken: Fixtures.accessToken,
        from: "2026-08-10",
        to: "not-a-date"
      )
    }
    await #expect(throws: RelayClientError.invalidQuery) {
      _ = try await client.fetchAccountUsagePeriod(
        from: "2026-8-10",
        to: "2026-08-10",
        timezone: "UTC",
        accessToken: Fixtures.accessToken
      )
    }
    await #expect(throws: RelayClientError.invalidQuery) {
      _ = try await client.fetchAccountUsagePeriod(
        from: "2026-08-10",
        to: "2026-08-10",
        timezone: "Not/AZone",
        accessToken: Fixtures.accessToken
      )
    }
    #expect(transport.recordedURLs.isEmpty)
  }

  @Test
  func providersStatusIsUnauthenticatedAndDecodesCatalogRows() async throws {
    let body = Data(
      """
      {"providers":[{"id":"claude","indicator":"minor","description":"Partial System Outage","checked_at":"2026-08-14T16:00:00Z"},{"id":"codex","indicator":"unknown","description":"","checked_at":"2026-08-14T16:00:00Z"}]}
      """.utf8)
    let transport = ScriptedTransport([.init(status: 200, body: body)])
    let client = RelayClient(transport: transport)
    let response = try await client.fetchProviderStatus()
    #expect(response.providers.map(\.id) == [.claude])
    #expect(response.providers.first?.indicator == .minor)
    #expect(transport.recordedURLs.map(\.path) == ["/api/v2/providers/status"])
    #expect(transport.recordedAuthorization == [nil])
  }

  @Test
  func settingsWriteSendsIfMatchAndReturnsThe412BodyAsTheCurrentDocument() async throws {
    let written = Fixtures.accountSettingsJSON(
      revision: 1,
      thresholds: ["a1b2c3d4e5f6": [20, 10]],
      amountUSD: "250.00"
    )
    let conflict = Fixtures.accountSettingsJSON(
      revision: 2,
      thresholds: ["a1b2c3d4e5f6": [20, 10], "c3d4e5f6a1b2": [15]],
      amountUSD: "75.50"
    )
    let transport = ScriptedTransport([
      .init(status: 200, body: written, headers: ["ETag": "\"1\""]),
      .init(status: 412, body: conflict, headers: ["ETag": "\"2\""]),
    ])
    let client = RelayClient(transport: transport)
    let request = try AccountSettingsDocument.decode(written)

    let first = try await client.writeAccountSettings(
      request,
      accessToken: Fixtures.accessToken,
      ifMatch: "\"0\""
    )
    guard case .written(let document, let etag) = first else {
      Issue.record("expected written, got \(first)")
      return
    }
    #expect(document.revision == 1)
    #expect(document.budget.amountUSD == Decimal(250))
    #expect(etag == "\"1\"")

    let second = try await client.writeAccountSettings(
      request,
      accessToken: Fixtures.accessToken,
      ifMatch: "\"0\""
    )
    guard case .conflict(let current, let conflictETag) = second else {
      Issue.record("expected conflict, got \(second)")
      return
    }
    #expect(current.revision == 2)
    #expect(current.budget.amountUSD == Decimal(string: "75.50"))
    #expect(current.alerts.thresholds["c3d4e5f6a1b2"] == [15])
    #expect(conflictETag == "\"2\"")

    #expect(
      transport.recordedURLs.map(\.path) == [
        "/api/v2/account/settings",
        "/api/v2/account/settings",
      ])
    #expect(transport.recordedMethods == ["PUT", "PUT"])
    #expect(transport.recordedIfMatch == ["\"0\"", "\"0\""])
    let body = String(data: transport.recordedBodies[0], encoding: .utf8) ?? ""
    #expect(body.contains("\"protocol_version\":2"))
    #expect(body.contains("\"amount_usd\":\"250.00\""))
    #expect(!body.contains("\"revision\""))
    #expect(!body.contains("\"updated_at\""))
  }

  @Test
  func originGuardRejectsNonManagedHosts() {
    #expect(throws: RelayClientError.invalidOrigin) {
      try RelayClient.requireManagedOrigin(URL(string: "https://example.com/api")!)
    }
    #expect(throws: RelayClientError.invalidOrigin) {
      try RelayClient.requireManagedOrigin(URL(string: "http://quota.gotry.io/api")!)
    }
    var request = URLRequest(url: URL(string: "https://example.com")!)
    #expect(throws: RelayClientError.invalidOrigin) {
      try RelayClient.attachBearer(&request, token: Fixtures.accessToken)
    }
  }
}
