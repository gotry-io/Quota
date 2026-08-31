import Foundation
import QuotaPresentation
import Testing

/// The website says these phrases too. Both runtimes answer the same file, so a phrase one of
/// them changes cannot quietly drift from the other.
struct FreshnessCopyConformanceTests {
  private let now = Date(timeIntervalSince1970: 1_786_000_000)

  @Test func namedPhrasesMatchTheSharedFixture() throws {
    let phrases = try FreshnessCopyFixture.phrases()
    #expect(FreshnessCopy.noResetTime == phrases["no_reset_time"])
    #expect(FreshnessCopy.notChecked == phrases["not_checked"])
    #expect(FreshnessCopy.noReadings == phrases["no_readings"])
    #expect(FreshnessCopy.updated(since: nil, now: now) == phrases["not_checked"])
  }

  @Test func relativeAgeMatchesTheSharedFixture() throws {
    let cases = try FreshnessCopyFixture.cases(for: "age")
    #expect(cases.count > 1)
    for testCase in cases {
      let observed = FreshnessCopy.age(since: instant(testCase.ageSeconds!), now: now)
      #expect(observed == testCase.expected, "\(testCase.name)")
    }
  }

  @Test func observationLinesMatchTheSharedFixture() throws {
    let cases = try FreshnessCopyFixture.cases(for: "observation")
    #expect(cases.count > 1)
    for testCase in cases {
      let state = FreshnessCopyConformanceTests.state(for: testCase.status!)
      let observed = FreshnessCopy.observation(
        state: state,
        observedAt: instant(testCase.ageSeconds!),
        now: now
      )
      #expect(observed == testCase.expected, "\(testCase.name)")
    }
  }

  @Test func deviceLinesMatchTheSharedFixture() throws {
    let cases = try FreshnessCopyFixture.cases(for: "device")
    #expect(cases.count > 1)
    for testCase in cases {
      let observed = FreshnessCopy.lastReading(since: testCase.ageSeconds.map(instant), now: now)
      #expect(observed == testCase.expected, "\(testCase.name)")
    }
  }

  @Test func missingResetDisplayMatchesTheSharedFixture() throws {
    let cases = try FreshnessCopyFixture.missingResetCases()
    #expect(cases.count > 1)
    for testCase in cases {
      let observed = FreshnessCopy.showsNoResetTime(
        remainingPercent: testCase.remainingPercent,
        showsPercentMeter: testCase.showsPercentMeter
      )
      #expect(observed == testCase.expected, "\(testCase.name)")
    }
  }

  @Test func missingResetDisplayDerivesBothScalarsFromAWindow() {
    struct Window: RemainingQuotaWindow {
      var usedPercent: Double
      var remainingValue: Double?
      var limitValue: Double?
    }
    #expect(
      FreshnessCopy.showsNoResetTime(
        Window(usedPercent: 63.102, remainingValue: 14.55, limitValue: 400)
      )
    )
    #expect(
      !FreshnessCopy.showsNoResetTime(
        Window(usedPercent: 0, remainingValue: 12.5, limitValue: nil)
      )
    )
  }

  private func instant(_ ageSeconds: Int) -> Date {
    now.addingTimeInterval(-TimeInterval(ageSeconds))
  }

  /// The fixture names wire statuses because that is what a client actually receives.
  private static func state(for status: String) -> QuotaObservationState {
    switch status {
    case "available": .available
    case "stale": .stale
    case "auth_required": .signInNeeded
    case "unavailable": .unavailable
    case "unsupported": .unsupported
    case "error": .failed
    default: fatalError("Unknown observation status in the shared fixture: \(status)")
    }
  }
}

enum FreshnessCopyFixture {
  struct Case {
    let name: String
    let status: String?
    let ageSeconds: Int?
    let expected: String
  }

  struct MissingResetCase {
    let name: String
    let remainingPercent: Double
    let showsPercentMeter: Bool
    let expected: Bool
  }

  static func phrases() throws -> [String: String] {
    try root()["phrases"] as! [String: String]
  }

  static func cases(for group: String) throws -> [Case] {
    let entries = try root()[group] as! [[String: Any]]
    return entries.map {
      Case(
        name: $0["name"] as! String,
        status: $0["status"] as? String,
        ageSeconds: $0["age_seconds"] as? Int,
        expected: $0["expected"] as! String
      )
    }
  }

  static func missingResetCases() throws -> [MissingResetCase] {
    let entries = try root()["missing_reset"] as! [[String: Any]]
    return entries.map {
      MissingResetCase(
        name: $0["name"] as! String,
        remainingPercent: ($0["remaining_percent"] as! NSNumber).doubleValue,
        showsPercentMeter: $0["shows_percent_meter"] as! Bool,
        expected: $0["expected"] as! Bool
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
    .appendingPathComponent("protocol/fixtures/freshness-copy-conformance.json")
}
