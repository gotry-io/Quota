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
        "/api/v4/account/summary",
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
      from: "2026-08-14",
      to: "2026-08-14",
      accessToken: Fixtures.accessToken
    )
    await #expect(throws: RelayClientError.redirectRefused) {
      _ = try await client.fetchAccountSummary(
        from: "2026-08-14",
        to: "2026-08-14",
        accessToken: Fixtures.accessToken
      )
    }

    #expect(
      transport.recordedURLs.allSatisfy { url in
        url.scheme == "https" && url.host == "quota.gotry.io"
          && (url.port == nil || url.port == 443)
      })
    #expect(transport.recordedURLs.first?.path == "/api/v4/account/summary")
    let query =
      URLComponents(url: transport.recordedURLs[0], resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    let items = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
    #expect(items["usage_agents"] == "all")
    // One contract: the summary carries client groups, the catalog revision, and Device
    // Health without being asked, so the request has no negotiation keys.
    for retired in ["usage_clients", "model_catalog", "device_health", "usage_channels"] {
      #expect(items[retired] == nil)
    }
    #expect(items["cost_mode"] == "auto")
    #expect(items["from"] == "2026-08-14")
    #expect(items["to"] == "2026-08-14")
    #expect(transport.recordedAuthorization.first == "Bearer \(Fixtures.accessToken)")
  }

  @Test
  func refusesResponsesOverOneMebibyte() async throws {
    let oversized = Data(repeating: 0x61, count: WireCodec.maximumResponseBytes + 1)
    let transport = ScriptedTransport([.init(status: 200, body: oversized)])
    let client = RelayClient(transport: transport)
    await #expect(throws: RelayClientError.responseTooLarge) {
      _ = try await client.fetchAccountSummary(
        from: "2026-08-14",
        to: "2026-08-14",
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
    let refreshed = try await client.refreshAccountSession(refreshToken: Fixtures.refreshToken)
    #expect(refreshed.accountSession.accessToken == Fixtures.rotatedAccess)
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
