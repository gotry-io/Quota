import Foundation
import Testing

@testable import QuotaWire

/// The website folds the same days into the same period. Both answer this file, so a client that
/// starts adding a range up differently cannot do it quietly.
@Suite
struct UsageDayFoldConformanceTests {
  @Test func everyFoldCaseMatchesTheSharedFixture() throws {
    let fixture = try Fixture.load()
    #expect(fixture.cases.count >= 6)
    for testCase in fixture.cases {
      let folded = UsageDayFold.period(testCase.days, from: testCase.from, to: testCase.to)
      #expect(folded.totals == testCase.expected.totals, "\(testCase.name)")
      #expect(folded.cost == testCase.expected.cost, "\(testCase.name)")
      #expect(folded.cacheSaved == testCase.expected.cacheSaved, "\(testCase.name)")
      #expect(folded.partial == testCase.expected.partial, "\(testCase.name)")
      #expect(folded.agents.isEmpty, "\(testCase.name)")
    }
  }

  private struct Fixture: Decodable {
    var cases: [Case]

    struct Case: Decodable {
      var name: String
      var from: String
      var to: String
      var days: [UsageActivityDay]
      var expected: Expected
    }

    struct Expected: Decodable {
      var totals: UsageSummaryTotals
      var cost: UsageCostOutcome
      var cacheSaved: UsageCacheSaved
      var partial: Bool
    }

    static func load() throws -> Fixture {
      try WireCodec.decode(Fixture.self, from: Data(contentsOf: fixtureURL))
    }

    private static let fixtureURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("protocol/fixtures/usage-day-fold-conformance.json")
  }
}
