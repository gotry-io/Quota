import Foundation
import QuotaPresentation

extension QuotaValueUnit {
  var remainingUnit: RemainingQuotaUnit {
    switch self {
    case .usd: .usd
    case .credits: .credits
    case .count: .count
    }
  }
}

extension QuotaWindow {
  var remainingPercent: Double {
    RemainingQuotaFormat.remainingPercent(usedPercent: usedPercent)
  }

  /// Wallet-style window: absolute remaining only, no budget/limit ratio.
  var isBalanceOnly: Bool {
    RemainingQuotaFormat.isBalanceOnly(
      remainingValue: remainingValue,
      hasLimit: limitValue != nil
    )
  }

  /// Rate-limit / budget meters need a percent bar. Balance-only wallets do not.
  var showsPercentMeter: Bool {
    RemainingQuotaFormat.showsPercentMeter(
      remainingValue: remainingValue,
      hasLimit: limitValue != nil
    )
  }

  /// Absolute remaining when `value_unit`/`remaining_value` are present.
  /// Balance-only rows without a unit (e.g. DeepSeek CNY) still show the number.
  var absoluteRemainingLabel: String? {
    RemainingQuotaFormat.absolute(
      remainingValue: remainingValue,
      hasLimit: limitValue != nil,
      unit: valueUnit?.remainingUnit
    )
  }

  /// Overview remaining copy. No "left" suffix; the value is remaining by product rule.
  /// Budget windows with an amount show `71% · $3.75`.
  var remainingDisplayLabel: String {
    RemainingQuotaFormat.remaining(
      remainingPercent: remainingPercent,
      remainingValue: remainingValue,
      hasLimit: limitValue != nil,
      unit: valueUnit?.remainingUnit
    )
  }

  /// Compact Overview copy. Cursor's Other Models percentage and included-usage dollars are
  /// different provider meters, so retain the dollars for a future detail surface without
  /// presenting them as one value here.
  func overviewRemainingDisplayLabel(provider: ProviderID) -> String {
    if provider == .cursor, id == "other_models" {
      return formattedRemainingPercent
    }
    return remainingDisplayLabel
  }

  var formattedRemainingPercent: String {
    RemainingQuotaFormat.percent(remainingPercent)
  }

  var displayTitle: String {
    RemainingQuotaFormat.windowTitle(title, isBalanceOnly: isBalanceOnly)
  }

  static func formattedPercent(_ value: Double) -> String {
    RemainingQuotaFormat.percent(value)
  }
}
