import Foundation
import QuotaPresentation
import Testing

struct UsagePeriodSelectionTests {
  /// A Sunday, so the week and the month both start before it.
  private static let today = calendar.date(from: DateComponents(year: 2026, month: 9, day: 6))!

  private static var calendar: Calendar {
    var value = Calendar(identifier: .gregorian)
    value.timeZone = TimeZone(identifier: "UTC")!
    // Monday-first, which is how every Quota surface draws a week.
    value.firstWeekday = 2
    return value
  }

  @Test func resolvesEachPeriodAgainstTheDeviceCalendar() {
    let calendar = Self.calendar
    func range(_ selection: UsagePeriodSelection) -> String? {
      selection.range(today: Self.today, calendar: calendar).map { "\($0.from)/\($0.to)" }
    }
    #expect(range(.today) == "2026-09-06/2026-09-06")
    #expect(range(.day(offset: 1)) == "2026-09-05/2026-09-05")
    #expect(range(.thisWeek) == "2026-08-31/2026-09-06")
    #expect(range(.week(offset: 1)) == "2026-08-24/2026-08-30")
    #expect(range(.thisMonth) == "2026-09-01/2026-09-30")
    #expect(range(.month(offset: 1)) == "2026-08-01/2026-08-31")
    #expect(range(.last7Days) == "2026-08-31/2026-09-06")
    #expect(range(.last30Days) == "2026-08-08/2026-09-06")
    #expect(range(.all) == nil)
    #expect(range(.custom(from: "2026-01-01", to: "2026-01-31")) == "2026-01-01/2026-01-31")
  }

  @Test func stepsADayAWeekAndAMonthAndStopsAtTheCurrentOne() {
    #expect(UsagePeriodSelection.thisMonth.previous == .month(offset: 1))
    #expect(UsagePeriodSelection.month(offset: 1).next == .thisMonth)
    #expect(UsagePeriodSelection.thisMonth.next == nil)
    #expect(UsagePeriodSelection.last30Days.previous == nil)
    #expect(UsagePeriodSelection.all.next == nil)
  }

  @Test func namesOnlyTheFourPeriodsTheSummaryFolds() {
    #expect(UsagePeriodSelection.today.summaryKey == .today)
    #expect(UsagePeriodSelection.day(offset: 1).summaryKey == nil)
    #expect(UsagePeriodSelection.last7Days.summaryKey == .last7Days)
    #expect(UsagePeriodSelection.last30Days.summaryKey == .last30Days)
    #expect(UsagePeriodSelection.all.summaryKey == .all)
    #expect(UsagePeriodSelection.thisWeek.summaryKey == nil)
    #expect(UsagePeriodSelection.thisMonth.summaryKey == nil)
  }

  @Test func titlesAPeriodWithTheRangeItCovers() {
    let calendar = Self.calendar
    let locale = Locale(identifier: "en_US_POSIX")
    let day = UsagePeriodTitle.text(
      for: .today, today: Self.today, calendar: calendar, locale: locale)
    #expect(day.contains("2026"))
    let week = UsagePeriodTitle.text(
      for: .thisWeek, today: Self.today, calendar: calendar, locale: locale)
    #expect(week.contains("–"))
    #expect(
      UsagePeriodTitle.text(for: .all, today: Self.today, calendar: calendar, locale: locale)
        == "Everything kept"
    )
  }

  @Test func countsTheDaysARangeCovers() {
    let calendar = Self.calendar
    #expect(UsageDateText.days(from: "2026-09-01", to: "2026-09-01", calendar) == 1)
    #expect(UsageDateText.days(from: "2026-09-01", to: "2026-09-30", calendar) == 30)
  }

  /// The app's preset ranges are the same local dates the period fixture names.
  @Test func presetRangesEqualThePeriodFixture() throws {
    let fixture = try PeriodFixture.load()
    let testCase = try #require(fixture.cases.first { $0.name == "preset_equals_custom" })
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: testCase.timezone))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let now = try #require(formatter.date(from: testCase.checkedAt))
    let presets = try #require(testCase.summaryPresets)
    #expect(presets.count == 3)
    for preset in presets {
      let selection: UsagePeriodSelection
      switch preset.key {
      case "today": selection = .today
      case "last_7_days": selection = .last7Days
      case "last_30_days": selection = .last30Days
      default:
        Issue.record("unexpected preset \(preset.key)")
        continue
      }
      let range = try #require(selection.range(today: now, calendar: calendar))
      #expect(range.from == preset.from, "\(preset.key)")
      #expect(range.to == preset.to, "\(preset.key)")
    }
  }
}

private struct PeriodFixture: Decodable {
  var cases: [Case]

  struct Case: Decodable {
    var name: String
    var checkedAt: String
    var timezone: String
    var summaryPresets: [Preset]?
  }

  struct Preset: Decodable {
    var key: String
    var from: String
    var to: String
  }

  static func load() throws -> PeriodFixture {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try decoder.decode(PeriodFixture.self, from: Data(contentsOf: fixtureURL))
  }

  private static let fixtureURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("protocol/fixtures/usage-period-conformance.json")
}
