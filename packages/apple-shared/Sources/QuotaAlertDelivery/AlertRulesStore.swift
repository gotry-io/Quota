import Foundation
import QuotaAlerts

/// UserDefaults adapter for `AlertRules` under a caller-chosen key prefix.
///
/// Keys are `"\(keyPrefix).enabled"`, `.resetReminders`, `.paceAlerts`, and `.thresholds`.
/// Defaults match both apps: enabled off, reset reminders and pace warnings on, unedited
/// selectors `[20, 10]`. Each app passes its shipped prefix so persisted keys stay exactly
/// what those releases wrote.
public struct AlertRulesStore {
  public let defaults: UserDefaults
  public let keyPrefix: String

  public var enabledKey: String { "\(keyPrefix).enabled" }
  public var resetRemindersKey: String { "\(keyPrefix).resetReminders" }
  public var paceAlertsKey: String { "\(keyPrefix).paceAlerts" }
  public var thresholdsKey: String { "\(keyPrefix).thresholds" }

  public init(defaults: UserDefaults = .standard, keyPrefix: String) {
    self.defaults = defaults
    self.keyPrefix = keyPrefix
  }

  public func load() -> AlertRules {
    let enabled = defaults.object(forKey: enabledKey) as? Bool ?? AlertRules.defaultEnabled
    let resetReminders =
      defaults.object(forKey: resetRemindersKey) as? Bool ?? AlertRules.defaultResetReminders
    let paceAlerts =
      defaults.object(forKey: paceAlertsKey) as? Bool ?? AlertRules.defaultPaceAlerts
    var parsed: [String: [Int]] = [:]
    if let raw = defaults.dictionary(forKey: thresholdsKey) {
      for (selector, value) in raw {
        if let numbers = Self.intArray(value) {
          parsed[selector] = AlertRules.normalized(numbers)
        }
      }
    }
    return AlertRules(
      enabled: enabled,
      resetReminders: resetReminders,
      paceAlerts: paceAlerts,
      thresholds: parsed
    )
  }

  public func save(_ rules: AlertRules) {
    defaults.set(rules.enabled, forKey: enabledKey)
    defaults.set(rules.resetReminders, forKey: resetRemindersKey)
    defaults.set(rules.paceAlerts, forKey: paceAlertsKey)
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
