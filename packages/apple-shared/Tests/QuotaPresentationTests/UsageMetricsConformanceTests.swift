import Foundation
import QuotaPresentation
import Testing

/// Relay, the local service, and both Apple apps derive the cache hit rate from the same file,
/// so a rate one of them changes cannot quietly drift from the others.
///
/// The saving beside it is priced from the pricing catalog and the rows behind a period, neither
/// of which an Apple client holds: it arrives already folded on the wire. The cases naming it
/// are answered by the two runtimes that can price a row.
struct UsageMetricsConformanceTests {
  @Test func cacheHitRateMatchesTheSharedFixture() throws {
    let cases = try UsageMetricsFixture.hitRateCases()
    #expect(cases.count > 1)
    for testCase in cases {
      let observed = UsageMetrics.cacheHitBasisPoints(
        cacheReadInputTokens: testCase.cacheReadInputTokens,
        inputTokens: testCase.inputTokens
      )
      #expect(observed == testCase.expectedBasisPoints, "\(testCase.name)")
    }
  }

  @Test func everyHourOfTheClockBelongsToExactlyOneStretchOfTheDay() {
    let hours = UsageDayPart.allCases.flatMap { Array($0.hours) }
    #expect(hours.sorted() == Array(0..<24))
    #expect(UsageDayPart.containing(hour: 0) == .night)
    #expect(UsageDayPart.containing(hour: 6) == .morning)
    #expect(UsageDayPart.containing(hour: 23) == .evening)
    #expect(UsageDayPart.containing(hour: 24) == nil)
  }

  @Test func aWholePercentRoundsHalfUp() {
    #expect(UsageMetrics.cacheHitPercentLabel(basisPoints: 9_449) == "94%")
    #expect(UsageMetrics.cacheHitPercentLabel(basisPoints: 9_450) == "95%")
    #expect(UsageMetrics.cacheHitPercentLabel(basisPoints: nil) == nil)
  }
}

enum UsageMetricsFixture {
  struct HitRateCase {
    let name: String
    let cacheReadInputTokens: Int
    let inputTokens: Int
    let expectedBasisPoints: Int?
  }

  static func hitRateCases() throws -> [HitRateCase] {
    let entries = try root()["hit_rate"] as! [[String: Any]]
    return entries.map { entry in
      let totals = entry["totals"] as! [String: Any]
      return HitRateCase(
        name: entry["name"] as! String,
        cacheReadInputTokens: (totals["cache_read_input_tokens"] as! NSNumber).intValue,
        inputTokens: (totals["input_tokens"] as! NSNumber).intValue,
        expectedBasisPoints: (entry["expected_basis_points"] as? NSNumber)?.intValue
      )
    }
  }

  private static func root() throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as! [String: Any]
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/usage-metrics-conformance.json")
}
