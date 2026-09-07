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

  @Test func rhythmMatchesTheSharedFixture() throws {
    let cases = try UsageMetricsFixture.rhythmCases()
    #expect(cases.count > 1)
    for testCase in cases {
      let observed = UsageRhythm.fold(testCase.hours)
      #expect(observed.hoursOfDay.count == UsageRhythm.hoursOfDayCount, "\(testCase.name)")
      #expect(observed.weekdayHours.count == UsageRhythm.weekdayCount, "\(testCase.name)")
      for hour in 0..<UsageRhythm.hoursOfDayCount {
        let expected = testCase.hoursOfDay[hour]
        #expect(observed.hoursOfDay[hour].hour == hour, "\(testCase.name)")
        #expect(observed.hoursOfDay[hour].totalTokens == expected.totalTokens, "\(testCase.name) hour \(hour)")
        #expect(
          observed.hoursOfDay[hour].costMicrousd == expected.costMicrousd,
          "\(testCase.name) hour \(hour) cost"
        )
      }
      for weekday in 0..<UsageRhythm.weekdayCount {
        #expect(observed.weekdayHours[weekday].count == UsageRhythm.hoursOfDayCount, "\(testCase.name)")
        for hour in 0..<UsageRhythm.hoursOfDayCount {
          #expect(
            observed.weekdayHours[weekday][hour] == testCase.weekdayHours[weekday][hour],
            "\(testCase.name) weekday \(weekday) hour \(hour)"
          )
        }
      }
    }
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

  struct RhythmCase {
    let name: String
    let hours: [UsageRhythmHourFact]
    let hoursOfDay: [UsageHourOfDay]
    let weekdayHours: [[Int]]
  }

  static func rhythmCases() throws -> [RhythmCase] {
    let entries = try root()["rhythm_cases"] as! [[String: Any]]
    return entries.map { entry in
      let hours = (entry["hours"] as! [[String: Any]]).map { fact in
        UsageRhythmHourFact(
          date: fact["date"] as! String,
          hour: (fact["hour"] as! NSNumber).intValue,
          totalTokens: (fact["total_tokens"] as! NSNumber).intValue,
          costMicrousd: fact["cost_microusd"] as? String
        )
      }
      let expected = entry["expected"] as! [String: Any]
      let namedHours = expected["hours_of_day"] as! [String: Any]
      let hoursOfDay = (0..<UsageRhythm.hoursOfDayCount).map { hour in
        let cell = namedHours[String(hour)] as? [String: Any]
        return UsageHourOfDay(
          hour: hour,
          totalTokens: (cell?["total_tokens"] as? NSNumber)?.intValue ?? 0,
          costMicrousd: cell?["cost_microusd"] as? String
        )
      }
      let namedWeekdays = expected["weekday_hours"] as! [String: Any]
      let weekdayHours = (0..<UsageRhythm.weekdayCount).map { weekday in
        let row = namedWeekdays[String(weekday)] as? [String: Any] ?? [:]
        return (0..<UsageRhythm.hoursOfDayCount).map { hour in
          (row[String(hour)] as? NSNumber)?.intValue ?? 0
        }
      }
      return RhythmCase(
        name: entry["name"] as! String,
        hours: hours,
        hoursOfDay: hoursOfDay,
        weekdayHours: weekdayHours
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
