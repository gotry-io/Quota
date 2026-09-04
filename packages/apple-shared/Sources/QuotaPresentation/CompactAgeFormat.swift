import Foundation

/// The bare compact duration behind every relative age this app shows: the largest whole unit
/// that fits, with no words around it.
///
/// ``FreshnessCopy`` turns it into how old a reading is. Reset copy is a different phrase on
/// that type: a future refill rounds minutes up and can name hours and minutes together.
public enum CompactAgeFormat: Sendable {
  public static func string(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)m" }
    if seconds < 86_400 { return "\(seconds / 3_600)h" }
    if seconds < 604_800 { return "\(seconds / 86_400)d" }
    if seconds < 31_536_000 { return "\(seconds / 604_800)w" }
    return "\(seconds / 31_536_000)y"
  }
}
