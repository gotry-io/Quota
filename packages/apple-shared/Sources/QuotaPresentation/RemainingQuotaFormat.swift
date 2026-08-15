import Foundation

public enum RemainingQuotaUnit: Sendable, Equatable {
  case usd
  case credits
  case count
}

public enum RemainingQuotaFormat: Sendable {
  public static func remainingPercent(usedPercent: Double) -> Double {
    min(max(100 - usedPercent, 0), 100)
  }

  public static func isBalanceOnly(remainingValue: Double?, hasLimit: Bool) -> Bool {
    remainingValue != nil && !hasLimit
  }

  public static func showsPercentMeter(remainingValue: Double?, hasLimit: Bool) -> Bool {
    !isBalanceOnly(remainingValue: remainingValue, hasLimit: hasLimit)
  }

  public static func percent(_ value: Double) -> String {
    let remaining = min(max(value, 0), 100)
    if abs(remaining.rounded() - remaining) < 0.05 {
      return "\(Int(remaining.rounded()))%"
    }
    return String(format: "%.1f%%", remaining)
  }

  public static func absolute(
    remainingValue: Double?,
    hasLimit: Bool,
    unit: RemainingQuotaUnit?
  ) -> String? {
    guard let remainingValue else { return nil }
    if let unit {
      switch unit {
      case .usd:
        return String(format: "$%.2f", remainingValue)
      case .credits:
        return String(format: "%.2f credits", remainingValue)
      case .count:
        return String(format: "%.0f", remainingValue)
      }
    }
    if isBalanceOnly(remainingValue: remainingValue, hasLimit: hasLimit) {
      return String(format: "%.2f", remainingValue)
    }
    return nil
  }

  public static func remaining(
    remainingPercent: Double,
    remainingValue: Double?,
    hasLimit: Bool,
    unit: RemainingQuotaUnit?
  ) -> String {
    let percentLabel = percent(remainingPercent)
    guard
      let absoluteLabel = absolute(
        remainingValue: remainingValue,
        hasLimit: hasLimit,
        unit: unit
      )
    else {
      return percentLabel
    }
    if isBalanceOnly(remainingValue: remainingValue, hasLimit: hasLimit) {
      return absoluteLabel
    }
    return "\(percentLabel) · \(absoluteLabel)"
  }

  public static func windowTitle(_ title: String, isBalanceOnly: Bool) -> String {
    isBalanceOnly ? "Balance" : title
  }

  public static func remainingAccessibility(
    windowTitle: String,
    remainingLabel: String,
    isBalanceOnly: Bool
  ) -> String {
    if isBalanceOnly {
      return "\(windowTitle), \(remainingLabel)"
    }
    return "\(windowTitle), \(remainingLabel) remaining"
  }
}
