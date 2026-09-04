import Foundation
import QuotaAlerts

/// UserDefaults adapter for `AlertRules` under `alerts.*`.
///
/// Defaults match QuotaBar: enabled off, reset reminders on, unedited selectors `[20, 10]`.
struct IOSAlertRulesStore {
  static let enabledKey = "alerts.enabled"
  static let resetRemindersKey = "alerts.resetReminders"
  static let thresholdsKey = "alerts.thresholds"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func load() -> AlertRules {
    let enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? AlertRules.defaultEnabled
    let resetReminders =
      defaults.object(forKey: Self.resetRemindersKey) as? Bool ?? AlertRules.defaultResetReminders
    var parsed: [String: [Int]] = [:]
    if let raw = defaults.dictionary(forKey: Self.thresholdsKey) {
      for (selector, value) in raw {
        if let numbers = Self.intArray(value) {
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

  func save(_ rules: AlertRules) {
    defaults.set(rules.enabled, forKey: Self.enabledKey)
    defaults.set(rules.resetReminders, forKey: Self.resetRemindersKey)
    defaults.set(
      rules.thresholds.mapValues { AlertRules.normalized($0) } as [String: Any],
      forKey: Self.thresholdsKey
    )
  }

  private static func intArray(_ value: Any) -> [Int]? {
    if let ints = value as? [Int] { return ints }
    if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
    return nil
  }
}
