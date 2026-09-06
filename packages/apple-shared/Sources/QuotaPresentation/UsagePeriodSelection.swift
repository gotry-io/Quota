import Foundation

/// Which period a Usage page is showing.
///
/// Three of these are anchored to the device's own calendar and step: a day, a week, and a month,
/// each an offset back from the current one. Two are the trailing windows an Account summary
/// already folds, `all` is everything retained, and `custom` is a range someone picked. The
/// phrases are in `apps/menubar/DESIGN.md` Shared product vocabulary.
public enum UsagePeriodSelection: Equatable, Hashable, Sendable {
  case day(offset: Int)
  case week(offset: Int)
  case month(offset: Int)
  case last7Days
  case last30Days
  case all
  case custom(from: String, to: String)

  public static let today = Self.day(offset: 0)
  public static let thisWeek = Self.week(offset: 0)
  public static let thisMonth = Self.month(offset: 0)

  /// The segments a period selector draws, in the order it draws them.
  public static let segments: [UsagePeriodSegment] = UsagePeriodSegment.allCases

  public var segment: UsagePeriodSegment {
    switch self {
    case .day: .day
    case .week: .week
    case .month: .month
    case .last7Days: .last7Days
    case .last30Days: .last30Days
    case .all: .all
    case .custom: .custom
    }
  }

  /// The four an Account summary already carries, which are read rather than folded again.
  public var summaryKey: UsageSummaryPeriodKey? {
    switch self {
    case .day(0): .today
    case .last7Days: .last7Days
    case .last30Days: .last30Days
    case .all: .all
    default: nil
    }
  }

  /// The dates this period covers, or nil for `all`, which has no first day to name.
  ///
  /// The two dates are inclusive, and are written the way every Usage read names a range.
  public func range(today: Date, calendar: Calendar = .current) -> (from: String, to: String)? {
    switch self {
    case .day(let offset):
      guard let day = calendar.date(byAdding: .day, value: -offset, to: startOfDay(today, calendar))
      else { return nil }
      let text = UsageDateText.date(day, calendar)
      return (from: text, to: text)
    case .week(let offset):
      guard let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: startOfWeek(today, calendar)),
        let end = calendar.date(byAdding: .day, value: 6, to: start)
      else { return nil }
      return (from: UsageDateText.date(start, calendar), to: UsageDateText.date(end, calendar))
    case .month(let offset):
      guard let start = calendar.date(byAdding: .month, value: -offset, to: startOfMonth(today, calendar)),
        let next = calendar.date(byAdding: .month, value: 1, to: start),
        let end = calendar.date(byAdding: .day, value: -1, to: next)
      else { return nil }
      return (from: UsageDateText.date(start, calendar), to: UsageDateText.date(end, calendar))
    case .last7Days:
      return trailing(days: 7, today: today, calendar: calendar)
    case .last30Days:
      return trailing(days: 30, today: today, calendar: calendar)
    case .all:
      return nil
    case .custom(let from, let to):
      return (from: from, to: to)
    }
  }

  /// The period one unit before this one, or nil where stepping means nothing.
  public var previous: UsagePeriodSelection? {
    switch self {
    case .day(let offset): .day(offset: offset + 1)
    case .week(let offset): .week(offset: offset + 1)
    case .month(let offset): .month(offset: offset + 1)
    default: nil
    }
  }

  /// The period one unit after this one. The current one is the last: there is nothing ahead.
  public var next: UsagePeriodSelection? {
    switch self {
    case .day(let offset): offset > 0 ? .day(offset: offset - 1) : nil
    case .week(let offset): offset > 0 ? .week(offset: offset - 1) : nil
    case .month(let offset): offset > 0 ? .month(offset: offset - 1) : nil
    default: nil
    }
  }

  /// The segment's period, keeping an anchored one at the current day, week, or month.
  public static func selection(
    for segment: UsagePeriodSegment,
    custom: (from: String, to: String)?
  ) -> UsagePeriodSelection {
    switch segment {
    case .day: .day(offset: 0)
    case .week: .week(offset: 0)
    case .month: .month(offset: 0)
    case .last7Days: .last7Days
    case .last30Days: .last30Days
    case .all: .all
    case .custom: custom.map { .custom(from: $0.from, to: $0.to) } ?? .last30Days
    }
  }

  private func trailing(days: Int, today: Date, calendar: Calendar) -> (from: String, to: String)? {
    let end = startOfDay(today, calendar)
    guard let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) else { return nil }
    return (from: UsageDateText.date(start, calendar), to: UsageDateText.date(end, calendar))
  }

  private func startOfDay(_ date: Date, _ calendar: Calendar) -> Date {
    calendar.startOfDay(for: date)
  }

  private func startOfWeek(_ date: Date, _ calendar: Calendar) -> Date {
    let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
    return calendar.date(from: components) ?? startOfDay(date, calendar)
  }

  private func startOfMonth(_ date: Date, _ calendar: Calendar) -> Date {
    let components = calendar.dateComponents([.year, .month], from: date)
    return calendar.date(from: components) ?? startOfDay(date, calendar)
  }
}

/// The four periods an Account summary carries, keyed the way its wire object keys them.
public enum UsageSummaryPeriodKey: String, Sendable {
  case today
  case last7Days = "last_7_days"
  case last30Days = "last_30_days"
  case all
}

/// One button of the period selector.
public enum UsagePeriodSegment: String, CaseIterable, Identifiable, Sendable {
  case day
  case week
  case month
  case last7Days
  case last30Days
  case all
  case custom

  public var id: Self { self }

  /// The segment's own label, which is short enough for a six-wide control.
  public var title: String {
    switch self {
    case .day: "Day"
    case .week: "Week"
    case .month: "Month"
    case .last7Days: "7D"
    case .last30Days: "30D"
    case .all: "All"
    case .custom: "Custom"
    }
  }

  /// What the segment is called in full, which is what VoiceOver says and what a title reads.
  public var accessibilityTitle: String {
    switch self {
    case .day: "Today"
    case .week: "This week"
    case .month: "This month"
    case .last7Days: "Last 7 days"
    case .last30Days: "Last 30 days"
    case .all: "All"
    case .custom: "Custom range"
    }
  }

  /// Whether this segment's period steps a unit at a time.
  public var steps: Bool {
    switch self {
    case .day, .week, .month: true
    case .last7Days, .last30Days, .all, .custom: false
    }
  }
}

/// The dates a Usage read names, as text, and the phrases a period title is written from.
public enum UsageDateText: Sendable {
  /// `YYYY-MM-DD` in the given calendar's time zone.
  public static func date(_ value: Date, _ calendar: Calendar = .current) -> String {
    let parts = calendar.dateComponents([.year, .month, .day], from: value)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static func date(from text: String, _ calendar: Calendar = .current) -> Date? {
    let parts = text.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2])
    else { return nil }
    return calendar.date(from: DateComponents(year: year, month: month, day: day))
  }

  /// How many days a range covers, both ends included.
  public static func days(
    from: String,
    to: String,
    _ calendar: Calendar = .current
  ) -> Int? {
    guard let from = date(from: from, calendar), let to = date(from: to, calendar) else {
      return nil
    }
    guard let days = calendar.dateComponents([.day], from: from, to: to).day else { return nil }
    return days + 1
  }
}

/// The title a Usage page shows above a period: the range it covers, written for people.
///
/// A single day is that date. A range inside one year drops the repeated year from its first
/// half. `all` has no first day, so it says so instead of naming one.
public enum UsagePeriodTitle: Sendable {
  public static func text(
    for selection: UsagePeriodSelection,
    today: Date,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    guard let range = selection.range(today: today, calendar: calendar) else { return "Everything kept" }
    guard let from = UsageDateText.date(from: range.from, calendar),
      let to = UsageDateText.date(from: range.to, calendar)
    else { return "\(range.from) – \(range.to)" }
    if range.from == range.to { return full(from, calendar, locale) }
    let sameYear = calendar.component(.year, from: from) == calendar.component(.year, from: to)
    return "\(sameYear ? short(from, calendar, locale) : full(from, calendar, locale)) – \(full(to, calendar, locale))"
  }

  private static func full(_ date: Date, _ calendar: Calendar, _ locale: Locale) -> String {
    formatted(date, calendar, locale, template: "MMMd y")
  }

  private static func short(_ date: Date, _ calendar: Calendar, _ locale: Locale) -> String {
    formatted(date, calendar, locale, template: "MMMd")
  }

  private static func formatted(
    _ date: Date,
    _ calendar: Calendar,
    _ locale: Locale,
    template: String
  ) -> String {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.locale = locale
    formatter.timeZone = calendar.timeZone
    formatter.setLocalizedDateFormatFromTemplate(template)
    return formatter.string(from: date)
  }
}
