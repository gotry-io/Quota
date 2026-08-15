import Foundation

public enum CompactAgeFormat: Sendable {
  public static func string(since date: Date, now: Date = Date()) -> String {
    let seconds = max(0, Int(now.timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3_600 { return "\(seconds / 60)min" }
    if seconds < 86_400 { return "\(seconds / 3_600)h" }
    if seconds < 604_800 { return "\(seconds / 86_400)d" }
    if seconds < 31_536_000 { return "\(seconds / 604_800)w" }
    return "\(seconds / 31_536_000)y"
  }
}
