import Foundation

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
  }
#endif
