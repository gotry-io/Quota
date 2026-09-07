import Foundation

/// One hour-of-day fact a rhythm folds: the local calendar date, the hour of that date, and
/// the tokens and amount already measured for it.
public struct UsageRhythmHourFact: Equatable, Sendable {
  public var date: String
  public var hour: Int
  public var totalTokens: Int
  public var costMicrousd: String?

  public init(date: String, hour: Int, totalTokens: Int, costMicrousd: String?) {
    self.date = date
    self.hour = hour
    self.totalTokens = totalTokens
    self.costMicrousd = costMicrousd
  }
}

/// One hour of the clock, summed over every day of the period that reached it.
public struct UsageHourOfDay: Equatable, Sendable {
  public var hour: Int
  public var totalTokens: Int
  public var costMicrousd: String?

  public init(hour: Int, totalTokens: Int, costMicrousd: String?) {
    self.hour = hour
    self.totalTokens = totalTokens
    self.costMicrousd = costMicrousd
  }
}

/// The 24-hour and Sunday-first 7×24 rhythm of a list of local hour facts.
public struct UsageRhythm: Equatable, Sendable {
  public static let hoursOfDayCount = 24
  public static let weekdayCount = 7

  public var hoursOfDay: [UsageHourOfDay]
  public var weekdayHours: [[Int]]

  public init(hoursOfDay: [UsageHourOfDay], weekdayHours: [[Int]]) {
    self.hoursOfDay = hoursOfDay
    self.weekdayHours = weekdayHours
  }

  /// Sunday-first weekday of a `YYYY-MM-DD` civil date, matching the activity heatmap.
  public static func weekdaySundayFirst(_ date: String) -> Int? {
    let parts = date.split(separator: "-")
    guard parts.count == 3,
      let year = Int(parts[0]),
      let month = Int(parts[1]),
      let day = Int(parts[2])
    else { return nil }
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    guard let instant = calendar.date(from: components) else { return nil }
    return calendar.component(.weekday, from: instant) - 1
  }

  /// Every clock hour is named, including the ones nothing reached. An hour with no fact states
  /// no amount. Tokens add. Amounts add when at least one contributing fact states one.
  public static func fold(_ hours: [UsageRhythmHourFact]) -> UsageRhythm {
    var hoursOfDay = (0..<hoursOfDayCount).map {
      UsageHourOfDay(hour: $0, totalTokens: 0, costMicrousd: nil)
    }
    var weekdayHours = Array(
      repeating: Array(repeating: 0, count: hoursOfDayCount),
      count: weekdayCount
    )
    for fact in hours {
      guard (0..<hoursOfDayCount).contains(fact.hour) else { continue }
      hoursOfDay[fact.hour].totalTokens += fact.totalTokens
      hoursOfDay[fact.hour].costMicrousd = addMicrousd(
        hoursOfDay[fact.hour].costMicrousd,
        fact.costMicrousd
      )
      if let weekday = weekdaySundayFirst(fact.date), (0..<weekdayCount).contains(weekday) {
        weekdayHours[weekday][fact.hour] += fact.totalTokens
      }
    }
    return UsageRhythm(hoursOfDay: hoursOfDay, weekdayHours: weekdayHours)
  }

  private static func addMicrousd(_ left: String?, _ right: String?) -> String? {
    if left == nil, right == nil { return nil }
    let sum = (Decimal(string: left ?? "0") ?? 0) + (Decimal(string: right ?? "0") ?? 0)
    return NSDecimalNumber(decimal: sum).stringValue
  }
}
