import Foundation
import QuotaPresentation
import QuotaWire

extension QuotaWindow {
  /// Overview remaining copy. No "left" suffix; the value is remaining by product rule.
  /// Budget windows with an amount show `71% · $3.75`.
  var remainingDisplayLabel: String {
    RemainingQuotaFormat.remaining(
      remainingPercent: remainingPercent,
      remainingValue: remainingValue,
      hasLimit: limitValue != nil,
      unit: valueUnit.flatMap(\.remainingUnit)
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
