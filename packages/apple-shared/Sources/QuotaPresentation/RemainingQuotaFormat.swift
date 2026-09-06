import Foundation

public enum RemainingQuotaUnit: Sendable, Equatable {
  case usd
  case credits
  case count
}

public enum RemainingQuotaFormat: Sendable {
  /// How far remaining/limit may drift from used_percent and still be the same quantity.
  public static let amountOfLimitPercentTolerance: Double = 1

  public static func remainingPercent(usedPercent: Double) -> Double {
    min(max(100 - usedPercent, 0), 100)
  }

  public static func isBalanceOnly(remainingValue: Double?, hasLimit: Bool) -> Bool {
    remainingValue != nil && !hasLimit
  }

  /// A usd or credits window whose remaining and limit describe the same quantity as the
  /// remaining percent. Those print remaining of limit and drop the meter.
  public static func isAmountOfLimit(
    remainingPercent: Double,
    remainingValue: Double?,
    limitValue: Double?,
    unit: RemainingQuotaUnit?
  ) -> Bool {
    guard let remainingValue, let limitValue, limitValue > 0, let unit, isAmountUnit(unit)
    else {
      return false
    }
    let fromAmount = min(max((remainingValue / limitValue) * 100, 0), 100)
    return abs(fromAmount - remainingPercent) < amountOfLimitPercentTolerance
  }

  public static func showsPercentMeter(
    remainingPercent: Double,
    remainingValue: Double?,
    limitValue: Double?,
    hasLimit: Bool,
    unit: RemainingQuotaUnit?
  ) -> Bool {
    if isAmountOfLimit(
      remainingPercent: remainingPercent,
      remainingValue: remainingValue,
      limitValue: limitValue,
      unit: unit
    ) {
      return false
    }
    return !isBalanceOnly(remainingValue: remainingValue, hasLimit: hasLimit)
  }

  public static func showsPercentMeter(remainingValue: Double?, hasLimit: Bool) -> Bool {
    showsPercentMeter(
      remainingPercent: 0,
      remainingValue: remainingValue,
      limitValue: hasLimit ? 0 : nil,
      hasLimit: hasLimit,
      unit: nil
    )
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
        return usd(remainingValue)
      case .credits:
        return "\(credits(remainingValue)) credits"
      case .count:
        return String(format: "%.0f", remainingValue)
      }
    }
    if isBalanceOnly(remainingValue: remainingValue, hasLimit: hasLimit) {
      return String(format: "%.2f", remainingValue)
    }
    return nil
  }

  public static func amountOfLimit(
    remaining: Double,
    limit: Double,
    unit: RemainingQuotaUnit
  ) -> String {
    switch unit {
    case .usd:
      return "\(usd(remaining)) of \(usd(limit))"
    case .credits:
      return "\(credits(remaining)) of \(credits(limit)) credits"
    case .count:
      return "\(String(format: "%.0f", remaining)) of \(String(format: "%.0f", limit))"
    }
  }

  public static func remaining(
    remainingPercent: Double,
    remainingValue: Double?,
    limitValue: Double? = nil,
    hasLimit: Bool,
    unit: RemainingQuotaUnit?
  ) -> String {
    if isAmountOfLimit(
      remainingPercent: remainingPercent,
      remainingValue: remainingValue,
      limitValue: limitValue,
      unit: unit
    ), let remainingValue, let limitValue, let unit
    {
      return amountOfLimit(remaining: remainingValue, limit: limitValue, unit: unit)
    }
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
    if isBalanceOnly, title.lowercased().hasPrefix("balance") {
      return "Balance"
    }
    return title
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

  private static func isAmountUnit(_ unit: RemainingQuotaUnit) -> Bool {
    switch unit {
    case .usd, .credits: true
    case .count: false
    }
  }

  private static func usd(_ value: Double) -> String {
    String(format: "$%.2f", value)
  }

  private static func credits(_ value: Double) -> String {
    String(format: "%.2f", value)
  }
}
