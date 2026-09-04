import Foundation

/// How old a reading is, and when a window refills, in the words every Quota client uses.
///
/// One rule, one voice. The menu bar footer, a provider row, a device row, the website, and the
/// widgets all state age relative to now, because a clock time or a calendar date makes the reader
/// do the subtraction before they learn the only thing they wanted to know. A future refill is
/// the exception: it is a countdown or a local date, never an age.
///
/// `packages/protocol/fixtures/freshness-copy-conformance.json` is the shared statement of these
/// thresholds, phrases, when the no-reset phrase prints, and how a future refill is named; this
/// type and `apps/web/src/lib/format.ts` both answer it.
public enum FreshnessCopy: Sendable {
  /// Stands in for an age before anything has been read at all.
  public static let notChecked = "Not checked"

  /// A device the Account has never received a reading from.
  public static let noReadings = "no readings yet"

  /// One phrase for a window whose provider never says when it refills.
  public static let noResetTime = "No reset time reported"

  /// Whether to print ``noResetTime`` under a percent window.
  public static func showsNoResetTime(remainingPercent: Double, showsPercentMeter: Bool) -> Bool {
    showsPercentMeter && remainingPercent < 100
  }

  /// Same rule, with both scalars derived from the window.
  public static func showsNoResetTime(_ window: some RemainingQuotaWindow) -> Bool {
    showsNoResetTime(
      remainingPercent: RemainingQuotaFormat.remainingPercent(usedPercent: window.usedPercent),
      showsPercentMeter: RemainingQuotaFormat.showsPercentMeter(
        remainingValue: window.remainingValue,
        hasLimit: window.limitValue != nil
      )
    )
  }

  /// The bare relative phrase: `just now`, `3m ago`, `2d ago`.
  ///
  /// Anything under a minute is an instant rather than a ticking second count, because a number
  /// that changes while it is being read is noise, not information.
  public static func age(since date: Date, now: Date = Date()) -> String {
    guard now.timeIntervalSince(date) >= 60 else { return "just now" }
    return "\(CompactAgeFormat.string(since: date, now: now)) ago"
  }

  /// The whole line for a reading that still describes current quota.
  public static func updated(since date: Date?, now: Date = Date()) -> String {
    guard let date else { return notChecked }
    return "Updated \(age(since: date, now: now))"
  }

  /// The whole line for a reading that no longer does, naming why rather than only that it does not.
  public static func notCurrent(reason: String, since date: Date, now: Date = Date()) -> String {
    "\(reason) — last reading \(age(since: date, now: now))"
  }

  /// The one line a client shows under an observation.
  public static func observation(
    state: QuotaObservationState,
    observedAt: Date,
    now: Date = Date()
  ) -> String {
    guard state != .available else { return updated(since: observedAt, now: now) }
    return notCurrent(reason: state.label, since: observedAt, now: now)
  }

  /// The age half of a device row: `Active · last reading 5m ago`.
  public static func lastReading(since date: Date?, now: Date = Date()) -> String {
    guard let date else { return noReadings }
    return "last reading \(age(since: date, now: now))"
  }

  /// The line under a window that still has a future refill, or `nil` once that instant has passed.
  ///
  /// English is fixed; `timeZone` is the local zone the reader is in. Minutes round up, and a
  /// duration under a minute still reads as `Resets in 1m`.
  public static func resetCopy(
    resetsAt: Date,
    now: Date = Date(),
    timeZone: TimeZone = .current,
    calendar: Calendar = .current
  ) -> String? {
    let seconds = resetsAt.timeIntervalSince(now)
    guard seconds > 0 else { return nil }
    let wholeMinutes = max(1, Int((seconds / 60).rounded(.up)))
    if wholeMinutes < 60 {
      return "Resets in \(wholeMinutes)m"
    }
    if seconds < 86_400 {
      var hours = Int(seconds / 3_600)
      var minutes = Int(((seconds - TimeInterval(hours * 3_600)) / 60).rounded(.up))
      if minutes == 60 {
        hours += 1
        minutes = 0
      }
      if minutes == 0 {
        return "Resets in \(hours)h"
      }
      return "Resets in \(hours)h \(minutes)m"
    }
    var calendar = calendar
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.dateFormat = seconds < 604_800 ? "EEE HH:mm" : "MMM d"
    return "Resets \(formatter.string(from: resetsAt))"
  }
}

/// Remaining and limit as a window carries them. ``FreshnessCopy/showsNoResetTime(_:)``
/// derives the percent and meter scalars from these rather than asking the caller to
/// precompute them.
public protocol RemainingQuotaWindow {
  var usedPercent: Double { get }
  var remainingValue: Double? { get }
  var limitValue: Double? { get }
}
