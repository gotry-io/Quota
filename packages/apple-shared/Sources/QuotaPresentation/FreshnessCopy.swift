import Foundation

/// How old a reading is, in the words every Quota client uses.
///
/// One rule, one voice. The menu bar footer, a provider row, a device row, the website, and the
/// widgets all state age relative to now, because a clock time or a calendar date makes the reader
/// do the subtraction before they learn the only thing they wanted to know.
///
/// `packages/protocol/fixtures/freshness-copy-conformance.json` is the shared statement of these
/// thresholds and phrases; this type and `apps/web/src/lib/format.ts` both answer it.
public enum FreshnessCopy: Sendable {
  /// Stands in for an age before anything has been read at all.
  public static let notChecked = "Not checked"

  /// A device the Account has never received a reading from.
  public static let noReadings = "no readings yet"

  /// One phrase for a window whose provider never says when it refills.
  public static let noResetTime = "No reset time reported"

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
}
