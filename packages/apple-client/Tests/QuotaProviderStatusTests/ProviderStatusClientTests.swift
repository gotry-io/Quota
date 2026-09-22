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

  @Test
  func relayCatalogReadSkipsDirectPolls() async {
    let catalog = ScriptedStatusCatalog(
      result: .success([
        ProviderStatusReading(
          provider: .claude,
          indicator: .minor,
          description: "Partial System Outage",
          checkedAt: Date(timeIntervalSince1970: 1)
        )
      ])
    )
    let transport = ScriptedStatusTransport(results: [:])
    let client = ProviderStatusClient(
      catalog: catalog,
      transport: transport,
      userAgent: "Quota/test",
      now: { Date(timeIntervalSince1970: 1) }
    )
    let readings = await client.refresh()
    #expect(readings.contains { $0.provider == .claude && $0.indicator == .minor })
    #expect(transport.callCount == 0)
  }

  @Test
  func failedCatalogReadFallsBackToDirectPolls() async {
    let catalog = ScriptedStatusCatalog(result: .failure(.unavailable))
    let transport = ScriptedStatusTransport(
      results: [
        .claude: .success(
          Data(#"{"status":{"indicator":"none","description":"All Systems Operational"}}"#.utf8))
      ]
    )
    let client = ProviderStatusClient(
      catalog: catalog,
      transport: transport,
      userAgent: "Quota/test",
      now: { Date(timeIntervalSince1970: 1) }
    )
    let readings = await client.refresh()
    #expect(readings.contains { $0.provider == .claude && $0.indicator == .none })
    #expect(transport.callCount > 0)
  }

  @Test
  func persistedReadingsSurviveANewClient() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ProtectedFileProviderStatusStore(directory: directory)
    let reading = ProviderStatusReading(
      provider: .cursor,
      indicator: .major,
      description: "Outage",
      checkedAt: Date(timeIntervalSince1970: 2)
    )
    try store.save([reading])
    let client = ProviderStatusClient(
      store: store,
      userAgent: "Quota/test",
      now: { Date(timeIntervalSince1970: 3) }
    )
    let persisted = await client.persistedReadings()
    #expect(persisted.contains { $0.provider == .cursor && $0.indicator == .major })
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

  var callCount = 0

  func getJSON(url: URL, userAgent: String) async throws -> Data {
    callCount += 1
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

final class ScriptedStatusCatalog: ProviderStatusCatalogFetching, @unchecked Sendable {
  enum Result: Sendable {
    case success([ProviderStatusReading])
    case failure(ProviderStatusTransportError)
  }

  var result: Result

  init(result: Result) {
    self.result = result
  }

  func fetchReadings() async throws -> [ProviderStatusReading] {
    switch result {
    case .success(let readings):
      return readings
    case .failure(let error):
      throw error
    }
  }
}
