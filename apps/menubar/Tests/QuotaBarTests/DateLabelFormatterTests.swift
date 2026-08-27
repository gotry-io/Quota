import Foundation
import QuotaPresentation
import Testing

@testable import QuotaBar

/// The footer and the Support status line say the same thing the same way, and neither makes
/// the reader subtract a clock time from now.
struct FooterFreshnessTests {
  private let now = Date(timeIntervalSince1970: 1_786_617_600)

  @Test
  func nothingCheckedYetSaysSoInWords() {
    #expect(FreshnessCopy.updated(since: nil, now: now) == "Not checked")
  }

  @Test
  func aCompletedSyncStatesItsAgeRelativeToNow() {
    #expect(
      FreshnessCopy.updated(since: now.addingTimeInterval(-180), now: now) == "Updated 3m ago"
    )
    #expect(FreshnessCopy.updated(since: now, now: now) == "Updated just now")
  }
}

struct SupportHeaderActionTests {
  @Test
  func copyAccessibilityLabels() {
    #expect(SupportHeaderAction.copyAccessibilityLabel(didCopy: false) == "Copy report")
    #expect(SupportHeaderAction.copyAccessibilityLabel(didCopy: true) == "Report copied")
    #expect(SupportHeaderAction.recheckLabel == "Recheck")
    #expect(SupportHeaderAction.recheckAccessibilityLabel(isChecking: false) == "Recheck")
    #expect(SupportHeaderAction.recheckAccessibilityLabel(isChecking: true) == "Checking")
    #expect(SupportHeaderAction.copyFeedbackDuration == .seconds(2))
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
