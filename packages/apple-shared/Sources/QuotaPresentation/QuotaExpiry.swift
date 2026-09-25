import Foundation

/// Units of a count window that stop being usable at one instant — earned rate-limit resets a
/// provider grants with an end date. A window lists them ascending, one entry per instant; units
/// it does not list do not expire, so the window's remaining value stays the total.
public struct QuotaExpiry: Codable, Equatable, Sendable {
  public let expiresAt: Date
  public let count: Int

  public init(expiresAt: Date, count: Int) {
    self.expiresAt = expiresAt
    self.count = count
  }
}

/// When a window's units lapse, in the words both Apple products use.
///
/// `packages/protocol/fixtures/reset-copy-conformance.json` › `expiries` states these lines.
/// English is fixed; `timeZone` is the local zone the reader is in, and times are 24-hour.
public enum ExpiryCopy: Sendable {
  /// The unlisted remainder of a window that lists expiries.
  public static let noExpiry = "No expiry"

  /// The meta line under the window on a row: the nearest instant still ahead, or `nil` when the
  /// window lists none.
  public static func next(
    _ expiries: [QuotaExpiry],
    now: Date = Date(),
    timeZone: TimeZone = .current
  ) -> String? {
    guard let nearest = expiries.filter({ $0.expiresAt > now }).map(\.expiresAt).min() else {
      return nil
    }
    return "Next expires \(format(nearest, "MMM d", timeZone: timeZone))"
  }

  /// One line per instant still ahead, nearest first, then the remainder that does not expire.
  ///
  /// A window that lists nothing prints nothing: without the list there is no telling which of
  /// its units lapse. A group already past is not named, and still counts as listed, so the
  /// remainder never grows because a reading has aged.
  public static func lines(
    _ expiries: [QuotaExpiry],
    total: Double?,
    now: Date = Date(),
    timeZone: TimeZone = .current
  ) -> [String] {
    guard !expiries.isEmpty else { return [] }
    var lines =
      expiries
      .filter { $0.expiresAt > now }
      .sorted { $0.expiresAt < $1.expiresAt }
      .map { expiry in
        let verb = expiry.count == 1 ? "Expires" : "Expire"
        let when = format(expiry.expiresAt, "MMM d, HH:mm", timeZone: timeZone)
        return "\(expiry.count) · \(verb) \(when)"
      }
    let listed = expiries.reduce(0) { $0 + $1.count }
    if let total, total.isFinite, Int(total.rounded(.down)) > listed {
      lines.append("\(Int(total.rounded(.down)) - listed) · \(noExpiry)")
    }
    return lines
  }

  private static func format(_ date: Date, _ pattern: String, timeZone: TimeZone) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    calendar.locale = Locale(identifier: "en_US_POSIX")
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.calendar = calendar
    formatter.dateFormat = pattern
    return formatter.string(from: date)
  }
}
