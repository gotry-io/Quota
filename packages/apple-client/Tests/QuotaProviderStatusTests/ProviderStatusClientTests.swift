import Foundation
import QuotaPresentation
import QuotaProviderStatus
import QuotaWire
import Testing

struct ProviderStatusClientTests {
  @Test
  func catalogEndpointsMatchTheFourStatuspageV2Providers() {
    #expect(ProviderStatusPages.endpoints.map(\.0) == [.codex, .claude, .kimi, .cursor])
    #expect(
      ProviderStatusPages.endpoints.map(\.1.absoluteString) == [
        "https://status.openai.com/api/v2/status.json",
        "https://status.claude.com/api/v2/status.json",
        "https://status.moonshot.cn/api/v2/status.json",
        "https://status.cursor.com/api/v2/status.json",
      ]
    )
  }

  @Test
  func parseTakesIndicatorAndDescriptionOnly() throws {
    let data = Data(
      #"{"page":{"id":"x"},"status":{"indicator":"minor","description":"Partial System Outage"}}"#
        .utf8)
    let reading = try #require(
      ProviderStatusClient.parse(data, provider: .codex, checkedAt: Date(timeIntervalSince1970: 0))
    )
    #expect(reading.provider == .codex)
    #expect(reading.indicator == .minor)
    #expect(reading.description == "Partial System Outage")
  }

  @Test
  func parseRejectsUnknownIndicators() {
    let data = Data(#"{"status":{"indicator":"maintenance","description":"Scheduled"}}"#.utf8)
    #expect(ProviderStatusClient.parse(data, provider: .codex, checkedAt: Date()) == nil)
  }

  @Test
  func refreshKeepsTheLastReadingWhenALaterFetchFails() async {
    let transport = ScriptedStatusTransport(
      results: [
        .codex: .success(
          Data(#"{"status":{"indicator":"minor","description":"Partial System Outage"}}"#.utf8)),
        .claude: .success(
          Data(#"{"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8)),
      ]
    )
    let client = ProviderStatusClient(
      transport: transport,
      userAgent: "Quota/test",
      now: { Date(timeIntervalSince1970: 1) }
    )
    let first = await client.refresh()
    #expect(transport.lastUserAgent == "Quota/test")
    #expect(first.contains { $0.provider == .codex && $0.indicator == .minor })

    transport.results = [
      .codex: .failure(.unavailable),
      .claude: .success(
        Data(#"{"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8)),
    ]
    let second = await client.refresh()
    let codex = second.first { $0.provider == .codex }
    #expect(codex?.indicator == .minor)
    #expect(codex?.description == "Partial System Outage")
  }
}

final class ScriptedStatusTransport: ProviderStatusTransport, @unchecked Sendable {
  enum Result: Sendable {
    case success(Data)
    case failure(ProviderStatusTransportError)
  }

  var results: [ProviderID: Result]
  var lastUserAgent: String?

  init(results: [ProviderID: Result]) {
    self.results = results
  }

  func getJSON(url: URL, userAgent: String) async throws -> Data {
    lastUserAgent = userAgent
    let provider = ProviderStatusPages.endpoints.first { $0.1 == url }?.0
    switch provider.flatMap({ results[$0] }) {
    case .success(let data):
      return data
    case .failure(let error):
      throw error
    case nil:
      throw ProviderStatusTransportError.unavailable
    }
  }
}
