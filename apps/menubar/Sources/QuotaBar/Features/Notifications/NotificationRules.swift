import Foundation
import QuotaAlerts

/// UserDefaults adapter for `AlertRules` under `notifications.*`.
///
/// Thresholds are remaining-percent integers 1–99, kept descending and unique by `AlertRules`.
/// Remaining-percent choices the Notifications page offers live here; the second slot may be Off.
enum NotificationRules {
  static let enabledKey = "notifications.enabled"
  static let resetRemindersKey = "notifications.resetReminders"
  static let thresholdsKey = "notifications.thresholds"

  /// Remaining-percent choices the Notifications page offers. The second slot may be Off.
  static let thresholdChoices = [5, 10, 15, 20, 25, 30, 40, 50]

  static func load(from defaults: UserDefaults = .standard) -> AlertRules {
    let enabled = defaults.object(forKey: enabledKey) as? Bool ?? AlertRules.defaultEnabled
    let resetReminders =
      defaults.object(forKey: resetRemindersKey) as? Bool ?? AlertRules.defaultResetReminders
    var parsed: [String: [Int]] = [:]
    if let raw = defaults.dictionary(forKey: thresholdsKey) {
      for (selector, value) in raw {
        if let numbers = intArray(value) {
          parsed[selector] = AlertRules.normalized(numbers)
        }
      }
    }
    return AlertRules(
      enabled: enabled,
      resetReminders: resetReminders,
      thresholds: parsed
    )
  }

  static func save(_ rules: AlertRules, to defaults: UserDefaults = .standard) {
    defaults.set(rules.enabled, forKey: enabledKey)
    defaults.set(rules.resetReminders, forKey: resetRemindersKey)
    defaults.set(
      rules.thresholds.mapValues { AlertRules.normalized($0) } as [String: Any],
      forKey: thresholdsKey
    )
  }

  private static func intArray(_ value: Any) -> [Int]? {
    if let ints = value as? [Int] { return ints }
    if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
    return nil
  }
}
