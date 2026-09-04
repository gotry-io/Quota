import Foundation

/// Local notification rules, stored in UserDefaults under `notifications.*`.
///
/// Thresholds are remaining-percent integers 1–99, kept descending and unique. A selector
/// that has never been edited uses `[20, 10]`.
struct NotificationRules: Equatable, Sendable {
  var enabled: Bool
  var resetReminders: Bool
  var thresholds: [String: [Int]]

  static let enabledKey = "notifications.enabled"
  static let resetRemindersKey = "notifications.resetReminders"
  static let thresholdsKey = "notifications.thresholds"

  static let defaultEnabled = false
  static let defaultResetReminders = true
  static let defaultThresholds = [20, 10]

  init(
    enabled: Bool = defaultEnabled,
    resetReminders: Bool = defaultResetReminders,
    thresholds: [String: [Int]] = [:]
  ) {
    self.enabled = enabled
    self.resetReminders = resetReminders
    self.thresholds = thresholds.mapValues(Self.normalized)
  }

  static func load(from defaults: UserDefaults = .standard) -> NotificationRules {
    let enabled = defaults.object(forKey: enabledKey) as? Bool ?? defaultEnabled
    let resetReminders = defaults.object(forKey: resetRemindersKey) as? Bool ?? defaultResetReminders
    var parsed: [String: [Int]] = [:]
    if let raw = defaults.dictionary(forKey: thresholdsKey) {
      for (selector, value) in raw {
        if let numbers = intArray(value) {
          parsed[selector] = normalized(numbers)
        }
      }
    }
    return NotificationRules(
      enabled: enabled,
      resetReminders: resetReminders,
      thresholds: parsed
    )
  }

  func save(to defaults: UserDefaults = .standard) {
    defaults.set(enabled, forKey: Self.enabledKey)
    defaults.set(resetReminders, forKey: Self.resetRemindersKey)
    defaults.set(
      thresholds.mapValues { Self.normalized($0) } as [String: Any],
      forKey: Self.thresholdsKey
    )
  }

  func thresholds(for selector: String) -> [Int] {
    Self.normalized(thresholds[selector] ?? Self.defaultThresholds)
  }

  /// Drops values outside 1–99, then unique descending. An empty result is the default pair.
  static func normalized(_ values: [Int]) -> [Int] {
    let cleaned = Array(Set(values.filter { (1...99).contains($0) })).sorted(by: >)
    return cleaned.isEmpty ? defaultThresholds : cleaned
  }

  private static func intArray(_ value: Any) -> [Int]? {
    if let ints = value as? [Int] { return ints }
    if let numbers = value as? [NSNumber] { return numbers.map(\.intValue) }
    return nil
  }
}
