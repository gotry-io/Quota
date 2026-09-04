import Foundation
import QuotaRelay
import QuotaWire
import Testing

struct RelayClientTests {
  @Test
  func publicAPIHasNoDeviceOrWriteRoutes() {
    #expect(
      Set(RelayRoute.allCases.map(\.path)) == [
        "/oauth/v2/token",
        "/oauth/v2/revoke",
        "/api/v6/account/summary",
        "/api/v6/account/usage/activity",
      ])
    #expect(RelayRoute.allCases.allSatisfy { !$0.path.contains("/device/") })
    #expect(RelayRoute.allCases.allSatisfy { $0.method == "GET" || $0.method == "POST" })
    #expect(!RelayRoute.allCases.contains { $0.method == "PUT" || $0.method == "DELETE" })
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

  @Test
  func activityRequestEncodesWhitelistQueryAndOmitsDetailWhenAbsent() async throws {
    let body = try Fixtures.usageActivityJSON(days: [
      Fixtures.usageActivityDay(date: "2026-08-10")
    ])
    let transport = ScriptedTransport([
      .init(status: 200, body: body),
      .init(status: 200, body: body),
    ])
    let client = RelayClient(transport: transport)

    let omitted = try await client.fetchAccountUsageActivity(
      accessToken: Fixtures.accessToken,
      from: "2026-08-01",
      to: "2026-08-10"
    )
    #expect(omitted.days.map(\.date) == ["2026-08-10"])
    #expect(omitted.days.first?.agents == nil)

    let detailed = try await client.fetchAccountUsageActivity(
      accessToken: Fixtures.accessToken,
      from: "2026-08-10",
      to: "2026-08-10",
      detail: .agents
    )
    #expect(detailed.days.first?.date == "2026-08-10")

    #expect(
      transport.recordedURLs.map(\.path) == [
        "/api/v6/account/usage/activity",
        "/api/v6/account/usage/activity",
      ])
    #expect(transport.recordedMethods == ["GET", "GET"])
    #expect(transport.recordedIfNoneMatch == [nil, nil])
    #expect(
      transport.recordedURLs.allSatisfy { url in
        url.scheme == "https" && url.host == "quota.gotry.io"
          && (url.port == nil || url.port == 443)
      })
    #expect(transport.recordedAuthorization == [
      "Bearer \(Fixtures.accessToken)",
      "Bearer \(Fixtures.accessToken)",
    ])

    let omittedQuery = queryItems(transport.recordedURLs[0])
    #expect(omittedQuery.map(\.name) == ["from", "to"])
    #expect(Dictionary(uniqueKeysWithValues: omittedQuery.map { ($0.name, $0.value ?? "") }) == [
      "from": "2026-08-01",
      "to": "2026-08-10",
    ])

    let detailedQuery = queryItems(transport.recordedURLs[1])
    #expect(detailedQuery.map(\.name) == ["from", "to", "detail"])
    #expect(Dictionary(uniqueKeysWithValues: detailedQuery.map { ($0.name, $0.value ?? "") }) == [
      "from": "2026-08-10",
      "to": "2026-08-10",
      "detail": "agents",
    ])
  }

  @Test
  func activityRefusesResponsesOverOneMebibyte() async throws {
    let oversized = Data(repeating: 0x61, count: WireCodec.maximumResponseBytes + 1)
    let transport = ScriptedTransport([.init(status: 200, body: oversized)])
    let client = RelayClient(transport: transport)
    await #expect(throws: RelayClientError.responseTooLarge) {
      _ = try await client.fetchAccountUsageActivity(
        accessToken: Fixtures.accessToken,
        from: "2026-08-10",
        to: "2026-08-10"
      )
    }
  }

  @Test
  func activityRejectsInvalidCalendarDatesWithoutSending() async {
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
    #expect(transport.recordedURLs.isEmpty)
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

  private func queryItems(_ url: URL) -> [URLQueryItem] {
    URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
  }
}
