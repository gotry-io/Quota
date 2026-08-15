import Foundation
import Testing

@testable import QuotaBar

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

  @Test
  func diagnosticsCheckedStatusUsesFixedTimeNotRelativeAge() {
    let date = Date(timeIntervalSince1970: 1_786_617_600)
    let time = LastCheckedLabel.string(from: date)
    let status = LastCheckedLabel.checkedStatusString(from: date)
    #expect(status == "Checked \(time)")
    #expect(!status.localizedCaseInsensitiveContains("ago"))
    #expect(!status.localizedCaseInsensitiveContains("generated"))
    #expect(LastCheckedLabel.accessibleString(from: date) == "Last checked \(time)")
  }
}

struct DiagnosticsHeaderActionTests {
  @Test
  func copyAccessibilityLabels() {
    #expect(DiagnosticsHeaderAction.copyAccessibilityLabel(didCopy: false) == "Copy diagnostics")
    #expect(DiagnosticsHeaderAction.copyAccessibilityLabel(didCopy: true) == "Diagnostics copied")
    #expect(DiagnosticsHeaderAction.recheckLabel == "Recheck diagnostics")
    #expect(
      DiagnosticsHeaderAction.recheckAccessibilityLabel(isChecking: false)
        == "Recheck diagnostics"
    )
    #expect(
      DiagnosticsHeaderAction.recheckAccessibilityLabel(isChecking: true)
        == "Checking diagnostics"
    )
    #expect(DiagnosticsHeaderAction.copyFeedbackDuration == .seconds(2))
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
