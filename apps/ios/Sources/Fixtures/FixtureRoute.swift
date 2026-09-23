import Foundation
import QuotaPresentation

#if DEBUG
  /// Launch-argument clock for visual fixtures. Absent means the scenario reference date.
  enum VisualClock: String, Sendable {
    case wall

    static func parse(arguments: [String]) -> VisualClock? {
      guard let index = arguments.firstIndex(of: "--visual-clock") else { return nil }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return VisualClock(rawValue: arguments[valueIndex])
    }
  }

  /// DEBUG `--route <destination>` so a UI test can open one screen without tapping through.
  enum FixtureRoute: Equatable, Sendable {
    case usageRoot
    /// Usage on Today, the period the Overview Today row opens.
    case usageToday
    /// Usage on `customRange`: a fixed custom period, so its picture is the same on every run.
    case usageCustom
    case usageBreakdown
    case usagePatterns
    case usageDay
    case subscriptionDetail(String)
    case settingsRoot
    case settingsDevices
    case settingsNotifications
    case settingsAppearance
    case settingsAbout

    static func parse(arguments: [String]) -> FixtureRoute? {
      guard let index = arguments.firstIndex(of: "--route") else { return nil }
      let valueIndex = arguments.index(after: index)
      guard valueIndex < arguments.endIndex else { return nil }
      return parse(arguments[valueIndex])
    }

    static func parse(_ raw: String) -> FixtureRoute? {
      switch raw {
      case "usage", "usage.root":
        return .usageRoot
      case "usage.today":
        return .usageToday
      case "usage.custom":
        return .usageCustom
      case "usage.breakdown":
        return .usageBreakdown
      case "usage.patterns":
        return .usagePatterns
      case "usage.day":
        return .usageDay
      case "settings", "settings.root":
        return .settingsRoot
      case "settings.devices":
        return .settingsDevices
      case "settings.notifications":
        return .settingsNotifications
      case "settings.appearance":
        return .settingsAppearance
      case "settings.about":
        return .settingsAbout
      default:
        let prefix = "subscription.detail/"
        guard raw.hasPrefix(prefix) else { return nil }
        let key = String(raw.dropFirst(prefix.count))
        return key.isEmpty ? nil : .subscriptionDetail(key)
      }
    }

    /// The fixed custom period `usage.custom` opens: six days before the fixture clock's UTC day
    /// through two days before it — August 8 to 12, 2026 on the reference date. The fixture's
    /// activity days are UTC days, so counting in UTC gives the same range, title and totals in
    /// every time zone the simulator runs in. It is not one of the named periods, so what it draws
    /// is the custom range's own.
    static func customRange(today: Date) -> UsagePeriodSelection? {
      var utc = Calendar(identifier: .gregorian)
      utc.timeZone = TimeZone(identifier: "UTC")!
      guard let from = UsagePeriodSelection.day(offset: 6).range(today: today, calendar: utc),
        let to = UsagePeriodSelection.day(offset: 2).range(today: today, calendar: utc)
      else { return nil }
      return .custom(from: from.from, to: to.to)
    }
  }
#endif
