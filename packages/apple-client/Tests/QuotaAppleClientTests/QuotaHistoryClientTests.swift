import Foundation
import QuotaRelay
import QuotaWire
import Testing

struct QuotaHistoryClientTests {
  @Test func historySyncOffAndQuotaHistoryFullAreTheirOwnErrors() async throws {
    let off = Data(
      """
      {"error":{"code":"history_sync_off","message":"Quota history sync is off for this Account."}}
      """.utf8
    )
    let full = Data(
      #"{"error":{"code":"quota_history_full","message":"full"}}"#.utf8
    )
    let transport = ScriptedTransport([
      .init(status: 409, body: off),
      .init(status: 413, body: full),
    ])
    let client = RelayClient(transport: transport)
    let request = QuotaHistoryUploadRequest(generation: 1, series: [])
    await #expect(throws: RelayClientError.historySyncOff) {
      _ = try await client.uploadQuotaHistory(accessToken: Fixtures.accessToken, request: request)
    }
    await #expect(throws: RelayClientError.quotaHistoryFull) {
      _ = try await client.uploadQuotaHistory(accessToken: Fixtures.accessToken, request: request)
    }
  }

  @Test func aReadSendsTheSubscriptionAndHonoursNotModified() async throws {
    let body = Data(
      """
      {"protocol_version":6,"sync":true,"windows":{"five_hour":{"duration_seconds":18000,\
      "points":[{"resets_at":"2026-09-21T15:00:00Z","bucket_start":"2026-09-21T10:00:00Z",\
      "used_percent":40}]}}}
      """.utf8
    )
    let transport = ScriptedTransport([
      .init(status: 200, body: body, headers: ["ETag": "\"history-1\""]),
      .init(status: 304, body: Data(), headers: ["ETag": "\"history-1\""]),
    ])
    let client = RelayClient(transport: transport)
    let since = Fixtures.date("2026-08-22T00:00:00Z")
    let fresh = try await client.fetchQuotaHistory(
      accessToken: Fixtures.accessToken,
      provider: .codex,
      fingerprint: "account_test",
      since: since,
      etag: nil
    )
    guard case .fresh(let decoded, let etag) = fresh else {
      Issue.record("expected a body")
      return
    }
    #expect(etag == "\"history-1\"")
    #expect(decoded.sync)
    #expect(decoded.windows["five_hour"]?.points.first?.usedPercent == 40)
    let items = URLComponents(url: transport.recordedURLs[0], resolvingAgainstBaseURL: false)?
      .queryItems ?? []
    let query = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    #expect(query["provider"] == "codex")
    #expect(query["fingerprint"] == "account_test")
    #expect(query["since"] == "2026-08-22T00:00:00Z")
    #expect(transport.recordedIfNoneMatch[0] == nil)

    let again = try await client.fetchQuotaHistory(
      accessToken: Fixtures.accessToken,
      provider: .codex,
      fingerprint: "account_test",
      since: since,
      etag: "\"history-1\""
    )
    guard case .notModified = again else {
      Issue.record("expected 304")
      return
    }
    #expect(transport.recordedIfNoneMatch[1] == "\"history-1\"")
  }
}
