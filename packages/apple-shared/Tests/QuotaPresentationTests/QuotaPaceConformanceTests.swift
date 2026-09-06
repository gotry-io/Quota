import Foundation
import QuotaPresentation
import Testing

/// Every runtime answers this file. A rule or a phrase one of them changes cannot quietly drift.
struct QuotaPaceConformanceTests {
  @Test func everyPaceCaseMatchesTheSharedFixture() throws {
    let fixture = try PaceFixture.load()
    #expect(fixture.cases.count >= 12)
    for testCase in fixture.cases {
      let pace = QuotaPace.evaluate(
        QuotaPaceReading(
          usedPercent: testCase.window.usedPercent,
          resetsAt: testCase.window.resetsAt,
          cadenceSeconds: testCase.window.durationSeconds,
          isBalanceOnly: RemainingQuotaFormat.isBalanceOnly(
            remainingValue: testCase.window.remainingValue,
            hasLimit: testCase.window.limitValue != nil
          )
        ),
        now: testCase.now
      )
      #expect(pace == testCase.expected, "\(testCase.name)")
      #expect(
        QuotaPaceCopy.line(pace, resetsAt: testCase.window.resetsAt) == testCase.expectedCopy,
        "\(testCase.name)"
      )
    }
  }

  @Test func aWindowWithNoCadenceHasNoPace() {
    let pace = QuotaPace.evaluate(
      QuotaPaceReading(
        usedPercent: 60,
        resetsAt: Date(timeIntervalSince1970: 1_000_000),
        cadenceSeconds: nil,
        isBalanceOnly: false
      ),
      now: Date(timeIntervalSince1970: 999_000)
    )
    #expect(pace == .none)
    #expect(QuotaPaceCopy.line(pace, resetsAt: nil) == nil)
  }
}

private struct PaceFixture: Decodable {
  var cases: [Case]

  struct Case: Decodable {
    var name: String
    var now: Date
    var window: Window
    var expected: QuotaPace
    var expectedCopy: String?
  }

  struct Window: Decodable {
    var usedPercent: Double
    var resetsAt: Date?
    var durationSeconds: Int?
    var remainingValue: Double?
    var limitValue: Double?
  }

  static func load() throws -> PaceFixture {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(PaceFixture.self, from: Data(contentsOf: fixtureURL))
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/quota-pace-conformance.json")
}
