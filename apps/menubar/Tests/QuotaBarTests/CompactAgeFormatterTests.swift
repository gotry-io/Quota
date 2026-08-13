import Foundation
import Testing

@testable import QuotaBar

struct CompactAgeFormatterTests {
  @Test(
    arguments: [
      (0.0, "0s"),
      (59.0, "59s"),
      (60.0, "1min"),
      (3_599.0, "59min"),
      (3_600.0, "1h"),
      (86_400.0, "1d"),
      (604_800.0, "1w"),
      (31_536_000.0, "1y"),
    ]
  )
  func formatsLargestUsefulWholeUnit(age: TimeInterval, expected: String) {
    let now = Date(timeIntervalSince1970: 31_536_000)
    #expect(CompactAgeFormatter.string(since: now.addingTimeInterval(-age), now: now) == expected)
  }
}

struct LastCheckedLabelTests {
  @Test
  func neverCheckedIsAnEmDash() {
    #expect(LastCheckedLabel.string(from: nil) == "—")
    #expect(LastCheckedLabel.accessibleString(from: nil) == "Not checked")
  }

  @Test
  func checkedLabelIsTimeOnly() {
    let date = Date(timeIntervalSince1970: 1_786_617_600)
    let label = LastCheckedLabel.string(from: date)
    #expect(!label.isEmpty)
    #expect(!label.localizedCaseInsensitiveContains("last checked"))
    #expect(LastCheckedLabel.accessibleString(from: date).localizedStandardContains("Last checked"))
  }
}

struct ResetDateFormatterTests {
  private var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    return calendar
  }

  private var locale: Locale { Locale(identifier: "en_US_POSIX") }

  @Test
  func nearResetKeepsWeekdayAndTime() {
    let now = date(2026, 8, 13, 12, 0)
    let reset = date(2026, 8, 15, 16, 3)
    #expect(
      ResetDateFormatter.string(from: reset, now: now, calendar: calendar, locale: locale)
        == "Sat 4:03 PM"
    )
  }

  @Test
  func monthlyResetUsesMonthAndDay() {
    let now = date(2026, 8, 13, 12, 0)
    let reset = date(2026, 9, 12, 8, 3)
    #expect(
      ResetDateFormatter.string(from: reset, now: now, calendar: calendar, locale: locale)
        == "Sep 12"
    )
  }

  @Test
  func laterYearIncludesYear() {
    let now = date(2026, 8, 13, 12, 0)
    let reset = date(2027, 1, 3, 8, 0)
    #expect(
      ResetDateFormatter.string(from: reset, now: now, calendar: calendar, locale: locale)
        == "Jan 3, 2027"
    )
  }

  private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
    calendar.date(
      from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
  }
}
