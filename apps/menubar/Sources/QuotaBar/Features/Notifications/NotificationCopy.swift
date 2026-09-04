import Foundation
import QuotaPresentation

/// Title and body for a local remaining-quota notification.
///
/// The phrases live in `apps/menubar/DESIGN.md` Shared product vocabulary.
enum NotificationCopy {
  static func title(providerDisplayName: String, windowTitle: String) -> String {
    "\(providerDisplayName) · \(windowTitle)"
  }

  static func thresholdBody(
    remainingPercent: Double,
    resetsAt: Date?,
    now: Date,
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String {
    let left = "\(RemainingQuotaFormat.percent(remainingPercent)) left"
    guard let resetsAt,
      let phrase = resetPhrase(
        resetsAt: resetsAt, now: now, timeZone: timeZone, calendar: calendar)
    else {
      return left
    }
    return "\(left) · \(phrase)"
  }

  /// `<Window title> quota reset`.
  static func resetBody(windowTitle: String) -> String {
    "\(windowTitle) quota reset"
  }

  /// Lowercase of the shared reset-countdown buckets: `resets in 42m`, `resets in 3h 12m`,
  /// `resets Tue 14:00`. Nil once the instant has passed.
  static func resetPhrase(
    resetsAt: Date,
    now: Date,
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String? {
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return nil }
    let wholeMinutes = max(1, Int((seconds / 60).rounded(.up)))
    if wholeMinutes < 60 {
      return "resets in \(wholeMinutes)m"
    }
    if seconds < 86_400 {
      var hours = Int(seconds / 3_600)
      var minutes = Int(((seconds - TimeInterval(hours * 3_600)) / 60).rounded(.up))
      if minutes == 60 {
        hours += 1
        minutes = 0
      }
      if minutes == 0 {
        return "resets in \(hours)h"
      }
      return "resets in \(hours)h \(minutes)m"
    }
    var calendar = calendar
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.dateFormat = seconds < 604_800 ? "EEE HH:mm" : "MMM d"
    return "resets \(formatter.string(from: resetsAt))"
  }
}
