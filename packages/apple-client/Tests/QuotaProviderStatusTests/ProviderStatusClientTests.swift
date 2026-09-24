import Foundation
import QuotaPresentation
import QuotaProviderStatus
import QuotaWire
import Testing

struct ProviderStatusClientTests {
  /// A status page is read for its indicator and description; an indicator this build does not
  /// name is no reading rather than a guessed one.
  @Test
  func aPageIsReadForItsIndicatorAndAnUnknownIndicatorIsNoReading() throws {
    let data = Data(
      #"{"page":{"id":"x"},"status":{"indicator":"minor","description":"Partial System Outage"}}"#
        .utf8)
    let reading = try #require(
      ProviderStatusClient.parse(data, provider: .codex, checkedAt: Date(timeIntervalSince1970: 0))
    )
    #expect(reading.provider == .codex)
    #expect(reading.indicator == .minor)
    #expect(reading.description == "Partial System Outage")

    let unknown = Data(#"{"status":{"indicator":"maintenance","description":"Scheduled"}}"#.utf8)
    #expect(
      ProviderStatusClient.parse(
        unknown, provider: .codex, checkedAt: Date(timeIntervalSince1970: 0)) == nil)
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
