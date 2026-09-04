import Foundation

/// Local remaining-quota alert rules: a master switch, reset reminders, and remaining-percent
/// thresholds keyed by subscription selector.
///
/// Thresholds are remaining-percent integers 1–99, kept descending and unique. A selector
/// that has never been edited uses `[20, 10]`. Persistence is each app's own UserDefaults.
public struct AlertRules: Equatable, Sendable {
  public var enabled: Bool
  public var resetReminders: Bool
  public var thresholds: [String: [Int]]

  public static let defaultEnabled = false
  public static let defaultResetReminders = true
  public static let defaultThresholds = [20, 10]

  public init(
    enabled: Bool = defaultEnabled,
    resetReminders: Bool = defaultResetReminders,
    thresholds: [String: [Int]] = [:]
  ) {
    self.enabled = enabled
    self.resetReminders = resetReminders
    self.thresholds = thresholds.mapValues(Self.normalized)
  }

  public func thresholds(for selector: String) -> [Int] {
    Self.normalized(thresholds[selector] ?? Self.defaultThresholds)
  }

  public mutating func setThresholds(_ values: [Int], for selector: String) {
    thresholds[selector] = Self.normalized(values)
  }

  /// Drops values outside 1–99, then unique descending. An empty result is the default pair.
  public static func normalized(_ values: [Int]) -> [Int] {
    let cleaned = Array(Set(values.filter { (1...99).contains($0) })).sorted(by: >)
    return cleaned.isEmpty ? defaultThresholds : cleaned
  }
}
